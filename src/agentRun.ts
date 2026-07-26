import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { withFileMutationLock, writeTextAtomicallyIfUnchanged } from "./atomicFileMutation.js";
import {
  approvalMaterialIssues,
  approvalReviewability,
  computeApprovalFingerprint,
  computeApprovalMaterialDigest,
  isApprovalFingerprint,
  normalizeApprovalMaterial,
  type AgentRunApprovalEffectReceipt,
  type AgentRunApprovalEffectReservation,
  type AgentRunApprovalMaterial,
} from "./approval.js";

export type {
  AgentRunApprovalEffectReceipt,
  AgentRunApprovalEffectReservation,
  AgentRunApprovalMaterial,
} from "./approval.js";

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

export const AGENT_RUN_APPROVAL_BLOCK_REASON = "One or more approvals were not approved";

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
  requirementId?: string;
  fingerprint?: string;
  material?: AgentRunApprovalMaterial;
  supersedesId?: string;
  requestedRole?: string;
  requestedFrom?: string;
  requestedAt: string;
  decidedAt?: string;
  decidedBy?: string;
  note?: string;
  decisionNote?: string;
  receipt?: string;
  effectReservation?: AgentRunApprovalEffectReservation;
  effectReceipt?: AgentRunApprovalEffectReceipt;
}

export interface AgentRunApprovalRequirement {
  id: string;
  title: string;
  action: string;
  riskClass: AgentRunRiskClass;
  requestedRole?: string;
  beforeStepId?: string;
}

export type AgentRunApprovalRequirementState = "unbound" | "pending" | "approved" | "denied";

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

export interface AgentRunOutcome {
  summary: string;
  highlights: string[];
  nextActions: string[];
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
  approvalRequirements?: AgentRunApprovalRequirement[];
  validations: AgentRunValidation[];
  comments: AgentRunComment[];
  events: AgentRunEvent[];
  outcome?: AgentRunOutcome;
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
  approvalRequirements?: AgentRunApprovalRequirement[];
  outcome?: Partial<AgentRunOutcome>;
  budget?: AgentRunBudget;
  parentRunId?: string;
  forkedFromEventId?: string;
  now?: string;
}

export interface AgentRunRuntimeUpdate {
  provider?: string;
  model?: string;
  tokensUsed?: number;
  costUsedUsd?: number;
  elapsedSeconds?: number;
  actor?: string;
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
  blocked: ["queued", "running", "waiting-approval", "failed", "canceled"],
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

  const plan = (input.plan || []).map((step, index) => {
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
  }).filter((step) => step.title);
  const planIds = new Set(plan.map((step) => step.id));
  const requirementIds = new Set<string>();
  const approvalRequirements = (input.approvalRequirements || []).map((requirement) => {
    const requirementId = safeId(requirement.id);
    if (requirementIds.has(requirementId)) throw new Error(`approval requirement id already exists: ${requirementId}`);
    requirementIds.add(requirementId);
    if (!AGENT_RUN_RISK_CLASSES.includes(requirement.riskClass)) {
      throw new Error(`invalid approval requirement risk class: ${requirement.riskClass}`);
    }
    const title = String(requirement.title || "").trim();
    const action = String(requirement.action || "").trim();
    if (!title || !action) throw new Error("approval requirement title and action are required");
    const beforeStepId = optional(requirement.beforeStepId);
    if (beforeStepId && !planIds.has(beforeStepId)) {
      throw new Error(`approval requirement ${requirementId} references unknown step ${beforeStepId}`);
    }
    return {
      id: requirementId,
      title,
      action,
      riskClass: requirement.riskClass,
      ...(optional(requirement.requestedRole) ? { requestedRole: optional(requirement.requestedRole) } : {}),
      ...(beforeStepId ? { beforeStepId } : {}),
    };
  });

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
    plan,
    artifacts: [],
    approvals: [],
    ...(approvalRequirements.length > 0 ? { approvalRequirements } : {}),
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
    ...(optional(input.outcome?.summary) ? { outcome: {
      summary: optional(input.outcome?.summary)!,
      highlights: unique(input.outcome?.highlights),
      nextActions: unique(input.outcome?.nextActions),
    } } : {}),
  };
  if (status === "running") run.startedAt = now;
  if (status === "completed") {
    assertAgentRunApprovalRequirementsSatisfied(run, {
      action: "creating a completed run",
      allowSkippedStep: true,
    });
    run.completedAt = now;
  }
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
  if (run.approvalRequirements !== undefined && !Array.isArray(run.approvalRequirements)) {
    issues.push({ path: "$.approvalRequirements", message: "must be an array when present" });
  }
  for (const field of ["createdAt", "updatedAt"] as const) {
    const raw = run[field];
    if (!raw || Number.isNaN(new Date(raw).getTime())) issues.push({ path: `$.${field}`, message: "must be an ISO timestamp" });
  }
  for (const [name, value] of Object.entries(run.budget || {})) {
    if (value !== undefined && (!Number.isFinite(value) || value < 0)) issues.push({ path: `$.budget.${name}`, message: "must be a non-negative finite number" });
  }
  if (run.outcome !== undefined) {
    if (!String(run.outcome.summary || "").trim()) issues.push({ path: "$.outcome.summary", message: "must not be empty" });
    if (!Array.isArray(run.outcome.highlights)) issues.push({ path: "$.outcome.highlights", message: "must be an array" });
    if (!Array.isArray(run.outcome.nextActions)) issues.push({ path: "$.outcome.nextActions", message: "must be an array" });
  }
  const stepIds = new Set<string>();
  for (const [index, step] of (run.plan || []).entries()) {
    if (!step.id || stepIds.has(step.id)) issues.push({ path: `$.plan[${index}].id`, message: "must be unique and non-empty" });
    stepIds.add(step.id);
    if (!String(step.title || "").trim()) issues.push({ path: `$.plan[${index}].title`, message: "must not be empty" });
  }
  const requirements = Array.isArray(run.approvalRequirements) ? run.approvalRequirements : [];
  const requirementIds = new Set<string>();
  for (const [index, requirement] of requirements.entries()) {
    const base = `$.approvalRequirements[${index}]`;
    if (
      !requirement.id
      || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(requirement.id)
      || requirementIds.has(requirement.id)
    ) {
      issues.push({ path: `${base}.id`, message: "must be a unique safe non-empty id" });
    }
    requirementIds.add(requirement.id);
    if (!String(requirement.title || "").trim()) issues.push({ path: `${base}.title`, message: "must not be empty" });
    if (!String(requirement.action || "").trim()) issues.push({ path: `${base}.action`, message: "must not be empty" });
    if (!AGENT_RUN_RISK_CLASSES.includes(requirement.riskClass)) {
      issues.push({ path: `${base}.riskClass`, message: `must be one of: ${AGENT_RUN_RISK_CLASSES.join(", ")}` });
    }
    if (requirement.beforeStepId && !stepIds.has(requirement.beforeStepId)) {
      issues.push({ path: `${base}.beforeStepId`, message: "must reference a plan step in the same run" });
    }
  }
  const guardedStepIds = new Set(requirements.map((requirement) => requirement.beforeStepId).filter(Boolean));
  for (const [index, step] of (run.plan || []).entries()) {
    if (step.status === "skipped" && guardedStepIds.has(step.id) && !String(step.detail || "").trim()) {
      issues.push({
        path: `$.plan[${index}].detail`,
        message: "must record why no protected effect occurred when skipping an approval-guarded step",
      });
    }
  }
  const approvals = run.approvals || [];
  const approvalIds = new Set<string>();
  const pendingRequirementIds = new Set<string>();
  for (const [index, approval] of approvals.entries()) {
    const base = `$.approvals[${index}]`;
    if (!approval.id || approvalIds.has(approval.id)) issues.push({ path: `${base}.id`, message: "must be unique and non-empty" });
    approvalIds.add(approval.id);
    if (!String(approval.title || "").trim()) issues.push({ path: `${base}.title`, message: "must not be empty" });
    if (!String(approval.action || "").trim()) issues.push({ path: `${base}.action`, message: "must not be empty" });
    if (!AGENT_RUN_RISK_CLASSES.includes(approval.riskClass)) issues.push({ path: `${base}.riskClass`, message: `must be one of: ${AGENT_RUN_RISK_CLASSES.join(", ")}` });
    if (!["pending", ...AGENT_RUN_APPROVAL_DECISIONS].includes(approval.status)) issues.push({ path: `${base}.status`, message: "must be a valid approval status" });
    if (!approval.requestedAt || Number.isNaN(new Date(approval.requestedAt).getTime())) issues.push({ path: `${base}.requestedAt`, message: "must be an ISO timestamp" });
    if (approval.decidedAt && Number.isNaN(new Date(approval.decidedAt).getTime())) issues.push({ path: `${base}.decidedAt`, message: "must be an ISO timestamp" });
    if (approval.requirementId) {
      const requirement = requirements.find((candidate) => candidate.id === approval.requirementId);
      if (!requirement) {
        issues.push({ path: `${base}.requirementId`, message: "must reference an approval requirement in the same run" });
      } else {
        if (approval.title !== requirement.title) issues.push({ path: `${base}.title`, message: "must match the bound approval requirement" });
        if (approval.action !== requirement.action) issues.push({ path: `${base}.action`, message: "must match the bound approval requirement" });
        if (approval.riskClass !== requirement.riskClass) issues.push({ path: `${base}.riskClass`, message: "must match the bound approval requirement" });
        if ((approval.requestedRole || undefined) !== (requirement.requestedRole || undefined)) {
          issues.push({ path: `${base}.requestedRole`, message: "must match the bound approval requirement" });
        }
        const reviewability = approvalReviewability(approval);
        if (!reviewability.canApprove) {
          issues.push({ path: `${base}.material`, message: reviewability.reason || "must contain reviewable bound material" });
        }
      }
      if (approval.status === "pending") {
        if (pendingRequirementIds.has(approval.requirementId)) {
          issues.push({ path: `${base}.requirementId`, message: "must not have more than one pending request version" });
        }
        pendingRequirementIds.add(approval.requirementId);
      }
    }
    const materialIssues = approvalMaterialIssues(approval.material);
    for (const issue of materialIssues) issues.push({ path: `${base}.material`, message: issue });
    if (approval.fingerprint) {
      if (!isApprovalFingerprint(approval.fingerprint)) {
        issues.push({ path: `${base}.fingerprint`, message: "must be a sha256:<hex> digest" });
      } else if (materialIssues.length === 0 && approval.fingerprint !== computeApprovalFingerprint(approval)) {
        issues.push({ path: `${base}.fingerprint`, message: "does not match the immutable approval request material" });
      }
    }
    if (approval.effectReservation) {
      if (!approval.fingerprint || approval.effectReservation.fingerprint !== approval.fingerprint) {
        issues.push({ path: `${base}.effectReservation.fingerprint`, message: "must match the approved request fingerprint" });
      }
      if (!isApprovalFingerprint(approval.effectReservation.materialDigest)) {
        issues.push({ path: `${base}.effectReservation.materialDigest`, message: "must be a sha256:<hex> digest" });
      } else if (!approval.material || materialIssues.length > 0) {
        issues.push({ path: `${base}.effectReservation.materialDigest`, message: "requires valid bound approval material" });
      } else if (approval.effectReservation.materialDigest !== computeApprovalMaterialDigest(approval.material)) {
        issues.push({ path: `${base}.effectReservation.materialDigest`, message: "must match the bound approval material" });
      }
      if (!String(approval.effectReservation.toolCallId || "").trim()) {
        issues.push({ path: `${base}.effectReservation.toolCallId`, message: "must not be empty" });
      }
      if (Number.isNaN(new Date(approval.effectReservation.reservedAt).getTime())) {
        issues.push({ path: `${base}.effectReservation.reservedAt`, message: "must be an ISO timestamp" });
      }
      if (approval.effectReceipt) {
        issues.push({ path: `${base}.effectReservation`, message: "must be cleared after an effect receipt is recorded" });
      }
    }
    if (approval.effectReceipt) {
      if (!approval.fingerprint || approval.effectReceipt.fingerprint !== approval.fingerprint) {
        issues.push({ path: `${base}.effectReceipt.fingerprint`, message: "must match the approved request fingerprint" });
      }
      if (Number.isNaN(new Date(approval.effectReceipt.performedAt).getTime())) {
        issues.push({ path: `${base}.effectReceipt.performedAt`, message: "must be an ISO timestamp" });
      }
    }
  }
  for (const [index, approval] of approvals.entries()) {
    if (approval.supersedesId && (!approvalIds.has(approval.supersedesId) || approval.supersedesId === approval.id)) {
      issues.push({ path: `$.approvals[${index}].supersedesId`, message: "must reference another approval in the same run" });
      continue;
    }
    if (approval.supersedesId && approval.requirementId) {
      const superseded = approvals.find((candidate) => candidate.id === approval.supersedesId);
      if (superseded?.requirementId !== approval.requirementId) {
        issues.push({ path: `$.approvals[${index}].supersedesId`, message: "must reference an approval for the same requirement" });
      }
    }
  }
  if (
    Array.isArray(run.plan)
    && Array.isArray(run.approvals)
    && Array.isArray(run.approvalRequirements)
  ) {
    const completeRun = run as AgentRun;
    for (const requirement of run.approvalRequirements) {
      if (!requirement.beforeStepId) continue;
      const stepIndex = run.plan.findIndex((step) => step.id === requirement.beforeStepId);
      const step = run.plan[stepIndex];
      if (
        step
        && (step.status === "running" || step.status === "completed")
        && !agentRunApprovalRequirementSatisfied(completeRun, requirement)
      ) {
        issues.push({
          path: `$.plan[${stepIndex}].status`,
          message: `requires approved workflow approval requirement ${requirement.id}`,
        });
      }
    }
    if (run.status === "completed") {
      for (const requirement of unsatisfiedAgentRunApprovalRequirements(completeRun, { allowSkippedStep: true })) {
        issues.push({
          path: "$.status",
          message: `completed run requires approved workflow approval requirement ${requirement.id}`,
        });
      }
    }
  }
  return { valid: issues.length === 0, issues };
}

export function currentAgentRunApprovalForRequirement(
  run: AgentRun,
  requirementId: string,
): AgentRunApproval | undefined {
  for (let index = run.approvals.length - 1; index >= 0; index -= 1) {
    const approval = run.approvals[index]!;
    if (approval.requirementId === requirementId) return approval;
  }
  return undefined;
}

export function agentRunApprovalRequirementState(
  run: AgentRun,
  requirementId: string,
): AgentRunApprovalRequirementState {
  const requirement = run.approvalRequirements?.find((candidate) => candidate.id === requirementId);
  if (!requirement) throw new Error(`approval requirement not found: ${requirementId}`);
  const approval = currentAgentRunApprovalForRequirement(run, requirementId);
  if (!approval) return "unbound";
  if (approval.status === "pending") return "pending";
  if (approval.status === "approved") return "approved";
  return "denied";
}

function agentRunApprovalRequirementSatisfied(
  run: AgentRun,
  requirement: AgentRunApprovalRequirement,
  options: { allowSkippedStep?: boolean } = {},
): boolean {
  if (
    options.allowSkippedStep
    && requirement.beforeStepId
    && run.plan.some((step) => (
      step.id === requirement.beforeStepId
      && step.status === "skipped"
      && Boolean(String(step.detail || "").trim())
    ))
  ) {
    return true;
  }
  const approval = currentAgentRunApprovalForRequirement(run, requirement.id);
  return Boolean(
    approval
    && approval.status === "approved"
    && approvalReviewability(approval).canApprove,
  );
}

function unsatisfiedAgentRunApprovalRequirements(
  run: AgentRun,
  options: { beforeStepId?: string; allowSkippedStep?: boolean } = {},
): AgentRunApprovalRequirement[] {
  return (run.approvalRequirements || []).filter((requirement) => (
    (!options.beforeStepId || requirement.beforeStepId === options.beforeStepId)
    && !agentRunApprovalRequirementSatisfied(run, requirement, {
      allowSkippedStep: options.allowSkippedStep,
    })
  ));
}

function assertAgentRunApprovalRequirementsSatisfied(
  run: AgentRun,
  options: { beforeStepId?: string; allowSkippedStep?: boolean; action: string },
): void {
  const unsatisfied = unsatisfiedAgentRunApprovalRequirements(run, options);
  if (unsatisfied.length === 0) return;
  throw new Error(
    `${options.action} requires approved workflow approval requirement${unsatisfied.length === 1 ? "" : "s"}: ${unsatisfied.map((requirement) => requirement.id).join(", ")}`,
  );
}

export function transitionAgentRun(run: AgentRun, status: AgentRunStatus, options: { actor?: string; reason?: string; summary?: string; highlights?: string[]; nextActions?: string[]; now?: string; completionSource?: "external" } = {}): AgentRun {
  if (run.status === status) return { ...run };
  const completedExternally = status === "completed" && options.completionSource === "external";
  const allowedExternalCompletion = completedExternally && run.status === "blocked";
  if (!TRANSITIONS[run.status].includes(status) && !allowedExternalCompletion) throw new Error(`run cannot transition from ${run.status} to ${status}`);
  if (status === "queued" || status === "running") {
    const approvalBoundary = currentAgentRunApprovalBoundary(run);
    if (approvalBoundary.length > 0 && !approvalBoundary.every((approval) => approval.status === "approved")) {
      throw new Error("run cannot resume while its current approval boundary is unresolved");
    }
  }
  if (options.completionSource === "external" && !allowedExternalCompletion) {
    throw new Error("external completion is only allowed for a blocked run");
  }
  const blockedReason = status === "blocked" ? optional(options.reason) : undefined;
  if (status === "blocked" && !blockedReason) {
    throw new Error("blocking a run requires --reason with a specific clarification or next action");
  }
  const completionSummary = status === "completed" ? optional(options.summary) || optional(run.outcome?.summary) : undefined;
  if (status === "completed") {
    assertAgentRunApprovalRequirementsSatisfied(run, {
      action: "completing the run",
      allowSkippedStep: true,
    });
  }
  if (status === "completed" && !completedExternally && run.approvals.some((approval) => approval.status === "pending")) {
    throw new Error("completing a run with pending approvals is not allowed");
  }
  if (status === "completed" && !completedExternally && run.approvals.some((approval) => approval.effectReservation)) {
    throw new Error("completing a run with an unresolved approval effect reservation is not allowed; reconcile and record or release the effect first");
  }
  if (status === "completed" && !completedExternally && run.artifacts.some((artifact) => artifact.reviewStatus === "review-required")) {
    throw new Error("completing a run with review-required artifacts is not allowed; record the review with `org2 run artifact-review RUN_ID ARTIFACT_ID --status reviewed`");
  }
  if (status === "completed" && !completionSummary) {
    throw new Error("completing a run requires --summary with a human-readable outcome");
  }
  const now = isoNow(options.now);
  const statusEvent = event("status-changed", now, options.actor, `${run.status} -> ${status}`, {
    from: run.status,
    to: status,
    ...(options.reason ? { reason: options.reason } : {}),
    ...(completedExternally ? { completionSource: "external" } : {}),
  });
  const next: AgentRun = {
    ...run,
    status,
    updatedAt: now,
    events: [
      ...run.events,
      statusEvent,
      ...(completedExternally ? [event("completed-externally", now, options.actor, completionSummary)] : []),
    ],
  };
  if (status === "running" && !next.startedAt) next.startedAt = now;
  if (status === "completed") {
    next.completedAt = now;
    next.outcome = {
      summary: completionSummary!,
      highlights: options.highlights === undefined ? unique(run.outcome?.highlights) : unique(options.highlights),
      nextActions: options.nextActions === undefined ? unique(run.outcome?.nextActions) : unique(options.nextActions),
    };
  }
  if (status !== "blocked") delete next.blockedReason;
  if (status === "blocked") next.blockedReason = blockedReason;
  if (status === "failed") next.failure = optional(options.reason) || "Run failed";
  if (status !== "failed") delete next.failure;
  return next;
}

export function completeAgentRunExternally(run: AgentRun, input: { summary: string; actor: string; now?: string }): AgentRun {
  if (run.status !== "blocked") throw new Error("only a blocked run can be marked completed outside the workflow");
  const actor = optional(input.actor);
  if (!actor) throw new Error("marking a run completed outside the workflow requires an actor");
  assertAgentRunApprovalRequirementsSatisfied(run, {
    action: "completing the run externally",
    allowSkippedStep: true,
  });
  const now = isoNow(input.now);
  const externalDetail = "Outcome completed outside this workflow.";
  const prepared: AgentRun = {
    ...run,
    plan: run.plan.map((step) => ["completed", "skipped"].includes(step.status) ? step : {
      ...step,
      status: "skipped",
      detail: step.detail ? `${step.detail} ${externalDetail}` : externalDetail,
    }),
  };
  return transitionAgentRun(prepared, "completed", {
    summary: input.summary,
    actor,
    now,
    completionSource: "external",
  });
}

export function updateAgentRunOutcome(run: AgentRun, input: { summary: string; highlights?: string[]; nextActions?: string[]; actor?: string; now?: string }): AgentRun {
  const summary = optional(input.summary);
  if (!summary) throw new Error("run outcome summary is required");
  const now = isoNow(input.now);
  const outcome: AgentRunOutcome = {
    summary,
    highlights: unique(input.highlights),
    nextActions: unique(input.nextActions),
  };
  return {
    ...run,
    outcome,
    updatedAt: now,
    events: [...run.events, event("outcome-updated", now, input.actor, summary)],
  };
}

export function updateAgentRunRuntime(run: AgentRun, input: AgentRunRuntimeUpdate): AgentRun {
  const now = isoNow(input.now);
  const provider = optional(input.provider) || run.provider;
  const model = optional(input.model) || run.model;
  const budget = { ...(run.budget || {}) };
  for (const [name, value] of [
    ["tokensUsed", input.tokensUsed],
    ["costUsedUsd", input.costUsedUsd],
    ["elapsedSeconds", input.elapsedSeconds],
  ] as const) {
    if (value === undefined) continue;
    if (!Number.isFinite(value) || value < 0) throw new Error(`run runtime ${name} must be a non-negative finite number`);
    budget[name] = value;
  }
  const details = [
    provider ? `provider=${provider}` : undefined,
    model ? `model=${model}` : undefined,
    input.tokensUsed !== undefined ? `tokens=${input.tokensUsed}` : undefined,
    input.elapsedSeconds !== undefined ? `elapsed=${input.elapsedSeconds}s` : undefined,
  ].filter(Boolean).join(" ");
  return {
    ...run,
    ...(provider ? { provider } : {}),
    ...(model ? { model } : {}),
    ...(Object.keys(budget).length ? { budget } : {}),
    updatedAt: now,
    events: [...run.events, event("runtime-updated", now, input.actor, details || "Runtime metadata updated")],
  };
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

export function updateAgentRunArtifactReview(
  run: AgentRun,
  artifactId: string,
  reviewStatus: AgentRunArtifactReviewStatus,
  options: { actor?: string; now?: string } = {},
): AgentRun {
  if (!AGENT_RUN_ARTIFACT_REVIEW_STATUSES.includes(reviewStatus)) throw new Error(`invalid artifact review status: ${reviewStatus}`);
  const index = run.artifacts.findIndex((artifact) => artifact.id === artifactId);
  if (index < 0) throw new Error(`unknown artifact id: ${artifactId}`);
  const previous = run.artifacts[index]!;
  if (previous.reviewStatus === reviewStatus) return { ...run };
  const now = isoNow(options.now);
  const artifacts = [...run.artifacts];
  artifacts[index] = { ...previous, reviewStatus };
  return {
    ...run,
    artifacts,
    updatedAt: now,
    events: [...run.events, event(
      "artifact-review-changed",
      now,
      options.actor,
      `${previous.path}: ${previous.reviewStatus || "unspecified"} -> ${reviewStatus}`,
      { artifactId, from: previous.reviewStatus || "", to: reviewStatus },
    )],
  };
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

export interface AgentRunApprovalRequestInput {
  id?: string;
  requirementId?: string;
  title?: string;
  action?: string;
  riskClass?: AgentRunRiskClass;
  fingerprint?: string;
  material?: AgentRunApprovalMaterial;
  supersedesId?: string;
  requestedRole?: string;
  requestedFrom?: string;
  requestedAt?: string;
  note?: string;
  receipt?: string;
}

function sameApprovalRuntimeTarget(
  left: AgentRunApprovalMaterial["runtimeTarget"] | undefined,
  right: AgentRunApprovalMaterial["runtimeTarget"] | undefined,
): boolean {
  return Boolean(
    left
    && right
    && left.system === right.system
    && left.kind === right.kind
    && left.id === right.id,
  );
}

export function requestAgentRunApproval(run: AgentRun, input: AgentRunApprovalRequestInput, actor?: string): AgentRun {
  if (["completed", "failed", "canceled"].includes(run.status)) throw new Error(`cannot request approval for a ${run.status} run`);
  const requirementId = optional(input.requirementId);
  const requirement = requirementId
    ? run.approvalRequirements?.find((candidate) => candidate.id === requirementId)
    : undefined;
  if (requirementId && !requirement) throw new Error(`approval requirement not found: ${requirementId}`);
  if (requirement) {
    const conflictingFields = [
      input.title !== undefined && String(input.title || "").trim() !== requirement.title ? "title" : undefined,
      input.action !== undefined && String(input.action || "").trim() !== requirement.action ? "action" : undefined,
      input.riskClass !== undefined && input.riskClass !== requirement.riskClass ? "risk class" : undefined,
      input.requestedRole !== undefined
        && optional(input.requestedRole) !== optional(requirement.requestedRole)
        ? "requested role"
        : undefined,
    ].filter((field): field is string => Boolean(field));
    if (conflictingFields.length > 0) {
      throw new Error(`approval request ${conflictingFields.join(", ")} must match requirement ${requirement.id}`);
    }
  }
  const title = requirement?.title ?? String(input.title || "").trim();
  const action = requirement?.action ?? String(input.action || "").trim();
  const riskClass = requirement?.riskClass ?? input.riskClass;
  const requestedRole = requirement?.requestedRole ?? optional(input.requestedRole);
  if (!title || !action) throw new Error("approval title and action are required");
  if (!riskClass || !AGENT_RUN_RISK_CLASSES.includes(riskClass)) throw new Error(`invalid approval risk class: ${riskClass}`);
  const currentPendingRequirementApproval = requirementId
    ? run.approvals.find((candidate) => candidate.requirementId === requirementId && candidate.status === "pending")
    : undefined;
  if (
    currentPendingRequirementApproval
    && input.supersedesId !== currentPendingRequirementApproval.id
  ) {
    throw new Error(
      `approval requirement ${requirementId} already has pending request ${currentPendingRequirementApproval.id}; supersede that request explicitly`,
    );
  }
  const now = isoNow(input.requestedAt);
  const id = safeId(input.id || crypto.randomUUID());
  if (run.approvals.some((candidate) => candidate.id === id)) throw new Error(`approval id already exists: ${id}`);
  const materialIssues = approvalMaterialIssues(input.material);
  if (materialIssues.length > 0) {
    throw new Error(`invalid approval material: ${materialIssues.join("; ")}`);
  }
  const material = normalizeApprovalMaterial(input.material);
  if (material?.runtimeTarget) {
    const priorEffect = run.approvals.find((approval) => (
      sameApprovalRuntimeTarget(approval.material?.runtimeTarget, material.runtimeTarget)
      && (approval.effectReservation || approval.effectReceipt)
    ));
    if (priorEffect?.effectReservation) {
      throw new Error(`runtime target ${material.runtimeTarget.system}:${material.runtimeTarget.kind}:${material.runtimeTarget.id} has an unresolved effect reservation on approval ${priorEffect.id}`);
    }
    if (priorEffect?.effectReceipt) {
      throw new Error(`runtime target ${material.runtimeTarget.system}:${material.runtimeTarget.kind}:${material.runtimeTarget.id} was already performed by approval ${priorEffect.id}`);
    }
  }
  const request = {
    title,
    action,
    riskClass,
    ...(requirementId ? { requirementId } : {}),
    ...(requestedRole ? { requestedRole } : {}),
    ...(optional(input.requestedFrom) ? { requestedFrom: optional(input.requestedFrom) } : {}),
    ...(optional(input.note) ? { note: optional(input.note) } : {}),
    ...(material ? { material } : {}),
  };
  const reviewability = approvalReviewability(request);
  if (!reviewability.canApprove) throw new Error(reviewability.reason);
  const fingerprint = computeApprovalFingerprint(request);
  if (input.fingerprint && input.fingerprint !== fingerprint) {
    throw new Error(`approval fingerprint mismatch: expected ${fingerprint}`);
  }
  let supersededIndex = -1;
  if (input.supersedesId) {
    supersededIndex = run.approvals.findIndex((candidate) => candidate.id === input.supersedesId);
    if (supersededIndex < 0) throw new Error(`superseded approval not found: ${input.supersedesId}`);
    if (run.approvals[supersededIndex]!.status !== "pending") {
      throw new Error(`superseded approval is already ${run.approvals[supersededIndex]!.status}`);
    }
    if (requirementId && run.approvals[supersededIndex]!.requirementId !== requirementId) {
      throw new Error(`superseded approval must belong to requirement ${requirementId}`);
    }
  }
  const approval: AgentRunApproval = {
    id,
    ...request,
    status: "pending",
    fingerprint,
    requestedAt: now,
    ...(optional(input.supersedesId) ? { supersedesId: optional(input.supersedesId) } : {}),
    ...(optional(input.receipt) ? { receipt: optional(input.receipt) } : {}),
  };
  if (!approval.title || !approval.action) throw new Error("approval title and action are required");
  const approvals = [...run.approvals];
  if (supersededIndex >= 0) {
    approvals[supersededIndex] = {
      ...approvals[supersededIndex]!,
      status: "revised",
      decidedAt: now,
      decidedBy: optional(actor) || "org2",
      decisionNote: `Superseded by ${approval.id}.`,
    };
  }
  approvals.push(approval);
  const opensApprovalBoundary = run.status === "running"
    || run.status === "queued"
    || (run.status === "blocked" && run.blockedReason === AGENT_RUN_APPROVAL_BLOCK_REASON);
  const next = opensApprovalBoundary
    ? transitionAgentRun(run, "waiting-approval", { actor, now })
    : { ...run };
  return {
    ...next,
    approvals,
    updatedAt: now,
    events: [
      ...next.events,
      ...(input.supersedesId ? [event("approval-superseded", now, actor, `${input.supersedesId} -> ${approval.id}`, {
        approvalId: input.supersedesId,
        supersededById: approval.id,
      })] : []),
      event("approval-requested", now, actor, approval.title, {
        approvalId: approval.id,
        fingerprint: approval.fingerprint,
        riskClass: approval.riskClass,
        ...(approval.requirementId ? { requirementId: approval.requirementId } : {}),
        ...(approval.supersedesId ? { supersedesId: approval.supersedesId } : {}),
      }),
    ],
  };
}

export function currentAgentRunApprovalBoundary(run: AgentRun): AgentRunApproval[] {
  let boundaryStart = -1;
  for (let index = run.events.length - 1; index >= 0; index -= 1) {
    const candidate = run.events[index]!;
    if (candidate.type === "status-changed" && candidate.data?.to === "waiting-approval") {
      boundaryStart = index;
      break;
    }
  }
  const current = (items: AgentRunApproval[]): AgentRunApproval[] => {
    const supersededIds = new Set(items.map((approval) => approval.supersedesId).filter((id): id is string => Boolean(id)));
    return items.filter((approval) => !supersededIds.has(approval.id));
  };
  if (boundaryStart < 0) return current(run.approvals);

  const boundaryIds = new Set(
    run.events.slice(boundaryStart + 1)
      .filter((candidate) => candidate.type === "approval-requested")
      .map((candidate) => optional(candidate.data?.approvalId))
      .filter((id): id is string => Boolean(id)),
  );
  if (boundaryIds.size === 0) return current(run.approvals);
  return current(run.approvals.filter((approval) => boundaryIds.has(approval.id)));
}

export function decideAgentRunApproval(run: AgentRun, approvalId: string, decision: AgentRunApprovalDecision, input: { actor: string; actorRole?: string; expectedFingerprint?: string; note?: string; receipt?: string; now?: string }): AgentRun {
  const now = isoNow(input.now);
  if (!AGENT_RUN_APPROVAL_DECISIONS.includes(decision)) throw new Error(`invalid approval decision: ${decision}`);
  const actor = String(input.actor || "").trim();
  if (!actor) throw new Error("approval decision actor is required");
  const index = run.approvals.findIndex((approval) => approval.id === approvalId);
  if (index < 0) throw new Error(`approval not found: ${approvalId}`);
  const approval = run.approvals[index]!;
  if (approval.status !== "pending") throw new Error(`approval is already ${approval.status}`);
  const fingerprint = approval.fingerprint || computeApprovalFingerprint(approval);
  if (!input.expectedFingerprint) throw new Error(`--expected-fingerprint is required for approval ${approvalId}`);
  if (input.expectedFingerprint !== fingerprint) {
    throw new Error(`stale approval review: expected fingerprint ${fingerprint}, received ${input.expectedFingerprint}`);
  }
  if (decision === "approved") {
    const reviewability = approvalReviewability(approval);
    if (!reviewability.canApprove) throw new Error(reviewability.reason);
  }
  if (approval.requestedRole && input.actorRole !== approval.requestedRole) throw new Error(`approval requires role ${approval.requestedRole}; pass the matching actor role`);
  if (approval.requestedFrom && actor !== approval.requestedFrom) throw new Error(`approval is assigned to ${approval.requestedFrom}`);
  const approvals = [...run.approvals];
  approvals[index] = {
    ...approval,
    fingerprint,
    status: decision,
    decidedAt: now,
    decidedBy: actor,
    ...(optional(input.note) ? { decisionNote: optional(input.note) } : {}),
    ...(optional(input.receipt) ? { receipt: optional(input.receipt) } : {}),
  };
  let next: AgentRun = {
    ...run,
    approvals,
    updatedAt: now,
    events: [...run.events, event("approval-decided", now, actor, `${approvalId}: ${decision}`, {
      approvalId,
      decision,
      fingerprint,
      ...(input.actorRole ? { actorRole: input.actorRole } : {}),
    })],
  };
  if (run.status === "waiting-approval" && approvals.every((approval) => approval.status !== "pending")) {
    const allApproved = currentAgentRunApprovalBoundary(next).every((approval) => approval.status === "approved");
    next = transitionAgentRun(next, allApproved ? "running" : "blocked", {
      actor,
      reason: allApproved ? undefined : AGENT_RUN_APPROVAL_BLOCK_REASON,
      now,
    });
  }
  return next;
}

export function recordAgentRunApprovalEffect(
  run: AgentRun,
  approvalId: string,
  input: { fingerprint: string; performedAt?: string; system?: string; externalId?: string; toolCallId?: string; actor?: string },
): AgentRun {
  const index = run.approvals.findIndex((approval) => approval.id === approvalId);
  if (index < 0) throw new Error(`approval not found: ${approvalId}`);
  const approval = run.approvals[index]!;
  if (approval.status !== "approved") throw new Error(`approval effect requires an approved request; ${approvalId} is ${approval.status}`);
  if (!approval.fingerprint) throw new Error(`approval ${approvalId} has no immutable fingerprint`);
  if (input.fingerprint !== approval.fingerprint) {
    throw new Error(`approval effect fingerprint mismatch: approved ${approval.fingerprint}, received ${input.fingerprint}`);
  }
  if (approval.effectReceipt) {
    if (
      approval.effectReceipt.fingerprint === input.fingerprint
      && (!input.externalId || approval.effectReceipt.externalId === input.externalId)
    ) return { ...run };
    throw new Error(`approval ${approvalId} already has a different effect receipt`);
  }
  if (approval.effectReservation) {
    if (!input.toolCallId || input.toolCallId !== approval.effectReservation.toolCallId) {
      throw new Error(`approval ${approvalId} is reserved for a different tool call`);
    }
    if (approval.effectReservation.fingerprint !== input.fingerprint) {
      throw new Error(`approval ${approvalId} reservation fingerprint changed`);
    }
  } else if (input.toolCallId) {
    throw new Error(`approval ${approvalId} has no matching effect reservation`);
  }
  const performedAt = isoNow(input.performedAt);
  const approvals = [...run.approvals];
  const recorded: AgentRunApproval = {
    ...approval,
    effectReceipt: {
      fingerprint: input.fingerprint,
      performedAt,
      ...(optional(input.system) ? { system: optional(input.system) } : {}),
      ...(optional(input.externalId) ? { externalId: optional(input.externalId) } : {}),
    },
  };
  delete recorded.effectReservation;
  approvals[index] = recorded;
  return {
    ...run,
    approvals,
    updatedAt: performedAt,
    events: [...run.events, event("approval-effect-recorded", performedAt, input.actor, approval.title, {
      approvalId,
      fingerprint: input.fingerprint,
      ...(input.system ? { system: input.system } : {}),
      ...(input.externalId ? { externalId: input.externalId } : {}),
      ...(input.toolCallId ? { toolCallId: input.toolCallId } : {}),
    })],
  };
}

export function reserveAgentRunApprovalEffect(
  run: AgentRun,
  approvalId: string,
  input: { fingerprint: string; materialDigest: string; toolCallId: string; reservedAt?: string; actor?: string },
): AgentRun {
  const index = run.approvals.findIndex((approval) => approval.id === approvalId);
  if (index < 0) throw new Error(`approval not found: ${approvalId}`);
  const approval = run.approvals[index]!;
  if (approval.status !== "approved") throw new Error(`approval effect reservation requires an approved request; ${approvalId} is ${approval.status}`);
  if (!approval.fingerprint || approval.fingerprint !== input.fingerprint) {
    throw new Error(`approval effect fingerprint mismatch for ${approvalId}`);
  }
  if (!isApprovalFingerprint(input.materialDigest)) {
    throw new Error("approval effect reservation requires a sha256:<hex> material digest");
  }
  if (!approval.material) throw new Error(`approval ${approvalId} has no bound material to reserve`);
  const conflictingEffect = approval.material.runtimeTarget
    ? run.approvals.find((candidate) => (
      candidate.id !== approval.id
      && sameApprovalRuntimeTarget(candidate.material?.runtimeTarget, approval.material?.runtimeTarget)
      && (candidate.effectReservation || candidate.effectReceipt)
    ))
    : undefined;
  if (conflictingEffect?.effectReservation) {
    throw new Error(`runtime target is already reserved by approval ${conflictingEffect.id}`);
  }
  if (conflictingEffect?.effectReceipt) {
    throw new Error(`runtime target was already performed by approval ${conflictingEffect.id}`);
  }
  const expectedMaterialDigest = computeApprovalMaterialDigest(approval.material);
  if (input.materialDigest !== expectedMaterialDigest) {
    throw new Error(`approval effect material digest mismatch: approved ${expectedMaterialDigest}, received ${input.materialDigest}`);
  }
  const toolCallId = String(input.toolCallId || "").trim();
  if (!toolCallId) throw new Error("approval effect reservation requires a tool call id");
  if (approval.effectReceipt) throw new Error(`approval ${approvalId} already has an effect receipt`);
  if (approval.effectReservation) {
    throw new Error(`approval ${approvalId} already has an unresolved effect reservation`);
  }
  const reservedAt = isoNow(input.reservedAt);
  const approvals = [...run.approvals];
  approvals[index] = {
    ...approval,
    effectReservation: {
      fingerprint: input.fingerprint,
      materialDigest: input.materialDigest,
      toolCallId,
      reservedAt,
    },
  };
  return {
    ...run,
    approvals,
    updatedAt: reservedAt,
    events: [...run.events, event("approval-effect-reserved", reservedAt, input.actor, approval.title, {
      approvalId,
      fingerprint: input.fingerprint,
      materialDigest: input.materialDigest,
      toolCallId,
    })],
  };
}

export function releaseAgentRunApprovalEffectReservation(
  run: AgentRun,
  approvalId: string,
  input: { fingerprint: string; toolCallId: string; reason: string; actor: string; releasedAt?: string },
): AgentRun {
  const index = run.approvals.findIndex((approval) => approval.id === approvalId);
  if (index < 0) throw new Error(`approval not found: ${approvalId}`);
  const approval = run.approvals[index]!;
  if (approval.effectReceipt) throw new Error(`approval ${approvalId} already has an effect receipt`);
  const reservation = approval.effectReservation;
  if (!reservation) throw new Error(`approval ${approvalId} has no effect reservation`);
  if (reservation.fingerprint !== input.fingerprint || reservation.toolCallId !== input.toolCallId) {
    throw new Error(`approval ${approvalId} effect reservation does not match`);
  }
  const actor = String(input.actor || "").trim();
  const reason = String(input.reason || "").trim();
  if (!actor || !reason) throw new Error("releasing an effect reservation requires an actor and a reconciliation reason");
  const releasedAt = isoNow(input.releasedAt);
  const approvals = [...run.approvals];
  const released = { ...approval };
  delete released.effectReservation;
  approvals[index] = released;
  return {
    ...run,
    approvals,
    updatedAt: releasedAt,
    events: [...run.events, event("approval-effect-reservation-released", releasedAt, actor, reason, {
      approvalId,
      fingerprint: input.fingerprint,
      toolCallId: input.toolCallId,
    })],
  };
}

export function updateAgentRunStep(run: AgentRun, stepId: string, status: AgentRunStepStatus, input: { actor?: string; detail?: string; now?: string } = {}): AgentRun {
  const now = isoNow(input.now);
  if (!AGENT_RUN_STEP_STATUSES.includes(status)) throw new Error(`invalid run step status: ${status}`);
  const index = run.plan.findIndex((step) => step.id === stepId);
  if (index < 0) throw new Error(`plan step not found: ${stepId}`);
  if (
    status === "skipped"
    && run.approvalRequirements?.some((requirement) => requirement.beforeStepId === stepId)
    && !optional(input.detail)
  ) {
    throw new Error(`skipping approval-guarded step ${stepId} must record why no protected effect occurred`);
  }
  if (status === "running" || status === "completed") {
    assertAgentRunApprovalRequirementsSatisfied(run, {
      action: `moving step ${stepId} to ${status}`,
      beforeStepId: stepId,
    });
  }
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
    plan: run.plan.map((step) => ({
      id: step.id,
      title: step.title,
      kind: step.kind,
      capability: step.capability,
      detail: step.detail,
    })),
    approvalRequirements: run.approvalRequirements?.map((requirement) => ({ ...requirement })),
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
    "** Outcome",
    ...(run.outcome ? [
      run.outcome.summary,
      "",
      "*** Highlights",
      ...(run.outcome.highlights.length ? run.outcome.highlights.map((item) => `- ${item}`) : ["- None recorded."]),
      "",
      "*** Next actions",
      ...(run.outcome.nextActions.length ? run.outcome.nextActions.map((item) => `- ${item}`) : ["- None required."]),
    ] : ["No human-readable outcome has been recorded yet."]),
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
    "** Approval requirements",
    ...((run.approvalRequirements || []).length ? run.approvalRequirements!.map((requirement) => {
      const state = agentRunApprovalRequirementState(run, requirement.id);
      const boundary = requirement.beforeStepId ? `; before ${requirement.beforeStepId}` : "; before completion";
      return `- ${state.toUpperCase()} ${requirement.title} — ${requirement.action} (${requirement.riskClass}${boundary}) =${requirement.id}=`;
    }) : ["- No workflow approval requirements declared."]),
    "",
    `** Approvals [${run.approvals.filter((approval) => approval.status === "pending").length}/${run.approvals.length} pending]`,
    ...(run.approvals.length ? run.approvals.map((approval) => {
      const reviewer = approval.requestedFrom
        ? `; reviewer ${approval.requestedFrom}`
        : approval.requestedRole
          ? `; role ${approval.requestedRole}`
          : "";
      return `- ${approval.status.toUpperCase()} ${approval.title} — ${approval.action} (${approval.riskClass}${reviewer}) =${approval.id}=`;
    }) : ["- No approvals recorded."]),
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
  withFileMutationLock(outputPath, () => {
    if (fs.existsSync(outputPath)) throw new Error(`run already exists: ${run.id}`);
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    const tempPath = `${outputPath}.${process.pid}.${crypto.randomUUID()}.tmp`;
    try {
      fs.writeFileSync(tempPath, renderAgentRunOrg(run), { encoding: "utf8", mode: 0o600 });
      fs.linkSync(tempPath, outputPath);
    } finally {
      if (fs.existsSync(tempPath)) fs.unlinkSync(tempPath);
    }
  });
  return outputPath;
}

export function mutateAgentRun(
  corpusRoot: string,
  id: string,
  mutate: (run: AgentRun) => AgentRun,
): AgentRun {
  const file = agentRunPath(corpusRoot, id);
  return withFileMutationLock(file, () => {
    if (!fs.existsSync(file)) throw new Error(`run not found: ${id}`);
    const raw = fs.readFileSync(file, "utf8");
    const current = parseAgentRunOrg(raw);
    const updated = mutate(current);
    if (updated.id !== current.id) throw new Error("an in-place run mutation cannot change the run id");
    if (JSON.stringify(updated.approvalRequirements || []) !== JSON.stringify(current.approvalRequirements || [])) {
      throw new Error("an in-place run mutation cannot change immutable workflow approval requirements");
    }
    const validation = validateAgentRun(updated);
    if (!validation.valid) {
      throw new Error(`invalid Org2 agent run: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
    }
    writeTextAtomicallyIfUnchanged(file, raw, renderAgentRunOrg(updated));
    return updated;
  });
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
