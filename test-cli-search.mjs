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
