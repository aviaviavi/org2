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
      slack: {
        type: "slack",
        scopes: ["engineering"],
        media: "metadata-only",
        rawZone: "raw/connectors/slack-test",
        ingestion: { reviewZone: "views/connectors/slack-test", maxItems: 10 },
        schedule: { kind: "interval", everyMinutes: 120 },
      },
      notion: {
        type: "notion",
        scopes: ["Scarf"],
        rawZone: "raw/connectors/notion-test",
        ingestion: { reviewZone: "views/connectors/notion-test", maxItems: 10 },
        schedule: { kind: "daily", time: "02:00", timezone: "America/Los_Angeles" },
      },
    },
  }, null, 2));
  const crawlerConfig = path.join(tmp, "slacrawl.toml");
  fs.writeFileSync(crawlerConfig, "db_path = \"archive.db\"\n");
  const fakeCrawler = path.join(tmp, "fake-crawler");
  fs.writeFileSync(fakeCrawler, `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args.includes("messages")) {
  process.stdout.write(JSON.stringify([
    { workspace_id: "T1", workspace_name: "Scarf", channel_id: "C1", channel_name: "engineering", ts: "1784505600.000001", user_id: "U1", user_name: "Avi", text: "Decision: import this Slack message.\\n* TODO untrusted external heading", thread_ts: "" },
    { workspace_id: "T1", workspace_name: "Scarf", channel_id: "C2", channel_name: "random", ts: "1784505601.000001", user_id: "U2", user_name: "Else", text: "Out of scope.", thread_ts: "" }
  ]));
} else if (args.includes("tui")) {
  process.stdout.write(JSON.stringify([
    { id: "api-page", title: "API page", scope: "Notion", updated_at: "2026-07-20T00:00:00Z", text: "Fresh API content.", fields: { source: "api" } },
    { id: "desktop-scarf", title: "Scarf fallback", scope: "Scarf", updated_at: "2026-07-19T00:00:00Z", text: "Scoped desktop content.", fields: { source: "desktop" } },
    { id: "desktop-other", title: "Other fallback", scope: "Other", updated_at: "2026-07-18T00:00:00Z", text: "Out-of-scope desktop content.", fields: { source: "desktop" } }
  ]));
} else if (args.includes("status")) {
  process.stdout.write(JSON.stringify({ schema_version: "crawlkit.control.v1", summary: "2 messages", last_sync_at: "2026-07-19T00:00:00Z", database_bytes: 42, counts: [{ id: "messages", label: "Messages", value: 2 }] }));
} else if (args.includes("--hang")) {
  setInterval(() => {}, 1000);
} else {
  process.stdout.write(args.join("\\n") + "\\n");
}
`);
  fs.chmodSync(fakeCrawler, 0o755);

  const run = (...args) => spawnSync(process.execPath, ["dist/cli.js", "source", ...args, "--dir", corpus, "--json"], {
    cwd: process.cwd(), encoding: "utf8", env: { ...process.env, HOME: tmp, ORG2_INDEX_HOME: indexHome },
  });

  const listed = run("list");
  assert.equal(listed.status, 0, listed.stderr);
  const profiles = JSON.parse(listed.stdout);
  assert.deepEqual(profiles.map((item) => item.id), ["notion", "slack"]);
  assert.equal(profiles.find((item) => item.id === "slack").ready, false);
  assert.deepEqual(profiles.find((item) => item.id === "slack").syncArgs, ["--source", "api", "--latest-only"]);
  assert.deepEqual(profiles.find((item) => item.id === "slack").schedule, {
    enabled: true,
    kind: "interval",
    everyMinutes: 120,
    timezone: "local",
  });
  assert.deepEqual(profiles.find((item) => item.id === "notion").schedule, {
    enabled: true,
    kind: "daily",
    time: "02:00",
    timezone: "America/Los_Angeles",
  });
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

  const status = run("status", "slack");
  assert.equal(status.status, 0, status.stderr);
  assert.equal(JSON.parse(status.stdout).sources[0].crawlerStatus.summary, "2 messages");

  const importPreview = run("import", "slack", "--since", "2026-07-01T00:00:00Z");
  assert.equal(importPreview.status, 0, importPreview.stderr);
  const previewImport = JSON.parse(importPreview.stdout).results[0].imported;
  assert.equal(previewImport.apply, false);
  assert.equal(previewImport.acceptedCount, 1);
  assert.equal(fs.existsSync(path.join(corpus, "raw", "connectors", "slack-test")), false);

  const imported = run("import", "slack", "--since", "2026-07-01T00:00:00Z", "--apply");
  assert.equal(imported.status, 0, imported.stderr);
  const appliedImport = JSON.parse(imported.stdout).results[0].imported;
  assert.equal(appliedImport.apply, true);
  assert.equal(appliedImport.groupCount, 1);
  assert.equal(fs.existsSync(appliedImport.files[0].rawPath), true);
  assert.equal(fs.existsSync(appliedImport.files[0].reviewPath), true);
  const reviewPacket = fs.readFileSync(appliedImport.files[0].reviewPath, "utf8");
  assert.match(reviewPacket, /: Decision: import this Slack message/);
  assert.match(reviewPacket, /: \* TODO untrusted external heading/);
  assert.doesNotMatch(reviewPacket, /\n\* TODO untrusted external heading/);

  const staleRaw = path.join(corpus, "raw", "connectors", "slack-test", "stale.json");
  const staleReview = path.join(corpus, "views", "connectors", "slack-test", "stale.org2");
  fs.writeFileSync(staleRaw, JSON.stringify({ schema: "org2:source-import:v1", profile: "slack", sourceType: "slack" }));
  fs.writeFileSync(staleReview, ":ORG2_GENERATOR: org2-source-import\n");

  const repeated = run("import", "slack", "--since", "2026-07-01T00:00:00Z", "--apply");
  assert.equal(repeated.status, 0, repeated.stderr);
  const repeatedImport = JSON.parse(repeated.stdout).results[0].imported;
  assert.equal(repeatedImport.changedFileCount, 0);
  assert.equal(repeatedImport.removedFileCount, 2);
  assert.equal(fs.existsSync(staleRaw), false);
  assert.equal(fs.existsSync(staleReview), false);

  const notionBound = run("bind", "notion", "--binary", fakeCrawler, "--config", crawlerConfig, "--apply");
  assert.equal(notionBound.status, 0, notionBound.stderr);
  const notionImport = run("import", "notion", "--apply");
  assert.equal(notionImport.status, 0, notionImport.stderr);
  const notionApplied = JSON.parse(notionImport.stdout).results[0].imported;
  assert.equal(notionApplied.acceptedCount, 2);
  const notionRaw = notionApplied.files.map((file) => fs.readFileSync(file.rawPath, "utf8")).join("\n");
  assert.match(notionRaw, /api-page/);
  assert.match(notionRaw, /desktop-scarf/);
  assert.doesNotMatch(notionRaw, /desktop-other/);

  const synced = run("sync", "slack");
  assert.equal(synced.status, 0, synced.stderr);
  const result = JSON.parse(synced.stdout).results[0];
  assert.equal(result.ok, true);
  assert.match(result.stdout, /--config/);
  assert.match(result.stdout, /sync/);
  assert.match(result.stdout, /--latest-only/);

  const sourceLockDir = path.join(path.dirname(bindingPath), "source-slack.lock");
  fs.mkdirSync(sourceLockDir);
  const concurrentSync = run("sync", "slack");
  assert.equal(concurrentSync.status, 0, concurrentSync.stderr);
  assert.deepEqual(JSON.parse(concurrentSync.stdout).results[0], {
    id: "slack",
    ok: true,
    skipped: true,
    reason: "sync-in-progress",
    message: "Sync already in progress on this machine.",
  });
  assert.equal(fs.existsSync(sourceLockDir), true, "a fresh lock must not be stolen during owner metadata startup");

  const lockOwnerPath = path.join(sourceLockDir, "owner.json");
  const lockOwner = {
    schema: "org2:source-sync-lock:v1",
    token: "test-owner",
    pid: process.pid,
    sourceId: "slack",
    corpusRoot: corpus,
    hostname: os.hostname(),
    startedAt: new Date().toISOString(),
    timeoutMs: 30 * 60_000,
  };
  fs.writeFileSync(lockOwnerPath, JSON.stringify(lockOwner));
  const staleLockTime = new Date(Date.now() - 60_000);
  fs.utimesSync(sourceLockDir, staleLockTime, staleLockTime);
  const liveOwnerSync = run("sync", "slack");
  assert.equal(liveOwnerSync.status, 0, liveOwnerSync.stderr);
  assert.equal(JSON.parse(liveOwnerSync.stdout).results[0].reason, "sync-in-progress");
  assert.equal(fs.existsSync(sourceLockDir), true, "a live owner must retain its lock");

  lockOwner.pid = 2_147_483_647;
  fs.writeFileSync(lockOwnerPath, JSON.stringify(lockOwner));
  fs.utimesSync(sourceLockDir, staleLockTime, staleLockTime);
  const recoveredSync = run("sync", "slack");
  assert.equal(recoveredSync.status, 0, recoveredSync.stderr);
  const recoveredResult = JSON.parse(recoveredSync.stdout).results[0];
  assert.equal(recoveredResult.ok, true);
  assert.equal(recoveredResult.recoveredStaleLock, true);
  assert.equal(fs.existsSync(sourceLockDir), false, "a recovered sync must release its owned lock");

  const timeoutConfig = JSON.parse(fs.readFileSync(path.join(corpus, "org2.json"), "utf8"));
  timeoutConfig.externalSources.slack.syncArgs = ["--hang"];
  fs.writeFileSync(path.join(corpus, "org2.json"), JSON.stringify(timeoutConfig, null, 2));
  const timedOut = run("sync", "slack", "--timeout", "0.05");
  assert.equal(timedOut.status, 1, timedOut.stderr);
  assert.match(JSON.parse(timedOut.stdout).results[0].error, /timed out after 0\.05 seconds/);

  delete timeoutConfig.externalSources.slack.syncArgs;
  fs.writeFileSync(path.join(corpus, "org2.json"), JSON.stringify(timeoutConfig, null, 2));
  const retryAfterTimeout = run("sync", "slack");
  assert.equal(retryAfterTimeout.status, 0, retryAfterTimeout.stderr);

  const invalidLimit = run("import", "slack", "--limit", "0");
  assert.equal(invalidLimit.status, 1);
  assert.match(invalidLimit.stderr, /positive integer/);

  const invalidConfig = JSON.parse(fs.readFileSync(path.join(corpus, "org2.json"), "utf8"));
  invalidConfig.externalSources.slack.schedule = { kind: "daily", time: "25:00" };
  fs.writeFileSync(path.join(corpus, "org2.json"), JSON.stringify(invalidConfig, null, 2));
  const invalidSchedule = run("list");
  assert.equal(invalidSchedule.status, 1);
  assert.match(invalidSchedule.stderr, /daily schedule requires time in HH:MM form/);
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log("✓ source runtime");
