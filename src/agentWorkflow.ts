import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { guardedWriteFile, readGuardedFile, type GuardedFileWriteOptions } from "./guardedFile.js";
import {
  createAgentRun,
  type AgentRun,
  type AgentRunApproval,
  type AgentRunPlanStep,
  type AgentRunRiskClass,
} from "./agentRun.js";

export const ORG2_WORKFLOW_SCHEMA = "org2:workflow:v1" as const;
export const WORKFLOW_EVENT_TRIGGER_TYPES = ["capture", "meeting-import"] as const;

export type AgentWorkflowState = "draft" | "active" | "paused";
export type WorkflowEventTriggerType = typeof WORKFLOW_EVENT_TRIGGER_TYPES[number];
export type WorkflowSignalType = WorkflowEventTriggerType | "file-change";

export interface WorkflowSignal {
  id: string;
  type: WorkflowSignalType;
  at: string;
  paths: string[];
}

export interface WorkflowTriggerGate {
  events?: WorkflowSignalType[];
  paths?: string[];
}

export interface WorkflowInput {
  id: string;
  description: string;
  required: boolean;
  default?: string;
}

export interface WorkflowOutput {
  id: string;
  path: string;
  role: string;
  mediaType?: string;
}

export interface WorkflowTrigger {
  id: string;
  type: "manual" | "schedule" | "file-change" | WorkflowEventTriggerType;
  enabled: boolean;
  schedule?: string;
  timezone?: string;
  path?: string;
  lastRunAt?: string;
  lastAttemptAt?: string;
  gate?: WorkflowTriggerGate;
}

export interface AgentWorkflow {
  schema: typeof ORG2_WORKFLOW_SCHEMA;
  id: string;
  version: string;
  title: string;
  description: string;
  state: AgentWorkflowState;
  instructions: string;
  capabilities: string[];
  riskClass: AgentRunRiskClass;
  inputs: WorkflowInput[];
  contextRules: string[];
  steps: Array<Omit<AgentRunPlanStep, "status" | "startedAt" | "completedAt">>;
  outputs: WorkflowOutput[];
  validations: string[];
  approvals: Array<Pick<AgentRunApproval, "title" | "action" | "riskClass" | "requestedRole">>;
  triggers: WorkflowTrigger[];
  signals?: WorkflowSignal[];
  compatibility: { org2: string; schema: string };
  sourceRunId?: string;
  createdAt: string;
  updatedAt: string;
}

export interface AgentWorkflowSnapshot {
  file: string;
  revision: string;
  raw: string;
  workflow: AgentWorkflow;
}

export type AgentWorkflowTemplate = Omit<
  AgentWorkflow,
  "schema" | "state" | "compatibility" | "createdAt" | "updatedAt"
> & {
  schema: "org2:workflow-template:v1";
};

export interface WorkflowValidationResult {
  valid: boolean;
  issues: Array<{ path: string; message: string }>;
}

function safeId(raw: string): string {
  const value = String(raw || "").trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value)) throw new Error(`invalid workflow id: ${raw}`);
  return value;
}

function nowIso(now?: string): string {
  const value = now ? new Date(now) : new Date();
  if (Number.isNaN(value.getTime())) throw new Error(`invalid timestamp: ${now}`);
  return value.toISOString();
}

export function workflowFromRun(run: AgentRun, options: { id?: string; title?: string; version?: string; now?: string } = {}): AgentWorkflow {
  if (run.status !== "completed") throw new Error("only a completed run can be saved as a workflow");
  const now = nowIso(options.now);
  const outputs = run.artifacts.map((artifact) => ({
    id: artifact.id,
    path: artifact.path,
    role: artifact.role,
    ...(artifact.mediaType ? { mediaType: artifact.mediaType } : {}),
  }));
  const approvalKeys = new Set<string>();
  const approvals = run.approvals.flatMap((approval) => {
    const key = `${approval.action}\0${approval.riskClass}\0${approval.requestedRole || ""}`;
    if (approvalKeys.has(key)) return [];
    approvalKeys.add(key);
    return [{
      title: approval.title,
      action: approval.action,
      riskClass: approval.riskClass,
      ...(approval.requestedRole ? { requestedRole: approval.requestedRole } : {}),
    }];
  });
  return {
    schema: ORG2_WORKFLOW_SCHEMA,
    id: safeId(options.id || `workflow-${run.id}`),
    version: options.version || "1.0.0",
    title: options.title || run.goal,
    description: `Reusable workflow captured from run ${run.id}.`,
    state: "draft",
    instructions: run.goal,
    capabilities: [...run.capabilities],
    riskClass: run.riskClass,
    inputs: run.context.map((item, index) => ({ id: `context-${index + 1}`, description: item.title || item.ref, required: true, default: item.ref })),
    contextRules: run.context.map((item) => item.ref),
    steps: run.plan.map(({ status: _status, startedAt: _startedAt, completedAt: _completedAt, ...step }) => step),
    outputs,
    validations: run.validations.map((validation) => validation.name),
    approvals,
    triggers: [{ id: "manual", type: "manual", enabled: true }],
    compatibility: { org2: ">=0.3.0 <1", schema: ORG2_WORKFLOW_SCHEMA },
    sourceRunId: run.id,
    createdAt: now,
    updatedAt: now,
  };
}

export function validateWorkflow(workflow: AgentWorkflow): WorkflowValidationResult {
  const issues: WorkflowValidationResult["issues"] = [];
  if (workflow.schema !== ORG2_WORKFLOW_SCHEMA) issues.push({ path: "schema", message: `must equal ${ORG2_WORKFLOW_SCHEMA}` });
  try { safeId(workflow.id); } catch (error) { issues.push({ path: "id", message: (error as Error).message }); }
  if (!workflow.title?.trim()) issues.push({ path: "title", message: "is required" });
  if (!["draft", "active", "paused"].includes(workflow.state || "draft")) issues.push({ path: "state", message: "must be draft, active, or paused" });
  if (!/^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/.test(workflow.version || "")) issues.push({ path: "version", message: "must be semantic version syntax" });
  const ids = new Set<string>();
  for (const [index, step] of (workflow.steps || []).entries()) {
    if (!step.id || ids.has(step.id)) issues.push({ path: `steps[${index}].id`, message: "must be present and unique" });
    ids.add(step.id);
  }
  for (const [index, trigger] of (workflow.triggers || []).entries()) {
    if (trigger.type === "schedule" && !trigger.schedule) issues.push({ path: `triggers[${index}].schedule`, message: "is required for schedule triggers" });
    if (trigger.type === "file-change" && !trigger.path) issues.push({ path: `triggers[${index}].path`, message: "is required for file-change triggers" });
    if (trigger.gate && !(trigger.gate.events?.length || trigger.gate.paths?.length)) {
      issues.push({ path: `triggers[${index}].gate`, message: "must declare at least one event or path" });
    }
    for (const event of trigger.gate?.events || []) {
      if (![...WORKFLOW_EVENT_TRIGGER_TYPES, "file-change"].includes(event)) {
        issues.push({ path: `triggers[${index}].gate.events`, message: `unsupported event: ${event}` });
      }
    }
  }
  for (const [index, signal] of (workflow.signals || []).entries()) {
    if (!signal.id?.trim()) issues.push({ path: `signals[${index}].id`, message: "is required" });
    if (![...WORKFLOW_EVENT_TRIGGER_TYPES, "file-change"].includes(signal.type)) issues.push({ path: `signals[${index}].type`, message: "is not supported" });
    if (!signal.at || Number.isNaN(new Date(signal.at).getTime())) issues.push({ path: `signals[${index}].at`, message: "must be an ISO timestamp" });
  }
  return { valid: issues.length === 0, issues };
}

function applyTemplate(value: string, inputs: Record<string, string>): string {
  return value.replace(/\{\{\s*([A-Za-z0-9._-]+)\s*\}\}/g, (_match, name: string) => inputs[name] ?? `{{${name}}}`);
}

export function instantiateWorkflow(workflow: AgentWorkflow, inputs: Record<string, string>, options: {
  owner?: string;
  assignee?: string;
  now?: string;
  logicalWorkId?: string;
  attempt?: AgentRun["attempt"];
} = {}): AgentRun {
  const missing = workflow.inputs.filter((input) => input.required && !(inputs[input.id] || input.default));
  if (missing.length) throw new Error(`missing required workflow inputs: ${missing.map((input) => input.id).join(", ")}`);
  const resolved = Object.fromEntries(workflow.inputs.map((input) => [input.id, inputs[input.id] ?? input.default ?? ""]));
  return createAgentRun({
    goal: applyTemplate(workflow.instructions || workflow.title, resolved),
    acceptanceCriteria: workflow.outputs.map((output) => `Produce ${applyTemplate(output.path, resolved)}`).concat(workflow.validations.map((name) => `Pass validation: ${name}`)),
    riskClass: workflow.riskClass,
    owner: options.owner,
    assignee: options.assignee,
    workflowId: workflow.id,
    workflowVersion: workflow.version,
    capabilities: workflow.capabilities,
    context: workflow.contextRules.map((ref) => ({ ref: applyTemplate(ref, resolved) })),
    plan: workflow.steps.map((step) => ({ ...step, title: applyTemplate(step.title, resolved), detail: step.detail ? applyTemplate(step.detail, resolved) : undefined })),
    logicalWorkId: options.logicalWorkId,
    attempt: options.attempt,
    now: options.now,
  });
}

export function workflowDirectory(root: string): string { return path.join(path.resolve(root), "workflows"); }
export function legacyWorkflowDirectory(root: string): string { return path.join(path.resolve(root), ".org2", "workflows"); }
export function workflowPath(root: string, id: string): string { return path.join(workflowDirectory(root), `${safeId(id)}.org2`); }

export function workflowSourcePath(root: string, id: string): string {
  const primary = workflowPath(root, id);
  if (fs.existsSync(primary)) return primary;
  const legacy = path.join(legacyWorkflowDirectory(root), `${safeId(id)}.org2`);
  if (fs.existsSync(legacy)) return legacy;
  return primary;
}

export function renderWorkflowOrg(workflow: AgentWorkflow): string {
  const validation = validateWorkflow(workflow);
  if (!validation.valid) throw new Error(`invalid workflow: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return [
    "#+TITLE: Org2 workflow package",
    `* ${workflow.title}`,
    ":PROPERTIES:",
    `:ORG2_WORKFLOW_ID: ${workflow.id}`,
    `:ORG2_WORKFLOW_VERSION: ${workflow.version}`,
    `:WORKFLOW_STATE: ${workflow.state}`,
    `:RISK_CLASS: ${workflow.riskClass}`,
    ":END:",
    workflow.description,
    "",
    "** Instructions",
    workflow.instructions,
    "",
    "** Machine state",
    "#+begin_src json :org2-workflow",
    JSON.stringify(workflow, null, 2),
    "#+end_src",
    "",
  ].join("\n");
}

export function parseWorkflowOrg(raw: string): AgentWorkflow {
  const match = raw.match(/#\+begin_src\s+json\s+:org2-workflow\s*\r?\n([\s\S]*?)\r?\n#\+end_src/i);
  if (!match) throw new Error("workflow file is missing its :org2-workflow machine-state block");
  const parsed = JSON.parse(match[1] || "{}") as AgentWorkflow;
  const headingTitle = raw.match(/^\*\s+(.+)\s*$/m)?.[1]?.trim();
  const state = raw.match(/^:WORKFLOW_STATE:\s*(.+)\s*$/mi)?.[1]?.trim();
  const riskClass = raw.match(/^:RISK_CLASS:\s*(.+)\s*$/mi)?.[1]?.trim();
  const version = raw.match(/^:ORG2_WORKFLOW_VERSION:\s*(.+)\s*$/mi)?.[1]?.trim();
  const description = raw.match(/^:END:\s*\r?\n([\s\S]*?)\r?\n\*\* Instructions\s*$/m)?.[1]?.trim();
  const instructions = raw.match(/^\*\* Instructions\s*\r?\n([\s\S]*?)\r?\n\*\* Machine state\s*$/m)?.[1]?.trim();
  // The readable Org2 fields are authoring fields, not a decorative copy. The
  // machine block carries the complete portable schema; editing these visible
  // fields in any text editor overrides their corresponding machine values and
  // the next structured save writes the normalized definition back out.
  const workflow = {
    ...parsed,
    ...(headingTitle ? { title: headingTitle } : {}),
    ...(description ? { description } : {}),
    ...(instructions ? { instructions } : {}),
    ...(version ? { version } : {}),
    ...(riskClass ? { riskClass: riskClass as AgentRunRiskClass } : {}),
    state: (state || parsed.state || "draft") as AgentWorkflowState,
  };
  const validation = validateWorkflow(workflow);
  if (!validation.valid) throw new Error(`invalid workflow: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return workflow;
}

export function saveWorkflow(
  root: string,
  workflow: AgentWorkflow,
  options: GuardedFileWriteOptions = {},
): string {
  const target = workflowPath(root, workflow.id);
  return guardedWriteFile(target, renderWorkflowOrg(workflow), options).file;
}

export function installBuiltinWorkflow(root: string, template: AgentWorkflowTemplate): string {
  const now = new Date().toISOString();
  return saveWorkflow(root, {
    ...template,
    schema: ORG2_WORKFLOW_SCHEMA,
    state: "draft",
    compatibility: { org2: ">=0.3.0 <1", schema: ORG2_WORKFLOW_SCHEMA },
    createdAt: now,
    updatedAt: now,
  }, { expectedRevision: null });
}

export function loadWorkflow(root: string, id: string): AgentWorkflow {
  return loadWorkflowSnapshot(root, id).workflow;
}

export function loadWorkflowSnapshot(root: string, id: string): AgentWorkflowSnapshot {
  const snapshot = readGuardedFile(workflowSourcePath(root, id));
  return {
    file: snapshot.file,
    revision: snapshot.revision,
    raw: snapshot.content,
    workflow: parseWorkflowOrg(snapshot.content),
  };
}

export function listWorkflows(root: string): AgentWorkflow[] {
  const byID = new Map<string, AgentWorkflow>();
  // Load the legacy directory first so a visible top-level workflow wins when
  // both locations contain the same id during migration.
  for (const dir of [legacyWorkflowDirectory(root), workflowDirectory(root)]) {
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir).filter((item) => /\.org2$/i.test(item))) {
      try {
        const workflow = parseWorkflowOrg(fs.readFileSync(path.join(dir, name), "utf8"));
        byID.set(workflow.id, workflow);
      } catch {}
    }
  }
  return [...byID.values()].sort((a, b) => a.id.localeCompare(b.id));
}

export function updateWorkflow(
  root: string,
  id: string,
  update: (workflow: AgentWorkflow) => AgentWorkflow,
  now?: string,
): { workflow: AgentWorkflow; file: string } {
  const snapshot = loadWorkflowSnapshot(root, id);
  const workflow = update(snapshot.workflow);
  workflow.updatedAt = nowIso(now);
  const target = workflowPath(root, workflow.id);
  if (path.resolve(snapshot.file) !== path.resolve(target)) {
    const current = readGuardedFile(snapshot.file);
    if (current.revision !== snapshot.revision) throw new Error(`workflow changed after it was read: ${snapshot.file}`);
  }
  return {
    workflow,
    file: saveWorkflow(root, workflow, {
      expectedRevision: path.resolve(snapshot.file) === path.resolve(target) ? snapshot.revision : null,
    }),
  };
}

export function migrateLegacyWorkflows(root: string): Array<{ id: string; from: string; to: string; skipped: boolean }> {
  const legacy = legacyWorkflowDirectory(root);
  if (!fs.existsSync(legacy)) return [];
  const results: Array<{ id: string; from: string; to: string; skipped: boolean }> = [];
  for (const name of fs.readdirSync(legacy).filter((item) => /\.org2$/i.test(item))) {
    const from = path.join(legacy, name);
    let workflow: AgentWorkflow;
    try { workflow = parseWorkflowOrg(fs.readFileSync(from, "utf8")); } catch { continue; }
    const to = workflowPath(root, workflow.id);
    if (fs.existsSync(to)) {
      results.push({ id: workflow.id, from, to, skipped: true });
      continue;
    }
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.renameSync(from, to);
    results.push({ id: workflow.id, from, to, skipped: false });
  }
  return results;
}

function parseEvery(raw: string): number | null {
  const match = raw.trim().match(/^every\s+(\d+)\s*(m|h|d)$/i);
  if (!match) return null;
  const amount = Number(match[1]);
  return amount * (match[2]?.toLowerCase() === "m" ? 60_000 : match[2]?.toLowerCase() === "h" ? 3_600_000 : 86_400_000);
}

export function dueWorkflowTriggers(workflow: AgentWorkflow, options: { now?: string; changedPaths?: string[]; event?: WorkflowEventTriggerType } = {}): WorkflowTrigger[] {
  const now = new Date(options.now || Date.now()).getTime();
  return workflow.triggers.filter((trigger) => {
    if (!trigger.enabled || trigger.type === "manual") return false;
    if (trigger.type === options.event) return true;
    if (trigger.type === "file-change") return (options.changedPaths || []).some((item) => item === trigger.path || item.startsWith(`${trigger.path}/`));
    if (trigger.type === "schedule" && trigger.schedule) {
      const interval = parseEvery(trigger.schedule);
      if (!interval) return false;
      const last = trigger.lastRunAt ? new Date(trigger.lastRunAt).getTime() : 0;
      return Number.isFinite(last) && now - last >= interval && workflowTriggerEligibility(workflow, trigger.id).eligible;
    }
    return false;
  });
}

export function recordWorkflowSignal(
  workflow: AgentWorkflow,
  input: { id?: string; type: WorkflowSignalType; at?: string; paths?: string[] },
): AgentWorkflow {
  if (![...WORKFLOW_EVENT_TRIGGER_TYPES, "file-change"].includes(input.type)) throw new Error(`invalid workflow signal: ${input.type}`);
  const at = nowIso(input.at);
  const signal: WorkflowSignal = {
    id: safeId(input.id || crypto.randomUUID()),
    type: input.type,
    at,
    paths: Array.from(new Set((input.paths || []).map((item) => item.trim()).filter(Boolean))),
  };
  return {
    ...workflow,
    signals: [...(workflow.signals || []), signal],
    updatedAt: at,
  };
}

export function workflowTriggerEligibility(
  workflow: AgentWorkflow,
  triggerId: string,
): { eligible: boolean; reason: string; signalIds: string[] } {
  const trigger = workflow.triggers.find((item) => item.id === triggerId);
  if (!trigger) throw new Error(`workflow trigger not found: ${triggerId}`);
  if (!trigger.enabled) return { eligible: false, reason: "trigger is disabled", signalIds: [] };
  if (!trigger.gate) return { eligible: true, reason: "trigger has no event gate", signalIds: [] };
  const boundary = new Date(trigger.lastAttemptAt || trigger.lastRunAt || 0).getTime();
  const matching = (workflow.signals || []).filter((signal) => {
    const at = new Date(signal.at).getTime();
    if (!Number.isFinite(at) || at <= boundary) return false;
    const eventMatches = !trigger.gate?.events?.length || trigger.gate.events.includes(signal.type);
    const pathMatches = !trigger.gate?.paths?.length || signal.paths.some((candidate) =>
      trigger.gate!.paths!.some((expected) => candidate === expected || candidate.startsWith(`${expected}/`))
    );
    return eventMatches && pathMatches;
  });
  return matching.length
    ? { eligible: true, reason: `${matching.length} fresh signal${matching.length === 1 ? "" : "s"} matched`, signalIds: matching.map((item) => item.id) }
    : { eligible: false, reason: "no matching event or fresh-work signal arrived after the previous attempt", signalIds: [] };
}

export function markWorkflowTriggerAttempt(workflow: AgentWorkflow, triggerId: string, atRaw?: string): AgentWorkflow {
  const at = nowIso(atRaw);
  let found = false;
  const triggers = workflow.triggers.map((trigger) => {
    if (trigger.id !== triggerId) return trigger;
    found = true;
    return { ...trigger, lastAttemptAt: at, lastRunAt: at };
  });
  if (!found) throw new Error(`workflow trigger not found: ${triggerId}`);
  return { ...workflow, triggers, updatedAt: at };
}

export function packagedWorkflowManifest(workflow: AgentWorkflow): Record<string, unknown> {
  return {
    schema: "org2:workflow-package:v1",
    id: workflow.id,
    version: workflow.version,
    title: workflow.title,
    state: workflow.state,
    compatibility: workflow.compatibility,
    capabilities: workflow.capabilities,
    riskClass: workflow.riskClass,
    inputs: workflow.inputs,
    outputs: workflow.outputs,
    approvals: workflow.approvals,
  };
}

export function packagedCorpusTemplate(workflow: AgentWorkflow): Record<string, unknown> {
  return {
    schema: "org2:corpus-template:v1",
    id: `${workflow.id}-workspace`,
    version: workflow.version,
    compatibility: workflow.compatibility,
    directories: ["notes", "raw", "views", "compiled", "workflows", ".org2/runs"],
    starterFiles: [
      { path: "inbox.org2", content: "#+TITLE: Inbox\n\n* Inbox\n" },
      { path: "notes/welcome.org2", content: `#+TITLE: ${workflow.title}\n\nThis workspace includes the ${workflow.id} workflow.\n` },
    ],
    workflows: [packagedWorkflowManifest(workflow)],
  };
}
