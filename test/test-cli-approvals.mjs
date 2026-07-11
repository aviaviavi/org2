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

const staleIndex = JSON.parse(cli(["index", "--dir", tmp, "--files", note, conflict, "--format", "json"]));
assert.equal(staleIndex.fileCount, 2);
fs.unlinkSync(conflict);

const payload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
assert.equal(payload.$schema, "org2:approvals:v1");
assert.equal(payload.index.used, true);
assert.equal(payload.index.rebuilt, true);
assert.equal(payload.count, 2);
assert.equal(payload.skippedCandidates ?? 0, 0);
assert.equal(payload.items[0].title, "Review outreach copy");
assert.equal(payload.items[0].line, 3);
assert.equal(payload.items[0].idValue, "approval-1");
assert.equal(payload.items[0].status, "draft-needs-review");
assert.equal(payload.items[0].body, "Send this once approved.");
assert.doesNotMatch(payload.items[0].file, /\.stversions/);
assert.deepEqual(payload.items[0].properties, {
  ID: "approval-1",
  STATUS: "draft-needs-review",
});
assert.equal(payload.items[1].title, "Approve sending Mercor technographics data overview draft");
assert.equal(payload.items[1].idValue, "approval-priority");
assert.equal(payload.items[1].status, "waiting-on-avi-approval");

const scannedPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json"]));
assert.equal(scannedPayload.index.used, false);
assert.equal(scannedPayload.count, 2);
assert.doesNotMatch(scannedPayload.items[0].file, /\.stversions/);

const indexedPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
assert.equal(indexedPayload.index.used, true);
assert.equal(indexedPayload.index.rebuilt, undefined);
assert.equal(indexedPayload.count, 2);

const text = cli(["approvals", "--dir", tmp, "--recursive"]);
assert.match(text, /approvals\.org2:3 TODO Review outreach copy \[draft-needs-review\]/);
assert.match(text, /TODO Approve sending Mercor technographics data overview draft \[waiting-on-avi-approval\]/);

console.log("✓ cli approvals");
