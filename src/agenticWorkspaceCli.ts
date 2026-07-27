import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  AGENT_RUN_APPROVAL_DECISIONS,
  AGENT_RUN_ARTIFACT_REVIEW_STATUSES,
  AGENT_RUN_ARTIFACT_ROLES,
  AGENT_RUN_RISK_CLASSES,
  AGENT_RUN_STEP_KINDS,
  AGENT_RUN_STEP_STATUSES,
  AGENT_RUN_VALIDATION_STATUSES,
  addAgentRunArtifact,
  addAgentRunComment,
  addAgentRunValidation,
  agentRunApprovalDecisionKeys,
  completeAgentRunExternally,
  createAgentRun,
  decideAgentRunApproval,
  forkAgentRun,
  listAgentRuns,
  loadAgentRun,
  normalizeLegacyAgentRuns,
  requestAgentRunApproval,
  saveAgentRun,
  summarizeAgentRunAttempts,
  supersedeAgentRunApproval,
  transitionAgentRun,
  updateAgentRunAssignment,
  updateAgentRunArtifactReview,
  updateAgentRunOutcome,
  updateAgentRunRuntime,
  updateAgentRunStep,
  validateAgentRun,
  type AgentRun,
  type AgentRunApproval,
  type AgentRunStatus,
} from "./agentRun.js";
import { updateArtifactReviewStatusInText } from "./artifactMetadata.js";
import {
  WORKFLOW_EVENT_TRIGGER_TYPES,
  dueWorkflowTriggers,
  instantiateWorkflow,
  installBuiltinWorkflow,
  listWorkflows,
  loadWorkflow,
  markWorkflowTriggerAttempt,
  migrateLegacyWorkflows,
  packagedWorkflowManifest,
  packagedCorpusTemplate,
  recordWorkflowSignal,
  saveWorkflow,
  updateWorkflow,
  validateWorkflow,
  workflowTriggerEligibility,
  workflowSourcePath,
  workflowFromRun,
} from "./agentWorkflow.js";
import { artifactRebuildPlan, buildArtifactGraph, loadArtifactDeclarations, MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW, saveArtifactGraph } from "./artifactPipeline.js";
import { discoverMcpClient, loadMcpClients, saveMcpClients, serveMcp, writeMcpSnapshot } from "./mcpRuntime.js";
import { loadRuntimePolicy, runtimePolicyPath, saveRuntimePolicy, selectRuntime, validateRuntimePaths } from "./runtimePolicy.js";
import { evaluateRun, loadEvalExpectation, loadWorkflowReplayFixture, replayWorkflowFixture, sanitizeRunFixture, saveEvalResult } from "./workflowEval.js";
import { ORG2_CORPUS_KINDS, corpusIdentityStatus, initializeCorpusIdentity } from "./corpusIdentity.js";
import { federatedAgenda, federatedSearch } from "./federatedWorkspace.js";
import {
  autoSettleOpenClawThreads,
  configureOpenClawThreadSettlement,
  isOpenClawThreadSettled,
  loadOpenClawThreadState,
  openClawDateMilliseconds,
  reopenOpenClawThread,
  settleOpenClawThread,
} from "./openClawThreadState.js";

interface ParsedArgs { positional: string[]; flags: Map<string, string[]>; }
function parseArgs(args: string[]): ParsedArgs {
  const positional: string[] = [];
  const flags = new Map<string, string[]>();
  for (let i = 0; i < args.length; i += 1) {
    const item = args[i]!;
    if (!item.startsWith("--")) { positional.push(item); continue; }
    const equal = item.indexOf("=");
    const name = equal >= 0 ? item.slice(2, equal) : item.slice(2);
    const explicit = equal >= 0 ? item.slice(equal + 1) : undefined;
    const value = explicit ?? (args[i + 1] && !args[i + 1]!.startsWith("--") ? args[++i]! : "true");
    flags.set(name, [...(flags.get(name) || []), value]);
  }
  return { positional, flags };
}
function flag(parsed: ParsedArgs, name: string, fallback?: string): string | undefined { return parsed.flags.get(name)?.at(-1) ?? fallback; }
function flags(parsed: ParsedArgs, name: string): string[] { return parsed.flags.get(name) || []; }
function enabled(parsed: ParsedArgs, name: string): boolean { return parsed.flags.has(name); }
function root(parsed: ParsedArgs): string { return path.resolve(flag(parsed, "dir", ".")!); }
function output(parsed: ParsedArgs, value: unknown, text?: string): void {
  if (enabled(parsed, "json") || flag(parsed, "format") === "json") process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  else process.stdout.write(`${text ?? (typeof value === "string" ? value : JSON.stringify(value, null, 2))}\n`);
}
function required(value: string | undefined, message: string): string { if (!value) throw new Error(message); return value; }
function choice<const Choices extends readonly string[]>(value: string | undefined, choices: Choices, label: string): Choices[number] {
  const selected = required(value, `${label} is required`);
  if (!choices.includes(selected)) throw new Error(`invalid ${label}: ${selected}; expected one of: ${choices.join(", ")}`);
  return selected as Choices[number];
}
function optionalChoice<const Choices extends readonly string[]>(value: string | undefined, choices: Choices, label: string): Choices[number] | undefined {
  return value === undefined ? undefined : choice(value, choices, label);
}

function syncLinkedArtifactReviewStatus(corpus: string, artifactPath: string, reviewStatus: string): void {
  const file = path.resolve(corpus, artifactPath);
  const relative = path.relative(corpus, file);
  if (relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) return;
  if (![".org", ".org2"].includes(path.extname(file).toLowerCase())) return;
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return;
  const raw = fs.readFileSync(file, "utf8");
  const updated = updateArtifactReviewStatusInText(raw, reviewStatus);
  if (updated !== raw) fs.writeFileSync(file, updated, "utf8");
}

const HELP = `Agentic workspace commands:
  org2 corpus show|validate|init [--dir CORPUS] [--id ID --name NAME --kind personal|shared|project] [--apply]
  org2 workspace agenda --mount CORPUS [--mount CORPUS ...] [--from DATE --to DATE]
  org2 workspace search QUERY --mount CORPUS [--mount CORPUS ...] [--limit N]
  org2 thread list|show|settle|reopen|configure|auto-settle [--dir CORPUS] [--apply]
  org2 thread configure --auto-settle never|SECONDS [--dir CORPUS] [--apply]
  org2 run create --goal TEXT [--accept TEXT] [--risk CLASS] [--owner NAME] [--capability ID] [--dir CORPUS]
  org2 run list|show|validate|start|resume|retry|cancel|complete|complete-external|fail|block|fork|normalize|artifact-review
  org2 run block ID --reason "Specific clarification needed"
  org2 run complete ID --summary "What happened" [--highlight TEXT] [--next-action TEXT]
  org2 run complete-external ID --summary "Where or how it was completed" --actor NAME
  org2 run outcome ID --summary "What happened" [--highlight TEXT] [--next-action TEXT]
  org2 run runtime ID [--provider ID] [--model ID] [--tokens-used N] [--cost-used-usd N] [--elapsed-seconds N]
  org2 run assign ID [--owner NAME] [--assignee NAME]
  org2 run comment ID --author NAME --body TEXT
  org2 run step ID STEP --status STATUS
  org2 run artifact ID --path FILE [--role ROLE] [--review-status STATUS]
  org2 run artifact-review ID ARTIFACT --status reviewed|promoted|rejected [--actor NAME]
  org2 run validation ID --name NAME --status passed|failed|warning|skipped
  org2 run approval-request ID --title TEXT --action TEXT [--risk CLASS] [--role ROLE]
  org2 run approval-decide ID APPROVAL --decision approved|rejected|revised|canceled --actor NAME [--fingerprint SHA256] [--note TEXT] [--receipt TEXT]
  org2 run approval-resolve --decision-key PROVIDER_KEY [--json]
  org2 run approval-reconcile [--apply] [--json]
  org2 review list [--status pending] | org2 review show RUN
  org2 workflow list|show|validate|save|run|triggers|signal|gate|activate|pause|draft|schedule|migrate|package|corpus-template|install-builtin
  org2 artifact graph --manifest FILE | org2 artifact rebuild --manifest FILE
  org2 runtime init|show|select|verify-paths
  org2 mcp serve|clients|client-add|discover|snapshot
  org2 eval run RUN --expect FILE | org2 eval replay WORKFLOW --fixture FILE | org2 eval fixture RUN --output FILE

Writes are local, inspectable files under .org2/ or reviewable corpus zones. Consequential actions remain approval-gated.`;

function forwardedArgs(parsed: ParsedArgs, excluded: Set<string>): string[] {
  const result: string[] = [];
  for (const [name, values] of parsed.flags) {
    if (excluded.has(name)) continue;
    for (const value of values) {
      result.push(`--${name}`);
      if (value !== "true") result.push(value);
    }
  }
  return result;
}

async function workspaceCommand(parsed: ParsedArgs): Promise<void> {
  const action = parsed.positional[0] || "agenda";
  const mounts = flags(parsed, "mount");
  if (mounts.length === 0) throw new Error("workspace reads require at least one --mount CORPUS");
  const args = forwardedArgs(parsed, new Set(["mount", "dir", "json", "format"]));
  if (action === "agenda") {
    output(parsed, await federatedAgenda({ mounts, forwardedArgs: args }));
    return;
  }
  if (action === "search") {
    const query = required(parsed.positional[1], "search query is required");
    const rawLimit = flag(parsed, "limit", "50")!;
    if (!/^\d+$/.test(rawLimit) || Number(rawLimit) < 1) throw new Error("--limit must be a positive integer");
    output(parsed, await federatedSearch(query, { mounts, forwardedArgs: args, limit: Number(rawLimit) }));
    return;
  }
  throw new Error(`unknown workspace action: ${action}`);
}

function corpusCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "show";
  const corpus = root(parsed);
  if (action === "show" || action === "validate") {
    const status = corpusIdentityStatus(corpus);
    output(parsed, status, status.valid
      ? `${status.identity!.name}\n${status.identity!.id}\t${status.identity!.kind}\n${status.root}`
      : status.issues.map((issue) => `${issue.path}: ${issue.message}`).join("\n"));
    if (action === "validate" && !status.valid) process.exitCode = 1;
    return;
  }
  if (action === "init") {
    const result = initializeCorpusIdentity(corpus, {
      id: required(flag(parsed, "id"), "--id is required"),
      name: required(flag(parsed, "name"), "--name is required"),
      kind: choice(flag(parsed, "kind", "personal"), ORG2_CORPUS_KINDS, "corpus kind"),
    }, { apply: enabled(parsed, "apply"), force: enabled(parsed, "force") });
    output(parsed, result, `${result.applied ? "initialized" : "would initialize"} ${result.status.identity!.id}\n${result.status.configFile}`);
    return;
  }
  throw new Error(`unknown corpus action: ${action}`);
}

function threadCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "list";
  const corpus = root(parsed);
  if (action === "list") {
    const state = loadOpenClawThreadState(corpus);
    const filter = flag(parsed, "state", "all");
    if (!["all", "active", "settled"].includes(filter!)) {
      throw new Error("--state must be all, active, or settled");
    }
    const threads = state.threads
      .filter((thread) => filter === "all" || (filter === "settled") === isOpenClawThreadSettled(thread))
      .sort((left, right) => {
        const settledOrder = Number(isOpenClawThreadSettled(left)) - Number(isOpenClawThreadSettled(right));
        if (settledOrder !== 0) return settledOrder;
        const leftTime = openClawDateMilliseconds(left.updatedAt);
        const rightTime = openClawDateMilliseconds(right.updatedAt);
        if (Number.isFinite(leftTime) && Number.isFinite(rightTime) && leftTime !== rightTime) {
          return rightTime - leftTime;
        }
        return String(left.title || left.id).localeCompare(String(right.title || right.id));
      });
    output(parsed, { ...state, threads }, threads.length
      ? threads.map((thread) => `${thread.id}\t${isOpenClawThreadSettled(thread) ? "settled" : "active"}\t${thread.title || "Untitled"}`).join("\n")
      : "No chat threads.");
    return;
  }
  if (action === "show") {
    const id = required(parsed.positional[1], "thread id is required");
    const state = loadOpenClawThreadState(corpus);
    const thread = state.threads.find((item) => item.id === id);
    if (!thread) throw new Error(`unknown OpenClaw thread: ${id}`);
    output(parsed, {
      schema: "org2:openclaw-thread:v1",
      state: isOpenClawThreadSettled(thread) ? "settled" : "active",
      thread,
      settlementSettings: state.settlementSettings,
    }, `${id}\t${isOpenClawThreadSettled(thread) ? "settled" : "active"}\t${thread.title || "Untitled"}`);
    return;
  }
  const apply = enabled(parsed, "apply");
  if (action === "settle") {
    const id = required(parsed.positional[1], "thread id is required");
    const result = settleOpenClawThread(corpus, id, { apply });
    output(parsed, result, `${result.applied ? "settled" : result.changed ? "would settle" : "already settled"} ${id}`);
    return;
  }
  if (action === "reopen") {
    const id = required(parsed.positional[1], "thread id is required");
    const result = reopenOpenClawThread(corpus, id, { apply });
    output(parsed, result, `${result.applied ? "reopened" : result.changed ? "would reopen" : "already active"} ${id}`);
    return;
  }
  if (action === "configure") {
    const raw = required(flag(parsed, "auto-settle"), "--auto-settle is required");
    const seconds = raw === "never" || raw === "disabled" ? null : Number(raw);
    if (seconds !== null && (!Number.isFinite(seconds) || seconds <= 0)) {
      throw new Error("--auto-settle must be never or a positive number of seconds");
    }
    const result = configureOpenClawThreadSettlement(corpus, seconds, { apply });
    output(parsed, result, `${result.applied ? "configured" : result.changed ? "would configure" : "unchanged"} auto-settle ${seconds ?? "never"}`);
    return;
  }
  if (action === "auto-settle") {
    const rawNow = flag(parsed, "now");
    const now = rawNow ? new Date(rawNow) : new Date();
    if (!Number.isFinite(now.getTime())) throw new Error("--now must be an ISO date");
    const result = autoSettleOpenClawThreads(corpus, { apply, now });
    output(parsed, result, `${result.applied ? "settled" : "eligible"} ${result.affectedThreadIds.length} thread(s)`);
    return;
  }
  throw new Error(`unknown thread action: ${action}`);
}

type AgentRunApprovalReference = {
  run: AgentRun;
  approval: AgentRunApproval;
};

function approvalKeysOverlap(lhs: string[], rhs: string[]): boolean {
  const right = new Set(rhs);
  return lhs.some((key) => right.has(key));
}

function approvalMaterialVersion(approval: Pick<AgentRunApproval, "action" | "riskClass">): string {
  const reviewMaterial = String(approval.action || "").replace(/\r\n?/g, "\n").trim();
  const contentFingerprint = reviewMaterial.match(/^\s*Content fingerprint:\s*(\S+)\s*$/im)?.[1];
  return contentFingerprint
    ? `${approval.riskClass}:content:${contentFingerprint.toLowerCase()}`
    : `${approval.riskClass}:action:${reviewMaterial}`;
}

function compareApprovalReferences(lhs: AgentRunApprovalReference, rhs: AgentRunApprovalReference): number {
  return lhs.approval.requestedAt.localeCompare(rhs.approval.requestedAt)
    || lhs.run.id.localeCompare(rhs.run.id)
    || lhs.approval.id.localeCompare(rhs.approval.id);
}

function approvalReferences(runs: AgentRun[], keys: string[]): AgentRunApprovalReference[] {
  if (keys.length === 0) return [];
  return runs.flatMap((run) => run.approvals
    .filter((approval) => approvalKeysOverlap(agentRunApprovalDecisionKeys(approval), keys))
    .map((approval) => ({ run, approval })));
}

function isOpenClawExternalDraftRun(run: AgentRun): boolean {
  return run.comments.some((comment) =>
    /(?:^|\n)OPENCLAW_KIND:\s*external-draft\s*(?:\n|$)/i.test(comment.body));
}

function canCloseSupersededApprovalProjection(run: AgentRun, keys: string[]): boolean {
  if (["completed", "failed", "canceled"].includes(run.status)) return false;
  if (isOpenClawExternalDraftRun(run)) return true;
  if (run.plan.length > 0 || run.artifacts.length > 0 || run.approvals.length === 0) return false;
  return run.approvals.every((approval) => {
    const approvalKeys = agentRunApprovalDecisionKeys(approval);
    return approvalKeys.length > 0 && approvalKeysOverlap(approvalKeys, keys);
  });
}

function closeSupersededApprovalProjection(
  run: AgentRun,
  keys: string[],
  replacementRunId: string,
  replacementApprovalId: string,
  actor?: string,
): AgentRun {
  if (!canCloseSupersededApprovalProjection(run, keys)) return run;
  return transitionAgentRun(run, "canceled", {
    actor: actor || "org2-approval-reconciler",
    reason: `Superseded by approval ${replacementApprovalId} on run ${replacementRunId}.`,
  });
}

function correlatedApprovalRequest(
  parsed: ParsedArgs,
  corpus: string,
  target: AgentRun,
): AgentRun | null {
  const input = {
    title: required(flag(parsed, "title"), "--title is required"),
    action: required(flag(parsed, "action"), "--action is required"),
    riskClass: choice(flag(parsed, "risk", target.riskClass), AGENT_RUN_RISK_CLASSES, "approval risk class"),
    requestedRole: flag(parsed, "role"),
    requestedFrom: flag(parsed, "from"),
    note: flag(parsed, "note"),
  };
  const keys = agentRunApprovalDecisionKeys(input);
  if (keys.length === 0) return null;

  const runs = listAgentRuns(corpus);
  const references = approvalReferences(runs, keys);
  const targetOwnsDecision = target.approvals.some((approval) =>
    approvalKeysOverlap(agentRunApprovalDecisionKeys(approval), keys));
  const targetIsDraftProjection = isOpenClawExternalDraftRun(target);
  const exactPending = references
    .filter((reference) =>
      reference.approval.status === "pending"
      && approvalMaterialVersion(reference.approval) === approvalMaterialVersion(input))
    .sort(compareApprovalReferences)
    .at(-1);

  if (exactPending && (
    exactPending.run.id === target.id
    || targetIsDraftProjection
    || targetOwnsDecision
  )) {
    if (exactPending.run.id !== target.id && canCloseSupersededApprovalProjection(target, keys)) {
      saveAgentRun(corpus, transitionAgentRun(target, "canceled", {
        actor: flag(parsed, "actor") || "org2-approval-reconciler",
        reason: `Duplicate approval request reused ${exactPending.run.id}:${exactPending.approval.id}.`,
      }));
    }
    return exactPending.run;
  }

  const canonicalReference = [...references].sort(compareApprovalReferences).at(-1);
  const canonicalRun = targetOwnsDecision || !targetIsDraftProjection || !canonicalReference
    ? target
    : canonicalReference.run;
  const replacementApprovalId = crypto.randomUUID();
  const actor = flag(parsed, "actor") || "org2-approval-reconciler";
  const updatedRuns = new Map<string, AgentRun>();
  updatedRuns.set(canonicalRun.id, canonicalRun);

  for (const reference of references) {
    if (reference.approval.status !== "pending") continue;
    const current = updatedRuns.get(reference.run.id) || reference.run;
    updatedRuns.set(reference.run.id, supersedeAgentRunApproval(current, reference.approval.id, {
      actor,
      replacementRunId: canonicalRun.id,
      replacementApprovalId,
    }));
  }

  let updatedCanonical = updatedRuns.get(canonicalRun.id) || canonicalRun;
  updatedCanonical = requestAgentRunApproval(updatedCanonical, {
    ...input,
    id: replacementApprovalId,
  }, flag(parsed, "actor"));
  updatedRuns.set(updatedCanonical.id, updatedCanonical);

  if (target.id !== updatedCanonical.id && canCloseSupersededApprovalProjection(target, keys)) {
    const currentTarget = updatedRuns.get(target.id) || target;
    updatedRuns.set(target.id, transitionAgentRun(currentTarget, "canceled", {
      actor,
      reason: `Approval request was attached to existing run ${updatedCanonical.id}.`,
    }));
  }
  for (const [runId, candidate] of updatedRuns) {
    if (runId === updatedCanonical.id) continue;
    saveAgentRun(
      corpus,
      closeSupersededApprovalProjection(
        candidate,
        keys,
        updatedCanonical.id,
        replacementApprovalId,
        actor,
      ),
    );
  }
  saveAgentRun(corpus, updatedCanonical);
  return updatedCanonical;
}

function correlatedApprovalDecision(
  parsed: ParsedArgs,
  corpus: string,
  target: AgentRun,
): AgentRun | null {
  const approvalId = required(parsed.positional[2], "approval id is required");
  const approval = target.approvals.find((candidate) => candidate.id === approvalId);
  if (!approval) throw new Error(`approval not found: ${approvalId}`);
  const keys = agentRunApprovalDecisionKeys(approval);
  if (keys.length === 0) return null;

  const references = approvalReferences(listAgentRuns(corpus), keys);
  for (const key of keys) {
    const latest = references
      .filter((reference) => agentRunApprovalDecisionKeys(reference.approval).includes(key))
      .sort(compareApprovalReferences)
      .at(-1);
    if (latest && (latest.run.id !== target.id || latest.approval.id !== approval.id)) {
      throw new Error(
        `approval ${approval.id} is superseded by ${latest.run.id}:${latest.approval.id}; decide the latest review material`,
      );
    }
  }

  const actor = required(flag(parsed, "actor"), "--actor is required");
  const updated = decideAgentRunApproval(
    target,
    approvalId,
    choice(flag(parsed, "decision"), AGENT_RUN_APPROVAL_DECISIONS, "approval decision"),
    {
      actor,
      actorRole: flag(parsed, "role"),
      fingerprint: flag(parsed, "fingerprint"),
      note: flag(parsed, "note"),
      receipt: flag(parsed, "receipt"),
    },
  );
  const updatedRuns = new Map<string, AgentRun>();

  for (const reference of references) {
    if (reference.run.id === target.id || reference.approval.status !== "pending") continue;
    const current = updatedRuns.get(reference.run.id) || reference.run;
    updatedRuns.set(reference.run.id, supersedeAgentRunApproval(current, reference.approval.id, {
      actor: "org2-approval-reconciler",
      replacementRunId: target.id,
      replacementApprovalId: approval.id,
    }));
  }
  for (const candidate of updatedRuns.values()) {
    saveAgentRun(
      corpus,
      closeSupersededApprovalProjection(
        candidate,
        keys,
        target.id,
        approval.id,
      ),
    );
  }
  saveAgentRun(corpus, updated);
  return updated;
}

function reconcileCorrelatedApprovals(corpus: string, apply: boolean): {
  schema: "org2:approval-reconciliation:v1";
  applied: boolean;
  changed: boolean;
  updates: Array<{
    decisionKey: string;
    runId: string;
    approvalId: string;
    replacementRunId: string;
    replacementApprovalId: string;
    runClosed: boolean;
  }>;
} {
  const runs = listAgentRuns(corpus);
  const referencesByKey = new Map<string, AgentRunApprovalReference[]>();
  for (const run of runs) {
    for (const approval of run.approvals) {
      for (const key of agentRunApprovalDecisionKeys(approval)) {
        referencesByKey.set(key, [
          ...(referencesByKey.get(key) || []),
          { run, approval },
        ]);
      }
    }
  }

  const updatedRuns = new Map<string, AgentRun>();
  const processed = new Set<string>();
  const updates: Array<{
    decisionKey: string;
    runId: string;
    approvalId: string;
    replacementRunId: string;
    replacementApprovalId: string;
    runClosed: boolean;
  }> = [];
  for (const [decisionKey, references] of referencesByKey) {
    const canonical = [...references].sort(compareApprovalReferences).at(-1);
    if (!canonical) continue;
    for (const reference of references) {
      const identity = `${reference.run.id}:${reference.approval.id}`;
      if (identity === `${canonical.run.id}:${canonical.approval.id}`
        || reference.approval.status !== "pending"
        || processed.has(identity)) {
        continue;
      }
      processed.add(identity);
      const current = updatedRuns.get(reference.run.id) || reference.run;
      let reconciled = supersedeAgentRunApproval(current, reference.approval.id, {
        actor: "org2-approval-reconciler",
        replacementRunId: canonical.run.id,
        replacementApprovalId: canonical.approval.id,
      });
      const runClosed = canCloseSupersededApprovalProjection(reconciled, [decisionKey]);
      if (runClosed) {
        reconciled = closeSupersededApprovalProjection(
          reconciled,
          [decisionKey],
          canonical.run.id,
          canonical.approval.id,
        );
      }
      updatedRuns.set(reconciled.id, reconciled);
      updates.push({
        decisionKey,
        runId: reference.run.id,
        approvalId: reference.approval.id,
        replacementRunId: canonical.run.id,
        replacementApprovalId: canonical.approval.id,
        runClosed,
      });
    }
  }
  if (apply) {
    for (const run of updatedRuns.values()) saveAgentRun(corpus, run);
  }
  return {
    schema: "org2:approval-reconciliation:v1",
    applied: apply,
    changed: updates.length > 0,
    updates,
  };
}

function resolveCorrelatedApproval(corpus: string, rawDecisionKey: string): {
  schema: "org2:approval-resolution:v1";
  found: boolean;
  decisionKey: string;
  canonical?: {
    runId: string;
    runStatus: AgentRunStatus;
    approval: AgentRunApproval;
  };
  projections: Array<{
    runId: string;
    runStatus: AgentRunStatus;
    approvalId: string;
    approvalStatus: AgentRunApproval["status"];
    requestedAt: string;
  }>;
} {
  const normalized = rawDecisionKey.trim().toLowerCase();
  const decisionKey = normalized.startsWith("artifact:") ? normalized : `artifact:${normalized}`;
  const references = approvalReferences(listAgentRuns(corpus), [decisionKey])
    .filter((reference) => agentRunApprovalDecisionKeys(reference.approval).includes(decisionKey))
    .sort(compareApprovalReferences);
  const canonical = references.at(-1);
  return {
    schema: "org2:approval-resolution:v1",
    found: Boolean(canonical),
    decisionKey,
    ...(canonical ? {
      canonical: {
        runId: canonical.run.id,
        runStatus: canonical.run.status,
        approval: canonical.approval,
      },
    } : {}),
    projections: references.map((reference) => ({
      runId: reference.run.id,
      runStatus: reference.run.status,
      approvalId: reference.approval.id,
      approvalStatus: reference.approval.status,
      requestedAt: reference.approval.requestedAt,
    })),
  };
}

async function runCommand(parsed: ParsedArgs): Promise<void> {
  const action = parsed.positional[0] || "help";
  const corpus = root(parsed);
  if (action === "help") { output(parsed, HELP); return; }
  if (action === "create") {
    const risk = choice(flag(parsed, "risk", "local-draft"), AGENT_RUN_RISK_CLASSES, "risk class");
    const tokenLimit = flag(parsed, "token-limit"); const costLimit = flag(parsed, "cost-limit-usd"); const timeLimit = flag(parsed, "time-limit-seconds");
    const plan = flags(parsed, "step").map((raw, index) => { const colon = raw.indexOf(":"); const kind = colon > 0 ? raw.slice(0, colon) : "agent"; const title = colon > 0 ? raw.slice(colon + 1) : raw; if (!title.trim()) throw new Error(`--step ${index + 1} must be [${AGENT_RUN_STEP_KINDS.join("|")}]:TITLE`); return { id: `step-${index + 1}`, kind: choice(kind, AGENT_RUN_STEP_KINDS, `--step ${index + 1} kind`), title: title.trim() }; });
    const run = createAgentRun({ id: flag(parsed, "id"), goal: required(flag(parsed, "goal"), "--goal is required"), acceptanceCriteria: flags(parsed, "accept"), riskClass: risk, owner: flag(parsed, "owner"), assignee: flag(parsed, "assignee"), providerPolicy: flag(parsed, "policy"), provider: flag(parsed, "provider"), model: flag(parsed, "model"), capabilities: flags(parsed, "capability"), context: flags(parsed, "context").map((ref) => ({ ref })), plan, logicalWorkId: flag(parsed, "logical-work-id"), ...((tokenLimit || costLimit || timeLimit) ? { budget: { ...(tokenLimit ? { tokenLimit: Number(tokenLimit) } : {}), ...(costLimit ? { costLimitUsd: Number(costLimit) } : {}), ...(timeLimit ? { timeLimitSeconds: Number(timeLimit) } : {}) } } : {}) });
    const file = saveAgentRun(corpus, run); output(parsed, { run, file }, `created ${run.id}\n${file}`); return;
  }
  if (action === "list") {
    const status = flag(parsed, "status");
    const runs = listAgentRuns(corpus).filter((run) => !status || run.status === status);
    output(parsed, { schema: "org2:run-list:v1", runs, logicalWork: summarizeAgentRunAttempts(runs) }, runs.length ? runs.map((run) => `${run.id}\t${run.status}\t${run.attempt ? `${run.logicalWorkId}#${run.attempt.number}\t` : ""}${run.goal}`).join("\n") : "No runs."); return;
  }
  if (action === "normalize") { const result = normalizeLegacyAgentRuns(corpus); output(parsed, result, `created ${result.created.length}; skipped ${result.skippedExisting.length}`); return; }
  if (action === "approval-reconcile") {
    const result = reconcileCorrelatedApprovals(corpus, enabled(parsed, "apply"));
    output(
      parsed,
      result,
      `${result.applied ? "reconciled" : "would reconcile"} ${result.updates.length} duplicate approval projection(s)`,
    );
    return;
  }
  if (action === "approval-resolve") {
    const result = resolveCorrelatedApproval(
      corpus,
      required(flag(parsed, "decision-key"), "--decision-key is required"),
    );
    output(
      parsed,
      result,
      result.canonical
        ? `${result.decisionKey}\t${result.canonical.approval.status}\t${result.canonical.runId}:${result.canonical.approval.id}`
        : `${result.decisionKey}\tnot found`,
    );
    return;
  }
  const id = required(parsed.positional[1], `run id is required for ${action}`);
  if (action === "show") { const run = loadAgentRun(corpus, id); output(parsed, run, fs.readFileSync(path.join(corpus, ".org2", "runs", `${id}.org2`), "utf8")); return; }
  if (action === "validate") { const result = validateAgentRun(loadAgentRun(corpus, id)); output(parsed, result, result.valid ? `${id}: valid` : result.issues.map((issue) => `${issue.path}: ${issue.message}`).join("\n")); if (!result.valid) process.exitCode = 1; return; }
  const existing = loadAgentRun(corpus, id);
  let run = existing;
  const transitions: Record<string, AgentRunStatus> = { start: "running", resume: "running", retry: "queued", cancel: "canceled", complete: "completed", fail: "failed", block: "blocked" };
  if (action === "complete-external") run = completeAgentRunExternally(existing, {
    summary: required(flag(parsed, "summary"), "--summary is required"),
    actor: required(flag(parsed, "actor"), "--actor is required"),
  });
  else if (transitions[action]) run = transitionAgentRun(existing, transitions[action]!, {
    actor: flag(parsed, "actor"), reason: flag(parsed, "reason"), summary: flag(parsed, "summary"),
    highlights: flags(parsed, "highlight"), nextActions: flags(parsed, "next-action"),
  });
  else if (action === "assign") run = updateAgentRunAssignment(existing, { owner: flag(parsed, "owner"), assignee: flag(parsed, "assignee"), actor: flag(parsed, "actor") });
  else if (action === "outcome") run = updateAgentRunOutcome(existing, { summary: required(flag(parsed, "summary"), "--summary is required"), highlights: flags(parsed, "highlight"), nextActions: flags(parsed, "next-action"), actor: flag(parsed, "actor") });
  else if (action === "runtime") {
    const numberFlag = (name: string): number | undefined => {
      const raw = flag(parsed, name);
      if (raw === undefined) return undefined;
      const value = Number(raw);
      if (!Number.isFinite(value) || value < 0) throw new Error(`--${name} must be a non-negative number`);
      return value;
    };
    run = updateAgentRunRuntime(existing, {
      provider: flag(parsed, "provider"),
      model: flag(parsed, "model"),
      tokensUsed: numberFlag("tokens-used"),
      costUsedUsd: numberFlag("cost-used-usd"),
      elapsedSeconds: numberFlag("elapsed-seconds"),
      actor: flag(parsed, "actor"),
    });
  }
  else if (action === "comment") run = addAgentRunComment(existing, required(flag(parsed, "author"), "--author is required"), required(flag(parsed, "body"), "--body is required"));
  else if (action === "step") run = updateAgentRunStep(existing, required(parsed.positional[2], "step id is required"), choice(flag(parsed, "status"), AGENT_RUN_STEP_STATUSES, "step status"), { actor: flag(parsed, "actor"), detail: flag(parsed, "detail") });
  else if (action === "artifact") run = addAgentRunArtifact(existing, { path: required(flag(parsed, "path"), "--path is required"), role: choice(flag(parsed, "role", "draft"), AGENT_RUN_ARTIFACT_ROLES, "artifact role"), title: flag(parsed, "title"), mediaType: flag(parsed, "media-type"), sha256: flag(parsed, "sha256"), reviewStatus: optionalChoice(flag(parsed, "review-status"), AGENT_RUN_ARTIFACT_REVIEW_STATUSES, "artifact review status") }, flag(parsed, "actor"));
  else if (action === "artifact-review") {
    const artifactId = required(parsed.positional[2], "artifact id is required");
    const reviewStatus = choice(flag(parsed, "status"), AGENT_RUN_ARTIFACT_REVIEW_STATUSES, "artifact review status");
    const artifact = existing.artifacts.find((item) => item.id === artifactId);
    if (!artifact) throw new Error(`unknown artifact id: ${artifactId}`);
    run = updateAgentRunArtifactReview(existing, artifactId, reviewStatus, { actor: flag(parsed, "actor") });
    syncLinkedArtifactReviewStatus(root(parsed), artifact.path, reviewStatus);
  }
  else if (action === "validation") run = addAgentRunValidation(existing, { name: required(flag(parsed, "name"), "--name is required"), status: choice(flag(parsed, "status"), AGENT_RUN_VALIDATION_STATUSES, "validation status"), detail: flag(parsed, "detail") }, flag(parsed, "actor"));
  else if (action === "approval-request") {
    const correlated = correlatedApprovalRequest(parsed, corpus, existing);
    if (correlated) {
      output(parsed, correlated, `${correlated.id}: ${correlated.status}`);
      return;
    }
    run = requestAgentRunApproval(existing, { title: required(flag(parsed, "title"), "--title is required"), action: required(flag(parsed, "action"), "--action is required"), riskClass: choice(flag(parsed, "risk", existing.riskClass), AGENT_RUN_RISK_CLASSES, "approval risk class"), requestedRole: flag(parsed, "role"), requestedFrom: flag(parsed, "from"), note: flag(parsed, "note") }, flag(parsed, "actor"));
  }
  else if (action === "approval-decide") {
    const correlated = correlatedApprovalDecision(parsed, corpus, existing);
    if (correlated) {
      output(parsed, correlated, `${correlated.id}: ${correlated.status}`);
      return;
    }
    run = decideAgentRunApproval(existing, required(parsed.positional[2], "approval id is required"), choice(flag(parsed, "decision"), AGENT_RUN_APPROVAL_DECISIONS, "approval decision"), { actor: required(flag(parsed, "actor"), "--actor is required"), actorRole: flag(parsed, "role"), fingerprint: flag(parsed, "fingerprint"), note: flag(parsed, "note"), receipt: flag(parsed, "receipt") });
  }
  else if (action === "fork") { run = forkAgentRun(existing, { id: flag(parsed, "id"), actor: flag(parsed, "actor"), fromEventId: flag(parsed, "event") }); const file = saveAgentRun(corpus, run); output(parsed, { run, file }, `forked ${existing.id} -> ${run.id}`); return; }
  else throw new Error(`unknown run action: ${action}`);
  saveAgentRun(corpus, run); output(parsed, run, `${run.id}: ${run.status}`);
}

function reviewCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "list";
  const corpus = root(parsed);
  const runs = listAgentRuns(corpus);
  if (action === "list") {
    const items = runs.flatMap((run) => [
      ...run.approvals.filter((approval) => !flag(parsed, "status") || approval.status === flag(parsed, "status")).map((approval) => ({ kind: "approval", runId: run.id, runGoal: run.goal, ...approval })),
      ...run.artifacts.filter((artifact) => artifact.reviewStatus === "review-required").map((artifact) => ({ kind: "artifact", runId: run.id, runGoal: run.goal, ...artifact })),
      ...(run.status === "blocked" ? [{ kind: "clarification", runId: run.id, runGoal: run.goal, reason: run.blockedReason }] : []),
      ...run.validations.filter((validation) => validation.status === "failed" || validation.status === "warning").map((validation) => ({ kind: "validation", runId: run.id, runGoal: run.goal, ...validation })),
    ]);
    output(parsed, { schema: "org2:review-queue:v1", items }, items.length ? items.map((item: any) => `${item.kind}\t${item.runId}\t${item.title || item.name || item.path || item.reason}`).join("\n") : "Review queue is empty."); return;
  }
  if (action === "show") { const run = loadAgentRun(corpus, required(parsed.positional[1], "run id is required")); output(parsed, { run, approvals: run.approvals, artifacts: run.artifacts, validations: run.validations, comments: run.comments }); return; }
  throw new Error(`unknown review action: ${action}`);
}

function workflowCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "list"; const corpus = root(parsed);
  if (action === "list") {
    const workflows = listWorkflows(corpus).map((workflow) => ({
      ...workflow,
      file: workflowSourcePath(corpus, workflow.id),
      legacyLocation: workflowSourcePath(corpus, workflow.id).includes(`${path.sep}.org2${path.sep}workflows${path.sep}`),
    }));
    output(parsed, { schema: "org2:workflow-list:v1", workflows }, workflows.length ? workflows.map((item) => `${item.id}@${item.version}\t${item.state}\t${item.title}`).join("\n") : "No workflows.");
    return;
  }
  if (action === "migrate") {
    const migrated = migrateLegacyWorkflows(corpus);
    output(parsed, { schema: "org2:workflow-migration:v1", migrated }, migrated.length ? migrated.map((item) => `${item.skipped ? "kept" : "moved"}\t${item.id}\t${item.to}`).join("\n") : "No legacy workflows.");
    return;
  }
  if (action === "install-builtin") { const name = parsed.positional[1] || "meeting-to-controlled-execution"; if (name !== "meeting-to-controlled-execution") throw new Error(`unknown built-in workflow: ${name}`); const file = installBuiltinWorkflow(corpus, MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW); output(parsed, { id: name, file }, `installed ${name}\n${file}`); return; }
  const id = required(parsed.positional[1], `workflow id is required for ${action}`);
  if (action === "save") { const run = loadAgentRun(corpus, id); const workflow = workflowFromRun(run, { id: flag(parsed, "id"), title: flag(parsed, "title"), version: flag(parsed, "version") }); const file = saveWorkflow(corpus, workflow); output(parsed, { workflow, file }, `saved ${workflow.id}@${workflow.version}`); return; }
  const workflow = loadWorkflow(corpus, id);
  if (action === "show") { output(parsed, workflow); return; }
  if (action === "validate") { const result = validateWorkflow(workflow); output(parsed, result, result.valid ? `${id}: valid` : result.issues.map((issue) => `${issue.path}: ${issue.message}`).join("\n")); if (!result.valid) process.exitCode = 1; return; }
  if (action === "activate" || action === "pause" || action === "draft") {
    const state = action === "activate" ? "active" : action === "pause" ? "paused" : "draft";
    const updated = updateWorkflow(corpus, id, (item) => ({ ...item, state }));
    output(parsed, updated, `${id}: ${state}`);
    return;
  }
  if (action === "schedule") {
    const cron = flag(parsed, "cron")?.trim();
    const timezone = flag(parsed, "timezone")?.trim() || flag(parsed, "tz")?.trim();
    const disabled = parsed.flags.has("disable");
    const gateEvents = flags(parsed, "gate-event").map((event) =>
      choice(event, [...WORKFLOW_EVENT_TRIGGER_TYPES, "file-change"] as const, "workflow gate event")
    );
    const gatePaths = flags(parsed, "gate-path");
    if (!disabled && !cron) throw new Error("workflow schedule requires --cron EXPR or --disable");
    const updated = updateWorkflow(corpus, id, (item) => {
      const triggers = item.triggers.filter((trigger) => trigger.id !== "openclaw-schedule");
      triggers.push({
        id: "openclaw-schedule",
        type: "schedule",
        enabled: !disabled,
        ...(cron ? { schedule: cron } : {}),
        ...(timezone ? { timezone } : {}),
        ...((gateEvents.length || gatePaths.length) ? {
          gate: {
            ...(gateEvents.length ? { events: gateEvents } : {}),
            ...(gatePaths.length ? { paths: gatePaths } : {}),
          },
        } : {}),
      });
      return { ...item, triggers };
    });
    output(parsed, updated, disabled ? `${id}: schedule disabled` : `${id}: scheduled ${cron}`);
    return;
  }
  if (action === "package") { output(parsed, packagedWorkflowManifest(workflow)); return; }
  if (action === "corpus-template") { const template = packagedCorpusTemplate(workflow); const out = flag(parsed, "out"); if (out) { const file = path.resolve(out); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, `${JSON.stringify(template, null, 2)}\n`, "utf8"); output(parsed, { template, file }, file); } else output(parsed, template); return; }
  if (action === "triggers") {
    const event = optionalChoice(flag(parsed, "event"), WORKFLOW_EVENT_TRIGGER_TYPES, "workflow event");
    const due = dueWorkflowTriggers(workflow, {
      now: flag(parsed, "now"),
      changedPaths: flags(parsed, "changed"),
      event,
    });
    output(parsed, { workflow: id, due }, due.length ? due.map((trigger) => `${trigger.id}\t${trigger.type}`).join("\n") : "No triggers due.");
    return;
  }
  if (action === "signal") {
    const event = choice(flag(parsed, "event"), [...WORKFLOW_EVENT_TRIGGER_TYPES, "file-change"] as const, "workflow signal");
    const updated = updateWorkflow(corpus, id, (item) => recordWorkflowSignal(item, {
      id: flag(parsed, "signal-id"),
      type: event,
      at: flag(parsed, "at"),
      paths: flags(parsed, "changed"),
    }));
    output(parsed, updated, `${id}: recorded ${event} signal`);
    return;
  }
  if (action === "gate") {
    const triggerId = required(flag(parsed, "trigger"), "--trigger is required");
    const eligibility = workflowTriggerEligibility(workflow, triggerId);
    output(parsed, { schema: "org2:workflow-gate:v1", workflowId: id, triggerId, ...eligibility }, eligibility.eligible ? `${id}/${triggerId}: eligible` : `${id}/${triggerId}: skipped — ${eligibility.reason}`);
    return;
  }
  if (action === "run") {
    const inputs = Object.fromEntries(flags(parsed, "input").map((item) => { const at = item.indexOf("="); if (at < 1) throw new Error("--input must be NAME=VALUE"); return [item.slice(0, at), item.slice(at + 1)]; }));
    const triggerId = flag(parsed, "trigger");
    const eligibility = triggerId ? workflowTriggerEligibility(workflow, triggerId) : { eligible: true, reason: "manual run", signalIds: [] };
    if (!eligibility.eligible) {
      output(parsed, { schema: "org2:workflow-run-skipped:v1", workflowId: id, triggerId, ...eligibility }, `skipped ${id}: ${eligibility.reason}`);
      return;
    }
    const existingAttempts = listAgentRuns(corpus).filter((item) => item.logicalWorkId === (flag(parsed, "logical-work-id") || `workflow:${id}`) && item.attempt);
    const attemptNumber = existingAttempts.reduce((maximum, item) => Math.max(maximum, item.attempt?.number || 0), 0) + 1;
    const attemptAt = flag(parsed, "scheduled-for") || new Date().toISOString();
    const run = instantiateWorkflow(workflow, inputs, {
      owner: flag(parsed, "owner"),
      assignee: flag(parsed, "assignee"),
      logicalWorkId: flag(parsed, "logical-work-id") || (triggerId ? `workflow:${id}` : undefined),
      attempt: triggerId ? {
        id: flag(parsed, "attempt-id") || crypto.randomUUID(),
        number: attemptNumber,
        triggerId,
        triggerType: workflow.triggers.find((item) => item.id === triggerId)?.type,
        scheduledFor: attemptAt,
        signalIds: eligibility.signalIds,
      } : undefined,
    });
    const file = saveAgentRun(corpus, run);
    if (triggerId) updateWorkflow(corpus, id, (item) => markWorkflowTriggerAttempt(item, triggerId, attemptAt));
    output(parsed, { run, file, eligibility }, `created run ${run.id} from ${id}@${workflow.version}${run.attempt ? ` attempt ${run.attempt.number}` : ""}`);
    return;
  }
  throw new Error(`unknown workflow action: ${action}`);
}

function artifactCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "graph"; const corpus = root(parsed); const manifest = path.resolve(required(flag(parsed, "manifest"), "--manifest is required")); const graph = buildArtifactGraph(corpus, loadArtifactDeclarations(manifest));
  if (action === "graph") { const file = enabled(parsed, "apply") ? saveArtifactGraph(corpus, graph) : undefined; output(parsed, { graph, ...(file ? { file } : {}) }, graph.artifacts.map((item) => `${item.status}\t${item.path}${item.reason ? `\t${item.reason}` : ""}`).join("\n")); return; }
  if (action === "rebuild") { const plan = artifactRebuildPlan(graph); output(parsed, { schema: "org2:artifact-rebuild-plan:v1", plan }, plan.length ? plan.map((item) => `${item.path}\t${item.command || "manual"}\t${item.reason}`).join("\n") : "All artifacts are fresh."); return; }
  throw new Error(`unknown artifact action: ${action}`);
}

function runtimeCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "show"; const corpus = root(parsed);
  if (action === "init") { const config = loadRuntimePolicy(corpus); const file = saveRuntimePolicy(corpus, config); output(parsed, { config, file }, file); return; }
  const config = loadRuntimePolicy(corpus);
  if (action === "show") { output(parsed, { file: runtimePolicyPath(corpus), config }); return; }
  if (action === "select") { const policy = required(parsed.positional[1], "policy name is required"); const runtime = selectRuntime(config, policy, flags(parsed, "capability")); output(parsed, { policy, runtime }, `${runtime.id}\t${runtime.provider}/${runtime.model}\t${runtime.transport}`); return; }
  if (action === "verify-paths") { const result = validateRuntimePaths(config, flags(parsed, "capability")); output(parsed, result, result.valid ? `local: ${result.local!.id}\nhosted: ${result.hosted!.id}` : result.issues.join("\n")); if (!result.valid) process.exitCode = 1; return; }
  throw new Error(`unknown runtime action: ${action}`);
}

async function mcpCommand(parsed: ParsedArgs): Promise<void> {
  const action = parsed.positional[0] || "clients"; const corpus = root(parsed);
  if (action === "serve") { await serveMcp(corpus); return; }
  if (action === "clients") { const clients = loadMcpClients(corpus); output(parsed, { schema: "org2:mcp-clients:v1", clients }); return; }
  if (action === "client-add") { const id = required(parsed.positional[1], "client id is required"); const command = required(flag(parsed, "command"), "--command is required"); const clients = loadMcpClients(corpus).filter((item) => item.id !== id); clients.push({ id, command, args: flags(parsed, "arg"), capabilities: flags(parsed, "capability"), environmentVariables: flags(parsed, "env") }); const file = saveMcpClients(corpus, clients); output(parsed, { clients, file }, `saved ${id}`); return; }
  if (action === "discover") { const id = required(parsed.positional[1], "client id is required"); const discovery = discoverMcpClient(corpus, id, { timeoutMs: Number(flag(parsed, "timeout-ms", "10000")), snapshotId: flag(parsed, "snapshot") }); output(parsed, discovery, `${id}: ${Object.values(discovery.capabilities).flatMap((value) => Array.isArray(value) ? value : []).length} discovered item(s)${discovery.snapshot ? `\n${discovery.snapshot}` : ""}`); return; }
  if (action === "snapshot") { const id = required(parsed.positional[1], "snapshot id is required"); const source = required(flag(parsed, "source"), "--source is required"); const input = flag(parsed, "input"); const payload = input ? JSON.parse(fs.readFileSync(path.resolve(input), "utf8")) : JSON.parse(await new Promise<string>((resolve, reject) => { let raw = ""; process.stdin.setEncoding("utf8"); process.stdin.on("data", (chunk) => raw += chunk); process.stdin.on("end", () => resolve(raw)); process.stdin.on("error", reject); })); const snapshot = { schema: "org2:mcp-snapshot:v1" as const, id, source, retrievedAt: new Date().toISOString(), identity: flag(parsed, "identity"), freshUntil: flag(parsed, "fresh-until"), payload }; const file = writeMcpSnapshot(corpus, snapshot); output(parsed, { snapshot, file }, file); return; }
  throw new Error(`unknown mcp action: ${action}`);
}

function evalCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "run"; const corpus = root(parsed); const id = required(parsed.positional[1], `${action === "replay" ? "workflow" : "run"} id is required`);
  if (action === "replay") { const result = replayWorkflowFixture(loadWorkflow(corpus, id), loadWorkflowReplayFixture(path.resolve(required(flag(parsed, "fixture"), "--fixture is required")))); output(parsed, result, `${result.passed ? "PASS" : "FAIL"} replay ${id}\n${result.checks.map((item) => `${item.passed ? "PASS" : "FAIL"}\t${item.name}\t${item.detail}`).join("\n")}`); if (!result.passed) process.exitCode = 1; return; }
  const run = loadAgentRun(corpus, id);
  if (action === "run") { const result = evaluateRun(run, loadEvalExpectation(path.resolve(required(flag(parsed, "expect"), "--expect is required")))); const file = saveEvalResult(corpus, result); output(parsed, { result, file }, `${result.passed ? "PASS" : "FAIL"} ${run.id}\n${result.checks.map((item) => `${item.passed ? "PASS" : "FAIL"}\t${item.name}\t${item.detail}`).join("\n")}`); if (!result.passed) process.exitCode = 1; return; }
  if (action === "fixture") { const file = path.resolve(required(flag(parsed, "output"), "--output is required")); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, `${JSON.stringify(sanitizeRunFixture(run), null, 2)}\n`, "utf8"); output(parsed, { file }, file); return; }
  throw new Error(`unknown eval action: ${action}`);
}

export async function runAgenticWorkspaceCommand(args: string[]): Promise<boolean> {
  const family = args[0];
  if (!family || !["corpus", "workspace", "thread", "run", "review", "workflow", "artifact", "runtime", "mcp", "eval"].includes(family)) return false;
  const parsed = parseArgs(args.slice(1));
  if (enabled(parsed, "help") || parsed.positional[0] === "help") { output(parsed, HELP); return true; }
  if (family === "corpus") corpusCommand(parsed);
  else if (family === "workspace") await workspaceCommand(parsed);
  else if (family === "thread") threadCommand(parsed);
  else if (family === "run") await runCommand(parsed);
  else if (family === "review") reviewCommand(parsed);
  else if (family === "workflow") workflowCommand(parsed);
  else if (family === "artifact") artifactCommand(parsed);
  else if (family === "runtime") runtimeCommand(parsed);
  else if (family === "mcp") await mcpCommand(parsed);
  else if (family === "eval") evalCommand(parsed);
  return true;
}
