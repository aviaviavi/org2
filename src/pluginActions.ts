/**
 * Context-aware plugin actions and lifecycle hooks.
 *
 * Actions run against a person's current selection (a note, heading, chat
 * thread, durable run, or approval). Hooks run when an activity event such as
 * `run.blocked` or `thread.reply-received` occurs. Neither can change the
 * corpus directly:
 *
 * - the plugin receives the selected object as JSON, not a writable corpus;
 * - on macOS it runs under a `sandbox-exec` profile that denies writes to the
 *   corpus and plugin trust store, denies corpus reads unless the manifest
 *   requests `read-corpus`, and denies network unless it requests `network`;
 * - it returns *proposals* (exact-text edits, new files under `views/`, chat
 *   posts, run comments) that are stored as pending records under
 *   `.org2/plugin-proposals/` and change the corpus only when a person applies
 *   them with `org2 plugin proposals apply ID --apply` or OpenOrg's review
 *   sheet.
 */
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { addAgentRunComment, loadAgentRun, loadAgentRunSnapshot, saveAgentRun } from "./agentRun.js";
import { explainActivity } from "./activityState.js";
import { activityEventHistory, followActivityEvents, type ActivityEvent } from "./activityEvents.js";
import { queueAIChatInboxMessage } from "./aiChatInbox.js";
import { guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { findOpenClawThread, loadOpenClawThreadState, openClawDateMilliseconds } from "./openClawThreadState.js";
import {
  ORG2_PLUGIN_ACTION_CONTEXTS,
  assertPluginEngineCompatible,
  isPluginTrusted,
  org2PluginHome,
  pluginEntryPath,
  pluginEnvironment,
  readPluginLock,
  verifyPluginStore,
  type Org2PluginActionCapability,
  type Org2PluginActionContext,
  type Org2PluginActionContribution,
  type Org2PluginHookContribution,
  type Org2PluginLockEntry,
} from "./pluginRuntime.js";
import { buildUnifiedDiff } from "./unifiedDiff.js";

export const ORG2_PLUGIN_ACTION_INVOCATION_SCHEMA = "org2:plugin-action-invocation:v1" as const;
export const ORG2_PLUGIN_ACTION_RESULT_SCHEMA = "org2:plugin-action-result:v1" as const;
export const ORG2_PLUGIN_PROPOSAL_SCHEMA = "org2:plugin-proposal:v1" as const;
export const ORG2_PLUGIN_ACTION_LIST_SCHEMA = "org2:plugin-action-list:v1" as const;

const MAX_CONTEXT_TEXT = 200_000;
const MAX_PROPOSALS = 50;
const MAX_PROPOSAL_TEXT = 500_000;

export type PluginProposalChange =
  | { kind: "edit"; path: string; find: string; replace: string; expectedSha256?: string; summary?: string }
  | { kind: "create"; path: string; content: string; summary?: string }
  | { kind: "thread-post"; threadId: string; message: string; summary?: string }
  | { kind: "run-comment"; runId: string; body: string; summary?: string };

export interface PluginActionContextRef {
  kind: Org2PluginActionContext;
  file?: string;
  line?: number;
  threadId?: string;
  runId?: string;
  approvalId?: string;
}

export interface PluginProposalRecord {
  schema: typeof ORG2_PLUGIN_PROPOSAL_SCHEMA;
  id: string;
  createdAt: string;
  status: "pending" | "applied" | "dismissed" | "failed";
  source: {
    kind: "action" | "hook";
    pluginId: string;
    pluginName: string;
    pluginVersion: string;
    contentHash: string;
    contributionId: string;
    title: string;
    event?: { id: string; type: string; at: string; subject: ActivityEvent["subject"] };
  };
  context?: PluginActionContextRef;
  text?: string;
  proposals: PluginProposalChange[];
  sandbox: "macos-sandbox-exec" | "none";
  decidedAt?: string;
  decidedBy?: string;
  results?: Array<{ index: number; ok: boolean; detail: string }>;
}

type JSONRecord = Record<string, unknown>;

function isRecord(value: unknown): value is JSONRecord {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function boundedText(value: string, limit = MAX_CONTEXT_TEXT): string {
  return value.length > limit ? `${value.slice(0, limit)}\n…[truncated]` : value;
}

// MARK: - Discovery

export interface PluginActionDescriptor {
  id: string;
  pluginId: string;
  pluginName: string;
  actionId: string;
  title: string;
  description?: string;
  contexts: Org2PluginActionContext[];
  capabilities: Org2PluginActionCapability[];
  trusted: boolean;
}

export interface PluginHookDescriptor {
  id: string;
  pluginId: string;
  pluginName: string;
  hookId: string;
  description?: string;
  events: string[];
  capabilities: Org2PluginActionCapability[];
  trusted: boolean;
}

export function listPluginActions(corpusRoot: string, context?: Org2PluginActionContext): PluginActionDescriptor[] {
  const lock = readPluginLock(corpusRoot);
  return lock.plugins.flatMap((entry) => (entry.manifest.contributes?.actions ?? [])
    .filter((action) => !context || action.contexts.includes(context))
    .map((action) => ({
      id: `${entry.id}:${action.id}`,
      pluginId: entry.id,
      pluginName: entry.name,
      actionId: action.id,
      title: action.title,
      ...(action.description ? { description: action.description } : {}),
      contexts: action.contexts,
      capabilities: action.capabilities ?? [],
      trusted: isPluginTrusted(entry.contentHash),
    })));
}

export function listPluginHooks(corpusRoot: string): PluginHookDescriptor[] {
  const lock = readPluginLock(corpusRoot);
  return lock.plugins.flatMap((entry) => (entry.manifest.contributes?.hooks ?? []).map((hook) => ({
    id: `${entry.id}:${hook.id}`,
    pluginId: entry.id,
    pluginName: entry.name,
    hookId: hook.id,
    ...(hook.description ? { description: hook.description } : {}),
    events: hook.events,
    capabilities: hook.capabilities ?? [],
    trusted: isPluginTrusted(entry.contentHash),
  })));
}

function selectAction(corpusRoot: string, selector: string): { entry: Org2PluginLockEntry; action: Org2PluginActionContribution } {
  const separator = selector.indexOf(":");
  if (separator < 1) throw new Error("action selector must be PLUGIN_ID:ACTION_ID");
  const pluginId = selector.slice(0, separator).toLowerCase();
  const actionId = selector.slice(separator + 1).toLowerCase();
  const entry = readPluginLock(corpusRoot).plugins.find((item) => item.id === pluginId);
  if (!entry) throw new Error(`plugin ${pluginId} is not locked in this corpus`);
  const action = entry.manifest.contributes?.actions?.find((item) => item.id === actionId);
  if (!action) throw new Error(`plugin ${pluginId} does not contribute action ${actionId}`);
  return { entry, action };
}

// MARK: - Context

function corpusRelative(corpusRoot: string, file: string): string {
  const absolute = path.resolve(corpusRoot, file);
  const relative = path.relative(corpusRoot, absolute);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) throw new Error(`file is outside the corpus: ${file}`);
  return relative.split(path.sep).join("/");
}

const HEADING_PATTERN = /^(\*+)\s+(.*?)\s*$/u;

function headingAt(lines: string[], line: number): { start: number; end: number; level: number } | null {
  let start = Math.min(Math.max(1, line), lines.length);
  while (start >= 1 && !HEADING_PATTERN.test(lines[start - 1]!)) start -= 1;
  if (start < 1) return null;
  const level = HEADING_PATTERN.exec(lines[start - 1]!)![1]!.length;
  let end = start;
  while (end < lines.length) {
    const match = HEADING_PATTERN.exec(lines[end]!);
    if (match && match[1]!.length <= level) break;
    end += 1;
  }
  return { start, end, level };
}

function parseHeadingLine(raw: string): { todo?: string; priority?: string; title: string; tags: string[] } {
  let rest = HEADING_PATTERN.exec(raw)?.[2] ?? raw;
  let tags: string[] = [];
  const tagMatch = /\s+(:[^\s:]+(?::[^\s:]+)*:)$/u.exec(rest);
  if (tagMatch) {
    tags = tagMatch[1]!.split(":").filter(Boolean);
    rest = rest.slice(0, tagMatch.index);
  }
  let todo: string | undefined;
  const todoMatch = /^([A-Z][A-Z_]+)\s+/u.exec(rest);
  if (todoMatch) { todo = todoMatch[1]; rest = rest.slice(todoMatch[0].length); }
  let priority: string | undefined;
  const priorityMatch = /^\[#([A-Z0-9])\]\s*/u.exec(rest);
  if (priorityMatch) { priority = priorityMatch[1]; rest = rest.slice(priorityMatch[0].length); }
  return { ...(todo ? { todo } : {}), ...(priority ? { priority } : {}), title: rest.trim(), tags };
}

function propertiesIn(lines: string[]): Record<string, string> {
  const properties: Record<string, string> = {};
  const start = lines.findIndex((line) => line.trim().toUpperCase() === ":PROPERTIES:");
  if (start < 0) return properties;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index]!.trim();
    if (line.toUpperCase() === ":END:") break;
    const match = /^:([^:\s]+):\s*(.*)$/u.exec(line);
    if (match) properties[match[1]!] = match[2]!;
  }
  return properties;
}

/** Builds the JSON a plugin receives for a selection. Only the selected object is included. */
export function buildPluginActionContext(corpusRoot: string, ref: PluginActionContextRef): JSONRecord {
  if (!(ORG2_PLUGIN_ACTION_CONTEXTS as readonly string[]).includes(ref.kind)) throw new Error(`unsupported action context: ${ref.kind}`);
  if (ref.kind === "note" || ref.kind === "heading") {
    if (!ref.file) throw new Error(`${ref.kind} context requires --file`);
    const relative = corpusRelative(corpusRoot, ref.file);
    const snapshot = readGuardedFile(path.join(corpusRoot, relative));
    const lines = snapshot.content.split("\n");
    const title = /^#\+TITLE:\s*(.+)$/imu.exec(snapshot.content)?.[1]?.trim() ?? path.basename(relative, path.extname(relative));
    if (ref.kind === "note") {
      return { kind: "note", file: relative, title, revision: snapshot.revision, text: boundedText(snapshot.content) };
    }
    const heading = headingAt(lines, ref.line ?? 1);
    if (!heading) throw new Error(`no heading at or above ${relative}:${ref.line ?? 1}`);
    const subtree = lines.slice(heading.start - 1, heading.end);
    const parsed = parseHeadingLine(lines[heading.start - 1]!);
    return {
      kind: "heading",
      file: relative,
      noteTitle: title,
      line: heading.start,
      endLine: heading.end,
      level: heading.level,
      ...parsed,
      properties: propertiesIn(subtree.slice(1, 12)),
      revision: snapshot.revision,
      text: boundedText(subtree.join("\n")),
    };
  }
  if (ref.kind === "thread") {
    if (!ref.threadId) throw new Error("thread context requires --thread");
    const state = loadOpenClawThreadState(corpusRoot, { hydrateThreadID: ref.threadId });
    const thread = findOpenClawThread(state, ref.threadId);
    if (!thread) throw new Error(`unknown chat thread: ${ref.threadId}`);
    const explanation = explainActivity(corpusRoot, { thread: ref.threadId }).items[0];
    return {
      kind: "thread",
      id: thread.id,
      title: thread.title ?? "Untitled chat",
      runtime: thread.runtime ?? null,
      explanation,
      messages: (thread.messages ?? []).slice(-20).map((message) => ({
        id: message.id ?? null,
        role: message.role ?? null,
        author: message.authorLabel ?? null,
        createdAt: typeof message.createdAt === "number" || typeof message.createdAt === "string"
          ? new Date(openClawDateMilliseconds(message.createdAt)).toISOString()
          : null,
        content: boundedText(String(message.content ?? ""), 8_000),
      })),
    };
  }
  const runId = ref.runId;
  if (!runId) throw new Error(`${ref.kind} context requires --run`);
  const run = loadAgentRun(corpusRoot, runId);
  const explanation = explainActivity(corpusRoot, { run: runId }).items[0];
  const runContext = { ...run, events: run.events.slice(-50) };
  if (ref.kind === "run") return { kind: "run", run: runContext, explanation };
  const approval = run.approvals.find((item) => item.id === ref.approvalId) ?? run.approvals.find((item) => item.status === "pending");
  if (!approval) throw new Error(`run ${runId} has no ${ref.approvalId ? `approval ${ref.approvalId}` : "pending approval"}`);
  return { kind: "approval", approval, run: runContext, explanation };
}

// MARK: - Sandboxed invocation

function sandboxString(value: string): string {
  return `"${value.replace(/\\/gu, "\\\\").replace(/"/gu, '\\"')}"`;
}

export function pluginSandboxProfile(corpusRoot: string, capabilities: readonly Org2PluginActionCapability[]): string {
  const corpus = fs.realpathSync(path.resolve(corpusRoot));
  const home = path.resolve(org2PluginHome());
  const rules = [
    "(version 1)",
    "(allow default)",
    `(deny file-write* (subpath ${sandboxString(corpus)}))`,
    `(deny file-write* (subpath ${sandboxString(home)}))`,
  ];
  if (fs.existsSync(home)) rules.push(`(deny file-write* (subpath ${sandboxString(fs.realpathSync(home))}))`);
  if (!capabilities.includes("read-corpus")) rules.push(`(deny file-read* (subpath ${sandboxString(corpus)}))`);
  if (!capabilities.includes("network")) rules.push("(deny network*)");
  return rules.join("\n");
}

const SANDBOX_EXEC = "/usr/bin/sandbox-exec";

export function pluginSandboxAvailable(): boolean {
  return process.platform === "darwin" && fs.existsSync(SANDBOX_EXEC);
}

export function invokePluginSandboxed(
  corpusRoot: string,
  entry: Org2PluginLockEntry,
  relativeEntry: string,
  capabilities: readonly Org2PluginActionCapability[],
  invocation: JSONRecord,
  timeoutMs = 20_000,
): { result: JSONRecord; sandbox: PluginProposalRecord["sandbox"] } {
  assertPluginEngineCompatible(entry.manifest);
  if (!isPluginTrusted(entry.contentHash)) throw new Error(`plugin ${entry.id} is not trusted on this machine; run org2 plugin trust ${entry.id} --apply after reviewing it`);
  const stored = verifyPluginStore(entry);
  if (!stored.valid) throw new Error(`plugin ${entry.id} is unavailable: ${stored.issue}`);
  const executable = pluginEntryPath(stored.root, relativeEntry);
  const sandboxed = pluginSandboxAvailable();
  const command = sandboxed ? SANDBOX_EXEC : process.execPath;
  const args = sandboxed ? ["-p", pluginSandboxProfile(corpusRoot, capabilities), process.execPath, executable] : [executable];
  const environment = pluginEnvironment(entry.manifest, entry);
  if (capabilities.includes("read-corpus")) environment.ORG2_CORPUS_ROOT = path.resolve(corpusRoot);
  const child = spawnSync(command, args, {
    cwd: stored.root,
    env: environment,
    input: `${JSON.stringify(invocation)}\n`,
    encoding: "utf8",
    timeout: Math.max(100, Math.min(120_000, timeoutMs)),
    maxBuffer: 2 * 1024 * 1024,
  });
  if (child.error) throw child.error;
  if (child.status !== 0) {
    const detail = String(child.stderr || child.stdout || "").trim().slice(0, 1_000);
    throw new Error(`plugin ${entry.id} exited with status ${child.status}${detail ? `: ${detail}` : ""}`);
  }
  const output = String(child.stdout || "").trim();
  if (!output) throw new Error(`plugin ${entry.id} returned no result`);
  let parsed: unknown;
  try { parsed = JSON.parse(output); } catch { throw new Error(`plugin ${entry.id} returned invalid JSON`); }
  if (!isRecord(parsed)) throw new Error(`plugin ${entry.id} result must be an object`);
  return { result: parsed, sandbox: sandboxed ? "macos-sandbox-exec" : "none" };
}

// MARK: - Proposals

function requiredText(value: unknown, label: string, limit = MAX_PROPOSAL_TEXT): string {
  if (typeof value !== "string") throw new Error(`${label} must be a string`);
  if (value.length > limit) throw new Error(`${label} is too large`);
  return value;
}

function optionalSummary(value: unknown): { summary?: string } {
  return typeof value === "string" && value.trim() ? { summary: value.trim().slice(0, 500) } : {};
}

function proposalPath(corpusRoot: string, raw: unknown, label: string): string {
  const relative = corpusRelative(corpusRoot, requiredText(raw, label, 4096));
  if (relative.split("/").some((part) => part.startsWith("."))) throw new Error(`${label} must not target hidden or machine-managed paths: ${relative}`);
  return relative;
}

export function normalizePluginProposals(corpusRoot: string, raw: unknown): PluginProposalChange[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) throw new Error("proposals must be an array");
  if (raw.length > MAX_PROPOSALS) throw new Error(`a plugin may return at most ${MAX_PROPOSALS} proposals`);
  return raw.map((item, index): PluginProposalChange => {
    if (!isRecord(item)) throw new Error(`proposals[${index}] must be an object`);
    const label = `proposals[${index}]`;
    switch (item.kind) {
      case "edit": {
        const find = requiredText(item.find, `${label}.find`);
        if (!find) throw new Error(`${label}.find must not be empty`);
        return {
          kind: "edit",
          path: proposalPath(corpusRoot, item.path, `${label}.path`),
          find,
          replace: requiredText(item.replace, `${label}.replace`),
          ...(typeof item.expectedSha256 === "string" && /^[a-f0-9]{64}$/u.test(item.expectedSha256) ? { expectedSha256: item.expectedSha256 } : {}),
          ...optionalSummary(item.summary),
        };
      }
      case "create": {
        const target = proposalPath(corpusRoot, item.path, `${label}.path`);
        if (!target.startsWith("views/")) throw new Error(`${label}.path must be under views/ (a reviewable zone); promote it into notes/ explicitly`);
        return { kind: "create", path: target, content: requiredText(item.content, `${label}.content`), ...optionalSummary(item.summary) };
      }
      case "thread-post":
        return { kind: "thread-post", threadId: requiredText(item.threadId, `${label}.threadId`, 200), message: requiredText(item.message, `${label}.message`, 100_000), ...optionalSummary(item.summary) };
      case "run-comment":
        return { kind: "run-comment", runId: requiredText(item.runId, `${label}.runId`, 200), body: requiredText(item.body, `${label}.body`, 100_000), ...optionalSummary(item.summary) };
      default:
        throw new Error(`${label}.kind must be edit, create, thread-post, or run-comment`);
    }
  });
}

export function pluginProposalDirectory(corpusRoot: string): string {
  return path.join(path.resolve(corpusRoot), ".org2", "plugin-proposals");
}

function proposalFile(corpusRoot: string, id: string): string {
  if (!/^[A-Za-z0-9-]{8,80}$/u.test(id)) throw new Error(`invalid proposal id: ${id}`);
  return path.join(pluginProposalDirectory(corpusRoot), `${id}.json`);
}

function writeProposal(corpusRoot: string, record: PluginProposalRecord, expectedRevision?: string | null): void {
  const file = proposalFile(corpusRoot, record.id);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  guardedWriteFile(file, `${JSON.stringify(record, null, 2)}\n`, { expectedRevision });
}

export function loadPluginProposal(corpusRoot: string, id: string): { record: PluginProposalRecord; revision: string } {
  const snapshot = readGuardedFile(proposalFile(corpusRoot, id));
  const record = JSON.parse(snapshot.content) as PluginProposalRecord;
  if (record.schema !== ORG2_PLUGIN_PROPOSAL_SCHEMA) throw new Error(`not a plugin proposal: ${id}`);
  return { record, revision: snapshot.revision };
}

export function listPluginProposals(corpusRoot: string, status?: PluginProposalRecord["status"]): PluginProposalRecord[] {
  const directory = pluginProposalDirectory(corpusRoot);
  let names: string[] = [];
  try { names = fs.readdirSync(directory).filter((name) => name.endsWith(".json")); } catch { return []; }
  return names.flatMap((name) => {
    try {
      const record = JSON.parse(fs.readFileSync(path.join(directory, name), "utf8")) as PluginProposalRecord;
      return record.schema === ORG2_PLUGIN_PROPOSAL_SCHEMA && (!status || record.status === status) ? [record] : [];
    } catch {
      return [];
    }
  }).sort((lhs, rhs) => rhs.createdAt.localeCompare(lhs.createdAt));
}

function resultFromPlugin(corpusRoot: string, entry: Org2PluginLockEntry, raw: JSONRecord): { text?: string; proposals: PluginProposalChange[] } {
  if (raw.$schema !== ORG2_PLUGIN_ACTION_RESULT_SCHEMA) throw new Error(`plugin ${entry.id} must return ${ORG2_PLUGIN_ACTION_RESULT_SCHEMA}`);
  if (raw.ok !== true) throw new Error(typeof raw.error === "string" ? `plugin ${entry.id}: ${raw.error}` : `plugin ${entry.id} reported failure`);
  return {
    ...(typeof raw.text === "string" && raw.text.trim() ? { text: raw.text.slice(0, 20_000) } : {}),
    proposals: normalizePluginProposals(corpusRoot, raw.proposals),
  };
}

export interface RunPluginActionResult {
  schema: "org2:plugin-action-run:v1";
  action: string;
  text?: string;
  proposal: PluginProposalRecord | null;
}

/** Runs an action against a selection and records any proposals as pending. */
export function runPluginAction(corpusRootRaw: string, selector: string, ref: PluginActionContextRef, options: { now?: Date } = {}): RunPluginActionResult {
  const corpusRoot = path.resolve(corpusRootRaw);
  const { entry, action } = selectAction(corpusRoot, selector);
  if (!action.contexts.includes(ref.kind)) throw new Error(`action ${selector} does not support ${ref.kind} selections (supports ${action.contexts.join(", ")})`);
  const context = buildPluginActionContext(corpusRoot, ref);
  const { result, sandbox } = invokePluginSandboxed(corpusRoot, entry, action.entry, action.capabilities ?? [], {
    $schema: ORG2_PLUGIN_ACTION_INVOCATION_SCHEMA,
    kind: "action",
    plugin: { id: entry.id, version: entry.version, contentHash: entry.contentHash },
    contribution: { id: action.id, title: action.title },
    capabilities: action.capabilities ?? [],
    context,
  });
  const normalized = resultFromPlugin(corpusRoot, entry, result);
  const now = options.now ?? new Date();
  const proposal: PluginProposalRecord | null = normalized.proposals.length ? {
    schema: ORG2_PLUGIN_PROPOSAL_SCHEMA,
    id: crypto.randomUUID(),
    createdAt: now.toISOString(),
    status: "pending",
    source: { kind: "action", pluginId: entry.id, pluginName: entry.name, pluginVersion: entry.version, contentHash: entry.contentHash, contributionId: action.id, title: action.title },
    context: ref,
    ...(normalized.text ? { text: normalized.text } : {}),
    proposals: normalized.proposals,
    sandbox,
  } : null;
  if (proposal) writeProposal(corpusRoot, proposal, null);
  return { schema: "org2:plugin-action-run:v1", action: selector, ...(normalized.text ? { text: normalized.text } : {}), proposal };
}

export interface PluginProposalChangePreview {
  index: number;
  kind: PluginProposalChange["kind"];
  target: string;
  summary?: string;
  ok: boolean;
  detail: string;
  diff?: string;
}

function previewChange(corpusRoot: string, change: PluginProposalChange, index: number): PluginProposalChangePreview & { apply?: () => string } {
  const base = { index, kind: change.kind, ...(change.summary ? { summary: change.summary } : {}) };
  try {
    switch (change.kind) {
      case "edit": {
        const file = path.join(corpusRoot, change.path);
        const snapshot = readGuardedFile(file);
        if (change.expectedSha256 && crypto.createHash("sha256").update(snapshot.content).digest("hex") !== change.expectedSha256) {
          return { ...base, target: change.path, ok: false, detail: "file changed since the plugin read it" };
        }
        const first = snapshot.content.indexOf(change.find);
        if (first < 0) return { ...base, target: change.path, ok: false, detail: "text to replace was not found" };
        if (snapshot.content.indexOf(change.find, first + 1) >= 0) return { ...base, target: change.path, ok: false, detail: "text to replace occurs more than once" };
        const next = snapshot.content.slice(0, first) + change.replace + snapshot.content.slice(first + change.find.length);
        return {
          ...base,
          target: change.path,
          ok: true,
          detail: `replace ${change.find.length} character(s)`,
          diff: buildUnifiedDiff(snapshot.content, next, { targetPath: change.path, temporaryDirectoryPrefix: "org2-plugin-proposal-", useLabels: true }),
          apply: () => guardedWriteFile(file, next, { expectedRevision: snapshot.revision }).file,
        };
      }
      case "create": {
        const file = path.join(corpusRoot, change.path);
        if (fs.existsSync(file)) return { ...base, target: change.path, ok: false, detail: "file already exists" };
        return {
          ...base,
          target: change.path,
          ok: true,
          detail: `create ${change.content.length} character(s) in a reviewable zone`,
          diff: buildUnifiedDiff("", change.content, { targetPath: change.path, temporaryDirectoryPrefix: "org2-plugin-proposal-", useLabels: true }),
          apply: () => {
            fs.mkdirSync(path.dirname(file), { recursive: true });
            return guardedWriteFile(file, change.content, { expectedRevision: null }).file;
          },
        };
      }
      case "thread-post":
        return { ...base, target: `thread:${change.threadId}`, ok: true, detail: `post ${change.message.length} character(s) to the chat` };
      case "run-comment": {
        const snapshot = loadAgentRunSnapshot(corpusRoot, change.runId);
        return {
          ...base,
          target: `run:${change.runId}`,
          ok: true,
          detail: `comment on run ${snapshot.run.title ?? snapshot.run.goal}`,
        };
      }
    }
  } catch (error) {
    return { ...base, target: "path" in change ? change.path : "", ok: false, detail: error instanceof Error ? error.message : String(error) };
  }
}

export interface ApplyPluginProposalResult {
  schema: "org2:plugin-proposal-apply:v1";
  applied: boolean;
  proposal: PluginProposalRecord;
  changes: PluginProposalChangePreview[];
}

/** Previews (default) or applies a pending proposal. Applying requires every change to apply cleanly. */
export function applyPluginProposal(corpusRootRaw: string, id: string, options: { apply?: boolean; actor?: string; only?: number[]; now?: Date } = {}): ApplyPluginProposalResult {
  const corpusRoot = path.resolve(corpusRootRaw);
  const { record, revision } = loadPluginProposal(corpusRoot, id);
  if (record.status !== "pending") throw new Error(`proposal ${id} is already ${record.status}`);
  const selected = record.proposals.map((change, index) => ({ change, index }))
    .filter(({ index }) => !options.only?.length || options.only.includes(index));
  const previews = selected.map(({ change, index }) => previewChange(corpusRoot, change, index));
  const publicPreview = previews.map(({ apply: _apply, ...rest }) => rest);
  if (!options.apply) return { schema: "org2:plugin-proposal-apply:v1", applied: false, proposal: record, changes: publicPreview };
  const blocked = previews.filter((preview) => !preview.ok);
  if (blocked.length) throw new Error(`proposal ${id} cannot be applied: ${blocked.map((item) => `#${item.index} ${item.target}: ${item.detail}`).join("; ")}`);
  const results: NonNullable<PluginProposalRecord["results"]> = [];
  for (const { change, index } of selected) {
    const preview = previews.find((item) => item.index === index)!;
    if (change.kind === "edit" || change.kind === "create") {
      results.push({ index, ok: true, detail: path.relative(corpusRoot, preview.apply!()) });
    } else if (change.kind === "thread-post") {
      const posted = queueAIChatInboxMessage(corpusRoot, change.threadId, change.message, {
        authorLabel: record.source.pluginName,
        source: `plugin:${record.source.pluginId}/${record.source.contributionId}`,
        idempotencyKey: `plugin-proposal:${record.id}:${index}`,
        apply: true,
      });
      results.push({ index, ok: true, detail: `queued ${path.relative(corpusRoot, posted.file)}` });
    } else {
      const snapshot = loadAgentRunSnapshot(corpusRoot, change.runId);
      const updated = addAgentRunComment(snapshot.run, `${record.source.pluginName} (plugin)`, change.body);
      saveAgentRun(corpusRoot, updated, { expectedRevision: snapshot.revision });
      results.push({ index, ok: true, detail: `commented on ${change.runId}` });
    }
  }
  const decided: PluginProposalRecord = {
    ...record,
    status: "applied",
    decidedAt: (options.now ?? new Date()).toISOString(),
    ...(options.actor ? { decidedBy: options.actor } : {}),
    results,
  };
  writeProposal(corpusRoot, decided, revision);
  return { schema: "org2:plugin-proposal-apply:v1", applied: true, proposal: decided, changes: publicPreview };
}

export function dismissPluginProposal(corpusRootRaw: string, id: string, options: { apply?: boolean; actor?: string; now?: Date } = {}): { schema: "org2:plugin-proposal-dismiss:v1"; applied: boolean; proposal: PluginProposalRecord } {
  const corpusRoot = path.resolve(corpusRootRaw);
  const { record, revision } = loadPluginProposal(corpusRoot, id);
  if (record.status !== "pending") throw new Error(`proposal ${id} is already ${record.status}`);
  const dismissed: PluginProposalRecord = { ...record, status: "dismissed", decidedAt: (options.now ?? new Date()).toISOString(), ...(options.actor ? { decidedBy: options.actor } : {}) };
  if (options.apply) writeProposal(corpusRoot, dismissed, revision);
  return { schema: "org2:plugin-proposal-dismiss:v1", applied: Boolean(options.apply), proposal: options.apply ? dismissed : record };
}

// MARK: - Hooks

interface HookState {
  schema: "org2:plugin-hook-state:v1";
  cursor: string | null;
  dispatchedEventIds: string[];
}

function hookStatePath(corpusRoot: string): string {
  return path.join(path.resolve(corpusRoot), ".org2", "plugin-hooks", "state.json");
}

function readHookState(corpusRoot: string): { state: HookState; revision: string | null } {
  try {
    const snapshot = readGuardedFile(hookStatePath(corpusRoot));
    const state = JSON.parse(snapshot.content) as HookState;
    if (state.schema === "org2:plugin-hook-state:v1" && Array.isArray(state.dispatchedEventIds)) return { state, revision: snapshot.revision };
  } catch { /* first run */ }
  return { state: { schema: "org2:plugin-hook-state:v1", cursor: null, dispatchedEventIds: [] }, revision: null };
}

function writeHookState(corpusRoot: string, state: HookState, revision: string | null): void {
  const file = hookStatePath(corpusRoot);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const bounded = { ...state, dispatchedEventIds: state.dispatchedEventIds.slice(-2_000) };
  guardedWriteFile(file, `${JSON.stringify(bounded, null, 2)}\n`, { expectedRevision: revision });
}

export interface HookDispatchOutcome {
  eventId: string;
  eventType: string;
  hook: string;
  ok: boolean;
  detail: string;
  proposalId?: string;
}

function hookContext(corpusRoot: string, event: ActivityEvent): JSONRecord {
  try {
    if (event.subject.kind === "run") return buildPluginActionContext(corpusRoot, { kind: "run", runId: event.subject.id });
    if (event.subject.kind === "approval" && event.subject.runId) {
      return buildPluginActionContext(corpusRoot, { kind: "approval", runId: event.subject.runId, approvalId: event.subject.id });
    }
    if (event.subject.kind === "thread") return buildPluginActionContext(corpusRoot, { kind: "thread", threadId: event.subject.id });
  } catch (error) {
    return { kind: event.subject.kind, id: event.subject.id, unavailable: error instanceof Error ? error.message : String(error) };
  }
  return { kind: event.subject.kind, id: event.subject.id };
}

function matchingHooks(corpusRoot: string, eventType: string): Array<{ entry: Org2PluginLockEntry; hook: Org2PluginHookContribution }> {
  return readPluginLock(corpusRoot).plugins.flatMap((entry) => (entry.manifest.contributes?.hooks ?? [])
    .filter((hook) => (hook.events as readonly string[]).includes(eventType))
    .map((hook) => ({ entry, hook })));
}

/** Invokes subscribed hooks for each event. Results become pending proposals, never direct writes. */
export function dispatchPluginHooks(corpusRootRaw: string, events: ActivityEvent[], options: { apply?: boolean; now?: Date } = {}): HookDispatchOutcome[] {
  const corpusRoot = path.resolve(corpusRootRaw);
  const { state, revision } = readHookState(corpusRoot);
  const dispatched = new Set(state.dispatchedEventIds);
  const outcomes: HookDispatchOutcome[] = [];
  let cursor = state.cursor;
  for (const event of events) {
    if (dispatched.has(event.id)) continue;
    for (const { entry, hook } of matchingHooks(corpusRoot, event.type)) {
      const hookID = `${entry.id}:${hook.id}`;
      if (!isPluginTrusted(entry.contentHash)) {
        outcomes.push({ eventId: event.id, eventType: event.type, hook: hookID, ok: false, detail: "plugin is not trusted on this machine" });
        continue;
      }
      if (!options.apply) {
        outcomes.push({ eventId: event.id, eventType: event.type, hook: hookID, ok: true, detail: "would invoke" });
        continue;
      }
      try {
        const { result, sandbox } = invokePluginSandboxed(corpusRoot, entry, hook.entry, hook.capabilities ?? [], {
          $schema: ORG2_PLUGIN_ACTION_INVOCATION_SCHEMA,
          kind: "hook",
          plugin: { id: entry.id, version: entry.version, contentHash: entry.contentHash },
          contribution: { id: hook.id },
          capabilities: hook.capabilities ?? [],
          event,
          context: hookContext(corpusRoot, event),
        });
        const normalized = resultFromPlugin(corpusRoot, entry, result);
        let proposalId: string | undefined;
        if (normalized.proposals.length) {
          const record: PluginProposalRecord = {
            schema: ORG2_PLUGIN_PROPOSAL_SCHEMA,
            id: crypto.randomUUID(),
            createdAt: (options.now ?? new Date()).toISOString(),
            status: "pending",
            source: {
              kind: "hook", pluginId: entry.id, pluginName: entry.name, pluginVersion: entry.version, contentHash: entry.contentHash,
              contributionId: hook.id, title: hook.description ?? `${entry.name} on ${event.type}`,
              event: { id: event.id, type: event.type, at: event.at, subject: event.subject },
            },
            ...(normalized.text ? { text: normalized.text } : {}),
            proposals: normalized.proposals,
            sandbox,
          };
          writeProposal(corpusRoot, record, null);
          proposalId = record.id;
        }
        outcomes.push({ eventId: event.id, eventType: event.type, hook: hookID, ok: true, detail: normalized.text ?? (proposalId ? `${normalized.proposals.length} proposal(s) pending review` : "no proposals"), ...(proposalId ? { proposalId } : {}) });
      } catch (error) {
        outcomes.push({ eventId: event.id, eventType: event.type, hook: hookID, ok: false, detail: error instanceof Error ? error.message : String(error) });
      }
    }
    if (options.apply) {
      dispatched.add(event.id);
      state.dispatchedEventIds.push(event.id);
      if (!cursor || event.at > cursor) cursor = event.at;
    }
  }
  if (options.apply && events.length) writeHookState(corpusRoot, { ...state, cursor }, revision);
  return outcomes;
}

/** Dispatches hooks for events recorded since the last cursor (or `since`). */
export function dispatchPluginHooksOnce(corpusRoot: string, options: { since?: Date; apply?: boolean; now?: Date } = {}): { cursor: string | null; outcomes: HookDispatchOutcome[] } {
  const hooks = listPluginHooks(corpusRoot);
  if (!hooks.length) return { cursor: readHookState(corpusRoot).state.cursor, outcomes: [] };
  const types = [...new Set(hooks.flatMap((hook) => hook.events))];
  const state = readHookState(corpusRoot).state;
  const now = options.now ?? new Date();
  const since = options.since ?? (state.cursor ? new Date(Date.parse(state.cursor) - 1) : new Date(now.getTime() - 3600_000));
  const events = activityEventHistory(corpusRoot, { since, now, filter: { types } });
  const outcomes = dispatchPluginHooks(corpusRoot, events, options);
  return { cursor: readHookState(corpusRoot).state.cursor, outcomes };
}

/** Follows the activity stream and dispatches hooks as events arrive. */
export async function followPluginHooks(corpusRoot: string, onOutcome: (outcome: HookDispatchOutcome) => void, options: { signal?: AbortSignal; intervalMs?: number } = {}): Promise<void> {
  const hooks = listPluginHooks(corpusRoot);
  if (!hooks.length) return;
  const types = [...new Set(hooks.flatMap((hook) => hook.events))];
  const state = readHookState(corpusRoot).state;
  await followActivityEvents(corpusRoot, (event) => {
    for (const outcome of dispatchPluginHooks(corpusRoot, [event], { apply: true })) onOutcome(outcome);
  }, {
    since: state.cursor ? new Date(Date.parse(state.cursor) - 1) : undefined,
    filter: { types },
    intervalMs: options.intervalMs,
    signal: options.signal,
  });
}
