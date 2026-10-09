import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { normalizedRequestedResponders, queueAIChatInboxMessage } from "../dist/aiChatInbox.js";
import { loadAIChatOperations } from "../dist/aiChatOperationJournal.js";
import {
  configureOpenClawRoomAgentTurnLimit,
  findOpenClawThread,
  loadOpenClawThreadState,
} from "../dist/openClawThreadState.js";

const cli = path.resolve("dist/cli.js");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-ai-chat-agent-turns-"));
const roomID = "00000000-0000-4000-8000-0000000000a1";
const singleID = "00000000-0000-4000-8000-0000000000a2";

function runCLI(...args) {
  return spawnSync(process.execPath, [cli, ...args, "--dir", root], { encoding: "utf8" });
}

try {
  fs.mkdirSync(path.join(root, ".org2"), { recursive: true });
  fs.writeFileSync(path.join(root, ".org2", "openclaw-chat.json"), `${JSON.stringify({
    version: 6,
    threads: [
      {
        id: roomID.toUpperCase(),
        title: "Room",
        createdAt: 0,
        updatedAt: 0,
        sessionKey: "agent:main:room",
        isSharedRoom: true,
        roomDestinationIDs: ["builtin.codex", "builtin.opencode"],
        messages: [],
      },
      {
        id: singleID.toUpperCase(),
        title: "Single",
        createdAt: 0,
        updatedAt: 0,
        sessionKey: "agent:main:single",
        messages: [],
      },
    ],
  }, null, 2)}\n`);

  // Tokens are normalized to bare, lowercase, de-duplicated agent names.
  assert.deepEqual(
    normalizedRequestedResponders(["@Codex", "opencode,@codex", " builtin.pi "]),
    ["codex", "opencode", "builtin.pi"],
  );
  assert.throws(() => normalizedRequestedResponders(["@bad name"]), /invalid --request-turn agent/);
  assert.throws(
    () => normalizedRequestedResponders(Array.from({ length: 9 }, (_, index) => `agent${index}`)),
    /at most 8 agents/,
  );

  // A post with no request stays context only: the envelope has no responders.
  const contextOnly = queueAIChatInboxMessage(root, roomID, "FYI", { authorLabel: "Worker" });
  assert.equal("requestedResponders" in contextOnly.message, false);
  assert.equal(contextOnly.deliveryStatus, "preview");
  assert.equal(contextOnly.turnStatus, "not-requested");

  const help = runCLI("thread", "post", "--help");
  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /Single-agent chats do not support this flag/);
  assert.match(help.stdout, /Queuing a turn request does not confirm a started turn/);

  const messageOnly = runCLI("thread", "post", singleID, "--message", "FYI", "--author", "Worker");
  assert.equal(messageOnly.status, 0, messageOnly.stderr);
  assert.match(messageOnly.stdout, /No agent turn requested; message delivery only/);

  // The CLI records requested responders and reports them.
  const preview = runCLI(
    "thread", "post", roomID,
    "--message", "Export finished; please review it.",
    "--author", "Export worker",
    "--request-turn", "@codex",
    "--request-turn", "@OpenCode",
    "--idempotency-key", "export-review",
  );
  assert.equal(preview.status, 0, preview.stderr);
  assert.match(preview.stdout, /would queue message for/);
  assert.match(preview.stdout, /Turn request for @codex, @opencode; turn start unconfirmed/);
  assert.match(preview.stdout, /thread wait .* --after .* --until reply/);
  assert.equal(fs.existsSync(path.join(root, ".org2", "ai-chat-inbox")), false);
  const applied = runCLI(
    "thread", "post", roomID,
    "--message", "Export finished; please review it.",
    "--author", "Export worker",
    "--request-turn", "@codex",
    "--request-turn", "@OpenCode",
    "--idempotency-key", "export-review",
    "--apply", "--json",
  );
  assert.equal(applied.status, 0, applied.stderr);
  const queued = JSON.parse(applied.stdout);
  assert.equal(queued.deliveryStatus, "queued");
  assert.equal(queued.turnStatus, "unconfirmed");
  assert.deepEqual(queued.message.requestedResponders, ["codex", "opencode"]);
  assert.deepEqual(JSON.parse(fs.readFileSync(queued.file, "utf8")).requestedResponders, ["codex", "opencode"]);

  // Retrying with a different audience under the same key is a conflict.
  assert.throws(
    () => queueAIChatInboxMessage(root, roomID, "Export finished; please review it.", {
      authorLabel: "Export worker",
      requestedResponders: ["codex"],
      idempotencyKey: "export-review",
      apply: true,
    }),
    /already queues a different message/,
  );

  // Turn requests need a shared room.
  const single = runCLI(
    "thread", "post", singleID,
    "--message", "Wake up",
    "--author", "Worker",
    "--request-turn", "codex",
    "--apply",
  );
  assert.notEqual(single.status, 0);
  assert.match(single.stderr, /needs a shared AI room/);
  assert.match(single.stderr, /No message was queued/);
  assert.match(single.stderr, /send a message in the Celorga app/);
  assert.match(single.stderr, /will not start a turn/);
  assert.equal(fs.readdirSync(path.dirname(queued.file)).length, 1, "rejection must not queue a second envelope");

  for (const request of [["--request-turn"], ["--request-turn="], ["--request-turn", "@"]]) {
    const invalid = runCLI("thread", "post", roomID, "--message", "FYI", "--author", "Worker", ...request);
    assert.notEqual(invalid.status, 0);
    assert.match(invalid.stderr, /requires a shared-room agent destination ID or @mention/);
  }

  // The per-room agent turn limit is configurable through the operation journal.
  const limitPreview = runCLI("thread", "configure", roomID, "--agent-turn-limit", "2");
  assert.equal(limitPreview.status, 0, limitPreview.stderr);
  assert.match(limitPreview.stdout, /would queue agent turn limit 2/);
  assert.equal(loadAIChatOperations(root).length, 0);
  const limitApplied = runCLI("thread", "configure", roomID, "--agent-turn-limit", "2", "--apply", "--json");
  assert.equal(limitApplied.status, 0, limitApplied.stderr);
  const operations = loadAIChatOperations(root);
  assert.equal(operations.length, 1);
  assert.equal(operations[0].kind, "configure-room-agent-turns");
  assert.equal(operations[0].agentTurnLimit, 2);
  assert.equal(findOpenClawThread(loadOpenClawThreadState(root), roomID).roomAgentTurnLimit, 2);
  assert.equal(configureOpenClawRoomAgentTurnLimit(root, roomID, 2).changed, false);
  const restored = configureOpenClawRoomAgentTurnLimit(root, roomID, null, { apply: true });
  assert.equal(restored.queued, true);
  assert.equal("roomAgentTurnLimit" in findOpenClawThread(loadOpenClawThreadState(root), roomID), false);

  for (const bad of ["-1", "2.5", "51", "lots"]) {
    const result = runCLI("thread", "configure", roomID, "--agent-turn-limit", bad);
    assert.notEqual(result.status, 0, `--agent-turn-limit ${bad} must be rejected`);
  }
  const singleLimit = runCLI("thread", "configure", singleID, "--agent-turn-limit", "3");
  assert.notEqual(singleLimit.status, 0);
  assert.match(singleLimit.stderr, /shared AI rooms/);
  const missingThread = runCLI("thread", "configure", "--agent-turn-limit", "3");
  assert.notEqual(missingThread.status, 0);
  assert.match(missingThread.stderr, /thread id is required/);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

console.log("AI chat agent turn request tests passed");
