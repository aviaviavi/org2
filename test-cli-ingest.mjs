import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-cli-ingest-"));
const sourceFile = path.join(root, "source.txt");
fs.writeFileSync(sourceFile, "Project Orion\nDecision: keep captures review gated\nAction item: Ada reviews provenance\n", "utf8");

const dry = spawnSync(process.execPath, ["dist/cli.js", "ingest", "--file", sourceFile, "--corpus", root, "--captured-at", "2026-06-07T18:00:00.000Z"], { encoding: "utf8" });
assert.equal(dry.status, 0, dry.stderr);
assert.match(dry.stdout, /^dry-run:/);
assert.equal(fs.existsSync(path.join(root, "raw")), false, "dry-run must not write raw artifacts");

const applied = spawnSync(process.execPath, ["dist/cli.js", "ingest", "--file", sourceFile, "--corpus", root, "--apply", "--format", "json", "--author", "Ada", "--captured-at", "2026-06-07T18:00:00.000Z"], { encoding: "utf8" });
assert.equal(applied.status, 0, applied.stderr);
const payload = JSON.parse(applied.stdout);
assert.equal(payload.kind, "ingest");
assert.equal(payload.apply, true);
assert.match(payload.rawRef, /^file:source\.txt@sha256:/);
assert.equal(fs.existsSync(payload.rawPath), true);
assert.equal(fs.existsSync(payload.reviewPath), true);

const raw = JSON.parse(fs.readFileSync(payload.rawPath, "utf8"));
assert.equal(raw.sourceType, "file");
assert.equal(raw.sourceRef, `file:${path.resolve(sourceFile)}`);
assert.equal(raw.authors[0], "Ada");
assert.match(raw.contentHash, /^[a-f0-9]{64}$/);

const view = fs.readFileSync(payload.reviewPath, "utf8");
assert.match(view, /:ORG2_REVIEW_STATUS: review-required/);
assert.match(view, /\* Decisions\n- keep captures review gated/);
assert.match(view, /\* TODO candidates\n- Ada reviews provenance/);

const structuredPath = path.join(root, "capture.json");
fs.writeFileSync(structuredPath, JSON.stringify({ sourceType: "meeting", externalId: "structured-1", authors: ["Ben"], content: "Decision: structured JSON works" }), "utf8");
const structured = spawnSync(process.execPath, ["dist/cli.js", "ingest", "--json", structuredPath, "--corpus", root, "--apply", "--format", "json"], { encoding: "utf8" });
assert.equal(structured.status, 0, structured.stderr);
assert.match(JSON.parse(structured.stdout).rawRef, /^meeting:structured-1@sha256:/);

const stdin = spawnSync(process.execPath, ["dist/cli.js", "ingest", "--stdin", "--corpus", root, "--source-type", "note", "--apply", "--format", "json"], { input: "Action item: stdin path works\n", encoding: "utf8" });
assert.equal(stdin.status, 0, stdin.stderr);
assert.match(JSON.parse(stdin.stdout).rawRef, /^note:stdin-[a-f0-9]{12}@sha256:/);

console.log("cli ingest OK");
