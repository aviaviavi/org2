import fs from "node:fs";
import path from "node:path";
import type { AgentRun } from "./agentRun.js";
import { instantiateWorkflow, type AgentWorkflow } from "./agentWorkflow.js";

export interface WorkflowEvalExpectation {
  status?: AgentRun["status"];
  artifacts?: string[];
  validations?: string[];
  citations?: boolean;
  noExternalActionsWithoutApproval?: boolean;
  protectedPaths?: string[];
}

export interface WorkflowEvalResult {
  schema: "org2:workflow-eval:v1";
  runId: string;
  passed: boolean;
  checks: Array<{ name: string; passed: boolean; detail: string }>;
  metrics: { elapsedSeconds?: number; tokensUsed?: number; costUsedUsd?: number; citationCoverage: number; artifactFreshness: number };
}

export interface WorkflowReplayFixture {
  schema: "org2:workflow-replay-fixture:v1";
  workflowVersion: string;
  inputs: Record<string, string>;
  expectedGoal?: string;
  expectedSteps?: string[];
  expectedCapabilities?: string[];
  expectedRiskClass?: AgentRun["riskClass"];
}

export function replayWorkflowFixture(workflow: AgentWorkflow, fixture: WorkflowReplayFixture): WorkflowEvalResult {
  const run = instantiateWorkflow(workflow, fixture.inputs, { now: "2000-01-01T00:00:00.000Z" });
  const checks: WorkflowEvalResult["checks"] = [];
  const add = (name: string, passed: boolean, detail: string) => checks.push({ name, passed, detail });
  add("workflow-version", workflow.version === fixture.workflowVersion, `expected ${fixture.workflowVersion}; got ${workflow.version}`);
  if (fixture.expectedGoal) add("goal", run.goal === fixture.expectedGoal, `expected ${fixture.expectedGoal}; got ${run.goal}`);
  if (fixture.expectedRiskClass) add("risk-class", run.riskClass === fixture.expectedRiskClass, `expected ${fixture.expectedRiskClass}; got ${run.riskClass}`);
  for (const step of fixture.expectedSteps || []) add(`step:${step}`, run.plan.some((item) => item.id === step), `expected plan step ${step}`);
  for (const capability of fixture.expectedCapabilities || []) add(`capability:${capability}`, run.capabilities.includes(capability), `expected capability ${capability}`);
  return { schema: "org2:workflow-eval:v1", runId: `replay:${workflow.id}@${workflow.version}`, passed: checks.every((check) => check.passed), checks, metrics: { citationCoverage: run.context.length ? run.context.filter((item) => item.citation || item.ref).length / run.context.length : 1, artifactFreshness: 1 } };
}

export function evaluateRun(run: AgentRun, expected: WorkflowEvalExpectation): WorkflowEvalResult {
  const checks: WorkflowEvalResult["checks"] = [];
  const add = (name: string, passed: boolean, detail: string) => checks.push({ name, passed, detail });
  if (expected.status) add("status", run.status === expected.status, `expected ${expected.status}; got ${run.status}`);
  for (const artifact of expected.artifacts || []) add(`artifact:${artifact}`, run.artifacts.some((item) => item.path === artifact || item.id === artifact), `expected artifact ${artifact}`);
  for (const validation of expected.validations || []) add(`validation:${validation}`, run.validations.some((item) => item.name === validation && item.status === "passed"), `expected passing validation ${validation}`);
  if (expected.citations) add("citations", run.context.length > 0 && run.context.every((item) => Boolean(item.citation || item.ref)), "every context item must retain a source reference");
  if (expected.noExternalActionsWithoutApproval) {
    const external = run.riskClass === "external-action" || run.riskClass === "high-impact";
    add("approval-boundary", !external || run.approvals.some((item) => item.status === "approved"), "external/high-impact runs require an approved action");
  }
  for (const protectedPath of expected.protectedPaths || []) add(`protected:${protectedPath}`, !run.artifacts.some((item) => item.path === protectedPath || item.path.startsWith(`${protectedPath}/`)), `must not write ${protectedPath}`);
  const cited = run.context.filter((item) => item.citation || item.ref).length;
  const reviewed = run.artifacts.filter((item) => item.reviewStatus === "reviewed" || item.reviewStatus === "promoted").length;
  return {
    schema: "org2:workflow-eval:v1",
    runId: run.id,
    passed: checks.every((check) => check.passed),
    checks,
    metrics: {
      ...(run.budget?.elapsedSeconds !== undefined ? { elapsedSeconds: run.budget.elapsedSeconds } : {}),
      ...(run.budget?.tokensUsed !== undefined ? { tokensUsed: run.budget.tokensUsed } : {}),
      ...(run.budget?.costUsedUsd !== undefined ? { costUsedUsd: run.budget.costUsedUsd } : {}),
      citationCoverage: run.context.length ? cited / run.context.length : 1,
      artifactFreshness: run.artifacts.length ? reviewed / run.artifacts.length : 1,
    },
  };
}

export function loadEvalExpectation(file: string): WorkflowEvalExpectation { return JSON.parse(fs.readFileSync(file, "utf8")) as WorkflowEvalExpectation; }
export function loadWorkflowReplayFixture(file: string): WorkflowReplayFixture { return JSON.parse(fs.readFileSync(file, "utf8")) as WorkflowReplayFixture; }
export function saveEvalResult(root: string, result: WorkflowEvalResult): string {
  const file = path.join(path.resolve(root), ".org2", "evals", `${result.runId}.json`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(result, null, 2)}\n`, "utf8");
  return file;
}

export function sanitizeRunFixture(run: AgentRun): AgentRun {
  return {
    ...run,
    owner: run.owner ? "fixture-owner" : undefined,
    assignee: run.assignee ? "fixture-agent" : undefined,
    context: run.context.map((item, index) => ({ ref: `fixture/source-${index + 1}.org2`, title: item.title, citation: `fixture/source-${index + 1}.org2:1` })),
    comments: run.comments.map((comment) => ({ ...comment, author: "fixture-user" })),
    approvals: run.approvals.map((approval) => ({ ...approval, requestedFrom: approval.requestedFrom ? "fixture-reviewer" : undefined, decidedBy: approval.decidedBy ? "fixture-reviewer" : undefined, receipt: undefined })),
    provider: run.provider ? "fixture-provider" : undefined,
    model: run.model ? "fixture-model" : undefined,
  };
}
