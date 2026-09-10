import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import {
  appleReferenceDateSeconds,
  autoSettleOpenClawThreads,
  configureOpenClawThreadSettlement,
  isOpenClawThreadSettled,
  loadOpenClawThreadState,
  reopenOpenClawThread,
  settleOpenClawThread,
} from "../dist/openClawThreadState.js";
import { aiChatOperationDirectory } from "../dist/aiChatOperationJournal.js";
import {
  encodedJSON,
  sha256,
  writeShardedV2Store,
} from "./helpers/ai-chat-sharded-fixture.mjs";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-openclaw-thread-state-"));
const stateFile = path.join(root, ".org2", "openclaw-chat.json");
const now = new Date("2026-07-25T12:00:00Z");
const old = new Date("2026-07-20T12:00:00Z");
const recent = new Date("2026-07-25T06:00:00Z");
const message = (deliveryStatus = "sent") => ({
  role: "user",
  content: "Keep the full searchable conversation",
  createdAt: appleReferenceDateSeconds(old),
  deliveryStatus,
});
const thread = (id, overrides = {}) => ({
  id,
  title: id,
  createdAt: appleReferenceDateSeconds(old),
  updatedAt: appleReferenceDateSeconds(old),
  sessionKey: `agent:main:${id}`,
  messages: [message()],
  isPinned: false,
  isArchived: false,
  unreadMessageCount: 0,
  ...overrides,
});

try {
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(stateFile, `${JSON.stringify({
    version: 4,
    selectedThreadID: "selected",
    threads: [
      thread("eligible"),
      thread("selected"),
      thread("legacy-settled", { isArchived: true }),
      thread("pinned", { isPinned: true }),
      thread("unread", { unreadMessageCount: 1 }),
      thread("failed", { messages: [message("failed")] }),
      thread("recovered", {
        messages: [
          message("failed"),
          { ...message(), role: "assistant" },
        ],
      }),
      thread("pending", { pendingTurn: { runID: "run-1" } }),
      thread("recent", { updatedAt: appleReferenceDateSeconds(recent) }),
      thread("empty", { messages: [] }),
      thread("codex", {
        runtime: "codex",
        runtimeThreadID: "thr-codex",
        model: "gpt-test",
        reasoningEffort: "high",
      }),
    ],
  }, null, 2)}\n`);
  const originalLegacyBytes = fs.readFileSync(stateFile);

  const legacy = loadOpenClawThreadState(root);
  assert.equal(legacy.version, 4);
  assert.equal(legacy.settlementSettings.autoSettleAfterSeconds, null);
  assert.equal(isOpenClawThreadSettled(legacy.threads.find((item) => item.id === "legacy-settled")), true);

  const preview = configureOpenClawThreadSettlement(root, 86_400);
  assert.equal(preview.changed, true);
  assert.equal(preview.applied, false);
  assert.equal(loadOpenClawThreadState(root).settlementSettings.autoSettleAfterSeconds, null);

  configureOpenClawThreadSettlement(root, 86_400, { apply: true });
  assert.equal(loadOpenClawThreadState(root).settlementSettings.autoSettleAfterSeconds, 86_400);

  const autoPreview = autoSettleOpenClawThreads(root, { now });
  assert.deepEqual(autoPreview.affectedThreadIds, ["eligible", "recovered", "empty", "codex"]);
  assert.equal(isOpenClawThreadSettled(loadOpenClawThreadState(root).threads.find((item) => item.id === "eligible")), false);

  const autoApplied = autoSettleOpenClawThreads(root, { now, apply: true });
  assert.deepEqual(autoApplied.affectedThreadIds, ["eligible", "recovered", "empty", "codex"]);
  const settled = loadOpenClawThreadState(root);
  assert.equal(settled.version, 4);
  for (const id of ["eligible", "recovered", "empty", "codex"]) {
    assert.equal(isOpenClawThreadSettled(settled.threads.find((item) => item.id === id)), true, id);
  }
  const codex = settled.threads.find((item) => item.id === "codex");
  assert.equal(codex.runtime, "codex");
  assert.equal(codex.runtimeThreadID, "thr-codex");
  assert.equal(codex.model, "gpt-test");
  assert.equal(codex.reasoningEffort, "high");
  for (const id of ["selected", "pinned", "unread", "failed", "pending", "recent"]) {
    assert.equal(isOpenClawThreadSettled(settled.threads.find((item) => item.id === id)), false, id);
  }

  const reopened = reopenOpenClawThread(root, "eligible", { apply: true });
  assert.equal(reopened.applied, true);
  assert.equal(isOpenClawThreadSettled(loadOpenClawThreadState(root).threads.find((item) => item.id === "eligible")), false);

  const manuallySettled = settleOpenClawThread(root, "recent", { apply: true, now });
  assert.equal(manuallySettled.applied, true);
  assert.equal(isOpenClawThreadSettled(loadOpenClawThreadState(root).threads.find((item) => item.id === "recent")), true);

  configureOpenClawThreadSettlement(root, null, { apply: true });
  assert.equal(loadOpenClawThreadState(root).settlementSettings.autoSettleAfterSeconds, null);
  assert.deepEqual(
    fs.readFileSync(stateFile),
    originalLegacyBytes,
    "external metadata mutations must never rewrite the transcript monolith",
  );
  assert.ok(fs.readdirSync(aiChatOperationDirectory(root)).length >= 4);

  const cli = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"),
    "thread", "list",
    "--dir", root,
    "--json",
  ], { encoding: "utf8" });
  assert.equal(cli.status, 0, cli.stderr);
  const listed = JSON.parse(cli.stdout);
  const firstSettledIndex = listed.threads.findIndex((item) => isOpenClawThreadSettled(item));
  assert.ok(firstSettledIndex > 0);
  assert.ok(listed.threads.slice(0, firstSettledIndex).every((item) => !isOpenClawThreadSettled(item)));
  assert.ok(listed.threads.slice(firstSettledIndex).every((item) => isOpenClawThreadSettled(item)));

} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

const shardedRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-openclaw-sharded-state-"));
const selectedID = "00000000-0000-4000-8000-000000000101";
const hydratedID = "00000000-0000-4000-8000-000000000102";
const eligibleID = "00000000-0000-4000-8000-000000000103";
const unresolvedID = "00000000-0000-4000-8000-000000000104";
const staleID = "00000000-0000-4000-8000-000000000199";
const metadata = (id, overrides = {}) => ({
  id: id.toUpperCase(),
  title: `Thread ${id.slice(-3)}`,
  createdAt: appleReferenceDateSeconds(old),
  updatedAt: appleReferenceDateSeconds(old),
  runtime: "codex",
  destinationID: "codex",
  sessionKey: `agent:main:${id}`,
  messages: [],
  storedMessageCount: 0,
  storedHasUnresolvedLatestDelivery: false,
  storedLatestDeliveryNeedsAttention: false,
  isPinned: false,
  isArchived: false,
  unreadMessageCount: 0,
  ...overrides,
});

try {
  const fixture = writeShardedV2Store(shardedRoot, {
    commitID: "current-commit",
    generation: 7,
    selectedThreadID: selectedID.toUpperCase(),
    autoSettleAfterSeconds: 86_400,
    legacyPayload: {
      version: 6,
      threads: [metadata(staleID, { title: "Stale legacy only" })],
      selectedThreadID: staleID,
    },
    threads: [
      { metadata: metadata(selectedID) },
      {
        metadata: metadata(hydratedID, { storedMessageCount: 1 }),
        messages: [{
          id: "10000000-0000-4000-8000-000000000102",
          role: "assistant",
          content: "Authoritative sharded history",
          deliveryStatus: "sent",
        }],
      },
      { metadata: metadata(eligibleID) },
      {
        metadata: metadata(unresolvedID, {
          storedMessageCount: 1,
          storedHasUnresolvedLatestDelivery: true,
          storedLatestDeliveryNeedsAttention: true,
        })
      },
    ],
  });
  const originalLegacy = fs.readFileSync(fixture.legacyFile);
  const originalManifest = fs.readFileSync(fixture.manifestFile);
  const originalMarker = fs.readFileSync(fixture.markerFile);

  const state = loadOpenClawThreadState(shardedRoot);
  assert.equal(state.storageLayout, "sharded-v2");
  assert.equal(state.recoveryStatus, "healthy");
  assert.equal(state.commitID, "current-commit");
  assert.equal(state.generation, 7);
  assert.equal(state.threads.some((item) => item.id.toLowerCase() === hydratedID), true);
  assert.equal(state.threads.some((item) => item.id.toLowerCase() === staleID), false);
  assert.deepEqual(
    state.threads.find((item) => item.id.toLowerCase() === hydratedID).messages,
    [],
    "metadata-only list reads must not hydrate every shard",
  );

  const hydrated = loadOpenClawThreadState(shardedRoot, { hydrateThreadID: hydratedID });
  assert.equal(
    hydrated.threads.find((item) => item.id.toLowerCase() === hydratedID).messages[0].content,
    "Authoritative sharded history",
  );

  const listCLI = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "thread", "list", "--dir", shardedRoot, "--json",
  ], { encoding: "utf8" });
  assert.equal(listCLI.status, 0, listCLI.stderr);
  const listed = JSON.parse(listCLI.stdout);
  assert.equal(listed.storageLayout, "sharded-v2");
  assert.equal(listed.threads.some((item) => item.id.toLowerCase() === staleID), false);

  const showCLI = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "thread", "show", hydratedID, "--dir", shardedRoot, "--json",
  ], { encoding: "utf8" });
  assert.equal(showCLI.status, 0, showCLI.stderr);
  assert.equal(JSON.parse(showCLI.stdout).thread.messages[0].content, "Authoritative sharded history");

  const queuedSettlement = settleOpenClawThread(shardedRoot, hydratedID, { apply: true, now });
  assert.equal(queuedSettlement.applied, true);
  assert.equal(queuedSettlement.queued, true);
  assert.equal(queuedSettlement.committed, false);
  assert.equal(queuedSettlement.operation.kind, "settle-thread");
  assert.equal(isOpenClawThreadSettled(
    loadOpenClawThreadState(shardedRoot).threads.find(
      (item) => item.id.toLowerCase() === hydratedID,
    ),
  ), true);
  assert.deepEqual(fs.readFileSync(fixture.legacyFile), originalLegacy);
  assert.deepEqual(fs.readFileSync(fixture.manifestFile), originalManifest);
  assert.deepEqual(fs.readFileSync(fixture.markerFile), originalMarker);

  const auto = autoSettleOpenClawThreads(shardedRoot, { now });
  assert.deepEqual(auto.affectedThreadIds.map((id) => id.toLowerCase()), [eligibleID]);
  assert.equal(auto.affectedThreadIds.some((id) => id.toLowerCase() === unresolvedID), false);

  // A new-corpus compatibility pointer is also immutable. Configuration is a
  // durable operation, never an in-place version-2 -> version-6 rewrite.
  fs.writeFileSync(fixture.legacyFile, fixture.manifestData);
  const pointerBytes = fs.readFileSync(fixture.legacyFile);
  const configured = configureOpenClawThreadSettlement(shardedRoot, 172_800, { apply: true });
  assert.equal(configured.queued, true);
  assert.deepEqual(fs.readFileSync(fixture.legacyFile), pointerBytes);
} finally {
  fs.rmSync(shardedRoot, { recursive: true, force: true });
}

const recoveryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-openclaw-sharded-recovery-"));
try {
  const previous = writeShardedV2Store(recoveryRoot, {
    commitID: "previous-commit",
    generation: 4,
    selectedThreadID: hydratedID,
    threads: [{
      metadata: metadata(hydratedID, { title: "Recovered authoritative thread" }),
      messages: [{ role: "assistant", content: "Previous commit survives" }],
    }],
  });
  const previousName = path.basename(previous.manifestFile);
  const current = writeShardedV2Store(recoveryRoot, {
    commitID: "broken-current-commit",
    generation: 5,
    parentCommitID: "previous-commit",
    previousManifest: previousName,
    previousDigest: sha256(previous.manifestData),
    selectedThreadID: eligibleID,
    legacyPayload: {
      version: 6,
      threads: [metadata(staleID, { title: "Must never be fallback" })],
    },
    threads: [{ metadata: metadata(eligibleID, { title: "Broken current" }) }],
  });
  fs.writeFileSync(current.manifestFile, "corrupt current\n");
  fs.writeFileSync(path.join(current.storeRoot, "manifest.json"), "corrupt current view\n");
  fs.writeFileSync(path.join(current.storeRoot, "manifest.previous.json"), previous.manifestData);

  const recovered = loadOpenClawThreadState(recoveryRoot);
  assert.equal(recovered.recoveryStatus, "recovered-previous-manifest");
  assert.equal(recovered.commitID, "previous-commit");
  assert.equal(recovered.threads[0].title, "Recovered authoritative thread");

  const legacyBytes = fs.readFileSync(current.legacyFile);
  fs.writeFileSync(previous.manifestFile, "corrupt previous\n");
  fs.writeFileSync(path.join(current.storeRoot, "manifest.previous.json"), "corrupt previous view\n");
  assert.throws(
    () => loadOpenClawThreadState(recoveryRoot),
    /stale legacy transcript was not loaded/,
  );
  assert.throws(
    () => configureOpenClawThreadSettlement(recoveryRoot, 60, { apply: true }),
    /stale legacy transcript was not loaded/,
  );
  assert.deepEqual(fs.readFileSync(current.legacyFile), legacyBytes);
  assert.equal(fs.existsSync(aiChatOperationDirectory(recoveryRoot)), false);
} finally {
  fs.rmSync(recoveryRoot, { recursive: true, force: true });
}

const missingShardRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), "org2-openclaw-missing-shard-recovery-"),
);
try {
  const previous = writeShardedV2Store(missingShardRoot, {
    commitID: "complete-previous-commit",
    generation: 8,
    selectedThreadID: hydratedID,
    threads: [{
      metadata: metadata(hydratedID, {
        title: "Complete previous thread",
        storedMessageCount: 1,
      }),
      messages: [{ role: "assistant", content: "Complete previous history" }],
    }],
  });
  const current = writeShardedV2Store(missingShardRoot, {
    commitID: "incomplete-current-commit",
    generation: 9,
    previousManifest: path.basename(previous.manifestFile),
    previousDigest: sha256(previous.manifestData),
    selectedThreadID: hydratedID,
    threads: [{
      metadata: metadata(hydratedID, {
        title: "Incomplete current thread",
        storedMessageCount: 1,
      }),
      messages: [{ role: "assistant", content: "Missing current history" }],
    }],
  });
  fs.rmSync(path.join(current.storeRoot, current.entries[0].shard));

  const recovered = loadOpenClawThreadState(missingShardRoot, { hydrateThreadID: hydratedID });
  assert.equal(recovered.recoveryStatus, "recovered-previous-manifest");
  assert.equal(recovered.commitID, "recovered-complete-previous-commit");
  assert.equal(recovered.threads[0].messages[0].content, "Complete previous history");
} finally {
  fs.rmSync(missingShardRoot, { recursive: true, force: true });
}

const v1Root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-openclaw-sharded-v1-"));
try {
  const storeRoot = path.join(v1Root, ".org2", "openclaw-chat.store");
  const shardFile = path.join(storeRoot, "threads", `${hydratedID}.json`);
  fs.mkdirSync(path.dirname(shardFile), { recursive: true });
  fs.writeFileSync(shardFile, encodedJSON({
    schema: "org2:ai-chat-thread:v1",
    version: 1,
    messages: [{
      message: { role: "assistant", content: "Legacy shard remains readable" },
      attachments: [],
    }],
  }));
  fs.writeFileSync(path.join(storeRoot, "manifest.json"), encodedJSON({
    schema: "org2:ai-chat-transcript-manifest:v1",
    version: 1,
    threads: [metadata(hydratedID, { storedMessageCount: 1 })],
    selectedThreadID: hydratedID,
    settlementSettings: { autoSettleAfterSeconds: null },
  }));
  const state = loadOpenClawThreadState(v1Root, { hydrateThreadID: hydratedID });
  assert.equal(state.storageLayout, "sharded-v1");
  assert.equal(state.threads[0].messages[0].content, "Legacy shard remains readable");
} finally {
  fs.rmSync(v1Root, { recursive: true, force: true });
}

console.log("OpenClaw legacy and sharded thread settlement tests passed");
