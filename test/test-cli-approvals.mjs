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
assert.equal(payload.count, 1);
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

const scannedPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json"]));
assert.equal(scannedPayload.index.used, false);
assert.equal(scannedPayload.count, 1);
assert.doesNotMatch(scannedPayload.items[0].file, /\.stversions/);

const indexedPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
assert.equal(indexedPayload.index.used, true);
assert.equal(indexedPayload.index.rebuilt, undefined);
assert.equal(indexedPayload.count, 1);

const text = cli(["approvals", "--dir", tmp, "--recursive"]);
assert.match(text, /approvals\.org2:3 TODO Review outreach copy \[draft-needs-review\]/);

console.log("✓ cli approvals");
