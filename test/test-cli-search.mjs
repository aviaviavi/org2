#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-search-test-"));
const file = path.join(tmp, "notes.org2");
fs.writeFileSync(file, `#+title: Search Fixture

* TODO Alpha plan :work:urgent:
:PROPERTIES:
:ID: alpha-1
:END:
We decided to ship the cited search slice.

** DONE Alpha archive :work:
The old alpha note is done.

* Beta note :personal:
Waiting on a beta reply.
`, "utf8");

const run = (...args) => execFileSync("node", ["dist/cli.js", ...args], { encoding: "utf8" });

const text = run("search", "cited", "--file", file);
assert.match(text, /notes\.org2:7 Alpha plan \[TODO :work: :urgent:\]/);
assert.match(text, /We decided to ship the cited search slice\./);

const filtered = run("search", "old", "--file", file, "--todo", "DONE", "--tag", "work", "--format", "json");
const payload = JSON.parse(filtered);
assert.equal(payload.$schema, "org2:search:v1");
assert.equal(payload.query, "old");
assert.equal(payload.results.length, 1);
assert.equal(payload.results[0].line, 10);
assert.equal(payload.results[0].heading, "Alpha archive");
assert.equal(payload.results[0].todo, "DONE");
assert.deepEqual(payload.results[0].tags, ["work"]);

const queryAlias = run("query", "waiting", "--file", file, "--format", "json");
const aliasPayload = JSON.parse(queryAlias);
assert.equal(aliasPayload.$schema, "org2:search:v1");
assert.equal(aliasPayload.results[0].heading, "Beta note");

const meetingsDir = path.join(tmp, "meetings");
const rawDir = path.join(tmp, "raw");
fs.mkdirSync(meetingsDir);
fs.mkdirSync(rawDir);
fs.writeFileSync(path.join(rawDir, "2026-05-18.org2"), `* Raw Chris Martin note
Chris Martin mentioned an older vendor context.
`, "utf8");
fs.writeFileSync(path.join(meetingsDir, "2026-05-19.org2"), `#+title: Daily

* Meeting with Chris Martin :work:
SCHEDULED: <2026-05-19 Tue>
We talked with Chris Martin about timeline risks.

** Sibling detail
This sibling should stay inside the meeting subtree.

* Other
Chris Martin appears here but is a separate subtree.
`, "utf8");
fs.writeFileSync(path.join(meetingsDir, "undated.org2"), `* TODO Follow-up with Chris Martin :work:
<2026-05-20 Wed>
Chris Martin asked for a cited recap.

* Later unrelated
No matching text here.
`, "utf8");

const subtreeJson = run(
  "query",
  "Chris Martin",
  "--dir",
  tmp,
  "--recursive",
  "--subtree",
  "--sort",
  "date-desc",
  "--date-from",
  "2026-05-19",
  "--file-zone",
  "meetings",
  "--format",
  "json",
);
const subtreePayload = JSON.parse(subtreeJson);
assert.equal(subtreePayload.$schema, "org2:search:v1");
assert.equal(subtreePayload.mode, "subtree");
assert.equal(subtreePayload.results.length, 3);
assert.equal(subtreePayload.results[0].heading, "Follow-up with Chris Martin");
assert.equal(subtreePayload.results[0].date, "2026-05-20");
assert.deepEqual(subtreePayload.results[0].sourceRange, { startLine: 1, endLine: 4 });
assert.equal(subtreePayload.results[0].matchedLines[0].line, 1);
assert.equal(subtreePayload.results[1].heading, "Meeting with Chris Martin");
assert.equal(subtreePayload.results[1].date, "2026-05-19");
assert.deepEqual(subtreePayload.results[1].headingAncestry.map((h) => h.title), ["Meeting with Chris Martin"]);
assert.match(subtreePayload.results[1].context.lines.join("\n"), /Sibling detail/);
assert.equal(subtreePayload.results[2].heading, "Other");
assert.ok(subtreePayload.results.every((r) => r.file.includes(`${path.sep}meetings${path.sep}`)));
assert.ok(!subtreePayload.results.some((r) => r.file.includes(`${path.sep}raw${path.sep}`)));

const answerContextJson = run("query", "cited recap", "--file", path.join(meetingsDir, "undated.org2"), "--answer-context", "--format", "json");
const answerContextPayload = JSON.parse(answerContextJson);
assert.match(answerContextPayload.results[0].answerContext, /Follow-up with Chris Martin/);
