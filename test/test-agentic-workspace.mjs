import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { PassThrough } from "node:stream";
import {
  addAgentRunArtifact, addAgentRunComment, addAgentRunValidation, createAgentRun,
  decideAgentRunApproval, forkAgentRun, listAgentRuns, loadAgentRun, normalizeLegacyAgentRuns,
  parseAgentRunOrg, renderAgentRunOrg, requestAgentRunApproval, saveAgentRun,
  transitionAgentRun, updateAgentRunAssignment, updateAgentRunStep, validateAgentRun,
} from "../dist/agentRun.js";
import { dueWorkflowTriggers, instantiateWorkflow, legacyWorkflowDirectory, loadWorkflow, migrateLegacyWorkflows, packagedCorpusTemplate, parseWorkflowOrg, renderWorkflowOrg, saveWorkflow, workflowFromRun, workflowPath } from "../dist/agentWorkflow.js";
import { artifactRebuildPlan, buildArtifactGraph, MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW } from "../dist/artifactPipeline.js";
import { discoverMcpClient, installBuiltinWorkflow, saveMcpClients, serveMcp, writeMcpSnapshot } from "../dist/mcpRuntime.js";
import { defaultRuntimePolicy, selectRuntime, validateRuntimePaths } from "../dist/runtimePolicy.js";
import { evaluateRun, replayWorkflowFixture, sanitizeRunFixture } from "../dist/workflowEval.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agentic-"));
try {
  let run = createAgentRun({
    id: "board-brief", goal: "Prepare a cited board briefing",
    acceptanceCriteria: ["A reviewed PDF exists"], owner: "Avi", assignee: "research-agent",
    capabilities: ["agent-context", "publish"], context: [{ ref: "notes/board.org2", citation: "notes/board.org2:1" }],
    plan: [{ id: "draft", title: "Draft briefing", kind: "agent" }, { id: "review", title: "Review release", kind: "approval" }],
  });
  assert.equal(validateAgentRun(run).valid, true);
  assert.deepEqual(parseAgentRunOrg(renderAgentRunOrg(run)), run);
  saveAgentRun(root, run);
  assert.equal(loadAgentRun(root, run.id).goal, run.goal);

  assert.throws(() => createAgentRun({ goal: "Reject an invalid plan", plan: [{ title: "Broken", kind: "unknown" }] }), /invalid run step kind/);
  assert.throws(() => updateAgentRunStep(run, "draft", "unknown"), /invalid run step status/);
  assert.throws(() => addAgentRunArtifact(run, { path: "views/broken.org2", role: "unknown" }), /invalid artifact role/);
  assert.throws(() => addAgentRunArtifact(run, { path: "views/broken.org2", role: "draft", reviewStatus: "unknown" }), /invalid artifact review status/);
  assert.throws(() => addAgentRunValidation(run, { name: "broken", status: "unknown" }), /invalid validation status/);
  assert.throws(() => requestAgentRunApproval(run, { title: "Broken", action: "broken", riskClass: "unknown" }), /invalid approval risk class/);
  const pendingApproval = requestAgentRunApproval(run, { id: "test", title: "Test", action: "test", riskClass: "local-draft" });
  assert.throws(() => decideAgentRunApproval(pendingApproval, "test", "unknown", { actor: "Avi" }), /invalid approval decision/);
  assert.throws(
    () => transitionAgentRun(createAgentRun({ id: "missing-clarification", goal: "Require an actionable blocker" }), "blocked"),
    /requires --reason/
  );
  assert.equal(
    transitionAgentRun(
      createAgentRun({ id: "specific-clarification", goal: "Ask a useful question" }),
      "blocked",
      { reason: "Which reporting period should this cover?" }
    ).blockedReason,
    "Which reporting period should this cover?"
  );
  assert.throws(
    () => transitionAgentRun(transitionAgentRun(createAgentRun({ id: "missing-outcome", goal: "Explain the result" }), "running"), "completed"),
    /requires --summary/
  );

  const invalidStep = spawnSync(process.execPath, [path.resolve("dist/cli.js"), "run", "step", run.id, "draft", "--status", "unknown", "--dir", root], { encoding: "utf8" });
  assert.notEqual(invalidStep.status, 0);
  assert.match(invalidStep.stderr, /invalid step status: unknown/);
  assert.equal(loadAgentRun(root, run.id).plan[0].status, "pending");

  run = transitionAgentRun(run, "running", { now: "2026-07-14T10:00:00Z" });
  run = updateAgentRunStep(run, "draft", "completed", { actor: "research-agent", now: "2026-07-14T10:01:00Z" });
  run = addAgentRunArtifact(run, { id: "brief", path: "views/board/briefing.org2", role: "view", reviewStatus: "review-required" });
  run = addAgentRunValidation(run, { id: "citations", name: "citations", status: "passed" });
  run = addAgentRunComment(run, "Avi", "Tighten the recommendation section.");
  run = updateAgentRunAssignment(run, { assignee: "writing-agent", actor: "Avi" });
  run = requestAgentRunApproval(run, { id: "release", title: "Release briefing", action: "publish PDF", riskClass: "external-action", requestedRole: "owner" });
  assert.equal(run.status, "waiting-approval");
  run = decideAgentRunApproval(run, "release", "approved", { actor: "Avi", actorRole: "owner", receipt: "approval:local:1" });
  assert.equal(run.status, "running");
  run = addAgentRunArtifact(run, { id: "pdf", path: "compiled/board.pdf", role: "export", reviewStatus: "reviewed", mediaType: "application/pdf" });
  run = transitionAgentRun(run, "completed", {
    summary: "Prepared and reviewed the cited board briefing and its PDF export.",
    highlights: ["The briefing and PDF are ready for use."],
    nextActions: [],
  });
  assert.equal(run.outcome.summary, "Prepared and reviewed the cited board briefing and its PDF export.");
  saveAgentRun(root, run);
  assert.equal(listAgentRuns(root).length, 1);
  assert.equal(forkAgentRun(run, { id: "board-brief-revision" }).parentRunId, run.id);

  let gated = createAgentRun({ id: "multi-approval", goal: "Exercise a multi-approval boundary" });
  gated = requestAgentRunApproval(gated, { id: "legal", title: "Legal review", action: "release", riskClass: "external-action", requestedRole: "legal" });
  gated = requestAgentRunApproval(gated, { id: "owner", title: "Owner review", action: "release", riskClass: "external-action", requestedRole: "owner" });
  assert.throws(() => decideAgentRunApproval(gated, "legal", "approved", { actor: "Avi", actorRole: "owner" }), /requires role legal/);
  gated = decideAgentRunApproval(gated, "legal", "rejected", { actor: "Counsel", actorRole: "legal" });
  gated = decideAgentRunApproval(gated, "owner", "approved", { actor: "Avi", actorRole: "owner" });
  assert.equal(gated.status, "blocked");

  const workflow = workflowFromRun(run, { id: "board-briefing", now: "2026-07-14T11:00:00Z" });
  workflow.inputs.push({ id: "quarter", description: "Reporting quarter", required: true });
  workflow.instructions = "Prepare the {{quarter}} board briefing";
  workflow.triggers.push({ id: "daily", type: "schedule", enabled: true, schedule: "every 1d", lastRunAt: "2026-07-12T00:00:00Z" });
  saveWorkflow(root, workflow);
  assert.equal(workflowPath(root, workflow.id), path.join(root, "workflows", "board-briefing.org2"));
  assert.equal(fs.existsSync(workflowPath(root, workflow.id)), true);
  assert.equal(loadWorkflow(root, workflow.id).version, "1.0.0");
  const editedWorkflowSource = renderWorkflowOrg(workflow)
    .replace("* Prepare a cited board briefing", "* Maintained board workflow")
    .replace("Prepare the {{quarter}} board briefing\n\n** Machine state", "Prepare a carefully cited {{quarter}} board briefing\n\n** Machine state")
    .replace(":WORKFLOW_STATE: draft", ":WORKFLOW_STATE: active");
  const editedWorkflow = parseWorkflowOrg(editedWorkflowSource);
  assert.equal(editedWorkflow.title, "Maintained board workflow");
  assert.equal(editedWorkflow.instructions, "Prepare a carefully cited {{quarter}} board briefing");
  assert.equal(editedWorkflow.state, "active");
  assert.equal(dueWorkflowTriggers(workflow, { now: "2026-07-14T00:00:00Z" }).some((item) => item.id === "daily"), true);
  const instantiated = instantiateWorkflow(workflow, { quarter: "Q3" });
  assert.equal(instantiated.goal, "Prepare the Q3 board briefing");
  assert.equal(instantiated.workflowId, "board-briefing");
  assert.equal(packagedCorpusTemplate(workflow).schema, "org2:corpus-template:v1");
  assert.equal(replayWorkflowFixture(workflow, { schema: "org2:workflow-replay-fixture:v1", workflowVersion: "1.0.0", inputs: { quarter: "Q3" }, expectedGoal: "Prepare the Q3 board briefing", expectedSteps: ["draft"], expectedCapabilities: ["publish"], expectedRiskClass: "local-draft" }).passed, true);
  assert.equal(fs.existsSync(installBuiltinWorkflow(root, MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW)), true);
  const installedMeetingWorkflow = loadWorkflow(root, "meeting-to-controlled-execution");
  const meetingRun = instantiateWorkflow(installedMeetingWorkflow, { meeting: "meetings/standup.org2" });
  assert.match(meetingRun.goal, /meetings\/standup\.org2/);
  assert.equal(meetingRun.context[0].ref, "meetings/standup.org2");

  const legacyWorkflow = { ...workflow, id: "legacy-workflow", title: "Legacy workflow" };
  const legacyDirectory = legacyWorkflowDirectory(root);
  fs.mkdirSync(legacyDirectory, { recursive: true });
  fs.writeFileSync(path.join(legacyDirectory, "legacy-workflow.org2"), fs.readFileSync(workflowPath(root, workflow.id), "utf8").replaceAll("board-briefing", "legacy-workflow").replace("Prepare a cited board briefing", "Legacy workflow"));
  assert.equal(loadWorkflow(root, "legacy-workflow").id, "legacy-workflow");
  const migration = migrateLegacyWorkflows(root);
  assert.equal(migration.some((item) => item.id === "legacy-workflow" && !item.skipped), true);
  assert.equal(fs.existsSync(workflowPath(root, "legacy-workflow")), true);

  const source = path.join(root, "notes", "source.org2");
  const report = path.join(root, "compiled", "report.pdf");
  fs.mkdirSync(path.dirname(source), { recursive: true }); fs.mkdirSync(path.dirname(report), { recursive: true });
  fs.writeFileSync(source, "source\n"); fs.writeFileSync(report, "output\n");
  const baseline = buildArtifactGraph(root, [{ id: "report", path: "compiled/report.pdf", sources: ["notes/source.org2"], sourceHashes: {} }]);
  const hash = baseline.artifacts[0].sourceHashes["notes/source.org2"];
  fs.writeFileSync(source, "changed\n");
  const changed = buildArtifactGraph(root, [{ id: "report", path: "compiled/report.pdf", sources: ["notes/source.org2"], sourceHashes: { "notes/source.org2": hash } }]);
  assert.equal(changed.artifacts[0].status, "stale");
  assert.equal(artifactRebuildPlan(changed)[0].path, "compiled/report.pdf");

  const policy = defaultRuntimePolicy();
  policy.runtimes = [
    { id: "hosted-fast", provider: "example", model: "fast", transport: "hosted", capabilities: ["text"], privacy: "cloud", costClass: "low" },
    { id: "local-private", provider: "local", model: "small", transport: "local", capabilities: ["text"], privacy: "local", costClass: "free" },
  ];
  assert.equal(selectRuntime(policy, "private-local").id, "local-private");
  assert.equal(selectRuntime(policy, "fast-draft").id, "local-private");
  assert.equal(validateRuntimePaths(policy, ["text"]).valid, true);
  const evalResult = evaluateRun(run, { status: "completed", artifacts: ["pdf"], validations: ["citations"], citations: true, noExternalActionsWithoutApproval: true, protectedPaths: ["notes"] });
  assert.equal(evalResult.passed, true);
  assert.equal(sanitizeRunFixture(run).owner, "fixture-owner");

  const snapshot = writeMcpSnapshot(root, { schema: "org2:mcp-snapshot:v1", id: "crm-account", source: "mcp://crm/account/1", retrievedAt: "2026-07-14T00:00:00Z", identity: "account:1", payload: { name: "Example" } });
  assert.equal(fs.existsSync(snapshot), true);
  const input = new PassThrough(); const output = new PassThrough(); let response = "";
  output.setEncoding("utf8"); output.on("data", (chunk) => response += chunk);
  const serving = serveMcp(root, input, output);
  input.end(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })}\n${JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} })}\n`);
  await serving;
  const messages = response.trim().split("\n").map((line) => JSON.parse(line));
  assert.equal(messages[0].result.serverInfo.name, "org2");
  assert.equal(messages[1].result.tools.some((tool) => tool.name === "org2_run_create"), true);

  const mcpTransitionRun = createAgentRun({ id: "mcp-transition", goal: "Persist an MCP transition" });
  saveAgentRun(root, mcpTransitionRun);
  const transitionInput = new PassThrough(); const transitionOutput = new PassThrough(); let transitionResponse = "";
  transitionOutput.setEncoding("utf8"); transitionOutput.on("data", (chunk) => transitionResponse += chunk);
  const transitionServing = serveMcp(root, transitionInput, transitionOutput);
  transitionInput.end(`${JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "org2_run_transition", arguments: { run: "mcp-transition", status: "running", actor: "test" } } })}\n`);
  await transitionServing;
  assert.equal(JSON.parse(transitionResponse.trim()).result.content[0].type, "text");
  assert.equal(loadAgentRun(root, "mcp-transition").status, "running");

  saveMcpClients(root, [{
    id: "org2-self",
    command: process.execPath,
    args: [path.resolve("dist/cli.js"), "mcp", "serve", "--dir", root],
  }]);
  const discovery = discoverMcpClient(root, "org2-self", { snapshotId: "org2-self-capabilities", now: "2026-07-14T00:00:00Z" });
  assert.equal(discovery.capabilities.tools.some((tool) => tool.name === "org2_run_list"), true);
  assert.equal(fs.existsSync(discovery.snapshot), true);

  fs.writeFileSync(path.join(root, "notes", "legacy.org2"), "* TODO Delegated research\n:PROPERTIES:\n:AGENT_RUN_ID: legacy-1\n:AGENT_SESSION_ID: session-42\n:STATUS: needs-review\n:ORG2_ARTIFACT_ROLE: draft\n:ORG2_REVIEW_STATUS: review-required\n:END:\n");
  const normalized = normalizeLegacyAgentRuns(root, "2026-07-14T00:00:00Z");
  assert.equal(normalized.created[0].id, "legacy-1");
  const legacyRun = loadAgentRun(root, "legacy-1");
  assert.equal(legacyRun.status, "waiting-approval");
  assert.equal(legacyRun.artifacts[0].reviewStatus, "review-required");
  assert.equal(legacyRun.approvals[0].status, "pending");
  assert.equal(legacyRun.context.some((item) => item.ref === "session:session-42"), true);
  console.log("agentic workspace tests passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
