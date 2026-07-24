#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

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
cli(["run", "approval-request", "release-run", "--title", "Approve recipients", "--action", "confirm recipient list", "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json"]);
cli(["run", "approval-request", "release-run", "--title", "Approve final copy", "--action", "send weekly brief", "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json"]);

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
assert.equal(runItems[0].runId, "release-run");
assert.equal(runItems[0].runGoal, "Release the weekly brief");
assert.equal(runItems[0].runStatus, "waiting-approval");
assert.equal(runItems[0].runPendingApprovalCount, 2);
assert.equal(runItems[0].runApprovalCount, 2);
assert.equal(runItems[0].runDecisionEffect, "Approving this leaves 1 other pending approval before the run can resume.");
assert.equal(headlineItems[0].title, "Review outreach copy");
assert.equal(headlineItems[0].line, 3);
assert.equal(headlineItems[0].idValue, "approval-1");
assert.equal(headlineItems[0].status, "draft-needs-review");
assert.equal(headlineItems[0].body, "Send this once approved.");
assert.doesNotMatch(headlineItems[0].file, /\.stversions/);
assert.deepEqual(headlineItems[0].properties, {
  ID: "approval-1",
  STATUS: "draft-needs-review",
});
assert.equal(headlineItems[1].title, "Approve sending Mercor technographics data overview draft");
assert.equal(headlineItems[1].idValue, "approval-priority");
assert.equal(headlineItems[1].status, "waiting-on-avi-approval");

cli(["run", "create", "--id", "revision-run", "--goal", "Release revised copy", "--dir", tmp, "--json"]);
cli(["run", "start", "revision-run", "--dir", tmp, "--json"]);
let revisionRun = JSON.parse(cli([
  "run", "approval-request", "revision-run",
  "--title", "Approve original copy", "--action", "send original copy",
  "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json",
]));
cli([
  "run", "approval-decide", "revision-run", revisionRun.approvals.at(-1).id,
  "--decision", "revised", "--actor", "Avi", "--role", "owner", "--dir", tmp, "--json",
]);
revisionRun = JSON.parse(cli([
  "run", "approval-request", "revision-run",
  "--title", "Approve revised copy", "--action", "send revised copy",
  "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json",
]));
const replacementApprovalId = revisionRun.approvals.at(-1).id;
const replacementPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
const replacementItem = replacementPayload.items.find((item) => item.runId === "revision-run");
assert.equal(replacementItem.runStatus, "waiting-approval");
assert.equal(replacementItem.runDecisionEffect, "This is the last pending approval; approving it resumes the run.");
revisionRun = JSON.parse(cli([
  "run", "approval-decide", "revision-run", replacementApprovalId,
  "--decision", "approved", "--actor", "Avi", "--role", "owner", "--dir", tmp, "--json",
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
cli(["run", "approval-decide", "release-run", approvalToDecide, "--decision", "approved", "--actor", "Avi", "--role", "owner", "--dir", tmp, "--json"]);
const afterDecision = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
const remainingRunApproval = afterDecision.items.find((item) => item.kind === "run");
assert.equal(afterDecision.count, 3);
assert.equal(remainingRunApproval.runId, "release-run");
assert.equal(remainingRunApproval.runPendingApprovalCount, 1);
assert.equal(remainingRunApproval.runDecisionEffect, "This is the last pending approval; approving it resumes the run.");

console.log("✓ cli approvals");
