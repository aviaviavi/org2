#!/usr/bin/env node
// `org2 source add` is the one validated write path behind OpenOrg's unified
// source sheet: every supported type (Slack, Notion, email) is created and
// updated through the same contract, and credentials never enter org2.json.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-source-add-"));
const corpus = path.join(tmp, "corpus");
fs.mkdirSync(corpus, { recursive: true });
fs.writeFileSync(path.join(corpus, "org2.json"), JSON.stringify({ corpus: { id: "test" } }, null, 2));
const config = () => JSON.parse(fs.readFileSync(path.join(corpus, "org2.json"), "utf8"));
const run = (...args) => spawnSync(process.execPath, ["dist/cli.js", "source", ...args, "--dir", corpus, "--json"], {
  cwd: process.cwd(), encoding: "utf8", env: { ...process.env, HOME: tmp, ORG2_INDEX_HOME: path.join(tmp, "index") },
});

try {
  const slack = { type: "slack", workspaceId: "T1", syncArgs: ["--source", "bot", "--latest-only"], ingestion: { since: "14d" } };
  const preview = run("add", "slack", "--source-json", JSON.stringify(slack));
  assert.equal(preview.status, 0, preview.stderr);
  assert.equal(JSON.parse(preview.stdout).applied, false);
  assert.equal(config().externalSources, undefined);

  for (const [id, profile] of [
    ["slack", slack],
    ["notion", { type: "notion", scopes: ["Scarf"], syncArgs: ["--source", "api"], ingestion: { since: "30d" } }],
    ["mail", { type: "email", email: { host: "imap.example.com", port: 993, security: "tls", username: "a@example.com", mailboxes: ["INBOX"] } }],
  ]) {
    const added = run("add", id, "--source-json", JSON.stringify(profile), "--apply");
    assert.equal(added.status, 0, added.stderr);
    assert.equal(JSON.parse(added.stdout).created, true);
  }
  assert.deepEqual(Object.keys(config().externalSources).sort(), ["mail", "notion", "slack"]);
  assert.equal(config().corpus.id, "test", "unrelated settings are preserved");

  const listed = JSON.parse(run("list").stdout);
  assert.deepEqual(listed.map((item) => item.type).sort(), ["email", "notion", "slack"]);

  // Re-adding without --update is refused; --update merges and null removes.
  assert.match(run("add", "slack", "--source-json", JSON.stringify(slack), "--apply").stderr, /already exists/);
  const updated = run("add", "slack", "--update", "--source-json", JSON.stringify({ workspaceId: null, ingestion: { since: "7d" } }), "--apply");
  assert.equal(updated.status, 0, updated.stderr);
  assert.equal(config().externalSources.slack.workspaceId, undefined);
  assert.equal(config().externalSources.slack.ingestion.since, "7d");
  assert.deepEqual(config().externalSources.slack.syncArgs, ["--source", "bot", "--latest-only"]);
  assert.match(run("add", "slack", "--update", "--source-json", JSON.stringify({ type: "notion" })).stderr, /cannot change type/);

  // Secrets, unknown keys, and unsupported types are rejected before writing.
  const before = fs.readFileSync(path.join(corpus, "org2.json"), "utf8");
  assert.match(run("add", "n2", "--source-json", JSON.stringify({ type: "notion", token: "x" }), "--apply").stderr, /credentials stay machine-local/);
  assert.match(run("add", "s2", "--source-json", JSON.stringify({ type: "slack", syncArgs: ["--token", "xoxb-123"] }), "--apply").stderr, /looks like a credential/);
  assert.match(run("add", "m2", "--source-json", JSON.stringify({ type: "email", email: { host: "h", username: "u", password: "p" } }), "--apply").stderr, /credentials stay machine-local/);
  assert.match(run("add", "x", "--source-json", JSON.stringify({ type: "discord" }), "--apply").stderr, /type must be one of/);
  assert.match(run("add", "x", "--source-json", JSON.stringify({ type: "slack", colour: 1 }), "--apply").stderr, /unknown key colour/);
  assert.match(run("add", "x", "--source-json", JSON.stringify({ type: "slack", rawZone: "../escape" }), "--apply").stderr, /inside the corpus/);
  assert.match(run("add", "m3", "--source-json", JSON.stringify({ type: "email", email: { host: "imap.example.com" } }), "--apply").stderr, /username is required/);
  assert.equal(fs.readFileSync(path.join(corpus, "org2.json"), "utf8"), before);
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log("✓ source add");
