#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agent-test-"));
const a = path.join(tmp, "alpha.org2");
const b = path.join(tmp, "beta.org2");
fs.writeFileSync(a, `#+title: Alpha File

* Alpha plan :work:
:PROPERTIES:
:ID: alpha-1
:CUSTOM: value
:END:
We decided to ship the retrieval API.
See [[id:beta-1][Beta note]].
`, "utf8");
fs.writeFileSync(b, `#+title: Beta File

* Beta note :ref:
:PROPERTIES:
:ID: beta-1
:END:
Backlink to [[id:alpha-1][Alpha plan]].
`, "utf8");

const runJson = (...args) => JSON.parse(execFileSync("node", ["dist/cli.js", ...args], { encoding: "utf8" }));

const context = runJson("agent", "context", "--query", "retrieval API", "--dir", tmp, "--recursive", "--include", "sources,neighbors,backlinks", "--limit", "5", "--max-chars", "800");
assert.equal(context.$schema, "org2:agent-context:v1");
assert.equal(context.action, "context");
assert.equal(context.results[0].id, "alpha-1");
assert.equal(context.results[0].file, "alpha.org2");
assert.deepEqual(context.results[0].sourceRange, { startLine: 3, endLine: 10 });
assert.equal(context.results[0].properties.CUSTOM, "value");
assert.ok(context.results[0].citation.endsWith("alpha.org2:3-10"));
assert.ok(context.results[0].neighbors.some((n) => n.id === "beta-1" && n.direction === "out"));
assert.ok(context.context.text.includes("Source: alpha.org2:3-10"));
assert.ok(context.context.citations[0].citation.endsWith("alpha.org2:3-10"));

const fetched = runJson("agent", "fetch", "--id", "beta-1", "--dir", tmp, "--include", "backlinks,neighbors");
assert.equal(fetched.results.length, 1);
assert.equal(fetched.results[0].title, "Beta note");
assert.ok(fetched.results[0].backlinks.some((link) => link.sourceId === "alpha-1"));
assert.ok(fetched.results[0].neighbors.some((n) => n.id === "alpha-1" && n.direction === "in"));

const search = runJson("agent", "search", "--query", "work value", "--dir", tmp, "--limit", "1");
assert.equal(search.results.length, 1);
assert.equal(search.results[0].id, "alpha-1");
assert.ok(search.results[0].matchedTerms.includes("work"));
