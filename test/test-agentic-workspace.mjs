import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { PassThrough } from "node:stream";
import {
  addAgentRunArtifact, addAgentRunComment, addAgentRunValidation, completeAgentRunExternally, createAgentRun,
  decideAgentRunApproval, forkAgentRun, listAgentRuns, loadAgentRun, normalizeLegacyAgentRuns,
  loadAgentRunSnapshot, parseAgentRunOrg, renderAgentRunOrg, requestAgentRunApproval, saveAgentRun, summarizeAgentRunAttempts,
  transitionAgentRun, updateAgentRunAssignment, updateAgentRunRuntime, updateAgentRunStep, validateAgentRun,
  updateAgentRunArtifactReview,
} from "../dist/agentRun.js";
import { dueWorkflowTriggers, installBuiltinWorkflow, instantiateWorkflow, legacyWorkflowDirectory, loadWorkflow, loadWorkflowSnapshot, markWorkflowTriggerAttempt, migrateLegacyWorkflows, packagedCorpusTemplate, parseWorkflowOrg, recordWorkflowSignal, renderWorkflowOrg, saveWorkflow, updateWorkflow, workflowFromRun, workflowPath, workflowTriggerEligibility } from "../dist/agentWorkflow.js";
import { artifactRebuildPlan, buildArtifactGraph, MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW } from "../dist/artifactPipeline.js";
import { discoverMcpClient, saveMcpClients, serveMcp, writeMcpSnapshot } from "../dist/mcpRuntime.js";
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

  const guardedRun = createAgentRun({ id: "guarded-write", goal: "Preserve concurrent source changes" });
  const guardedFile = saveAgentRun(root, guardedRun, { expectedRevision: null });
  assert.throws(
    () => saveAgentRun(root, guardedRun, { expectedRevision: null }),
    /expected to be absent/,
  );
  const guardedSnapshot = loadAgentRunSnapshot(root, guardedRun.id);
  assert.match(guardedSnapshot.revision, /^sha256:[a-f0-9]{64}$/);
  const guardedUpdated = addAgentRunComment(guardedSnapshot.run, "test", "First guarded update");
  saveAgentRun(root, guardedUpdated, {
    expectedRevision: guardedSnapshot.revision,
    rejectSourceDrift: true,
  });
  assert.throws(
    () => saveAgentRun(root, addAgentRunComment(guardedSnapshot.run, "test", "Stale update"), {
      expectedRevision: guardedSnapshot.revision,
      rejectSourceDrift: true,
    }),
    /changed after it was read/,
  );
  const afterGuardedUpdate = loadAgentRunSnapshot(root, guardedRun.id);
  assert.equal(afterGuardedUpdate.run.comments.length, 1);

  const wrongRevision = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "run", "comment", guardedRun.id,
    "--author", "test", "--body", "Must not overwrite", "--if-revision", "sha256:stale", "--dir", root,
  ], { encoding: "utf8" });
  assert.notEqual(wrongRevision.status, 0);
  assert.match(wrongRevision.stderr, /run revision changed/);
  assert.equal(loadAgentRun(root, guardedRun.id).comments.length, 1);

  fs.writeFileSync(
    guardedFile,
    afterGuardedUpdate.raw.replace(":RUN_STATUS: queued", ":RUN_STATUS: running"),
    "utf8",
  );
  const driftedSnapshot = loadAgentRunSnapshot(root, guardedRun.id);
  assert.deepEqual(driftedSnapshot.sourceIssues.map((issue) => issue.field), ["status"]);
  const driftedMutation = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "run", "comment", guardedRun.id,
    "--author", "test", "--body", "Must respect direct edit", "--dir", root,
  ], { encoding: "utf8" });
  assert.notEqual(driftedMutation.status, 0);
  assert.match(driftedMutation.stderr, /out-of-band readable-state changes/);
  fs.writeFileSync(guardedFile, afterGuardedUpdate.raw, "utf8");

  const lockedSnapshot = loadAgentRunSnapshot(root, guardedRun.id);
  fs.writeFileSync(`${guardedFile}.lock`, "{}\n", "utf8");
  assert.throws(
    () => saveAgentRun(root, addAgentRunComment(lockedSnapshot.run, "test", "Locked update"), {
      expectedRevision: lockedSnapshot.revision,
      rejectSourceDrift: true,
    }),
    /already being updated/,
  );
  fs.unlinkSync(`${guardedFile}.lock`);

  const showRevision = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "run", "show", guardedRun.id,
    "--with-revision", "--json", "--dir", root,
  ], { encoding: "utf8" });
  assert.equal(showRevision.status, 0, showRevision.stderr || showRevision.stdout);
  const shownSnapshot = JSON.parse(showRevision.stdout);
  assert.equal(shownSnapshot.schema, "org2:run-snapshot:v1");
  assert.equal(shownSnapshot.revision, lockedSnapshot.revision);
  fs.unlinkSync(guardedFile);

  assert.throws(() => createAgentRun({ goal: "Reject an invalid plan", plan: [{ title: "Broken", kind: "unknown" }] }), /invalid run step kind/);
  assert.throws(() => updateAgentRunStep(run, "draft", "unknown"), /invalid run step status/);
  assert.throws(() => addAgentRunArtifact(run, { path: "views/broken.org2", role: "unknown" }), /invalid artifact role/);
  assert.throws(() => addAgentRunArtifact(run, { path: "views/broken.org2", role: "draft", reviewStatus: "unknown" }), /invalid artifact review status/);
  assert.throws(() => addAgentRunValidation(run, { name: "broken", status: "unknown" }), /invalid validation status/);
  assert.throws(() => requestAgentRunApproval(run, { title: "Broken", action: "broken", riskClass: "unknown" }), /invalid approval risk class/);
  const pendingApproval = requestAgentRunApproval(run, { id: "test", title: "Test", action: "test", riskClass: "local-draft" });
  assert.match(renderAgentRunOrg(pendingApproval), /\*\* Approvals \[1\/1 pending\]/);
  assert.match(renderAgentRunOrg(pendingApproval), /PENDING Test — test \(local-draft\) =test=/);
  assert.match(pendingApproval.approvals[0].fingerprint, /^sha256:[a-f0-9]{64}$/);
  assert.throws(
    () => decideAgentRunApproval(pendingApproval, "test", "approved", { actor: "Avi", fingerprint: "sha256:wrong" }),
    /fingerprint does not match/,
  );
  assert.throws(() => transitionAgentRun(pendingApproval, "completed", { summary: "Should remain open." }), /pending approvals/);
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
  let completedElsewhere = transitionAgentRun(
    createAgentRun({
      id: "completed-elsewhere",
      goal: "Publish a release note",
      plan: [{ id: "publish", title: "Publish the release note", kind: "agent" }],
    }),
    "blocked",
    { reason: "The release process is unavailable." }
  );
  completedElsewhere = addAgentRunArtifact(completedElsewhere, {
    id: "unused-draft",
    path: "views/release-note.org2",
    role: "draft",
    reviewStatus: "review-required",
  });
  completedElsewhere = requestAgentRunApproval(completedElsewhere, {
    id: "unused-approval",
    title: "Publish release note",
    action: "publish",
    riskClass: "external-action",
  });
  completedElsewhere = transitionAgentRun(completedElsewhere, "blocked", {
    reason: "The release was handled in the external release process."
  });
  completedElsewhere = completeAgentRunExternally(completedElsewhere, {
    summary: "Published through the external release process.",
    actor: "Avi",
    now: "2026-07-14T12:00:00Z",
  });
  assert.equal(completedElsewhere.status, "completed");
  assert.equal(completedElsewhere.outcome.summary, "Published through the external release process.");
  assert.equal(completedElsewhere.approvals[0].status, "pending");
  assert.equal(completedElsewhere.artifacts[0].reviewStatus, "review-required");
  assert.equal(completedElsewhere.plan[0].status, "skipped");
  assert.match(completedElsewhere.plan[0].detail, /completed outside this workflow/);
  assert.equal(completedElsewhere.events.at(-1).type, "completed-externally");
  for (const [status, prepare] of [
    ["queued", (candidate) => candidate],
    ["running", (candidate) => transitionAgentRun(candidate, "running")],
    ["waiting-approval", (candidate) => transitionAgentRun(transitionAgentRun(candidate, "running"), "waiting-approval")],
    ["blocked", (candidate) => transitionAgentRun(candidate, "blocked", { reason: "Waiting for external work." })],
    ["failed", (candidate) => transitionAgentRun(transitionAgentRun(candidate, "running"), "failed", { reason: "Provider failed." })],
    ["canceled", (candidate) => transitionAgentRun(candidate, "canceled")],
  ]) {
    const candidate = prepare(createAgentRun({
      id: `external-${status}`,
      goal: `Record external completion from ${status}`,
      plan: [{ id: "remaining", title: "Remaining workflow step", kind: "agent" }],
    }));
    const externallyCompleted = completeAgentRunExternally(candidate, {
      summary: `Completed elsewhere from ${status}.`,
      actor: "Avi",
      now: "2026-07-14T12:05:00Z",
    });
    assert.equal(externallyCompleted.status, "completed");
    assert.equal(externallyCompleted.plan[0].status, "skipped");
    assert.equal(externallyCompleted.events.at(-1).type, "completed-externally");
  }
  assert.throws(
    () => completeAgentRunExternally(
      completedElsewhere,
      { summary: "Done again.", actor: "Avi" }
    ),
    /completed run cannot/
  );
  saveAgentRun(root, transitionAgentRun(
    createAgentRun({ id: "external-cli", goal: "Record an externally completed outcome" }),
    "blocked",
    { reason: "Waiting for work in another system." }
  ));
  const externalCompletion = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "run", "complete-external", "external-cli",
    "--summary", "Completed in the external system.", "--actor", "Avi", "--dir", root, "--json",
  ], { encoding: "utf8" });
  assert.equal(externalCompletion.status, 0, externalCompletion.stderr || externalCompletion.stdout);
  assert.equal(loadAgentRun(root, "external-cli").events.at(-1).type, "completed-externally");
  fs.unlinkSync(path.join(root, ".org2", "runs", "external-cli.org2"));
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
  assert.throws(
    () => transitionAgentRun(run, "completed", { summary: "Review is still pending." }),
    /review-required artifacts/
  );
  run = addAgentRunValidation(run, { id: "citations", name: "citations", status: "passed" });
  run = addAgentRunComment(run, "Avi", "Tighten the recommendation section.");
  run = updateAgentRunAssignment(run, { assignee: "writing-agent", actor: "Avi" });
  run = updateAgentRunRuntime(run, { provider: "openai", model: "gpt-5", tokensUsed: 1234, elapsedSeconds: 42, actor: "org2-lifecycle" });
  assert.equal(run.provider, "openai");
  assert.equal(run.model, "gpt-5");
  assert.equal(run.budget.tokensUsed, 1234);
  assert.equal(run.budget.elapsedSeconds, 42);
  run = requestAgentRunApproval(run, { id: "release", title: "Release briefing", action: "publish PDF", riskClass: "external-action", requestedRole: "owner" });
  assert.equal(run.status, "waiting-approval");
  const releaseFingerprint = run.approvals.find((approval) => approval.id === "release").fingerprint;
  assert.throws(
    () => decideAgentRunApproval(run, "release", "revised", { actor: "Avi", actorRole: "owner", fingerprint: releaseFingerprint }),
    /revision decision requires a note/,
  );
  run = decideAgentRunApproval(run, "release", "approved", { actor: "Avi", actorRole: "owner", fingerprint: releaseFingerprint, note: "Reviewed exact PDF", receipt: "approval:local:1" });
  assert.equal(run.status, "running");
  assert.equal(run.approvals.find((approval) => approval.id === "release").decisionNote, "Reviewed exact PDF");
  assert.equal(run.approvals.find((approval) => approval.id === "release").fingerprint, releaseFingerprint);
  run = updateAgentRunArtifactReview(run, "brief", "reviewed", { actor: "Avi" });
  assert.equal(run.artifacts.find((artifact) => artifact.id === "brief").reviewStatus, "reviewed");
  assert.equal(run.events.at(-1).type, "artifact-review-changed");
  run = addAgentRunArtifact(run, { id: "pdf", path: "compiled/board.pdf", role: "export", reviewStatus: "reviewed", mediaType: "application/pdf" });
  run = transitionAgentRun(run, "completed", {
    summary: "Prepared and reviewed the cited board briefing and its PDF export.",
    highlights: ["The briefing and PDF are ready for use."],
    nextActions: [],
  });
  assert.equal(run.outcome.summary, "Prepared and reviewed the cited board briefing and its PDF export.");
  saveAgentRun(root, run);
  assert.equal(listAgentRuns(root).length, 1);
  assert.equal(loadAgentRun(root, run.id).budget.tokensUsed, 1234);
  assert.equal(forkAgentRun(run, { id: "board-brief-revision" }).parentRunId, run.id);

  fs.mkdirSync(path.join(root, "views", "review-sync"), { recursive: true });
  fs.writeFileSync(
    path.join(root, "views", "review-sync", "direction.org2"),
    "#+TITLE: Direction\n#+ORG2_REVIEW_STATUS: review-required\n\n* Decision\nProceed.\n",
    "utf8",
  );
  let reviewSync = transitionAgentRun(createAgentRun({ id: "review-sync", goal: "Review a direction" }), "running");
  reviewSync = addAgentRunArtifact(reviewSync, {
    id: "direction",
    path: "views/review-sync/direction.org2",
    role: "report",
    reviewStatus: "review-required",
  });
  saveAgentRun(root, reviewSync);
  const reviewDecision = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "run", "artifact-review", reviewSync.id, "direction",
    "--status", "reviewed", "--actor", "Avi", "--dir", root, "--json",
  ], { encoding: "utf8" });
  assert.equal(reviewDecision.status, 0, reviewDecision.stderr || reviewDecision.stdout);
  assert.equal(loadAgentRun(root, reviewSync.id).artifacts[0].reviewStatus, "reviewed");
  assert.match(
    fs.readFileSync(path.join(root, "views", "review-sync", "direction.org2"), "utf8"),
    /^#\+ORG2_REVIEW_STATUS: reviewed$/m,
  );

  let gated = createAgentRun({ id: "multi-approval", goal: "Exercise a multi-approval boundary" });
  gated = requestAgentRunApproval(gated, { id: "legal", title: "Legal review", action: "release", riskClass: "external-action", requestedRole: "legal" });
  gated = requestAgentRunApproval(gated, { id: "owner", title: "Owner review", action: "release", riskClass: "external-action", requestedRole: "owner" });
  assert.throws(() => decideAgentRunApproval(gated, "legal", "approved", { actor: "Avi", actorRole: "owner" }), /requires role legal/);
  gated = decideAgentRunApproval(gated, "legal", "revised", {
    actor: "Counsel",
    actorRole: "legal",
    note: "Address the legal review before requesting approval again.",
  });
  gated = decideAgentRunApproval(gated, "owner", "approved", { actor: "Avi", actorRole: "owner" });
  assert.equal(gated.status, "blocked");

  gated = requestAgentRunApproval(gated, {
    id: "replacement",
    title: "Approve revised release",
    action: "release revised copy",
    riskClass: "external-action",
    requestedRole: "owner",
  });
  assert.equal(gated.status, "waiting-approval");
  gated = decideAgentRunApproval(gated, "replacement", "approved", { actor: "Avi", actorRole: "owner" });
  assert.equal(gated.status, "running");
  assert.equal(gated.approvals.find((approval) => approval.id === "legal").status, "revised");
  assert.equal(gated.approvals.find((approval) => approval.id === "replacement").status, "approved");

  let rejected = transitionAgentRun(
    createAgentRun({ id: "rejected-approval", goal: "Cancel after a rejected approval" }),
    "running",
  );
  rejected = requestAgentRunApproval(rejected, {
    id: "reject-action",
    title: "Approve protected action",
    action: "perform protected action",
    riskClass: "external-action",
  });
  rejected = requestAgentRunApproval(rejected, {
    id: "second-review",
    title: "Second review",
    action: "perform protected action",
    riskClass: "external-action",
  });
  rejected = decideAgentRunApproval(rejected, "reject-action", "rejected", { actor: "Avi" });
  assert.equal(rejected.status, "canceled");
  assert.equal(rejected.approvals.find((approval) => approval.id === "second-review").status, "pending");
  assert.match(rejected.events.at(-1).detail, /waiting-approval -> canceled/);

  let canceledApproval = transitionAgentRun(
    createAgentRun({ id: "canceled-approval", goal: "Cancel after a canceled approval" }),
    "running",
  );
  canceledApproval = requestAgentRunApproval(canceledApproval, {
    id: "cancel-action",
    title: "Approve optional action",
    action: "perform optional action",
    riskClass: "external-action",
  });
  canceledApproval = decideAgentRunApproval(canceledApproval, "cancel-action", "canceled", { actor: "Avi" });
  assert.equal(canceledApproval.status, "canceled");

  let blockedPendingApproval = transitionAgentRun(
    createAgentRun({ id: "blocked-pending-approval", goal: "Resolve an approval-blocked run" }),
    "running",
  );
  blockedPendingApproval = requestAgentRunApproval(blockedPendingApproval, {
    id: "blocked-action",
    title: "Approve blocked action",
    action: "perform blocked action",
    riskClass: "external-action",
  });
  blockedPendingApproval = transitionAgentRun(blockedPendingApproval, "blocked", {
    reason: "Waiting for the protected action decision.",
  });
  blockedPendingApproval = decideAgentRunApproval(
    blockedPendingApproval,
    "blocked-action",
    "rejected",
    { actor: "Avi" },
  );
  assert.equal(blockedPendingApproval.status, "canceled");

  let separatelyBlocked = transitionAgentRun(
    createAgentRun({ id: "separately-blocked", goal: "Keep separate blockers intact" }),
    "blocked",
    { reason: "The external service is unavailable." },
  );
  separatelyBlocked = requestAgentRunApproval(separatelyBlocked, {
    id: "separate-approval",
    title: "Approve retry",
    action: "retry after recovery",
    riskClass: "external-action",
  });
  assert.equal(separatelyBlocked.status, "blocked");
  separatelyBlocked = decideAgentRunApproval(separatelyBlocked, "separate-approval", "approved", { actor: "Avi" });
  assert.equal(separatelyBlocked.status, "blocked");
  assert.equal(separatelyBlocked.blockedReason, "The external service is unavailable.");

  let workflow = workflowFromRun(run, { id: "board-briefing", now: "2026-07-14T11:00:00Z" });
  workflow.inputs.push({ id: "quarter", description: "Reporting quarter", required: true });
  workflow.instructions = "Prepare the {{quarter}} board briefing";
  workflow.triggers.push({ id: "daily", type: "schedule", enabled: true, schedule: "every 1d", lastRunAt: "2026-07-12T00:00:00Z" });
  workflow.triggers.push({ id: "after-capture", type: "capture", enabled: true });
  saveWorkflow(root, workflow);
  assert.equal(workflowPath(root, workflow.id), path.join(root, "workflows", "board-briefing.org2"));
  assert.equal(fs.existsSync(workflowPath(root, workflow.id)), true);
  assert.equal(loadWorkflow(root, workflow.id).version, "1.0.0");
  const guardedWorkflow = workflowFromRun(run, { id: "guarded-workflow", now: "2026-07-14T11:00:00Z" });
  saveWorkflow(root, guardedWorkflow, { expectedRevision: null });
  assert.throws(
    () => saveWorkflow(root, guardedWorkflow, { expectedRevision: null }),
    /expected to be absent/,
  );
  const guardedWorkflowSnapshot = loadWorkflowSnapshot(root, guardedWorkflow.id);
  updateWorkflow(root, guardedWorkflow.id, (item) => ({ ...item, state: "active" }), "2026-07-14T11:01:00Z");
  assert.equal(loadWorkflow(root, guardedWorkflow.id).state, "active");
  assert.throws(
    () => saveWorkflow(root, { ...guardedWorkflowSnapshot.workflow, state: "paused" }, {
      expectedRevision: guardedWorkflowSnapshot.revision,
    }),
    /changed after it was read/,
  );
  const editedWorkflowSource = renderWorkflowOrg(workflow)
    .replace("* Prepare a cited board briefing", "* Maintained board workflow")
    .replace("Prepare the {{quarter}} board briefing\n\n** Machine state", "Prepare a carefully cited {{quarter}} board briefing\n\n** Machine state")
    .replace(":WORKFLOW_STATE: draft", ":WORKFLOW_STATE: active");
  const editedWorkflow = parseWorkflowOrg(editedWorkflowSource);
  assert.equal(editedWorkflow.title, "Maintained board workflow");
  assert.equal(editedWorkflow.instructions, "Prepare a carefully cited {{quarter}} board briefing");
  assert.equal(editedWorkflow.state, "active");
  assert.equal(dueWorkflowTriggers(workflow, { now: "2026-07-14T00:00:00Z" }).some((item) => item.id === "daily"), true);
  workflow.triggers = workflow.triggers.map((trigger) => trigger.id === "daily"
    ? { ...trigger, gate: { events: ["capture"], paths: ["notes"] }, lastAttemptAt: "2026-07-13T00:00:00Z" }
    : trigger);
  assert.equal(workflowTriggerEligibility(workflow, "daily").eligible, false);
  workflow = recordWorkflowSignal(workflow, { id: "capture-1", type: "capture", at: "2026-07-14T00:00:00Z", paths: ["notes/inbox.org2"] });
  assert.deepEqual(workflowTriggerEligibility(workflow, "daily").signalIds, ["capture-1"]);
  workflow = markWorkflowTriggerAttempt(workflow, "daily", "2026-07-14T01:00:00Z");
  assert.equal(workflowTriggerEligibility(workflow, "daily").eligible, false);
  saveWorkflow(root, workflow);
  const skippedGate = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "workflow", "run", workflow.id,
    "--trigger", "daily", "--input", "quarter=Q3", "--dir", root, "--json",
  ], { encoding: "utf8" });
  assert.equal(skippedGate.status, 0, skippedGate.stderr || skippedGate.stdout);
  assert.equal(JSON.parse(skippedGate.stdout).schema, "org2:workflow-run-skipped:v1");
  const recordedSignal = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "workflow", "signal", workflow.id,
    "--event", "capture", "--signal-id", "capture-cli", "--at", "2026-07-14T02:00:00Z",
    "--changed", "notes/inbox.org2", "--dir", root, "--json",
  ], { encoding: "utf8" });
  assert.equal(recordedSignal.status, 0, recordedSignal.stderr || recordedSignal.stdout);
  const eligibleGate = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "workflow", "gate", workflow.id,
    "--trigger", "daily", "--dir", root, "--json",
  ], { encoding: "utf8" });
  assert.equal(eligibleGate.status, 0, eligibleGate.stderr || eligibleGate.stdout);
  assert.deepEqual(JSON.parse(eligibleGate.stdout).signalIds, ["capture-cli"]);
  const attemptedWorkflow = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "workflow", "run", workflow.id,
    "--trigger", "daily", "--attempt-id", "daily-cli-1",
    "--scheduled-for", "2026-07-14T03:00:00Z", "--input", "quarter=Q3",
    "--dir", root, "--json",
  ], { encoding: "utf8" });
  assert.equal(attemptedWorkflow.status, 0, attemptedWorkflow.stderr || attemptedWorkflow.stdout);
  const attemptedWorkflowResult = JSON.parse(attemptedWorkflow.stdout);
  assert.equal(attemptedWorkflowResult.run.logicalWorkId, "workflow:board-briefing");
  assert.equal(attemptedWorkflowResult.run.attempt.id, "daily-cli-1");
  assert.equal(attemptedWorkflowResult.run.attempt.number, 1);
  assert.deepEqual(attemptedWorkflowResult.run.attempt.signalIds, ["capture-cli"]);
  const consumedSignal = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "workflow", "gate", workflow.id,
    "--trigger", "daily", "--dir", root, "--json",
  ], { encoding: "utf8" });
  assert.equal(consumedSignal.status, 0, consumedSignal.stderr || consumedSignal.stdout);
  assert.equal(JSON.parse(consumedSignal.stdout).eligible, false);
  const captureTriggers = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "workflow", "triggers", workflow.id,
    "--event", "capture", "--dir", root, "--json",
  ], { encoding: "utf8" });
  assert.equal(captureTriggers.status, 0, captureTriggers.stderr || captureTriggers.stdout);
  assert.equal(JSON.parse(captureTriggers.stdout).due.some((item) => item.id === "after-capture"), true);
  const invalidEvent = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "workflow", "triggers", workflow.id,
    "--event", "captured", "--dir", root,
  ], { encoding: "utf8" });
  assert.notEqual(invalidEvent.status, 0);
  assert.match(invalidEvent.stderr, /invalid workflow event: captured; expected one of: capture, meeting-import/);
  const instantiated = instantiateWorkflow(workflow, { quarter: "Q3" });
  assert.equal(instantiated.goal, "Prepare the Q3 board briefing");
  assert.equal(instantiated.workflowId, "board-briefing");
  const attemptOne = instantiateWorkflow(workflow, { quarter: "Q3" }, {
    logicalWorkId: "workflow:board-briefing",
    attempt: { id: "daily-1", number: 1, triggerId: "daily", triggerType: "schedule", scheduledFor: "2026-07-14T01:00:00Z" },
  });
  const attemptTwo = instantiateWorkflow(workflow, { quarter: "Q3" }, {
    logicalWorkId: "workflow:board-briefing",
    attempt: { id: "daily-2", number: 2, triggerId: "daily", triggerType: "schedule", scheduledFor: "2026-07-15T01:00:00Z" },
  });
  assert.equal(summarizeAgentRunAttempts([attemptOne, attemptTwo])[0].attempts, 2);
  assert.equal(summarizeAgentRunAttempts([attemptOne, attemptTwo])[0].latestAttemptNumber, 2);
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
  const linkedResource = path.join(root, "notes", "outside-corpus.org2");
  fs.symlinkSync(path.resolve("package.json"), linkedResource);
  const input = new PassThrough(); const output = new PassThrough(); let response = "";
  output.setEncoding("utf8"); output.on("data", (chunk) => response += chunk);
  const serving = serveMcp(root, input, output);
  input.end(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })}\n${JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} })}\n${JSON.stringify({ jsonrpc: "2.0", id: 3, method: "resources/list", params: {} })}\n${JSON.stringify({ jsonrpc: "2.0", id: 4, method: "resources/read", params: { uri: "org2://corpus/notes/outside-corpus.org2" } })}\n${JSON.stringify({ jsonrpc: "2.0", id: 5, method: "resources/read", params: { uri: "org2://corpus/notes/source.org2" } })}\n${JSON.stringify({ jsonrpc: "2.0", id: 6, method: "resources/read", params: { uri: "org2://corpus/package.json" } })}\n`);
  await serving;
  const messages = response.trim().split("\n").map((line) => JSON.parse(line));
  assert.equal(messages[0].result.serverInfo.name, "org2");
  assert.equal(messages[1].result.tools.some((tool) => tool.name === "org2_run_create"), true);
  assert.equal(messages[2].result.resources.some((resource) => resource.name === "notes/outside-corpus.org2"), false);
  assert.equal(messages[3].error.code, -32603);
  assert.match(messages[3].error.message, /resource is a symbolic link/);
  assert.equal(messages[4].result.contents[0].text, "changed\n");
  assert.equal(messages[5].error.code, -32603);
  assert.match(messages[5].error.message, /resource is not an Org2 source file/);
  fs.unlinkSync(linkedResource);

  const invalidInput = new PassThrough(); const invalidOutput = new PassThrough(); let invalidResponse = "";
  invalidOutput.setEncoding("utf8"); invalidOutput.on("data", (chunk) => invalidResponse += chunk);
  const invalidServing = serveMcp(root, invalidInput, invalidOutput);
  invalidInput.end(`${JSON.stringify({ jsonrpc: "2.0", id: 3, method: 42, params: {} })}\n`);
  await invalidServing;
  assert.equal(JSON.parse(invalidResponse.trim()).error.code, -32600);

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
