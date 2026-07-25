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
    ],
  }, null, 2)}\n`);

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
  assert.deepEqual(autoPreview.affectedThreadIds, ["eligible", "recovered", "empty"]);
  assert.equal(isOpenClawThreadSettled(loadOpenClawThreadState(root).threads.find((item) => item.id === "eligible")), false);

  const autoApplied = autoSettleOpenClawThreads(root, { now, apply: true });
  assert.deepEqual(autoApplied.affectedThreadIds, ["eligible", "recovered", "empty"]);
  const settled = loadOpenClawThreadState(root);
  assert.equal(settled.version, 5);
  for (const id of ["eligible", "recovered", "empty"]) {
    assert.equal(isOpenClawThreadSettled(settled.threads.find((item) => item.id === id)), true, id);
  }
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

  console.log("OpenClaw thread settlement tests passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
