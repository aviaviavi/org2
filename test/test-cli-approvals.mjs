#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createAgentRun, saveAgentRun } from "../dist/agentRun.js";

const repo = process.cwd();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-approvals-test-"));
const indexHome = fs.mkdtempSync(path.join(os.tmpdir(), "org2-approvals-index-home-"));
const note = path.join(tmp, "approvals.org2");
const conflict = path.join(tmp, "approvals.sync-conflict-20260626-100557-3XMYYT2.org2");
const versionsDir = path.join(tmp, ".stversions", "agents");
const versionedApproval = path.join(versionsDir, "approvals~20260706-100605.org2");

function cli(args) {
  return execFileSync("node", ["dist/cli.js", ...args], {
    cwd: repo,
    encoding: "utf8",
    env: { ...process.env, ORG2_INDEX_HOME: indexHome },
  });
}

function messageMaterial(target, content) {
  return JSON.stringify({ kind: "message", target, content });
}

fs.mkdirSync(versionsDir, { recursive: true });
fs.writeFileSync(note, `#+title: Approval queue

* TODO Review outreach copy
SCHEDULED: <2026-06-26 Fri>
:PROPERTIES:
:ID: approval-1
:STATUS: draft-needs-review
:END:
Send this once approved.

* DONE Review old item
:PROPERTIES:
:STATUS: draft-needs-review
:END:
Already closed.

* TODO [#B] Approve sending Mercor technographics data [[id:8f3c76e5-dd1f-4819-9738-7959b95c3649][overview]] draft
:PROPERTIES:
:ID: approval-priority
:STATUS: waiting-on-avi-approval
:END:
Approve before sending.
`, "utf8");

fs.writeFileSync(versionedApproval, `* TODO Review outreach copy
:PROPERTIES:
:ID: approval-1
:STATUS: draft-needs-review
:END:
Historical Syncthing snapshot.
`, "utf8");

fs.writeFileSync(conflict, `* TODO Review deleted sync artifact
:PROPERTIES:
:STATUS: draft-needs-review
:END:
`, "utf8");

cli(["run", "create", "--id", "release-run", "--goal", "Release the weekly brief", "--dir", tmp, "--json"]);
cli(["run", "start", "release-run", "--dir", tmp, "--json"]);
cli([
  "run", "approval-request", "release-run",
  "--title", "Approve recipients", "--action", "confirm recipient list",
  "--risk", "external-action", "--role", "owner",
  "--note", "Recipients: reviewed@example.com",
  "--material-json", messageMaterial("reviewed@example.com", "Weekly brief recipient"),
  "--dir", tmp, "--json",
]);
cli([
  "run", "approval-request", "release-run",
  "--title", "Approve final copy", "--action", "send weekly brief",
  "--risk", "external-action", "--role", "owner",
  "--note", "Send the exact weekly brief shown here.",
  "--material-json", messageMaterial("reviewed@example.com", "The exact weekly brief."),
  "--dir", tmp, "--json",
]);

const staleIndex = JSON.parse(cli(["index", "--dir", tmp, "--files", note, conflict, "--format", "json"]));
assert.equal(staleIndex.fileCount, 2);
fs.unlinkSync(conflict);

const payload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
assert.equal(payload.$schema, "org2:approvals:v2");
assert.equal(payload.index.used, true);
assert.equal(payload.index.rebuilt, true);
assert.equal(payload.count, 4);
assert.equal(payload.skippedCandidates ?? 0, 0);
const runItems = payload.items.filter((item) => item.kind === "run");
const headlineItems = payload.items.filter((item) => item.kind === "headline");
assert.equal(runItems.length, 2);
const resumePendingRun = spawnSync("node", [
  "dist/cli.js", "run", "resume", "release-run", "--dir", tmp,
], { cwd: repo, encoding: "utf8", env: { ...process.env, ORG2_INDEX_HOME: indexHome } });
assert.notEqual(resumePendingRun.status, 0);
assert.match(resumePendingRun.stderr, /current approval boundary is unresolved/);
assert.equal(runItems[0].runId, "release-run");
assert.equal(runItems[0].runGoal, "Release the weekly brief");
assert.equal(runItems[0].runStatus, "waiting-approval");
assert.equal(runItems[0].runPendingApprovalCount, 2);
assert.equal(runItems[0].runApprovalCount, 2);
assert.equal(runItems[0].runDecisionEffect, "Approving this leaves 1 other pending approval before the run can resume.");
assert.match(runItems[0].queueId, /^run:release-run:/);
assert.match(runItems[0].fingerprint, /^sha256:[a-f0-9]{64}$/);
assert.equal(runItems[0].binding, "native");
assert.equal(runItems[0].canApprove, true);
assert.equal(headlineItems[0].title, "Review outreach copy");
assert.equal(headlineItems[0].line, 3);
assert.equal(headlineItems[0].idValue, "approval-1");
assert.equal(headlineItems[0].status, "draft-needs-review");
assert.equal(headlineItems[0].body, "Send this once approved.");
assert.match(headlineItems[0].queueId, /^headline:/);
assert.match(headlineItems[0].fingerprint, /^sha256:[a-f0-9]{64}$/);
assert.equal(headlineItems[0].binding, "legacy");
assert.doesNotMatch(headlineItems[0].file, /\.stversions/);
assert.deepEqual(headlineItems[0].properties, {
  ID: "approval-1",
  STATUS: "draft-needs-review",
});

const requirementRun = createAgentRun({
  id: "requirement-queue-run",
  goal: "Release a requirement-bound artifact",
  plan: [{ id: "release", title: "Release the artifact", kind: "tool" }],
  approvalRequirements: [{
    id: "release-gate",
    title: "Approve the exact release",
    action: "publish the reviewed artifact",
    riskClass: "external-action",
    requestedRole: "owner",
    beforeStepId: "release",
  }],
});
saveAgentRun(tmp, requirementRun);
cli(["run", "start", requirementRun.id, "--dir", tmp, "--json"]);
cli([
  "run", "approval-request", requirementRun.id,
  "--requirement", "release-gate",
  "--material-json", messageMaterial("reviewed@example.com", "The exact reviewed artifact."),
  "--dir", tmp, "--json",
]);
const requirementPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
const requirementItem = requirementPayload.items.find((item) => item.runId === requirementRun.id);
assert.deepEqual(requirementItem.requirement, {
  id: "release-gate",
  title: "Approve the exact release",
  action: "publish the reviewed artifact",
  riskClass: "external-action",
  requestedRole: "owner",
  beforeStepId: "release",
  state: "pending",
});
cli([
  "approval", "decide", requirementItem.queueId,
  "--decision", "approved", "--actor", "Avi", "--role", "owner",
  "--expected-fingerprint", requirementItem.fingerprint,
  "--dir", tmp, "--apply", "--json",
]);

const nativeEndStatus = spawnSync("node", [
  "dist/cli.js", "approval", "decide", runItems[0].queueId,
  "--decision", "approved", "--actor", "Avi",
  "--expected-fingerprint", runItems[0].fingerprint,
  "--end-status", "done", "--dir", tmp,
], { cwd: repo, encoding: "utf8", env: { ...process.env, ORG2_INDEX_HOME: indexHome } });
assert.notEqual(nativeEndStatus.status, 0);
assert.match(nativeEndStatus.stderr, /--end-status applies only to legacy headline approvals/);
const legacyRole = spawnSync("node", [
  "dist/cli.js", "approval", "decide", headlineItems[0].queueId,
  "--decision", "approved", "--actor", "Avi",
  "--expected-fingerprint", headlineItems[0].fingerprint,
  "--role", "owner", "--dir", tmp,
], { cwd: repo, encoding: "utf8", env: { ...process.env, ORG2_INDEX_HOME: indexHome } });
assert.notEqual(legacyRole.status, 0);
assert.match(legacyRole.stderr, /--role applies only to native run approvals/);
assert.equal(headlineItems[1].title, "Approve sending Mercor technographics data overview draft");
assert.equal(headlineItems[1].idValue, "approval-priority");
assert.equal(headlineItems[1].status, "waiting-on-avi-approval");

cli(["run", "create", "--id", "revision-run", "--goal", "Release revised copy", "--dir", tmp, "--json"]);
cli(["run", "start", "revision-run", "--dir", tmp, "--json"]);
let revisionRun = JSON.parse(cli([
  "run", "approval-request", "revision-run",
  "--title", "Approve original copy", "--action", "send original copy",
  "--risk", "external-action", "--role", "owner", "--note", "Send the exact original copy.",
  "--material-json", messageMaterial("reviewed@example.com", "Original copy."),
  "--dir", tmp, "--json",
]));
const originalApproval = revisionRun.approvals.at(-1);
cli([
  "run", "approval-decide", "revision-run", originalApproval.id,
  "--decision", "revised", "--actor", "Avi", "--role", "owner",
  "--expected-fingerprint", originalApproval.fingerprint, "--dir", tmp, "--json",
]);
revisionRun = JSON.parse(cli([
  "run", "approval-request", "revision-run",
  "--title", "Approve revised copy", "--action", "send revised copy",
  "--risk", "external-action", "--role", "owner", "--note", "Send the exact revised copy.",
  "--material-json", messageMaterial("reviewed@example.com", "Revised copy."),
  "--dir", tmp, "--json",
]));
const replacementApprovalId = revisionRun.approvals.at(-1).id;
const replacementFingerprint = revisionRun.approvals.at(-1).fingerprint;
const replacementPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
const replacementItem = replacementPayload.items.find((item) => item.runId === "revision-run");
assert.equal(replacementItem.runStatus, "waiting-approval");
assert.equal(replacementItem.runDecisionEffect, "This is the last pending approval; approving it resumes the run.");
revisionRun = JSON.parse(cli([
  "run", "approval-decide", "revision-run", replacementApprovalId,
  "--decision", "approved", "--actor", "Avi", "--role", "owner",
  "--expected-fingerprint", replacementFingerprint, "--dir", tmp, "--json",
]));
assert.equal(revisionRun.status, "running");
assert.deepEqual(revisionRun.approvals.map((approval) => approval.status), ["revised", "approved"]);

const scannedPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json"]));
assert.equal(scannedPayload.index.used, false);
assert.equal(scannedPayload.count, 4);
assert.doesNotMatch(scannedPayload.items.find((item) => item.kind === "headline").file, /\.stversions/);

const indexedPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
assert.equal(indexedPayload.index.used, true);
assert.equal(indexedPayload.index.rebuilt, undefined);
assert.equal(indexedPayload.count, 4);

const text = cli(["approvals", "--dir", tmp, "--recursive"]);
assert.match(text, /approvals\.org2:3 TODO Review outreach copy \[draft-needs-review\]/);
assert.match(text, /TODO Approve sending Mercor technographics data overview draft \[waiting-on-avi-approval\]/);
assert.match(text, /run:release-run:.+ Approve .+ \[pending; 2 pending for run\]/);

const approvalToDecide = runItems[0].approvalId;
const unifiedRunDecision = JSON.parse(cli([
  "approval", "decide", runItems[0].queueId,
  "--decision", "approved", "--actor", "Avi", "--role", "owner",
  "--expected-fingerprint", runItems[0].fingerprint, "--dir", tmp, "--apply",
]));
assert.equal(unifiedRunDecision.schema, "org2:approval-decision:v1");
assert.equal(unifiedRunDecision.binding, "native");
assert.equal(unifiedRunDecision.applied, true);
assert.equal(unifiedRunDecision.run.approvals.find((item) => item.id === approvalToDecide).status, "approved");
const afterDecision = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
const remainingRunApproval = afterDecision.items.find((item) => item.kind === "run");
assert.equal(afterDecision.count, 3);
assert.equal(remainingRunApproval.runId, "release-run");
assert.equal(remainingRunApproval.runPendingApprovalCount, 1);
assert.equal(remainingRunApproval.runDecisionEffect, "This is the last pending approval; approving it resumes the run.");

const reviewedHeadline = afterDecision.items.find((item) => item.kind === "headline" && item.idValue === "approval-1");
fs.writeFileSync(note, fs.readFileSync(note, "utf8").replace("Send this once approved.", "Send this only after the revised review."), "utf8");
const staleHeadlineDecision = spawnSync("node", [
  "dist/cli.js", "approval", "decide", reviewedHeadline.queueId,
  "--decision", "approved", "--actor", "Avi",
  "--expected-fingerprint", reviewedHeadline.fingerprint,
  "--dir", tmp, "--apply",
], { cwd: repo, encoding: "utf8", env: { ...process.env, ORG2_INDEX_HOME: indexHome } });
assert.notEqual(staleHeadlineDecision.status, 0);
assert.match(staleHeadlineDecision.stderr, /stale approval review/);

const refreshedHeadline = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json"]))
  .items.find((item) => item.kind === "headline" && item.idValue === "approval-1");
const unifiedHeadlineDecision = JSON.parse(cli([
  "approval", "decide", refreshedHeadline.queueId,
  "--decision", "approved", "--actor", "Avi",
  "--expected-fingerprint", refreshedHeadline.fingerprint,
  "--dir", tmp, "--apply",
]));
assert.equal(unifiedHeadlineDecision.binding, "legacy");
assert.equal(unifiedHeadlineDecision.applied, true);
const decidedHeadline = fs.readFileSync(note, "utf8");
assert.match(decidedHeadline, /^\* DONE Review outreach copy$/m);
assert.match(decidedHeadline, /^:STATUS: approved$/m);
assert.match(decidedHeadline, /^:APPROVAL_FINGERPRINT: sha256:[a-f0-9]{64}$/m);

cli(["run", "create", "--id", "preview-run", "--goal", "Preview a native decision", "--dir", tmp, "--json"]);
cli(["run", "start", "preview-run", "--dir", tmp, "--json"]);
const previewRequested = JSON.parse(cli([
  "run", "approval-request", "preview-run",
  "--title", "Preview only", "--action", "hold", "--risk", "local-draft",
  "--dir", tmp, "--json",
]));
const previewApproval = previewRequested.approvals.at(-1);
const nativePreview = JSON.parse(cli([
  "approval", "decide", `run:preview-run:${previewApproval.id}`,
  "--decision", "approved", "--actor", "Avi",
  "--expected-fingerprint", previewApproval.fingerprint,
  "--dir", tmp,
]));
assert.equal(nativePreview.applied, false);
assert.equal(JSON.parse(cli(["run", "show", "preview-run", "--dir", tmp, "--json"])).approvals.at(-1).status, "pending");

const signals = path.join(tmp, "approval-signals.org2");
fs.writeFileSync(signals, `* TODO Waiting signal
:PROPERTIES:
:ID: signal-waiting
:WAITING_ON: Avi approval
:END:

* TODO Action signal
:PROPERTIES:
:ID: signal-action
:NEXT_ACTION: review and approve
:END:

* TODO Handoff signal
:PROPERTIES:
:ID: signal-handoff
:HANDOFF_SUMMARY: waiting for human review
:END:

* TODO Access signal
:PROPERTIES:
:ID: signal-access
:ACCESS_POLICY: approval-required
:END:
`, "utf8");
for (const id of ["signal-waiting", "signal-action", "signal-handoff", "signal-access"]) {
  const item = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json"]))
    .items.find((candidate) => candidate.kind === "headline" && candidate.idValue === id);
  assert.ok(item, `missing ${id}`);
  cli([
    "approval", "decide", item.queueId,
    "--decision", "approved", "--actor", "Avi",
    "--expected-fingerprint", item.fingerprint,
    "--dir", tmp, "--apply",
  ]);
}
const remainingSignals = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json"]))
  .items.filter((item) => item.file === signals);
assert.deepEqual(remainingSignals, []);

const ambiguous = path.join(tmp, "ambiguous-pair.org2");
fs.writeFileSync(ambiguous, `* TODO Send approved duplicate
First.

* TODO Send approved duplicate
Second.

* TODO Approve duplicate
:PROPERTIES:
:ID: ambiguous-approval
:STATUS: draft-needs-review
:PAIRED_SEND_TODO: Send approved duplicate
:END:
`, "utf8");
const ambiguousItem = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json"]))
  .items.find((item) => item.idValue === "ambiguous-approval");
assert.equal(ambiguousItem.canApprove, false);
assert.match(ambiguousItem.approvalBlockedReason, /ambiguous/i);

const paired = path.join(tmp, "paired-stale.org2");
fs.writeFileSync(paired, `* TODO Send approved release
Version one.

* TODO Approve release
:PROPERTIES:
:ID: paired-approval
:STATUS: draft-needs-review
:PAIRED_SEND_TODO: Send approved release
:END:
`, "utf8");
const pairedItem = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json"]))
  .items.find((item) => item.idValue === "paired-approval");
fs.writeFileSync(paired, fs.readFileSync(paired, "utf8").replace("Version one.", "Version two."), "utf8");
const stalePaired = spawnSync("node", [
  "dist/cli.js", "approval", "decide", pairedItem.queueId,
  "--decision", "approved", "--actor", "Avi",
  "--expected-fingerprint", pairedItem.fingerprint,
  "--dir", tmp, "--apply",
], { cwd: repo, encoding: "utf8", env: { ...process.env, ORG2_INDEX_HOME: indexHome } });
assert.notEqual(stalePaired.status, 0);
assert.match(stalePaired.stderr, /stale approval review/);

const refreshedPaired = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json"]))
  .items.find((item) => item.idValue === "paired-approval");
const pairedLock = path.join(path.dirname(paired), `.${path.basename(paired)}.org2-mutation.lock`);
fs.mkdirSync(pairedLock, { recursive: true });
const pairedLockToken = globalThis.crypto.randomUUID();
const pairedLockOwner = {
  schema: "org2:mutation-lock-owner:v2",
  host: os.hostname(),
  pid: process.pid,
  token: pairedLockToken,
  phase: "ticket",
  ticket: 1,
  createdAt: "2026-07-25T00:00:00.000Z",
};
fs.writeFileSync(
  path.join(pairedLock, `ticket.${String(1).padStart(16, "0")}.${pairedLockToken}.json`),
  `${JSON.stringify(pairedLockOwner)}\n`,
  "utf8",
);
const lockedPaired = spawnSync("node", [
  "dist/cli.js", "approval", "decide", refreshedPaired.queueId,
  "--decision", "approved", "--actor", "Avi",
  "--expected-fingerprint", refreshedPaired.fingerprint,
  "--dir", tmp, "--apply",
], { cwd: repo, encoding: "utf8", env: { ...process.env, ORG2_INDEX_HOME: indexHome } });
assert.notEqual(lockedPaired.status, 0);
assert.match(lockedPaired.stderr, /already updating/);
fs.rmSync(pairedLock, { recursive: true });

const duplicateIdentities = path.join(tmp, "duplicate-identities.org2");
fs.writeFileSync(duplicateIdentities, `* TODO Review first duplicate
:PROPERTIES:
:ORG2_APPROVAL_ID: repeated-approval
:STATUS: draft-needs-review
:END:
First.

* TODO Review second duplicate
:PROPERTIES:
:ORG2_APPROVAL_ID: repeated-approval
:STATUS: draft-needs-review
:END:
Second.
`, "utf8");
const duplicateIdentityItems = JSON.parse(cli([
  "approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json",
])).items.filter((item) => item.file === duplicateIdentities);
assert.equal(duplicateIdentityItems.length, 2);
assert.equal(new Set(duplicateIdentityItems.map((item) => item.queueId)).size, 1);
assert.equal(duplicateIdentityItems.every((item) => item.canApprove === false), true);
assert.equal(duplicateIdentityItems.every((item) => /identity is duplicated/i.test(item.approvalBlockedReason)), true);
const duplicateIdentityDecision = spawnSync("node", [
  "dist/cli.js", "approval", "decide", duplicateIdentityItems[0].queueId,
  "--decision", "rejected", "--actor", "Avi",
  "--expected-fingerprint", duplicateIdentityItems[0].fingerprint,
  "--dir", tmp, "--apply",
], { cwd: repo, encoding: "utf8", env: { ...process.env, ORG2_INDEX_HOME: indexHome } });
assert.notEqual(duplicateIdentityDecision.status, 0);
assert.match(duplicateIdentityDecision.stderr, /identity is duplicated/);
assert.match(fs.readFileSync(duplicateIdentities, "utf8"), /^\* TODO Review first duplicate$/m);
assert.match(fs.readFileSync(duplicateIdentities, "utf8"), /^\* TODO Review second duplicate$/m);

const conflictingPointers = path.join(tmp, "conflicting-pointers.org2");
fs.writeFileSync(conflictingPointers, `* TODO Send approved first action
First action.

* TODO Continue approved second action
Second action.

* TODO Approve conflicting action
:PROPERTIES:
:ORG2_APPROVAL_ID: conflicting-pointers
:STATUS: draft-needs-review
:PAIRED_SEND_TODO: Send approved first action
:PAIRED_AGENT_TODO: Continue approved second action
:END:
`, "utf8");
const conflictingPointerItem = JSON.parse(cli([
  "approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json",
])).items.find((item) => item.idValue === "conflicting-pointers");
assert.equal(conflictingPointerItem.canApprove, false);
assert.match(conflictingPointerItem.approvalBlockedReason, /conflicting paired agent actions/i);
const conflictingApprove = spawnSync("node", [
  "dist/cli.js", "approval", "decide", conflictingPointerItem.queueId,
  "--decision", "approved", "--actor", "Avi",
  "--expected-fingerprint", conflictingPointerItem.fingerprint,
  "--dir", tmp, "--apply",
], { cwd: repo, encoding: "utf8", env: { ...process.env, ORG2_INDEX_HOME: indexHome } });
assert.notEqual(conflictingApprove.status, 0);
assert.match(conflictingApprove.stderr, /conflicting paired agent actions/i);
const conflictingRejection = JSON.parse(cli([
  "approval", "decide", conflictingPointerItem.queueId,
  "--decision", "rejected", "--actor", "Avi",
  "--expected-fingerprint", conflictingPointerItem.fingerprint,
  "--dir", tmp, "--apply",
]));
assert.equal(conflictingRejection.decision, "rejected");
const conflictingText = fs.readFileSync(conflictingPointers, "utf8");
assert.match(conflictingText, /^\* CANCELED Approve conflicting action$/m);
assert.match(conflictingText, /^\* TODO Send approved first action$/m);
assert.match(conflictingText, /^\* TODO Continue approved second action$/m);

const approvalHelp = spawnSync("node", ["dist/cli.js", "approval", "--help"], {
  cwd: repo,
  encoding: "utf8",
});
assert.equal(approvalHelp.status, 0);
assert.match(approvalHelp.stderr, /Omit --apply to preview a\s+decision for either binding/);
assert.match(approvalHelp.stderr, /--role ROLE\s+Native run approvals only/);
assert.match(approvalHelp.stderr, /--end-status done\|canceled\s+Legacy headline approvals only/);
const todoApproveHelp = spawnSync("node", ["dist/cli.js", "todo", "approve", "--help"], {
  cwd: repo,
  encoding: "utf8",
});
assert.equal(todoApproveHelp.status, 0);
assert.match(todoApproveHelp.stderr, /--actor NAME\s+Required reviewer identity for 'approve'/);
assert.match(todoApproveHelp.stderr, /--expected-fingerprint SHA256\s+Required reviewed fingerprint for 'approve'/);
const generalHelp = spawnSync("node", ["dist/cli.js", "--help"], {
  cwd: repo,
  encoding: "utf8",
});
assert.equal(generalHelp.status, 0);
assert.match(generalHelp.stderr, /todo <set\|toggle\|assign\|approve>.*--actor NAME.*--expected-fingerprint SHA256/);

const duplicateProperties = path.join(tmp, "duplicate-properties.org2");
fs.writeFileSync(duplicateProperties, `* TODO Review duplicate properties
:PROPERTIES:
:ORG2_APPROVAL_ID: duplicate-property-approval
:STATUS: draft-needs-review
:STATUS: waiting-on-approval
:END:
Exact review body.
`, "utf8");
const duplicatePropertyItem = JSON.parse(cli([
  "approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json",
])).items.find((item) => item.idValue === "duplicate-property-approval");
assert.equal(duplicatePropertyItem.canApprove, false);
assert.match(duplicatePropertyItem.approvalBlockedReason, /repeats STATUS/i);
const rejectedDuplicateProperty = JSON.parse(cli([
  "approval", "decide", duplicatePropertyItem.queueId,
  "--decision", "rejected", "--actor", "Avi",
  "--expected-fingerprint", duplicatePropertyItem.fingerprint,
  "--dir", tmp, "--apply",
]));
assert.equal(rejectedDuplicateProperty.decision, "rejected");
assert.equal(rejectedDuplicateProperty.applied, true);
assert.equal(
  fs.readFileSync(duplicateProperties, "utf8").match(/^:STATUS: rejected$/gm)?.length,
  2,
);

console.log("✓ cli approvals");
