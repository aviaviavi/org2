import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  createAgentRun,
  type AgentRun,
  type AgentRunApproval,
  type AgentRunPlanStep,
  type AgentRunRiskClass,
} from "./agentRun.js";

export const ORG2_WORKFLOW_SCHEMA = "org2:workflow:v1" as const;

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
  type: "manual" | "schedule" | "file-change" | "capture" | "meeting-import";
  enabled: boolean;
  schedule?: string;
  path?: string;
  lastRunAt?: string;
}

export interface AgentWorkflow {
  schema: typeof ORG2_WORKFLOW_SCHEMA;
  id: string;
  version: string;
  title: string;
  description: string;
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
  compatibility: { org2: string; schema: string };
  sourceRunId?: string;
  createdAt: string;
  updatedAt: string;
}

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
  if (!/^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/.test(workflow.version || "")) issues.push({ path: "version", message: "must be semantic version syntax" });
  const ids = new Set<string>();
  for (const [index, step] of (workflow.steps || []).entries()) {
    if (!step.id || ids.has(step.id)) issues.push({ path: `steps[${index}].id`, message: "must be present and unique" });
    ids.add(step.id);
  }
  for (const [index, trigger] of (workflow.triggers || []).entries()) {
    if (trigger.type === "schedule" && !trigger.schedule) issues.push({ path: `triggers[${index}].schedule`, message: "is required for schedule triggers" });
    if (trigger.type === "file-change" && !trigger.path) issues.push({ path: `triggers[${index}].path`, message: "is required for file-change triggers" });
  }
  return { valid: issues.length === 0, issues };
}

function applyTemplate(value: string, inputs: Record<string, string>): string {
  return value.replace(/\{\{\s*([A-Za-z0-9._-]+)\s*\}\}/g, (_match, name: string) => inputs[name] ?? `{{${name}}}`);
}

export function instantiateWorkflow(workflow: AgentWorkflow, inputs: Record<string, string>, options: { owner?: string; assignee?: string; now?: string } = {}): AgentRun {
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
    now: options.now,
  });
}

export function workflowDirectory(root: string): string { return path.join(path.resolve(root), ".org2", "workflows"); }
export function workflowPath(root: string, id: string): string { return path.join(workflowDirectory(root), `${safeId(id)}.org2`); }

export function renderWorkflowOrg(workflow: AgentWorkflow): string {
  const validation = validateWorkflow(workflow);
  if (!validation.valid) throw new Error(`invalid workflow: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return [
    "#+TITLE: Org2 workflow package",
    `* ${workflow.title}`,
    ":PROPERTIES:",
    `:ORG2_WORKFLOW_ID: ${workflow.id}`,
    `:ORG2_WORKFLOW_VERSION: ${workflow.version}`,
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
  const workflow = JSON.parse(match[1] || "{}") as AgentWorkflow;
  const validation = validateWorkflow(workflow);
  if (!validation.valid) throw new Error(`invalid workflow: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return workflow;
}

export function saveWorkflow(root: string, workflow: AgentWorkflow): string {
  const target = workflowPath(root, workflow.id);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const temporary = `${target}.${process.pid}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporary, renderWorkflowOrg(workflow), "utf8");
  fs.renameSync(temporary, target);
  return target;
}

export function loadWorkflow(root: string, id: string): AgentWorkflow {
  return parseWorkflowOrg(fs.readFileSync(workflowPath(root, id), "utf8"));
}

export function listWorkflows(root: string): AgentWorkflow[] {
  const dir = workflowDirectory(root);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((name) => /\.org2$/i.test(name)).flatMap((name) => {
    try { return [parseWorkflowOrg(fs.readFileSync(path.join(dir, name), "utf8"))]; } catch { return []; }
  }).sort((a, b) => a.id.localeCompare(b.id));
}

function parseEvery(raw: string): number | null {
  const match = raw.trim().match(/^every\s+(\d+)\s*(m|h|d)$/i);
  if (!match) return null;
  const amount = Number(match[1]);
  return amount * (match[2]?.toLowerCase() === "m" ? 60_000 : match[2]?.toLowerCase() === "h" ? 3_600_000 : 86_400_000);
}

export function dueWorkflowTriggers(workflow: AgentWorkflow, options: { now?: string; changedPaths?: string[]; event?: "capture" | "meeting-import" } = {}): WorkflowTrigger[] {
  const now = new Date(options.now || Date.now()).getTime();
  return workflow.triggers.filter((trigger) => {
    if (!trigger.enabled || trigger.type === "manual") return false;
    if (trigger.type === options.event) return true;
    if (trigger.type === "file-change") return (options.changedPaths || []).some((item) => item === trigger.path || item.startsWith(`${trigger.path}/`));
    if (trigger.type === "schedule" && trigger.schedule) {
      const interval = parseEvery(trigger.schedule);
      if (!interval) return false;
      const last = trigger.lastRunAt ? new Date(trigger.lastRunAt).getTime() : 0;
      return Number.isFinite(last) && now - last >= interval;
    }
    return false;
  });
}

export function packagedWorkflowManifest(workflow: AgentWorkflow): Record<string, unknown> {
  return {
    schema: "org2:workflow-package:v1",
    id: workflow.id,
    version: workflow.version,
    title: workflow.title,
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
    directories: ["notes", "raw", "views", "compiled", ".org2/workflows", ".org2/runs"],
    starterFiles: [
      { path: "inbox.org2", content: "#+TITLE: Inbox\n\n* Inbox\n" },
      { path: "notes/welcome.org2", content: `#+TITLE: ${workflow.title}\n\nThis workspace includes the ${workflow.id} workflow.\n` },
    ],
    workflows: [packagedWorkflowManifest(workflow)],
  };
}
