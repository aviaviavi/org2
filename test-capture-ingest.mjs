#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-capture-ingest-test-"));
const target = path.join(tmp, "inbox.org2");
const run = (...args) => execFileSync("node", ["dist/cli.js", ...args], { encoding: "utf8" });

const preview = run("capture", "--text", "Discuss routing model", "--to", target, "--title", "Meeting note", "--author", "Avi", "--now", "2026-05-26T12:00:00.000Z", "--format", "json");
const payload = JSON.parse(preview);
assert.equal(payload.kind, "capture");
assert.equal(payload.file, target);
assert.equal(payload.title, "Meeting note");
assert.equal(payload.source.type, "text");
assert.equal(payload.source.origin, "literal:text");
assert.equal(payload.source.author, "Avi");
assert.match(payload.source.contentHash, /^[a-f0-9]{64}$/);
assert.equal(fs.existsSync(target), false);
assert.match(payload.outText, /:SOURCE_TYPE: text/);
assert.match(payload.outText, /:SOURCE_HASH: [a-f0-9]{64}/);
assert.match(payload.outText, /Discuss routing model/);

run("capture", "--text", "Discuss routing model", "--to", target, "--title", "Meeting note", "--now", "2026-05-26T12:00:00.000Z", "--apply");
const written = fs.readFileSync(target, "utf8");
assert.match(written, /^\* Meeting note/m);
assert.match(written, /CAPTURED: <2026-05-26 Tue 05:00>/);

const sourceFile = path.join(tmp, "transcript.txt");
fs.writeFileSync(sourceFile, "Transcript body\n", "utf8");
const fileCapture = JSON.parse(run("capture", "--file", sourceFile, "--to", target, "--format", "json"));
assert.equal(fileCapture.title, "transcript.txt");
assert.equal(fileCapture.source.type, "file");
assert.equal(fileCapture.source.provenance, `file:${path.resolve(sourceFile)}`);
assert.equal(fileCapture.body, "Transcript body");

const stdinOut = execFileSync("node", ["dist/cli.js", "capture", "--stdin", "--to", target, "--format", "json"], { input: "from stdin\n", encoding: "utf8" });
const stdinPayload = JSON.parse(stdinOut);
assert.equal(stdinPayload.source.type, "stdin");
assert.equal(stdinPayload.source.origin, "stdin");
assert.equal(stdinPayload.body, "from stdin");
