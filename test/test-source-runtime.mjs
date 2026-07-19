import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-source-runtime-"));
const corpus = path.join(tmp, "corpus");
const indexHome = path.join(tmp, "index");
fs.mkdirSync(corpus, { recursive: true });

try {
  fs.writeFileSync(path.join(corpus, "org2.json"), JSON.stringify({
    externalSources: {
      slack: { type: "slack", scopes: ["engineering"], media: "metadata-only" },
      notion: { type: "notion", enabled: false },
    },
  }, null, 2));
  const crawlerConfig = path.join(tmp, "slacrawl.toml");
  fs.writeFileSync(crawlerConfig, "db_path = \"archive.db\"\n");
  const fakeCrawler = path.join(tmp, "fake-crawler");
  fs.writeFileSync(fakeCrawler, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
  fs.chmodSync(fakeCrawler, 0o755);

  const run = (...args) => spawnSync(process.execPath, ["dist/cli.js", "source", ...args, "--dir", corpus, "--json"], {
    cwd: process.cwd(), encoding: "utf8", env: { ...process.env, HOME: tmp, ORG2_INDEX_HOME: indexHome },
  });

  const listed = run("list");
  assert.equal(listed.status, 0, listed.stderr);
  const profiles = JSON.parse(listed.stdout);
  assert.deepEqual(profiles.map((item) => item.id), ["notion", "slack"]);
  assert.equal(profiles.find((item) => item.id === "slack").ready, false);
  assert.equal(run("doctor", "slack").status, 1);

  const missingDir = run("list", "--dir");
  assert.equal(missingDir.status, 1);
  assert.match(missingDir.stderr, /--dir requires a value/);

  const missingBinary = run("bind", "slack", "--binary", "--apply");
  assert.equal(missingBinary.status, 1);
  assert.match(missingBinary.stderr, /--binary requires a value/);

  const unsupportedFormat = run("list", "--format", "text");
  assert.equal(unsupportedFormat.status, 1);
  assert.match(unsupportedFormat.stderr, /source --format must be json/);

  const preview = run("bind", "slack", "--binary", fakeCrawler, "--config", crawlerConfig);
  assert.equal(preview.status, 0, preview.stderr);
  assert.equal(JSON.parse(preview.stdout).applied, false);

  const bound = run("bind", "slack", "--binary", fakeCrawler, "--config", crawlerConfig, "--apply");
  assert.equal(bound.status, 0, bound.stderr);
  const bindingPath = JSON.parse(bound.stdout).bindingPath;
  assert.equal(fs.statSync(bindingPath).mode & 0o777, 0o600);
  assert.equal(bindingPath.startsWith(indexHome), true);

  const healthy = run("doctor", "slack");
  assert.equal(healthy.status, 0, healthy.stderr);
  assert.equal(JSON.parse(healthy.stdout).ok, true);

  const synced = run("sync", "slack");
  assert.equal(synced.status, 0, synced.stderr);
  const result = JSON.parse(synced.stdout).results[0];
  assert.equal(result.ok, true);
  assert.match(result.stdout, /--config/);
  assert.match(result.stdout, /sync/);
  assert.match(result.stdout, /--latest-only/);
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log("✓ source runtime");
