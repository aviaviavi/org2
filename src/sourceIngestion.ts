import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import type { Org2ExternalSourceConfig } from "./config.js";
import {
  renderIngestReviewArtifact,
  type AgentIngestRecord,
  type AgentIngestConnectorMetadata,
} from "./agentIngestConnectors.js";

export const ORG2_SOURCE_IMPORT_SCHEMA = "org2:source-import:v1" as const;

type JsonObject = Record<string, unknown>;

export type SourceImportOptions = {
  root: string;
  profileId: string;
  profile: Org2ExternalSourceConfig;
  binary: string;
  configPath: string;
  since?: string;
  limit?: number;
  apply?: boolean;
  now?: Date;
};

export type SourceImportFile = {
  group: string;
  recordCount: number;
  rawPath: string;
  reviewPath: string;
  changed: boolean;
  applied: boolean;
};

export type SourceImportResult = {
  schema: typeof ORG2_SOURCE_IMPORT_SCHEMA;
  profile: string;
  sourceType: "slack" | "notion";
  apply: boolean;
  since?: string;
  inputCount: number;
  acceptedCount: number;
  skippedCount: number;
  groupCount: number;
  changedFileCount: number;
  removedFileCount: number;
  files: SourceImportFile[];
};

function object(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : {};
}

function string(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function singleLine(value: unknown): string {
  return string(value).replace(/[\r\n\t]+/g, " ").replace(/\s{2,}/g, " ").trim();
}

function safeSlug(value: string): string {
  return value.normalize("NFKD").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 72) || "source";
}

function resolveZone(root: string, configured: string | undefined, fallback: string): string {
  const resolvedRoot = path.resolve(root);
  const resolved = path.resolve(resolvedRoot, configured || fallback);
  if (resolved !== resolvedRoot && !resolved.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new Error(`external source zone must stay inside the corpus: ${configured}`);
  }
  return resolved;
}

function parseSince(value: string | undefined, now: Date): { label?: string; timestamp?: number } {
  const raw = string(value);
  if (!raw) return {};
  const relative = raw.match(/^(\d+)([dhwm])$/i);
  if (relative) {
    const amount = Number(relative[1]);
    const unit = relative[2]!.toLowerCase();
    const milliseconds = amount * ({ m: 60_000, h: 3_600_000, d: 86_400_000, w: 604_800_000 }[unit] || 0);
    return { label: raw, timestamp: now.getTime() - milliseconds };
  }
  const timestamp = Date.parse(raw);
  if (!Number.isFinite(timestamp)) throw new Error(`invalid source import --since value: ${raw}`);
  return { label: raw, timestamp };
}

function runCrawlerJson(binary: string, args: string[]): unknown[] {
  const child = spawnSync(binary, args, {
    encoding: "utf8",
    env: process.env,
    maxBuffer: 128 * 1024 * 1024,
  });
  if (child.status !== 0) {
    throw new Error(`${path.basename(binary)} archive read failed: ${string(child.stderr) || string(child.stdout) || `exit ${child.status}`}`);
  }
  try {
    const parsed = JSON.parse(child.stdout || "[]");
    if (!Array.isArray(parsed)) throw new Error("crawler output was not an array");
    return parsed;
  } catch (error) {
    throw new Error(`${path.basename(binary)} returned invalid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function slackTimestamp(value: string): string {
  const seconds = Number(value);
  return Number.isFinite(seconds) ? new Date(seconds * 1000).toISOString() : value;
}

function slackRecords(options: SourceImportOptions, scanLimit: number): AgentIngestRecord[] {
  const args = ["--config", options.configPath, "--json", "messages"];
  if (options.profile.workspaceId) args.push("--workspace", options.profile.workspaceId);
  args.push("--limit", String(scanLimit));
  return runCrawlerJson(options.binary, args).map((raw, index) => {
    const row = object(raw);
    const workspaceId = singleLine(row.workspace_id);
    const workspaceName = singleLine(row.workspace_name) || workspaceId;
    const channelId = singleLine(row.channel_id);
    const channelName = singleLine(row.channel_name) || channelId;
    const timestampRaw = singleLine(row.ts);
    const timestamp = slackTimestamp(timestampRaw);
    const author = singleLine(row.user_name) || singleLine(row.user_id) || singleLine(row.subtype) || "Slack";
    const id = `${workspaceId || "workspace"}:${channelId || "channel"}:${timestampRaw || index}`;
    return {
      id,
      title: `#${channelName} · ${author}`,
      text: string(row.text) || string(row.normalized_text),
      cursor: `${timestamp}#${id}`,
      rawPayload: row,
      source: {
        kind: "slack",
        workspace: workspaceName,
        channel: channelName,
        thread: singleLine(row.thread_ts) || undefined,
        author,
        timestamp,
      },
    } satisfies AgentIngestRecord;
  });
}

function notionRecords(options: SourceImportOptions, scanLimit: number): AgentIngestRecord[] {
  return runCrawlerJson(options.binary, ["--config", options.configPath, "tui", "--json", "--limit", String(scanLimit)]).map((raw, index) => {
    const row = object(raw);
    const fields = object(row.fields);
    const id = singleLine(row.id) || `notion-page-${index}`;
    const scope = singleLine(row.scope) || "Notion";
    const title = singleLine(row.title) || "Untitled Notion page";
    const timestamp = singleLine(row.updated_at) || singleLine(row.created_at) || new Date(0).toISOString();
    const source: AgentIngestConnectorMetadata = {
      kind: "notion",
      workspace: scope,
      conversationId: id,
      conversationTitle: title,
      service: singleLine(fields.source) || "notion",
      pageId: id,
      spaceId: singleLine(fields.space_id) || undefined,
      parentId: singleLine(row.parent_id) || singleLine(fields.parent_id) || undefined,
      sourceName: singleLine(fields.source) || "notion",
      timestamp,
      url: `https://www.notion.so/${id.replaceAll("-", "")}`,
    };
    return {
      id,
      title,
      text: string(row.text) || string(row.detail),
      cursor: `${timestamp}#${id}`,
      rawPayload: row,
      source,
    } satisfies AgentIngestRecord;
  });
}

function scopeAllowed(record: AgentIngestRecord, scopes: string[]): boolean {
  if (!scopes.length) return true;
  // A Notion integration token is itself the API access boundary. API records
  // do not reliably carry the desktop workspace label (for example, "Scarf"),
  // so applying a desktop-name filter here would discard freshly authenticated
  // pages. Keep the configured scope filter for desktop-cache fallbacks.
  if (record.source.kind === "notion" && record.source.sourceName?.toLowerCase() === "api") return true;
  const candidates = [
    record.source.workspace,
    record.source.channel,
    record.source.conversationTitle,
    record.source.conversationId,
  ].filter(Boolean).map((value) => value!.toLowerCase());
  return scopes.some((scope) => candidates.includes(scope.toLowerCase()));
}

function groupKey(record: AgentIngestRecord): string {
  const timestamp = Date.parse(record.source.timestamp);
  const date = Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : "unknown";
  if (record.source.kind === "slack") {
    return `${date.slice(0, 10)}--${safeSlug(record.source.channel || "channel")}`;
  }
  return `${safeSlug(record.source.workspace || "notion")}--${date.slice(0, 7)}`;
}

function stableJson(value: unknown): string {
  return JSON.stringify(value, null, 2) + "\n";
}

function writeIfChanged(file: string, contents: string, apply: boolean): boolean {
  const changed = !fs.existsSync(file) || fs.readFileSync(file, "utf8") !== contents;
  if (apply && changed) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, contents, "utf8");
  }
  return changed;
}

function managedRawFile(file: string, profileId: string, sourceType: "slack" | "notion"): boolean {
  try {
    const value = object(JSON.parse(fs.readFileSync(file, "utf8")));
    return value.schema === ORG2_SOURCE_IMPORT_SCHEMA && value.profile === profileId && value.sourceType === sourceType;
  } catch {
    return false;
  }
}

function reconcileGeneratedFiles(options: {
  rawRoot: string;
  reviewRoot: string;
  expectedRaw: Set<string>;
  expectedReview: Set<string>;
  profileId: string;
  sourceType: "slack" | "notion";
  apply: boolean;
}): string[] {
  const removed: string[] = [];
  if (!fs.existsSync(options.rawRoot)) return removed;
  for (const name of fs.readdirSync(options.rawRoot)) {
    if (!name.endsWith(".json")) continue;
    const rawFile = path.join(options.rawRoot, name);
    if (options.expectedRaw.has(rawFile) || !managedRawFile(rawFile, options.profileId, options.sourceType)) continue;
    removed.push(rawFile);
    if (options.apply) fs.unlinkSync(rawFile);

    const reviewFile = path.join(options.reviewRoot, `${path.basename(name, ".json")}.org2`);
    if (options.expectedReview.has(reviewFile) || !fs.existsSync(reviewFile)) continue;
    const review = fs.readFileSync(reviewFile, "utf8");
    if (!review.includes(":ORG2_GENERATOR: org2-source-import")) continue;
    removed.push(reviewFile);
    if (options.apply) fs.unlinkSync(reviewFile);
  }
  return removed;
}

export function importCrawlerArchive(options: SourceImportOptions): SourceImportResult {
  const now = options.now || new Date();
  const configuredLimit = options.profile.ingestion?.maxItems;
  const limit = Math.max(1, Math.min(options.limit || configuredLimit || 5_000, 50_000));
  const since = parseSince(options.since || options.profile.ingestion?.since, now);
  const scanLimit = options.profile.type === "slack" ? Math.min(Math.max(limit * 4, 5_000), 50_000) : limit;
  const input = options.profile.type === "slack" ? slackRecords(options, scanLimit) : notionRecords(options, scanLimit);
  const scopes = options.profile.scopes || [];
  const accepted = input
    .filter((record) => record.text.trim())
    .filter((record) => scopeAllowed(record, scopes))
    .filter((record) => since.timestamp === undefined || Date.parse(record.source.timestamp) >= since.timestamp)
    .sort((a, b) => a.source.timestamp.localeCompare(b.source.timestamp) || a.id.localeCompare(b.id))
    .slice(-limit);

  const groupedRecords = new Map<string, AgentIngestRecord[]>();
  for (const record of accepted) {
    const key = groupKey(record);
    groupedRecords.set(key, [...(groupedRecords.get(key) || []), record]);
  }
  const groups = new Map<string, AgentIngestRecord[]>();
  const groupSize = options.profile.type === "notion" ? 100 : 250;
  for (const [base, records] of groupedRecords) {
    if (records.length <= groupSize) {
      groups.set(base, records);
      continue;
    }
    for (let offset = 0; offset < records.length; offset += groupSize) {
      groups.set(`${base}--part-${String(offset / groupSize + 1).padStart(2, "0")}`, records.slice(offset, offset + groupSize));
    }
  }

  const rawRoot = resolveZone(options.root, options.profile.rawZone, `raw/connectors/${options.profile.type}/${options.profileId}`);
  const reviewRoot = resolveZone(options.root, options.profile.ingestion?.reviewZone, `views/connectors/${options.profile.type}/${options.profileId}`);
  const files: SourceImportFile[] = [];
  for (const [group, records] of [...groups].sort(([a], [b]) => a.localeCompare(b))) {
    const generatedAt = records.at(-1)?.source.timestamp || now.toISOString();
    const rawPath = path.join(rawRoot, `${group}.json`);
    const reviewPath = path.join(reviewRoot, `${group}.org2`);
    const raw = stableJson({
      schema: ORG2_SOURCE_IMPORT_SCHEMA,
      profile: options.profileId,
      sourceType: options.profile.type,
      generatedAt,
      records,
    });
    const review = renderIngestReviewArtifact(records, {
      title: `${options.profileId} ${options.profile.type} import · ${group}`,
      generatedAt,
      generator: "org2-source-import",
      quoteRecordText: true,
    });
    const rawChanged = writeIfChanged(rawPath, raw, Boolean(options.apply));
    const reviewChanged = writeIfChanged(reviewPath, review, Boolean(options.apply));
    files.push({
      group,
      recordCount: records.length,
      rawPath,
      reviewPath,
      changed: rawChanged || reviewChanged,
      applied: Boolean(options.apply),
    });
  }
  const removedFiles = reconcileGeneratedFiles({
    rawRoot,
    reviewRoot,
    expectedRaw: new Set(files.map((file) => file.rawPath)),
    expectedReview: new Set(files.map((file) => file.reviewPath)),
    profileId: options.profileId,
    sourceType: options.profile.type,
    apply: Boolean(options.apply),
  });

  return {
    schema: ORG2_SOURCE_IMPORT_SCHEMA,
    profile: options.profileId,
    sourceType: options.profile.type,
    apply: Boolean(options.apply),
    ...(since.label ? { since: since.label } : {}),
    inputCount: input.length,
    acceptedCount: accepted.length,
    skippedCount: input.length - accepted.length,
    groupCount: groups.size,
    changedFileCount: files.filter((file) => file.changed).length,
    removedFileCount: removedFiles.length,
    files,
  };
}
