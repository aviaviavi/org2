import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const ORG2_AGENT_RUN_SCHEMA = "org2:agent-run:v1" as const;

export const AGENT_RUN_STATUSES = [
  "queued",
  "running",
  "waiting-approval",
  "blocked",
  "completed",
  "failed",
  "canceled",
] as const;

export const AGENT_RUN_RISK_CLASSES = [
  "read-only",
  "local-draft",
  "canonical-write",
  "external-action",
  "high-impact",
] as const;

export const AGENT_RUN_STEP_KINDS = [
  "compiler",
  "agent",
  "tool",
  "approval",
  "artifact",
  "validation",
] as const;

export const AGENT_RUN_STEP_STATUSES = [
  "pending",
  "running",
  "completed",
  "blocked",
  "failed",
  "skipped",
] as const;

export const AGENT_RUN_ARTIFACT_ROLES = [
  "draft",
  "diff",
  "compiled",
  "view",
  "report",
  "export",
  "receipt",
] as const;

export const AGENT_RUN_ARTIFACT_REVIEW_STATUSES = [
  "generated",
  "review-required",
  "reviewed",
  "promoted",
  "rejected",
] as const;

export const AGENT_RUN_APPROVAL_DECISIONS = [
  "approved",
  "rejected",
  "revised",
  "canceled",
] as const;

export const AGENT_RUN_VALIDATION_STATUSES = [
  "passed",
  "failed",
  "warning",
  "skipped",
] as const;

export type AgentRunStatus = (typeof AGENT_RUN_STATUSES)[number];
export type AgentRunRiskClass = (typeof AGENT_RUN_RISK_CLASSES)[number];
export type AgentRunStepKind = (typeof AGENT_RUN_STEP_KINDS)[number];
export type AgentRunStepStatus = (typeof AGENT_RUN_STEP_STATUSES)[number];
export type AgentRunArtifactRole = (typeof AGENT_RUN_ARTIFACT_ROLES)[number];
export type AgentRunArtifactReviewStatus = (typeof AGENT_RUN_ARTIFACT_REVIEW_STATUSES)[number];
export type AgentRunApprovalDecision = (typeof AGENT_RUN_APPROVAL_DECISIONS)[number];
export type AgentRunApprovalStatus = "pending" | AgentRunApprovalDecision;
export type AgentRunValidationStatus = (typeof AGENT_RUN_VALIDATION_STATUSES)[number];

export interface AgentRunContextRef {
  ref: string;
  title?: string;
  citation?: string;
  sha256?: string;
}

export interface AgentRunPlanStep {
  id: string;
  title: string;
  kind: AgentRunStepKind;
  status: AgentRunStepStatus;
  capability?: string;
  startedAt?: string;
  completedAt?: string;
  detail?: string;
}

export interface AgentRunArtifact {
  id: string;
  path: string;
  role: AgentRunArtifactRole;
  title?: string;
  mediaType?: string;
  sha256?: string;
  reviewStatus?: AgentRunArtifactReviewStatus;
  createdAt: string;
}

export interface AgentRunApproval {
  id: string;
  title: string;
  action: string;
  riskClass: AgentRunRiskClass;
  status: AgentRunApprovalStatus;
  requestedRole?: string;
  requestedFrom?: string;
  requestedAt: string;
  decidedAt?: string;
  decidedBy?: string;
  note?: string;
  receipt?: string;
}

export interface AgentRunValidation {
  id: string;
  name: string;
  status: AgentRunValidationStatus;
  checkedAt: string;
  detail?: string;
}

export interface AgentRunComment {
  id: string;
  author: string;
  body: string;
  createdAt: string;
}

export interface AgentRunEvent {
  id: string;
  type: string;
  at: string;
  actor?: string;
  detail?: string;
  data?: Record<string, unknown>;
}

export interface AgentRunBudget {
  tokenLimit?: number;
  costLimitUsd?: number;
  timeLimitSeconds?: number;
  tokensUsed?: number;
  costUsedUsd?: number;
  elapsedSeconds?: number;
}

export interface AgentRun {
  schema: typeof ORG2_AGENT_RUN_SCHEMA;
  id: string;
  goal: string;
  acceptanceCriteria: string[];
  status: AgentRunStatus;
  riskClass: AgentRunRiskClass;
  owner?: string;
  assignee?: string;
  workflowId?: string;
  workflowVersion?: string;
  providerPolicy?: string;
  provider?: string;
  model?: string;
  capabilities: string[];
  context: AgentRunContextRef[];
  plan: AgentRunPlanStep[];
  artifacts: AgentRunArtifact[];
  approvals: AgentRunApproval[];
  validations: AgentRunValidation[];
  comments: AgentRunComment[];
  events: AgentRunEvent[];
  budget?: AgentRunBudget;
  parentRunId?: string;
  forkedFromEventId?: string;
  createdAt: string;
  updatedAt: string;
  startedAt?: string;
  completedAt?: string;
  blockedReason?: string;
  failure?: string;
}

export interface AgentRunCreateInput {
  id?: string;
  goal: string;
  acceptanceCriteria?: string[];
  status?: AgentRunStatus;
  riskClass?: AgentRunRiskClass;
  owner?: string;
  assignee?: string;
  workflowId?: string;
  workflowVersion?: string;
  providerPolicy?: string;
  provider?: string;
  model?: string;
  capabilities?: string[];
  context?: AgentRunContextRef[];
  plan?: Array<Omit<AgentRunPlanStep, "id" | "status"> & { id?: string; status?: AgentRunStepStatus }>;
  budget?: AgentRunBudget;
  parentRunId?: string;
  forkedFromEventId?: string;
  now?: string;
}

export interface AgentRunValidationIssue {
  path: string;
  message: string;
}

export interface AgentRunValidationResult {
  valid: boolean;
  issues: AgentRunValidationIssue[];
}

const TRANSITIONS: Record<AgentRunStatus, readonly AgentRunStatus[]> = {
  queued: ["running", "waiting-approval", "blocked", "canceled", "failed"],
  running: ["waiting-approval", "blocked", "completed", "failed", "canceled"],
  "waiting-approval": ["running", "blocked", "completed", "failed", "canceled"],
  blocked: ["queued", "running", "failed", "canceled"],
  completed: [],
  failed: ["queued", "running", "canceled"],
  canceled: ["queued"],
};

function unique(values: readonly string[] | undefined): string[] {
  return Array.from(new Set((values || []).map((value) => String(value || "").trim()).filter(Boolean)));
}

function optional(raw: unknown): string | undefined {
  const value = String(raw || "").trim();
  return value || undefined;
}

function safeId(raw: string): string {
  const value = String(raw || "").trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value)) {
    throw new Error("run id must start with an alphanumeric character and contain only letters, numbers, dots, underscores, or dashes");
  }
  return value;
}

function isoNow(raw?: string): string {
  const date = raw ? new Date(raw) : new Date();
  if (Number.isNaN(date.getTime())) throw new Error(`invalid timestamp: ${raw}`);
  return date.toISOString();
}

function event(type: string, at: string, actor?: string, detail?: string, data?: Record<string, unknown>): AgentRunEvent {
  return {
    id: crypto.randomUUID(),
    type,
    at,
    ...(optional(actor) ? { actor: optional(actor) } : {}),
    ...(optional(detail) ? { detail: optional(detail) } : {}),
    ...(data && Object.keys(data).length > 0 ? { data } : {}),
  };
}

export function createAgentRun(input: AgentRunCreateInput): AgentRun {
  const now = isoNow(input.now);
  const id = safeId(input.id || crypto.randomUUID());
  const goal = String(input.goal || "").trim();
  if (!goal) throw new Error("run goal is required");
  const status = input.status || "queued";
  if (!AGENT_RUN_STATUSES.includes(status)) throw new Error(`invalid run status: ${status}`);
  const riskClass = input.riskClass || "local-draft";
  if (!AGENT_RUN_RISK_CLASSES.includes(riskClass)) throw new Error(`invalid run risk class: ${riskClass}`);
  if (input.budget) {
    for (const [name, value] of Object.entries(input.budget)) {
      if (value !== undefined && (!Number.isFinite(value) || value < 0)) throw new Error(`run budget ${name} must be a non-negative finite number`);
    }
  }

  const run: AgentRun = {
    schema: ORG2_AGENT_RUN_SCHEMA,
    id,
    goal,
    acceptanceCriteria: unique(input.acceptanceCriteria),
    status,
    riskClass,
    capabilities: unique(input.capabilities),
    context: (input.context || []).map((item) => ({
      ref: String(item.ref || "").trim(),
      ...(optional(item.title) ? { title: optional(item.title) } : {}),
      ...(optional(item.citation) ? { citation: optional(item.citation) } : {}),
      ...(optional(item.sha256) ? { sha256: optional(item.sha256)?.toLowerCase() } : {}),
    })).filter((item) => item.ref),
    plan: (input.plan || []).map((step, index) => {
      if (!AGENT_RUN_STEP_KINDS.includes(step.kind)) throw new Error(`invalid run step kind: ${step.kind}`);
      const status = step.status || "pending";
      if (!AGENT_RUN_STEP_STATUSES.includes(status)) throw new Error(`invalid run step status: ${status}`);
      return {
        id: safeId(step.id || `step-${index + 1}`),
        title: String(step.title || "").trim(),
        kind: step.kind,
        status,
        ...(optional(step.capability) ? { capability: optional(step.capability) } : {}),
        ...(optional(step.detail) ? { detail: optional(step.detail) } : {}),
      };
    }).filter((step) => step.title),
    artifacts: [],
    approvals: [],
    validations: [],
    comments: [],
    events: [event("created", now, input.owner, goal)],
    createdAt: now,
    updatedAt: now,
    ...(optional(input.owner) ? { owner: optional(input.owner) } : {}),
    ...(optional(input.assignee) ? { assignee: optional(input.assignee) } : {}),
    ...(optional(input.workflowId) ? { workflowId: optional(input.workflowId) } : {}),
    ...(optional(input.workflowVersion) ? { workflowVersion: optional(input.workflowVersion) } : {}),
    ...(optional(input.providerPolicy) ? { providerPolicy: optional(input.providerPolicy) } : {}),
    ...(optional(input.provider) ? { provider: optional(input.provider) } : {}),
    ...(optional(input.model) ? { model: optional(input.model) } : {}),
    ...(input.budget ? { budget: { ...input.budget } } : {}),
    ...(optional(input.parentRunId) ? { parentRunId: optional(input.parentRunId) } : {}),
    ...(optional(input.forkedFromEventId) ? { forkedFromEventId: optional(input.forkedFromEventId) } : {}),
  };
  if (status === "running") run.startedAt = now;
  if (status === "completed") run.completedAt = now;
  return run;
}

export function validateAgentRun(value: unknown): AgentRunValidationResult {
  const issues: AgentRunValidationIssue[] = [];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { valid: false, issues: [{ path: "$", message: "run must be an object" }] };
  }
  const run = value as Partial<AgentRun>;
  if (run.schema !== ORG2_AGENT_RUN_SCHEMA) issues.push({ path: "$.schema", message: `must be ${ORG2_AGENT_RUN_SCHEMA}` });
  if (!run.id || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(run.id)) issues.push({ path: "$.id", message: "must be a safe non-empty id" });
  if (!String(run.goal || "").trim()) issues.push({ path: "$.goal", message: "must not be empty" });
  if (!run.status || !AGENT_RUN_STATUSES.includes(run.status)) issues.push({ path: "$.status", message: `must be one of: ${AGENT_RUN_STATUSES.join(", ")}` });
  if (!run.riskClass || !AGENT_RUN_RISK_CLASSES.includes(run.riskClass)) issues.push({ path: "$.riskClass", message: `must be one of: ${AGENT_RUN_RISK_CLASSES.join(", ")}` });
  for (const field of ["acceptanceCriteria", "capabilities", "context", "plan", "artifacts", "approvals", "validations", "comments", "events"] as const) {
    if (!Array.isArray(run[field])) issues.push({ path: `$.${field}`, message: "must be an array" });
  }
  for (const field of ["createdAt", "updatedAt"] as const) {
    const raw = run[field];
    if (!raw || Number.isNaN(new Date(raw).getTime())) issues.push({ path: `$.${field}`, message: "must be an ISO timestamp" });
  }
  for (const [name, value] of Object.entries(run.budget || {})) {
    if (value !== undefined && (!Number.isFinite(value) || value < 0)) issues.push({ path: `$.budget.${name}`, message: "must be a non-negative finite number" });
  }
  const stepIds = new Set<string>();
  for (const [index, step] of (run.plan || []).entries()) {
    if (!step.id || stepIds.has(step.id)) issues.push({ path: `$.plan[${index}].id`, message: "must be unique and non-empty" });
    stepIds.add(step.id);
    if (!String(step.title || "").trim()) issues.push({ path: `$.plan[${index}].title`, message: "must not be empty" });
  }
  return { valid: issues.length === 0, issues };
}

export function transitionAgentRun(run: AgentRun, status: AgentRunStatus, options: { actor?: string; reason?: string; now?: string } = {}): AgentRun {
  if (run.status === status) return { ...run };
  if (!TRANSITIONS[run.status].includes(status)) throw new Error(`run cannot transition from ${run.status} to ${status}`);
  const now = isoNow(options.now);
  const next: AgentRun = {
    ...run,
    status,
    updatedAt: now,
    events: [...run.events, event("status-changed", now, options.actor, `${run.status} -> ${status}`, { from: run.status, to: status, ...(options.reason ? { reason: options.reason } : {}) })],
  };
  if (status === "running" && !next.startedAt) next.startedAt = now;
  if (status === "completed") next.completedAt = now;
  if (status !== "blocked") delete next.blockedReason;
  if (status === "blocked") next.blockedReason = optional(options.reason) || "Blocked pending clarification";
  if (status === "failed") next.failure = optional(options.reason) || "Run failed";
  if (status !== "failed") delete next.failure;
  return next;
}

export function updateAgentRunAssignment(run: AgentRun, input: { owner?: string; assignee?: string; actor?: string; now?: string }): AgentRun {
  const now = isoNow(input.now);
  return {
    ...run,
    ...(input.owner !== undefined ? { owner: optional(input.owner) } : {}),
    ...(input.assignee !== undefined ? { assignee: optional(input.assignee) } : {}),
    updatedAt: now,
    events: [...run.events, event("assigned", now, input.actor, `owner=${optional(input.owner) || run.owner || ""}; assignee=${optional(input.assignee) || run.assignee || ""}`)],
  };
}

export function addAgentRunComment(run: AgentRun, author: string, body: string, nowRaw?: string): AgentRun {
  const now = isoNow(nowRaw);
  const cleanAuthor = String(author || "").trim();
  const cleanBody = String(body || "").trim();
  if (!cleanAuthor || !cleanBody) throw new Error("comment author and body are required");
  const comment: AgentRunComment = { id: crypto.randomUUID(), author: cleanAuthor, body: cleanBody, createdAt: now };
  return { ...run, comments: [...run.comments, comment], updatedAt: now, events: [...run.events, event("commented", now, cleanAuthor, cleanBody)] };
}

export function addAgentRunArtifact(run: AgentRun, input: Omit<AgentRunArtifact, "id" | "createdAt"> & { id?: string; createdAt?: string }, actor?: string): AgentRun {
  const now = isoNow(input.createdAt);
  const artifactPath = String(input.path || "").trim();
  if (!artifactPath) throw new Error("artifact path is required");
  if (!AGENT_RUN_ARTIFACT_ROLES.includes(input.role)) throw new Error(`invalid artifact role: ${input.role}`);
  if (input.reviewStatus && !AGENT_RUN_ARTIFACT_REVIEW_STATUSES.includes(input.reviewStatus)) throw new Error(`invalid artifact review status: ${input.reviewStatus}`);
  const artifact: AgentRunArtifact = {
    id: safeId(input.id || crypto.randomUUID()),
    path: artifactPath,
    role: input.role,
    createdAt: now,
    ...(optional(input.title) ? { title: optional(input.title) } : {}),
    ...(optional(input.mediaType) ? { mediaType: optional(input.mediaType) } : {}),
    ...(optional(input.sha256) ? { sha256: optional(input.sha256)?.toLowerCase() } : {}),
    ...(input.reviewStatus ? { reviewStatus: input.reviewStatus } : {}),
  };
  return { ...run, artifacts: [...run.artifacts, artifact], updatedAt: now, events: [...run.events, event("artifact-added", now, actor, artifactPath, { artifactId: artifact.id, role: artifact.role })] };
}

export function addAgentRunValidation(run: AgentRun, input: Omit<AgentRunValidation, "id" | "checkedAt"> & { id?: string; checkedAt?: string }, actor?: string): AgentRun {
  const now = isoNow(input.checkedAt);
  const validation: AgentRunValidation = {
    id: safeId(input.id || crypto.randomUUID()),
    name: String(input.name || "").trim(),
    status: input.status,
    checkedAt: now,
    ...(optional(input.detail) ? { detail: optional(input.detail) } : {}),
  };
  if (!validation.name) throw new Error("validation name is required");
  if (!AGENT_RUN_VALIDATION_STATUSES.includes(validation.status)) throw new Error(`invalid validation status: ${validation.status}`);
  return { ...run, validations: [...run.validations, validation], updatedAt: now, events: [...run.events, event("validated", now, actor, `${validation.name}: ${validation.status}`)] };
}

export function requestAgentRunApproval(run: AgentRun, input: Omit<AgentRunApproval, "id" | "status" | "requestedAt"> & { id?: string; requestedAt?: string }, actor?: string): AgentRun {
  if (["completed", "failed", "canceled"].includes(run.status)) throw new Error(`cannot request approval for a ${run.status} run`);
  if (!AGENT_RUN_RISK_CLASSES.includes(input.riskClass)) throw new Error(`invalid approval risk class: ${input.riskClass}`);
  const now = isoNow(input.requestedAt);
  const approval: AgentRunApproval = {
    id: safeId(input.id || crypto.randomUUID()),
    title: String(input.title || "").trim(),
    action: String(input.action || "").trim(),
    riskClass: input.riskClass,
    status: "pending",
    requestedAt: now,
    ...(optional(input.requestedRole) ? { requestedRole: optional(input.requestedRole) } : {}),
    ...(optional(input.requestedFrom) ? { requestedFrom: optional(input.requestedFrom) } : {}),
    ...(optional(input.note) ? { note: optional(input.note) } : {}),
    ...(optional(input.receipt) ? { receipt: optional(input.receipt) } : {}),
  };
  if (!approval.title || !approval.action) throw new Error("approval title and action are required");
  const next = run.status === "running" || run.status === "queued" ? transitionAgentRun(run, "waiting-approval", { actor, now }) : { ...run };
  return { ...next, approvals: [...next.approvals, approval], updatedAt: now, events: [...next.events, event("approval-requested", now, actor, approval.title, { approvalId: approval.id, riskClass: approval.riskClass })] };
}

export function decideAgentRunApproval(run: AgentRun, approvalId: string, decision: AgentRunApprovalDecision, input: { actor: string; actorRole?: string; note?: string; receipt?: string; now?: string }): AgentRun {
  const now = isoNow(input.now);
  if (!AGENT_RUN_APPROVAL_DECISIONS.includes(decision)) throw new Error(`invalid approval decision: ${decision}`);
  const index = run.approvals.findIndex((approval) => approval.id === approvalId);
  if (index < 0) throw new Error(`approval not found: ${approvalId}`);
  if (run.approvals[index]!.status !== "pending") throw new Error(`approval is already ${run.approvals[index]!.status}`);
  if (run.approvals[index]!.requestedRole && input.actorRole !== run.approvals[index]!.requestedRole) throw new Error(`approval requires role ${run.approvals[index]!.requestedRole}; pass the matching actor role`);
  if (run.approvals[index]!.requestedFrom && input.actor !== run.approvals[index]!.requestedFrom) throw new Error(`approval is assigned to ${run.approvals[index]!.requestedFrom}`);
  const approvals = [...run.approvals];
  approvals[index] = {
    ...approvals[index]!,
    status: decision,
    decidedAt: now,
    decidedBy: String(input.actor || "").trim(),
    ...(optional(input.note) ? { note: optional(input.note) } : {}),
    ...(optional(input.receipt) ? { receipt: optional(input.receipt) } : {}),
  };
  let next: AgentRun = { ...run, approvals, updatedAt: now, events: [...run.events, event("approval-decided", now, input.actor, `${approvalId}: ${decision}`, { approvalId, decision, ...(input.actorRole ? { actorRole: input.actorRole } : {}) })] };
  if (run.status === "waiting-approval" && approvals.every((approval) => approval.status !== "pending")) {
    const allApproved = approvals.every((approval) => approval.status === "approved");
    next = transitionAgentRun(next, allApproved ? "running" : "blocked", { actor: input.actor, reason: allApproved ? undefined : "One or more approvals were not approved", now });
  }
  return next;
}

export function updateAgentRunStep(run: AgentRun, stepId: string, status: AgentRunStepStatus, input: { actor?: string; detail?: string; now?: string } = {}): AgentRun {
  const now = isoNow(input.now);
  if (!AGENT_RUN_STEP_STATUSES.includes(status)) throw new Error(`invalid run step status: ${status}`);
  const index = run.plan.findIndex((step) => step.id === stepId);
  if (index < 0) throw new Error(`plan step not found: ${stepId}`);
  const plan = [...run.plan];
  const existing = plan[index]!;
  plan[index] = {
    ...existing,
    status,
    ...(status === "running" && !existing.startedAt ? { startedAt: now } : {}),
    ...(["completed", "failed", "skipped"].includes(status) ? { completedAt: now } : {}),
    ...(optional(input.detail) ? { detail: optional(input.detail) } : {}),
  };
  return { ...run, plan, updatedAt: now, events: [...run.events, event("step-updated", now, input.actor, `${stepId}: ${status}`, { stepId, status })] };
}

export function forkAgentRun(run: AgentRun, input: { id?: string; actor?: string; fromEventId?: string; now?: string } = {}): AgentRun {
  const fork = createAgentRun({
    id: input.id,
    goal: run.goal,
    acceptanceCriteria: run.acceptanceCriteria,
    riskClass: run.riskClass,
    owner: run.owner,
    assignee: run.assignee,
    workflowId: run.workflowId,
    workflowVersion: run.workflowVersion,
    providerPolicy: run.providerPolicy,
    capabilities: run.capabilities,
    context: run.context,
    plan: run.plan.map((step) => ({ title: step.title, kind: step.kind, capability: step.capability, detail: step.detail })),
    budget: run.budget ? { tokenLimit: run.budget.tokenLimit, costLimitUsd: run.budget.costLimitUsd, timeLimitSeconds: run.budget.timeLimitSeconds } : undefined,
    parentRunId: run.id,
    forkedFromEventId: input.fromEventId || run.events.at(-1)?.id,
    now: input.now,
  });
  fork.events.push(event("forked", fork.createdAt, input.actor, `Forked from ${run.id}`, { parentRunId: run.id }));
  return fork;
}

function orgEscape(raw: string): string {
  return String(raw || "").replace(/\r?\n/g, " ").trim();
}

function todoKeyword(status: AgentRunStatus): string {
  if (status === "completed") return "DONE";
  if (status === "canceled") return "CANCELED";
  return "TODO";
}

export function renderAgentRunOrg(run: AgentRun): string {
  const validation = validateAgentRun(run);
  if (!validation.valid) throw new Error(`invalid run: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  const lines = [
    `#+TITLE: Run: ${orgEscape(run.goal)}`,
    "#+ORG2_KIND: agent-run",
    "",
    `* ${todoKeyword(run.status)} ${orgEscape(run.goal)} :agent-run:`,
    ":PROPERTIES:",
    `:ID: ${run.id}`,
    `:KIND: agent-run`,
    `:RUN_SCHEMA: ${run.schema}`,
    `:RUN_STATUS: ${run.status}`,
    `:RISK_CLASS: ${run.riskClass}`,
    ...(run.owner ? [`:OWNER: ${orgEscape(run.owner)}`] : []),
    ...(run.assignee ? [`:ASSIGNEE: ${orgEscape(run.assignee)}`] : []),
    ...(run.workflowId ? [`:WORKFLOW_ID: ${orgEscape(run.workflowId)}`] : []),
    ...(run.workflowVersion ? [`:WORKFLOW_VERSION: ${orgEscape(run.workflowVersion)}`] : []),
    ...(run.providerPolicy ? [`:PROVIDER_POLICY: ${orgEscape(run.providerPolicy)}`] : []),
    ...(run.provider ? [`:PROVIDER: ${orgEscape(run.provider)}`] : []),
    ...(run.model ? [`:MODEL: ${orgEscape(run.model)}`] : []),
    `:CREATED_AT: ${run.createdAt}`,
    `:UPDATED_AT: ${run.updatedAt}`,
    ...(run.startedAt ? [`:STARTED_AT: ${run.startedAt}`] : []),
    ...(run.completedAt ? [`:COMPLETED_AT: ${run.completedAt}`] : []),
    ":END:",
    "",
    "** Goal",
    run.goal,
    "",
    "** Acceptance criteria",
    ...(run.acceptanceCriteria.length ? run.acceptanceCriteria.map((item) => `- ${item}`) : ["- None recorded."]),
    "",
    "** Plan",
    ...(run.plan.length ? run.plan.map((step) => `- [${step.status === "completed" ? "X" : step.status === "pending" ? " " : "-"}] ${step.title} =${step.id}= (${step.kind}; ${step.status})`) : ["- No plan recorded."]),
    "",
    "** Context",
    ...(run.context.length ? run.context.map((item) => `- ${item.citation || item.ref}${item.title ? ` — ${item.title}` : ""}`) : ["- No context recorded."]),
    "",
    "** Artifacts",
    ...(run.artifacts.length ? run.artifacts.map((artifact) => `- [[file:${artifact.path}][${artifact.title || artifact.path}]] (${artifact.role}; ${artifact.reviewStatus || "generated"})`) : ["- No artifacts recorded."]),
    "",
    "** Approvals",
    ...(run.approvals.length ? run.approvals.map((approval) => `- ${approval.status.toUpperCase()} ${approval.title} — ${approval.action} (${approval.riskClass})`) : ["- No approvals recorded."]),
    "",
    "** Validations",
    ...(run.validations.length ? run.validations.map((item) => `- ${item.status.toUpperCase()} ${item.name}${item.detail ? ` — ${item.detail}` : ""}`) : ["- No validations recorded."]),
    "",
    "** Machine state",
    "#+begin_src json :org2-agent-run",
    JSON.stringify(run, null, 2),
    "#+end_src",
    "",
  ];
  return lines.join("\n");
}

export function parseAgentRunOrg(raw: string): AgentRun {
  const match = /#\+begin_src\s+json\s+:org2-agent-run\s*\n([\s\S]*?)\n#\+end_src/i.exec(String(raw || "").replace(/\r\n/g, "\n"));
  if (!match) throw new Error("Org2 agent run is missing its machine-state JSON block");
  const value = JSON.parse(match[1]!) as AgentRun;
  const validation = validateAgentRun(value);
  if (!validation.valid) throw new Error(`invalid Org2 agent run: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return value;
}

export function agentRunDirectory(corpusRoot: string): string {
  return path.join(path.resolve(corpusRoot), ".org2", "runs");
}

export function agentRunPath(corpusRoot: string, id: string): string {
  return path.join(agentRunDirectory(corpusRoot), `${safeId(id)}.org2`);
}

export function saveAgentRun(corpusRoot: string, run: AgentRun): string {
  const outputPath = agentRunPath(corpusRoot, run.id);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  const tempPath = `${outputPath}.${process.pid}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(tempPath, renderAgentRunOrg(run), "utf8");
  fs.renameSync(tempPath, outputPath);
  return outputPath;
}

export function loadAgentRun(corpusRoot: string, id: string): AgentRun {
  const file = agentRunPath(corpusRoot, id);
  if (!fs.existsSync(file)) throw new Error(`run not found: ${id}`);
  return parseAgentRunOrg(fs.readFileSync(file, "utf8"));
}

export function listAgentRuns(corpusRoot: string): AgentRun[] {
  const dir = agentRunDirectory(corpusRoot);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".org2"))
    .map((entry) => parseAgentRunOrg(fs.readFileSync(path.join(dir, entry.name), "utf8")))
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt) || a.id.localeCompare(b.id));
}

function walkOrgFiles(root: string, output: string[] = []): string[] {
  if (!fs.existsSync(root)) return output;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    if ([".git", "node_modules", "site", "dist"].includes(entry.name)) continue;
    const absolute = path.join(root, entry.name);
    if (entry.isDirectory()) {
      if (absolute === agentRunDirectory(root)) continue;
      walkOrgFiles(absolute, output);
    } else if (entry.isFile() && /\.(org2?|ORG2?)$/.test(entry.name)) {
      output.push(absolute);
    }
  }
  return output;
}

function normalizeLegacyStatus(raw: string): AgentRunStatus {
  const value = String(raw || "").trim().toLowerCase().replace(/_/g, "-");
  if (["done", "complete", "completed", "promoted", "merged"].includes(value)) return "completed";
  if (["running", "in-progress", "active", "delegated"].includes(value)) return "running";
  if (value.includes("approval") || value.includes("review")) return "waiting-approval";
  if (value.includes("block") || value.includes("clarification") || value.includes("needs-avi") || value.includes("needs-human")) return "blocked";
  if (["failed", "error"].includes(value)) return "failed";
  if (["canceled", "cancelled", "rejected"].includes(value)) return "canceled";
  return "queued";
}

export interface LegacyAgentRunNormalizationResult {
  created: Array<{ id: string; file: string; runFile: string }>;
  skippedExisting: string[];
}

export function normalizeLegacyAgentRuns(corpusRoot: string, nowRaw?: string): LegacyAgentRunNormalizationResult {
  const root = path.resolve(corpusRoot);
  const existing = new Set(listAgentRuns(root).map((run) => run.id));
  const result: LegacyAgentRunNormalizationResult = { created: [], skippedExisting: [] };
  for (const file of walkOrgFiles(root)) {
    if (file.startsWith(agentRunDirectory(root) + path.sep)) continue;
    const lines = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n").split("\n");
    for (let index = 0; index < lines.length; index += 1) {
      const match = /^\s*:AGENT_RUN_ID:\s*(\S.*?)\s*$/i.exec(lines[index] || "");
      if (!match) continue;
      const id = String(match[1] || "").trim();
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) continue;
      if (existing.has(id)) {
        if (!result.skippedExisting.includes(id)) result.skippedExisting.push(id);
        continue;
      }
      let headingIndex = index;
      while (headingIndex >= 0 && !/^\*+\s+/.test(lines[headingIndex] || "")) headingIndex -= 1;
      const heading = headingIndex >= 0 ? String(lines[headingIndex] || "").replace(/^\*+\s+(?:(?:TODO|DONE|CANCELED|CANCELLED|WAIT|HOLD|IN_PROGRESS|IN-PROGRESS)\s+)?/i, "").replace(/\s+:[^\s:]+(?::[^\s:]+)*:\s*$/, "").trim() : `Imported agent run ${id}`;
      const props = new Map<string, string>();
      let drawerStart = index;
      while (drawerStart >= headingIndex && !/^\s*:PROPERTIES:\s*$/i.test(lines[drawerStart] || "")) drawerStart -= 1;
      if (drawerStart >= headingIndex) {
        for (let propertyIndex = drawerStart + 1; propertyIndex < lines.length; propertyIndex += 1) {
          if (/^\s*:END:\s*$/i.test(lines[propertyIndex] || "")) break;
          const property = /^\s*:([^:]+):\s*(.*?)\s*$/.exec(lines[propertyIndex] || "");
          if (property) props.set(property[1]!.trim().toUpperCase(), property[2]!.trim());
        }
      }
      const status = normalizeLegacyStatus(props.get("STATUS") || props.get("AGENT_STATUS") || (headingIndex >= 0 ? lines[headingIndex] || "" : ""));
      let run = createAgentRun({
        id,
        goal: heading || `Imported agent run ${id}`,
        status,
        owner: props.get("OWNER"),
        assignee: props.get("ASSIGNEE"),
        providerPolicy: props.get("PROVIDER_POLICY"),
        context: [
          { ref: `file:${path.relative(root, file).split(path.sep).join("/")}::${headingIndex + 1}`, citation: `${path.relative(root, file).split(path.sep).join("/")}:${headingIndex + 1}` },
          ...([props.get("AGENT_SESSION_ID"), props.get("OPENCLAW_SESSION_ID"), props.get("SESSION_ID")].filter(Boolean).slice(0, 1).map((session) => ({ ref: `session:${session}` }))),
        ],
        parentRunId: props.get("PARENT_RUN_ID"),
        now: nowRaw,
      });
      const artifactRole = String(props.get("ORG2_ARTIFACT_ROLE") || props.get("ARTIFACT_ROLE") || "").toLowerCase();
      if (["draft", "diff", "compiled", "view", "report", "export", "receipt"].includes(artifactRole)) {
        run = addAgentRunArtifact(run, {
          path: path.relative(root, file).split(path.sep).join("/"),
          role: artifactRole as AgentRunArtifact["role"],
          title: heading,
          reviewStatus: (["generated", "review-required", "reviewed", "promoted", "rejected"].includes(String(props.get("ORG2_REVIEW_STATUS") || "").toLowerCase()) ? String(props.get("ORG2_REVIEW_STATUS")).toLowerCase() : "review-required") as AgentRunArtifact["reviewStatus"],
        }, "org2");
      }
      const approvalStatus = String(props.get("APPROVAL_STATUS") || props.get("REVIEW_STATUS") || "").toLowerCase();
      const needsApproval = /^(1|true|yes|pending|required)$/i.test(String(props.get("NEEDS_APPROVAL") || "")) || approvalStatus === "pending" || status === "waiting-approval";
      if (needsApproval) {
        run = requestAgentRunApproval(run, {
          title: props.get("APPROVAL_TITLE") || `Review ${heading}`,
          action: props.get("APPROVAL_ACTION") || "Review the imported agent work before promotion or external action",
          riskClass: (AGENT_RUN_RISK_CLASSES.includes(props.get("RISK_CLASS") as AgentRunRiskClass) ? props.get("RISK_CLASS") : "canonical-write") as AgentRunRiskClass,
          requestedRole: props.get("APPROVAL_ROLE"),
          requestedFrom: props.get("APPROVER"),
        }, "org2");
      }
      run.events.push(event("legacy-imported", run.createdAt, "org2", `Imported from ${path.relative(root, file)}:${headingIndex + 1}`));
      const runFile = saveAgentRun(root, run);
      existing.add(id);
      result.created.push({ id, file, runFile });
    }
  }
  return result;
}
