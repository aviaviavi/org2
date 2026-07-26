import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { PassThrough } from "node:stream";
import {
  addAgentRunArtifact, addAgentRunComment, addAgentRunValidation, completeAgentRunExternally, createAgentRun,
  agentRunApprovalRequirementState, decideAgentRunApproval, forkAgentRun, listAgentRuns, loadAgentRun, normalizeLegacyAgentRuns,
  mutateAgentRun, parseAgentRunOrg, recordAgentRunApprovalEffect, releaseAgentRunApprovalEffectReservation,
  renderAgentRunOrg, requestAgentRunApproval, reserveAgentRunApprovalEffect, saveAgentRun,
  transitionAgentRun, updateAgentRunAssignment, updateAgentRunRuntime, updateAgentRunStep, validateAgentRun,
  updateAgentRunArtifactReview,
} from "../dist/agentRun.js";
import {
  assertPendingApprovalShortcutAllowed,
  computeApprovalFingerprint,
  computeApprovalMaterialDigest,
  computeLegacyHeadlineApprovalFingerprint,
} from "../dist/approval.js";
import { withFileMutationLock } from "../dist/atomicFileMutation.js";
import { dueWorkflowTriggers, installBuiltinWorkflow, instantiateWorkflow, legacyWorkflowDirectory, loadWorkflow, migrateLegacyWorkflows, packagedCorpusTemplate, parseWorkflowOrg, renderWorkflowOrg, saveWorkflow, workflowFromRun, workflowPath } from "../dist/agentWorkflow.js";
import { artifactRebuildPlan, buildArtifactGraph, MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW } from "../dist/artifactPipeline.js";
import { discoverMcpClient, saveMcpClients, serveMcp, writeMcpSnapshot } from "../dist/mcpRuntime.js";
import { defaultRuntimePolicy, selectRuntime, validateRuntimePaths } from "../dist/runtimePolicy.js";
import { evaluateRun, replayWorkflowFixture, sanitizeRunFixture } from "../dist/workflowEval.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agentic-"));
try {
  const exactMessage = (target, content) => ({ kind: "message", target, content });
  const pendingShortcutApproval = {
    queueId: "headline:dGVzdA:dGVzdA",
    fingerprint: `sha256:${"a".repeat(64)}`,
  };
  assert.doesNotThrow(() => assertPendingApprovalShortcutAllowed(undefined, "close"));
  assert.throws(
    () => assertPendingApprovalShortcutAllowed(pendingShortcutApproval, "close"),
    /cannot be closed from the agenda TUI/,
  );
  assert.throws(
    () => assertPendingApprovalShortcutAllowed(pendingShortcutApproval, "handoff"),
    /canonical decision path/,
  );
  assert.throws(
    () => assertPendingApprovalShortcutAllowed(pendingShortcutApproval, "property"),
    /properties cannot be changed from the agenda TUI/,
  );
  const runCli = (args) => new Promise((resolve) => {
    const child = spawn(process.execPath, [path.resolve("dist/cli.js"), ...args], {
      cwd: process.cwd(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
  const decide = (candidate, approvalId, decision, input) => decideAgentRunApproval(
    candidate,
    approvalId,
    decision,
    {
      ...input,
      expectedFingerprint: candidate.approvals.find((approval) => approval.id === approvalId)?.fingerprint,
    },
  );
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
  const originalRunSource = fs.readFileSync(path.join(root, ".org2", "runs", `${run.id}.org2`), "utf8");
  assert.throws(
    () => saveAgentRun(root, createAgentRun({ id: run.id, goal: "Attempt to overwrite the existing run" })),
    /run already exists/,
  );
  assert.equal(
    fs.readFileSync(path.join(root, ".org2", "runs", `${run.id}.org2`), "utf8"),
    originalRunSource,
  );

  assert.throws(() => createAgentRun({ goal: "Reject an invalid plan", plan: [{ title: "Broken", kind: "unknown" }] }), /invalid run step kind/);
  assert.throws(() => updateAgentRunStep(run, "draft", "unknown"), /invalid run step status/);
  assert.throws(() => addAgentRunArtifact(run, { path: "views/broken.org2", role: "unknown" }), /invalid artifact role/);
  assert.throws(() => addAgentRunArtifact(run, { path: "views/broken.org2", role: "draft", reviewStatus: "unknown" }), /invalid artifact review status/);
  assert.throws(() => addAgentRunValidation(run, { name: "broken", status: "unknown" }), /invalid validation status/);
  assert.throws(() => requestAgentRunApproval(run, { title: "Broken", action: "broken", riskClass: "unknown" }), /invalid approval risk class/);
  const pendingApproval = requestAgentRunApproval(run, { id: "test", title: "Test", action: "test", riskClass: "local-draft" });
  assert.throws(
    () => decideAgentRunApproval(pendingApproval, "test", "approved", {
      actor: "   ",
      expectedFingerprint: pendingApproval.approvals[0].fingerprint,
    }),
    /approval decision actor is required/,
  );
  assert.match(pendingApproval.approvals[0].fingerprint, /^sha256:[a-f0-9]{64}$/);
  assert.equal(
    pendingApproval.approvals[0].fingerprint,
    "sha256:fdcde8a9b2b6b663c82874c00c1694b64ae4511fbcf3f3199d46db1446cd53cd",
  );
  assert.equal(
    computeApprovalFingerprint({
      title: "Test",
      action: "test",
      riskClass: "local-draft",
      requirementId: "req-test",
    }),
    "sha256:0d7141c8ac5c950a25bb7e6dd898b80614229f921c87a20a4133553c9643214a",
  );
  assert.equal(
    computeApprovalFingerprint({
      riskClass: "local-draft",
      action: "test",
      title: "Test",
      requestedFrom: undefined,
      requestedRole: undefined,
      note: undefined,
      material: undefined,
    }),
    pendingApproval.approvals[0].fingerprint,
  );
  assert.equal(
    computeApprovalFingerprint({
      title: "Release ä/z",
      action: "publish",
      riskClass: "external-action",
      material: {
        kind: "artifact-release",
        attachments: [
          { name: "z", sha256: "2".repeat(64) },
          { name: "ä", sha256: "1".repeat(64) },
        ],
      },
    }),
    "sha256:3d4207c28982f94ef011dde7d4d267463de4bf750560dd30c639ff8f85057efa",
  );
  assert.equal(
    computeLegacyHeadlineApprovalFingerprint({
      title: "Review outreach copy",
      body: "Send this once approved.",
      properties: { STATUS: "draft-needs-review", ID: "approval-1" },
      status: "draft-needs-review",
      todo: "TODO",
      pairedAction: null,
    }),
    "sha256:fffe8c41264f251fcb42bf29a213be53ff0c3012267f8ca6868c948af2dc94a2",
  );
  assert.throws(
    () => requestAgentRunApproval(pendingApproval, { id: "test", title: "Duplicate", action: "test", riskClass: "local-draft" }),
    /already exists/,
  );
  assert.throws(
    () => requestAgentRunApproval(run, {
      id: "unknown-material",
      title: "Reject unknown material",
      action: "send",
      riskClass: "external-action",
      material: { kind: "external-action", target: "person@example.com", opaque: "hidden" },
    }),
    /opaque is not supported/,
  );
  assert.equal(
    computeApprovalFingerprint({
      title: "Release",
      action: "publish",
      riskClass: "external-action",
      material: {
        kind: "artifact-release",
        attachments: [
          { name: "b", sha256: "2".repeat(64) },
          { name: "a", sha256: "1".repeat(64) },
        ],
      },
    }),
    computeApprovalFingerprint({
      action: "publish",
      riskClass: "external-action",
      title: "Release",
      material: {
        attachments: [
          { sha256: `sha256:${"1".repeat(64)}`, name: "a" },
          { sha256: `sha256:${"2".repeat(64)}`, name: "b" },
        ],
        kind: "artifact-release",
      },
    }),
  );
  assert.throws(
    () => requestAgentRunApproval(run, {
      id: "unsafe",
      title: "Send opaque payload",
      action: "send",
      riskClass: "external-action",
      note: "Looks fine.",
    }),
    /Bound typed review material is required/,
  );
  assert.throws(
    () => requestAgentRunApproval(run, {
      id: "unsafe-high-impact",
      title: "Delete production data",
      action: "delete",
      riskClass: "high-impact",
      note: "Approved in principle.",
    }),
    /Bound typed review material is required/,
  );
  assert.throws(
    () => requestAgentRunApproval(run, {
      id: "opaque-target",
      title: "Send opaque target",
      action: "send",
      riskClass: "external-action",
      material: {
        kind: "external-action",
        target: "person@example.com",
        runtimeTarget: { system: "mail", kind: "draft", id: "draft-1" },
      },
    }),
    /Bound typed review material is required/,
  );
  for (const [index, content] of ["", "   \n\t"].entries()) {
    assert.throws(
      () => requestAgentRunApproval(run, {
        id: `empty-external-${index}`,
        title: "Reject empty generic external material",
        action: "perform",
        riskClass: "external-action",
        material: {
          kind: "external-action",
          content,
        },
      }),
      /Bound typed review material is required/,
    );
  }
  assert.throws(
    () => requestAgentRunApproval(run, {
      id: "object-content",
      title: "Reject malformed content",
      action: "send",
      riskClass: "external-action",
      material: {
        kind: "message",
        target: "person@example.com",
        content: { hidden: "payload" },
      },
    }),
    /content must be a string/,
  );
  const emptyContentApproval = requestAgentRunApproval(run, {
    id: "empty-content",
    title: "Send an intentionally empty message",
    action: "send",
    riskClass: "external-action",
    material: exactMessage("person@example.com", ""),
  });
  assert.equal(emptyContentApproval.approvals.at(-1).material.content, "");
  assert.equal(validateAgentRun(emptyContentApproval).valid, true);
  const legacyFingerprintRun = requestAgentRunApproval(run, {
    id: "legacy-fingerprint",
    title: "Legacy approval",
    action: "release",
    riskClass: "local-draft",
  });
  delete legacyFingerprintRun.approvals.at(-1).fingerprint;
  const derivedLegacyFingerprint = computeApprovalFingerprint(legacyFingerprintRun.approvals.at(-1));
  assert.throws(
    () => decideAgentRunApproval(legacyFingerprintRun, "legacy-fingerprint", "approved", {
      actor: "Avi",
      expectedFingerprint: `sha256:${"0".repeat(64)}`,
    }),
    /stale approval review/,
  );
  const decidedLegacyFingerprint = decideAgentRunApproval(
    legacyFingerprintRun,
    "legacy-fingerprint",
    "approved",
    { actor: "Avi", expectedFingerprint: derivedLegacyFingerprint },
  );
  assert.equal(decidedLegacyFingerprint.approvals.at(-1).fingerprint, derivedLegacyFingerprint);
  let superseded = requestAgentRunApproval(run, {
    id: "draft-v1",
    title: "Send draft",
    action: "send v1",
    riskClass: "external-action",
    note: "Version one",
    material: exactMessage("person@example.com", "Version one"),
  });
  superseded = requestAgentRunApproval(superseded, {
    id: "draft-v2",
    title: "Send draft",
    action: "send v2",
    riskClass: "external-action",
    note: "Version two",
    material: exactMessage("person@example.com", "Version two"),
    supersedesId: "draft-v1",
  });
  assert.deepEqual(superseded.approvals.map((approval) => approval.status), ["revised", "pending"]);
  superseded = decide(superseded, "draft-v2", "approved", { actor: "Avi" });
  assert.equal(superseded.status, "running");
  assert.match(renderAgentRunOrg(pendingApproval), /\*\* Approvals \[1\/1 pending\]/);
  assert.match(renderAgentRunOrg(pendingApproval), /PENDING Test — test \(local-draft\) =test=/);
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
    material: {
      kind: "artifact-release",
      artifacts: [{ id: "unused-draft", sha256: "2".repeat(64) }],
    },
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
  assert.throws(
    () => completeAgentRunExternally(
      createAgentRun({ id: "not-blocked", goal: "Reject invalid external completion" }),
      { summary: "Done.", actor: "Avi" }
    ),
    /only a blocked run/
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
  run = requestAgentRunApproval(run, {
    id: "release",
    title: "Release briefing",
    action: "publish PDF",
    riskClass: "external-action",
    requestedRole: "owner",
    material: {
      kind: "artifact-release",
      artifacts: [{ id: "brief", sha256: "1".repeat(64) }],
      runtimeTarget: { system: "publisher", kind: "release", id: "board-brief" },
    },
  });
  assert.equal(run.status, "waiting-approval");
  assert.throws(
    () => transitionAgentRun(run, "running"),
    /current approval boundary is unresolved/,
  );
  const canceledPendingApproval = transitionAgentRun(run, "canceled");
  assert.throws(
    () => transitionAgentRun(canceledPendingApproval, "queued"),
    /current approval boundary is unresolved/,
  );
  assert.throws(
    () => decideAgentRunApproval(run, "release", "approved", { actor: "Avi", actorRole: "owner", expectedFingerprint: `sha256:${"0".repeat(64)}` }),
    /stale approval review/,
  );
  run = decide(run, "release", "approved", { actor: "Avi", actorRole: "owner", note: "Reviewed exact PDF.", receipt: "approval:local:1" });
  assert.equal(run.approvals.find((approval) => approval.id === "release").note, undefined);
  assert.equal(run.approvals.find((approval) => approval.id === "release").decisionNote, "Reviewed exact PDF.");
  const releaseFingerprint = run.approvals.find((approval) => approval.id === "release").fingerprint;
  const releaseMaterialDigest = computeApprovalMaterialDigest(
    run.approvals.find((approval) => approval.id === "release").material,
  );
  assert.throws(
    () => reserveAgentRunApprovalEffect(run, "release", {
      fingerprint: releaseFingerprint,
      materialDigest: `sha256:${"3".repeat(64)}`,
      toolCallId: "tool-wrong-material",
    }),
    /material digest mismatch/,
  );
  run = reserveAgentRunApprovalEffect(run, "release", {
    fingerprint: releaseFingerprint,
    materialDigest: releaseMaterialDigest,
    toolCallId: "tool-release-1",
    reservedAt: "2026-07-14T10:01:30Z",
  });
  assert.throws(
    () => reserveAgentRunApprovalEffect(run, "release", {
      fingerprint: releaseFingerprint,
      materialDigest: releaseMaterialDigest,
      toolCallId: "tool-release-1",
    }),
    /unresolved effect reservation/,
  );
  assert.throws(
    () => transitionAgentRun(run, "completed", { summary: "Done" }),
    /unresolved approval effect reservation/,
  );
  assert.throws(
    () => requestAgentRunApproval(run, {
      id: "release-revision-while-uncertain",
      title: "Release revised briefing",
      action: "publish revised PDF",
      riskClass: "external-action",
      material: {
        kind: "artifact-release",
        artifacts: [{ id: "brief", sha256: "2".repeat(64) }],
        runtimeTarget: { system: "publisher", kind: "release", id: "board-brief" },
      },
    }),
    /unresolved effect reservation/,
  );
  assert.throws(
    () => reserveAgentRunApprovalEffect(run, "release", {
      fingerprint: releaseFingerprint,
      materialDigest: releaseMaterialDigest,
      toolCallId: "tool-release-2",
    }),
    /unresolved effect reservation/,
  );
  assert.throws(
    () => recordAgentRunApprovalEffect(run, "release", {
      fingerprint: releaseFingerprint,
      toolCallId: "tool-release-2",
    }),
    /reserved for a different tool call/,
  );
  assert.throws(
    () => releaseAgentRunApprovalEffectReservation(run, "release", {
      fingerprint: releaseFingerprint,
      toolCallId: "tool-release-2",
      reason: "Provider confirmed no effect.",
      actor: "Avi",
    }),
    /does not match/,
  );
  run = releaseAgentRunApprovalEffectReservation(run, "release", {
    fingerprint: releaseFingerprint,
    toolCallId: "tool-release-1",
    reason: "The provider confirmed that no external effect occurred.",
    actor: "Avi",
    releasedAt: "2026-07-14T10:01:45Z",
  });
  assert.equal(run.approvals.find((approval) => approval.id === "release").effectReservation, undefined);
  run = reserveAgentRunApprovalEffect(run, "release", {
    fingerprint: releaseFingerprint,
    materialDigest: releaseMaterialDigest,
    toolCallId: "tool-release-verified",
    reservedAt: "2026-07-14T10:01:50Z",
  });
  run = recordAgentRunApprovalEffect(run, "release", {
    fingerprint: releaseFingerprint,
    performedAt: "2026-07-14T10:02:00Z",
    system: "test",
    externalId: "effect-1",
    toolCallId: "tool-release-verified",
  });
  assert.equal(run.approvals.find((approval) => approval.id === "release").effectReservation, undefined);
  assert.equal(run.approvals.find((approval) => approval.id === "release").effectReceipt.system, "test");
  assert.throws(
    () => reserveAgentRunApprovalEffect(run, "release", {
      fingerprint: releaseFingerprint,
      materialDigest: releaseMaterialDigest,
      toolCallId: "tool-release-3",
    }),
    /already has an effect receipt/,
  );
  assert.throws(
    () => recordAgentRunApprovalEffect(run, "release", { fingerprint: `sha256:${"0".repeat(64)}` }),
    /fingerprint mismatch/,
  );
  assert.equal(run.status, "running");
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
  mutateAgentRun(root, run.id, () => run);
  const lockPath = path.join(root, ".org2", "runs", `.${run.id}.org2.org2-mutation.lock`);
  const participant = ({ pid, host = os.hostname(), token = globalThis.crypto.randomUUID(), phase = "ticket", ticket = 1 }) => ({
    schema: "org2:mutation-lock-owner:v2",
    host,
    pid,
    token,
    phase,
    ...(phase === "ticket" ? { ticket } : {}),
    createdAt: "2026-07-25T00:00:00.000Z",
  });
  const publishTestParticipant = (owner) => {
    fs.mkdirSync(lockPath, { recursive: true });
    const name = owner.phase === "choosing"
      ? `choosing.${owner.token}.json`
      : `ticket.${String(owner.ticket).padStart(16, "0")}.${owner.token}.json`;
    const file = path.join(lockPath, name);
    fs.writeFileSync(file, `${JSON.stringify(owner)}\n`, "utf8");
    return file;
  };
  const liveParticipant = publishTestParticipant(participant({ pid: process.pid }));
  assert.throws(
    () => mutateAgentRun(root, run.id, (current) => addAgentRunComment(current, "test", "blocked by lock")),
    /already updating/,
  );
  fs.unlinkSync(liveParticipant);
  fs.rmdirSync(lockPath);
  fs.writeFileSync(lockPath, "legacy singleton lock\n", "utf8");
  assert.throws(
    () => mutateAgentRun(root, run.id, (current) => addAgentRunComment(current, "test", "must not replace a legacy lock")),
    /legacy Org2 mutation lock.*not compatible/,
  );
  assert.equal(fs.readFileSync(lockPath, "utf8"), "legacy singleton lock\n");
  fs.unlinkSync(lockPath);
  publishTestParticipant(participant({ pid: 99_999_999 }));
  publishTestParticipant(participant({ pid: 99_999_998, phase: "choosing" }));
  const recoveredFromStaleLock = mutateAgentRun(
    root,
    run.id,
    (current) => addAgentRunComment(current, "test", "recovered from dead choosing and ticket owners"),
  );
  assert.match(recoveredFromStaleLock.comments.at(-1).body, /dead choosing and ticket owners/);
  assert.deepEqual(fs.readdirSync(lockPath), []);
  const foreignParticipant = publishTestParticipant(participant({
    pid: 99_999_999,
    host: "another-host.example",
  }));
  assert.throws(
    () => mutateAgentRun(root, run.id, (current) => addAgentRunComment(current, "test", "must not reclaim a foreign owner")),
    /already updating/,
  );
  assert.equal(fs.existsSync(foreignParticipant), true);
  fs.unlinkSync(foreignParticipant);
  const macToken = "12345678-1234-4abc-8def-1234567890ab";
  const macFilename = path.join(lockPath, `ticket.0000000000000007.${macToken}.json`);
  fs.writeFileSync(macFilename, `${JSON.stringify({
    createdAt: "2026-07-25T00:00:00Z",
    host: os.hostname(),
    phase: "ticket",
    pid: process.pid,
    schema: "org2:mutation-lock-owner:v2",
    ticket: 7,
    token: macToken,
  })}\n`, "utf8");
  assert.throws(
    () => mutateAgentRun(root, run.id, (current) => addAgentRunComment(current, "test", "blocked by Mac owner")),
    /already updating/,
  );
  assert.equal(fs.existsSync(macFilename), true);
  fs.unlinkSync(macFilename);
  let replacementFile;
  withFileMutationLock(path.join(root, ".org2", "runs", `${run.id}.org2`), () => {
    replacementFile = publishTestParticipant(participant({ pid: process.pid, ticket: 999 }));
  });
  assert.equal(fs.existsSync(replacementFile), true);
  fs.unlinkSync(replacementFile);
  const lockTarget = path.join(root, ".org2", "runs", `${run.id}.org2`);
  const crashReady = path.join(root, ".org2", "crash-lock-ready");
  const atomicModule = pathToFileURL(path.resolve("dist/atomicFileMutation.js")).href;
  const lockHolder = spawn(process.execPath, [
    "--input-type=module",
    "--eval",
    `
      import fs from "node:fs";
      import { withFileMutationLock } from ${JSON.stringify(atomicModule)};
      withFileMutationLock(process.argv[1], () => {
        fs.writeFileSync(process.argv[2], "ready\\n", "utf8");
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
      });
    `,
    lockTarget,
    crashReady,
  ], { stdio: "ignore" });
  const waitForCrashHolder = async () => {
    for (let attempt = 0; attempt < 100; attempt += 1) {
      if (fs.existsSync(crashReady)) return;
      if (lockHolder.exitCode !== null) throw new Error(`lock-holder child exited with ${lockHolder.exitCode}`);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error("lock-holder child did not acquire the mutation lock");
  };
  try {
    await waitForCrashHolder();
    const heldTicket = fs.readdirSync(lockPath).find((name) => name.startsWith("ticket."));
    assert.ok(heldTicket);
    assert.throws(
      () => withFileMutationLock(lockTarget, () => {}),
      /already updating/,
    );
    assert.equal(fs.existsSync(path.join(lockPath, heldTicket)), true);
    lockHolder.kill("SIGKILL");
    await new Promise((resolve) => lockHolder.once("close", resolve));
    assert.doesNotThrow(() => withFileMutationLock(lockTarget, () => {}));
    assert.equal(fs.existsSync(path.join(lockPath, heldTicket)), false);
    assert.deepEqual(fs.readdirSync(lockPath), []);
  } finally {
    if (lockHolder.exitCode === null) lockHolder.kill("SIGKILL");
  }
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

  let declaredGate = createAgentRun({
    id: "declared-approval-gate",
    goal: "Exercise declared workflow approval requirements",
    plan: [
      { id: "prepare", title: "Prepare the release", kind: "agent" },
      { id: "release", title: "Release the result", kind: "tool" },
    ],
    approvalRequirements: [
      {
        id: "release-approval",
        title: "Approve the exact release",
        action: "publish",
        riskClass: "external-action",
        requestedRole: "owner",
        beforeStepId: "release",
      },
      {
        id: "completion-approval",
        title: "Approve workflow completion",
        action: "complete",
        riskClass: "local-draft",
      },
    ],
  });
  assert.equal(validateAgentRun(declaredGate).valid, true);
  assert.deepEqual(parseAgentRunOrg(renderAgentRunOrg(declaredGate)), declaredGate);
  assert.equal(agentRunApprovalRequirementState(declaredGate, "release-approval"), "unbound");
  assert.throws(
    () => agentRunApprovalRequirementState(declaredGate, "missing"),
    /approval requirement not found/,
  );
  declaredGate = transitionAgentRun(declaredGate, "running");
  declaredGate = updateAgentRunStep(declaredGate, "prepare", "completed");
  assert.throws(
    () => updateAgentRunStep(declaredGate, "release", "running"),
    /requires approved workflow approval requirement: release-approval/,
  );
  assert.throws(
    () => transitionAgentRun(declaredGate, "completed", { summary: "Not yet approved." }),
    /release-approval, completion-approval/,
  );
  assert.throws(
    () => requestAgentRunApproval(declaredGate, {
      requirementId: "missing",
      material: exactMessage("public", "Release this."),
    }),
    /approval requirement not found/,
  );
  assert.throws(
    () => requestAgentRunApproval(declaredGate, {
      requirementId: "release-approval",
      title: "A different release",
      material: exactMessage("public", "Release this."),
    }),
    /title must match requirement release-approval/,
  );
  assert.throws(
    () => requestAgentRunApproval(declaredGate, { requirementId: "release-approval" }),
    /Bound typed review material is required/,
  );
  declaredGate = requestAgentRunApproval(declaredGate, {
    id: "release-request-v1",
    requirementId: "release-approval",
    material: exactMessage("public", "Release version one."),
  });
  assert.equal(agentRunApprovalRequirementState(declaredGate, "release-approval"), "pending");
  assert.equal(declaredGate.approvals.at(-1).title, "Approve the exact release");
  assert.equal(declaredGate.approvals.at(-1).requestedRole, "owner");
  assert.equal(declaredGate.approvals.at(-1).requirementId, "release-approval");
  assert.throws(
    () => requestAgentRunApproval(declaredGate, {
      id: "parallel-release-request",
      requirementId: "release-approval",
      material: exactMessage("public", "Release another version."),
    }),
    /already has pending request release-request-v1/,
  );
  declaredGate = decide(declaredGate, "release-request-v1", "rejected", {
    actor: "Avi",
    actorRole: "owner",
  });
  assert.equal(agentRunApprovalRequirementState(declaredGate, "release-approval"), "denied");
  assert.throws(
    () => updateAgentRunStep(declaredGate, "release", "completed"),
    /release-approval/,
  );
  declaredGate = requestAgentRunApproval(declaredGate, {
    id: "release-request-v2",
    requirementId: "release-approval",
    material: exactMessage("public", "Release version two."),
  });
  declaredGate = decide(declaredGate, "release-request-v2", "approved", {
    actor: "Avi",
    actorRole: "owner",
  });
  assert.equal(agentRunApprovalRequirementState(declaredGate, "release-approval"), "approved");
  declaredGate = updateAgentRunStep(declaredGate, "release", "running");
  declaredGate = updateAgentRunStep(declaredGate, "release", "completed");
  assert.throws(
    () => transitionAgentRun(declaredGate, "completed", { summary: "Completion is still gated." }),
    /completion-approval/,
  );
  declaredGate = requestAgentRunApproval(declaredGate, {
    id: "completion-request",
    requirementId: "completion-approval",
  });
  declaredGate = decide(declaredGate, "completion-request", "approved", { actor: "Avi" });
  declaredGate = transitionAgentRun(declaredGate, "completed", {
    summary: "Both declared approval requirements were satisfied.",
  });

  const declaredFork = forkAgentRun(declaredGate, { id: "declared-approval-fork" });
  assert.deepEqual(declaredFork.approvalRequirements, declaredGate.approvalRequirements);
  assert.equal(declaredFork.approvals.length, 0);
  assert.equal(agentRunApprovalRequirementState(declaredFork, "release-approval"), "unbound");
  assert.equal(declaredFork.plan.every((step) => step.status === "pending"), true);
  assert.throws(
    () => updateAgentRunStep(declaredFork, "release", "running"),
    /release-approval/,
  );
  const bypassedGuardedStep = structuredClone(declaredFork);
  bypassedGuardedStep.plan.find((step) => step.id === "release").status = "completed";
  assert.equal(
    validateAgentRun(bypassedGuardedStep).issues.some((issue) => (
      issue.path.endsWith(".status") && /release-approval/.test(issue.message)
    )),
    true,
  );
  const unauditedSkippedStep = structuredClone(declaredFork);
  unauditedSkippedStep.plan.find((step) => step.id === "release").status = "skipped";
  assert.equal(
    validateAgentRun(unauditedSkippedStep).issues.some((issue) => (
      issue.path.endsWith(".detail") && /no protected effect occurred/.test(issue.message)
    )),
    true,
  );
  assert.throws(
    () => createAgentRun({
      id: "completed-without-declared-approval",
      goal: "Do not bypass a declaration at creation time",
      status: "completed",
      outcome: { summary: "Improperly completed." },
      approvalRequirements: [{
        id: "completion-gate",
        title: "Approve completion",
        action: "complete",
        riskClass: "local-draft",
      }],
    }),
    /creating a completed run requires approved workflow approval requirement: completion-gate/,
  );
  saveAgentRun(root, declaredFork);
  assert.throws(
    () => mutateAgentRun(root, declaredFork.id, (current) => ({
      ...current,
      approvalRequirements: current.approvalRequirements.map((requirement) => (
        requirement.id === "release-approval"
          ? { ...requirement, action: "changed-action" }
          : requirement
      )),
    })),
    /cannot change immutable workflow approval requirements/,
  );
  assert.equal(loadAgentRun(root, declaredFork.id).approvalRequirements[0].action, "publish");

  let externalGate = createAgentRun({
    id: "external-completion-gate",
    goal: "Keep external completion approval-gated",
    plan: [{ id: "release", title: "Release externally", kind: "tool" }],
    approvalRequirements: [{
      id: "external-release",
      title: "Approve external release",
      action: "publish",
      riskClass: "external-action",
      beforeStepId: "release",
    }],
  });
  externalGate = transitionAgentRun(externalGate, "running");
  externalGate = transitionAgentRun(externalGate, "blocked", { reason: "The provider will perform this outside the workflow." });
  assert.throws(
    () => completeAgentRunExternally(externalGate, { summary: "Performed elsewhere.", actor: "Avi" }),
    /external-release/,
  );
  assert.throws(
    () => updateAgentRunStep(externalGate, "release", "skipped"),
    /must record why no protected effect occurred/,
  );
  externalGate = updateAgentRunStep(externalGate, "release", "skipped", {
    detail: "The provider confirmed that no protected release effect occurred.",
  });
  externalGate = completeAgentRunExternally(externalGate, { summary: "No release effect was needed.", actor: "Avi" });
  assert.equal(externalGate.status, "completed");

  const invalidRequirementBinding = structuredClone(declaredGate);
  invalidRequirementBinding.approvals.at(-1).requirementId = "unknown-requirement";
  assert.equal(
    validateAgentRun(invalidRequirementBinding).issues.some((issue) => issue.path.endsWith(".requirementId")),
    true,
  );

  let gated = createAgentRun({ id: "multi-approval", goal: "Exercise a multi-approval boundary" });
  gated = requestAgentRunApproval(gated, {
    id: "legal",
    title: "Legal review",
    action: "release",
    riskClass: "external-action",
    requestedRole: "legal",
    note: "Release the reviewed copy.",
    material: exactMessage("public", "Release the reviewed copy."),
  });
  gated = requestAgentRunApproval(gated, {
    id: "owner",
    title: "Owner review",
    action: "release",
    riskClass: "external-action",
    requestedRole: "owner",
    note: "Release the reviewed copy.",
    material: exactMessage("public", "Release the reviewed copy."),
  });
  assert.throws(() => decide(gated, "legal", "approved", { actor: "Avi", actorRole: "owner" }), /requires role legal/);
  gated = decide(gated, "legal", "rejected", { actor: "Counsel", actorRole: "legal" });
  gated = decide(gated, "owner", "approved", { actor: "Avi", actorRole: "owner" });
  assert.equal(gated.status, "blocked");

  gated = requestAgentRunApproval(gated, {
    id: "replacement",
    title: "Approve revised release",
    action: "release revised copy",
    riskClass: "external-action",
    requestedRole: "owner",
    note: "Release the revised reviewed copy.",
    material: exactMessage("public", "Release the revised reviewed copy."),
  });
  assert.equal(gated.status, "waiting-approval");
  gated = decide(gated, "replacement", "approved", { actor: "Avi", actorRole: "owner" });
  assert.equal(gated.status, "running");
  assert.equal(gated.approvals.find((approval) => approval.id === "legal").status, "rejected");
  assert.equal(gated.approvals.find((approval) => approval.id === "replacement").status, "approved");

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
    note: "Retry the exact failed action after service recovery.",
    material: {
      kind: "command",
      command: { text: "retry-exact-action", argv: ["retry-exact-action", "--id", "failed-action"] },
    },
  });
  assert.equal(separatelyBlocked.status, "blocked");
  separatelyBlocked = decide(separatelyBlocked, "separate-approval", "approved", { actor: "Avi" });
  assert.equal(separatelyBlocked.status, "blocked");
  assert.equal(separatelyBlocked.blockedReason, "The external service is unavailable.");

  let concurrentReservation = createAgentRun({
    id: "concurrent-reservation",
    goal: "Authorize one external effect",
  });
  concurrentReservation = requestAgentRunApproval(concurrentReservation, {
    id: "send-once",
    title: "Send one message",
    action: "send",
    riskClass: "external-action",
    material: exactMessage("person@example.com", "One exact message."),
  });
  concurrentReservation = decide(concurrentReservation, "send-once", "approved", { actor: "Avi" });
  saveAgentRun(root, concurrentReservation);
  const concurrentFingerprint = concurrentReservation.approvals[0].fingerprint;
  const concurrentDigest = computeApprovalMaterialDigest(concurrentReservation.approvals[0].material);
  const concurrentAttempts = await Promise.all(["call-a", "call-b"].map((toolCallId) => runCli([
    "run", "approval-effect-reserve", concurrentReservation.id, "send-once",
    "--fingerprint", concurrentFingerprint,
    "--material-digest", concurrentDigest,
    "--tool-call-id", toolCallId,
    "--dir", root,
    "--json",
  ])));
  assert.deepEqual(
    concurrentAttempts.map((attempt) => attempt.status).sort((left, right) => left - right),
    [0, 1],
  );
  assert.equal(
    concurrentAttempts.filter((attempt) => attempt.status !== 0)
      .every((attempt) => /already updating|unresolved effect reservation/.test(attempt.stderr)),
    true,
  );
  const persistedReservation = loadAgentRun(root, concurrentReservation.id).approvals[0].effectReservation;
  assert.ok(["call-a", "call-b"].includes(persistedReservation.toolCallId));
  assert.equal(persistedReservation.materialDigest, concurrentDigest);
  const losingToolCallId = persistedReservation.toolCallId === "call-a" ? "call-b" : "call-a";
  const retryAfterContention = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"),
    "run", "approval-effect-reserve", concurrentReservation.id, "send-once",
    "--fingerprint", concurrentFingerprint,
    "--material-digest", concurrentDigest,
    "--tool-call-id", losingToolCallId,
    "--dir", root,
    "--json",
  ], { encoding: "utf8" });
  assert.notEqual(retryAfterContention.status, 0);
  assert.match(retryAfterContention.stderr, /unresolved effect reservation/);

  const cliRequirementRun = createAgentRun({
    id: "cli-requirement",
    goal: "Request a declared approval through the CLI",
    plan: [{ id: "release", title: "Release", kind: "tool" }],
    approvalRequirements: [{
      id: "release-gate",
      title: "Approve CLI release",
      action: "publish",
      riskClass: "external-action",
      requestedRole: "owner",
      beforeStepId: "release",
    }],
  });
  saveAgentRun(root, cliRequirementRun);
  const cliRequirementMaterial = JSON.stringify(exactMessage("public", "Release from the CLI."));
  const conflictingCliRequirement = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "run", "approval-request", cliRequirementRun.id,
    "--id", "cli-release-conflict",
    "--requirement", "release-gate",
    "--title", "Wrong title",
    "--material-json", cliRequirementMaterial,
    "--dir", root,
    "--json",
  ], { encoding: "utf8" });
  assert.notEqual(conflictingCliRequirement.status, 0);
  assert.match(conflictingCliRequirement.stderr, /title must match requirement release-gate/);
  const requestedCliRequirement = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "run", "approval-request", cliRequirementRun.id,
    "--id", "cli-release",
    "--requirement", "release-gate",
    "--material-json", cliRequirementMaterial,
    "--dir", root,
    "--json",
  ], { encoding: "utf8" });
  assert.equal(requestedCliRequirement.status, 0, requestedCliRequirement.stderr || requestedCliRequirement.stdout);
  const cliRequirementApproval = JSON.parse(requestedCliRequirement.stdout).approvals.at(-1);
  assert.equal(cliRequirementApproval.requirementId, "release-gate");
  assert.equal(cliRequirementApproval.title, "Approve CLI release");
  assert.equal(cliRequirementApproval.action, "publish");
  assert.equal(cliRequirementApproval.riskClass, "external-action");
  assert.equal(cliRequirementApproval.requestedRole, "owner");

  const capturedDeclaredWorkflow = workflowFromRun(declaredGate, {
    id: "captured-declared-approvals",
    now: "2026-07-14T11:00:00Z",
  });
  assert.deepEqual(
    capturedDeclaredWorkflow.approvals.map(({ id, beforeStepId }) => ({ id, beforeStepId })),
    [
      { id: "release-approval", beforeStepId: "release" },
      { id: "completion-approval", beforeStepId: undefined },
    ],
  );

  const workflow = workflowFromRun(run, { id: "board-briefing", now: "2026-07-14T11:00:00Z" });
  workflow.inputs.push({ id: "quarter", description: "Reporting quarter", required: true });
  workflow.instructions = "Prepare the {{quarter}} board briefing";
  workflow.approvals = [{
    id: "review-release",
    title: "Approve the {{quarter}} release",
    action: "release {{quarter}} briefing",
    riskClass: "external-action",
    requestedRole: "owner",
    beforeStepId: "review",
  }];
  workflow.triggers.push({ id: "daily", type: "schedule", enabled: true, schedule: "every 1d", lastRunAt: "2026-07-12T00:00:00Z" });
  workflow.triggers.push({ id: "after-capture", type: "capture", enabled: true });
  saveWorkflow(root, workflow);
  assert.equal(workflowPath(root, workflow.id), path.join(root, "workflows", "board-briefing.org2"));
  assert.equal(fs.existsSync(workflowPath(root, workflow.id)), true);
  assert.equal(loadWorkflow(root, workflow.id).version, "1.0.0");
  const workflowMutationEntered = path.join(root, "workflow-mutation-entered");
  const releaseWorkflowMutation = path.join(root, "release-workflow-mutation");
  const workflowMutationModule = pathToFileURL(path.resolve("dist/agentWorkflow.js")).href;
  const workflowMutationChild = spawn(process.execPath, [
    "--input-type=module",
    "-e",
    `
      import fs from "node:fs";
      import { mutateWorkflow } from ${JSON.stringify(workflowMutationModule)};
      const [root, id, entered, release] = process.argv.slice(1);
      mutateWorkflow(root, id, (current) => {
        fs.writeFileSync(entered, "entered\\n", { flag: "wx" });
        const deadline = Date.now() + 10_000;
        while (!fs.existsSync(release)) {
          if (Date.now() >= deadline) throw new Error("timed out waiting to release workflow mutation");
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
        }
        return { ...current, state: "active" };
      }, "2026-07-14T01:00:00.000Z");
    `,
    root,
    workflow.id,
    workflowMutationEntered,
    releaseWorkflowMutation,
  ], {
    cwd: process.cwd(),
    stdio: ["ignore", "ignore", "pipe"],
  });
  let workflowMutationError = "";
  workflowMutationChild.stderr.setEncoding("utf8");
  workflowMutationChild.stderr.on("data", (chunk) => { workflowMutationError += chunk; });
  const workflowMutationDeadline = Date.now() + 10_000;
  while (!fs.existsSync(workflowMutationEntered)) {
    if (workflowMutationChild.exitCode !== null) {
      throw new Error(workflowMutationError || `workflow mutation child exited ${workflowMutationChild.exitCode}`);
    }
    if (Date.now() >= workflowMutationDeadline) throw new Error("timed out waiting for workflow mutation lock");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const overlappingSchedule = await runCli([
    "workflow", "schedule", workflow.id,
    "--cron", "every 2h",
    "--dir", root,
    "--json",
  ]);
  assert.notEqual(overlappingSchedule.status, 0);
  assert.match(overlappingSchedule.stderr, /already updating/);
  fs.writeFileSync(releaseWorkflowMutation, "release\n", { flag: "wx" });
  await new Promise((resolve, reject) => {
    workflowMutationChild.once("error", reject);
    workflowMutationChild.once("close", (status) => {
      if (status === 0) resolve();
      else reject(new Error(workflowMutationError || `workflow mutation child exited ${status}`));
    });
  });
  const retriedSchedule = await runCli([
    "workflow", "schedule", workflow.id,
    "--cron", "every 2h",
    "--dir", root,
    "--json",
  ]);
  assert.equal(retriedSchedule.status, 0, retriedSchedule.stderr || retriedSchedule.stdout);
  const concurrentlyUpdatedWorkflow = loadWorkflow(root, workflow.id);
  assert.equal(concurrentlyUpdatedWorkflow.state, "active");
  assert.equal(
    concurrentlyUpdatedWorkflow.triggers.find((trigger) => trigger.id === "openclaw-schedule")?.schedule,
    "every 2h",
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
  assert.deepEqual(instantiated.approvalRequirements, [{
    id: "review-release",
    title: "Approve the Q3 release",
    action: "release Q3 briefing",
    riskClass: "external-action",
    requestedRole: "owner",
    beforeStepId: "review",
  }]);
  assert.throws(() => updateAgentRunStep(instantiated, "review", "running"), /review-release/);
  const legacyApprovalDeclaration = structuredClone(workflow);
  legacyApprovalDeclaration.approvals = [{
    title: "Approve an older declaration",
    action: "release",
    riskClass: "local-draft",
  }];
  assert.equal(
    instantiateWorkflow(legacyApprovalDeclaration, { quarter: "Q3" }).approvalRequirements[0].id,
    "workflow-approval-1",
  );
  assert.equal(packagedCorpusTemplate(workflow).schema, "org2:corpus-template:v1");
  assert.equal(replayWorkflowFixture(workflow, { schema: "org2:workflow-replay-fixture:v1", workflowVersion: "1.0.0", inputs: { quarter: "Q3" }, expectedGoal: "Prepare the Q3 board briefing", expectedSteps: ["draft"], expectedCapabilities: ["publish"], expectedRiskClass: "local-draft" }).passed, true);
  assert.equal(fs.existsSync(installBuiltinWorkflow(root, MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW)), true);
  const installedMeetingWorkflow = loadWorkflow(root, "meeting-to-controlled-execution");
  const meetingRun = instantiateWorkflow(installedMeetingWorkflow, { meeting: "meetings/standup.org2" });
  assert.match(meetingRun.goal, /meetings\/standup\.org2/);
  assert.equal(meetingRun.context[0].ref, "meetings/standup.org2");
  assert.deepEqual(
    meetingRun.approvalRequirements.map(({ id, beforeStepId }) => ({ id, beforeStepId })),
    [{ id: "release-finished-artifacts", beforeStepId: "release" }],
  );
  assert.throws(() => updateAgentRunStep(meetingRun, "release", "running"), /release-finished-artifacts/);

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
