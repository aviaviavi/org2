import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { PassThrough } from "node:stream";
import {
  AI_CHAT_INBOX_SCHEMA,
  queueAIChatInboxMessage,
} from "../dist/aiChatInbox.js";
import { serveMcp } from "../dist/mcpRuntime.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-ai-chat-inbox-"));
const transcript = path.join(root, ".org2", "openclaw-chat.json");
const threadID = "00000000-0000-4000-8000-000000000001";
const storedThreadID = threadID.toUpperCase();

try {
  fs.mkdirSync(path.dirname(transcript), { recursive: true });
  fs.writeFileSync(transcript, `${JSON.stringify({
    version: 6,
    selectedThreadID: storedThreadID,
    threads: [{
      id: storedThreadID,
      title: "Background delivery",
      createdAt: 0,
      updatedAt: 0,
      sessionKey: "agent:main:background",
      messages: [],
    }],
  }, null, 2)}\n`);

  const preview = queueAIChatInboxMessage(root, threadID, "  Finished the background export.  ", {
    authorLabel: "Revenue Scout",
    authorAgentRef: "agent-profile-revenue-scout",
    source: "run:export-42",
    idempotencyKey: "export-42-complete",
    now: new Date("2026-08-19T12:00:00Z"),
  });
  assert.equal(preview.applied, false);
  assert.equal(preview.changed, true);
  assert.equal(fs.existsSync(preview.file), false);
  assert.equal(preview.message.schema, AI_CHAT_INBOX_SCHEMA);
  assert.equal(preview.message.threadID, threadID);
  assert.equal(preview.message.content, "Finished the background export.");

  const applied = queueAIChatInboxMessage(root, threadID, preview.message.content, {
    authorLabel: preview.message.authorLabel,
    authorAgentRef: preview.message.authorAgentRef,
    source: preview.message.source,
    idempotencyKey: "export-42-complete",
    apply: true,
    now: new Date("2026-08-19T12:00:00Z"),
  });
  assert.equal(applied.applied, true);
  assert.equal(fs.existsSync(applied.file), true);
  assert.deepEqual(JSON.parse(fs.readFileSync(applied.file, "utf8")), applied.message);

  const duplicate = queueAIChatInboxMessage(root, threadID, applied.message.content, {
    authorLabel: applied.message.authorLabel,
    authorAgentRef: applied.message.authorAgentRef,
    source: applied.message.source,
    idempotencyKey: "export-42-complete",
    apply: true,
  });
  assert.equal(duplicate.applied, false);
  assert.equal(duplicate.changed, false);
  assert.equal(duplicate.message.id, applied.message.id);

  assert.throws(
    () => queueAIChatInboxMessage(root, "missing", "No destination"),
    /unknown OpenClaw thread/,
  );
  assert.throws(
    () => queueAIChatInboxMessage(root, threadID, "No author"),
    /author or agent ref is required/,
  );

  const cliPreview = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"),
    "thread", "post", threadID,
    "--message", "CLI background result",
    "--author", "Codex worker",
    "--idempotency-key", "cli-background-result",
    "--dir", root,
    "--json",
  ], { encoding: "utf8" });
  assert.equal(cliPreview.status, 0, cliPreview.stderr);
  const cliResult = JSON.parse(cliPreview.stdout);
  assert.equal(cliResult.applied, false);
  assert.equal(cliResult.message.authorLabel, "Codex worker");
  assert.equal(fs.existsSync(cliResult.file), false);

  const input = new PassThrough();
  const output = new PassThrough();
  let responseText = "";
  output.setEncoding("utf8");
  output.on("data", (chunk) => { responseText += chunk; });
  const serving = serveMcp(root, input, output);
  input.end(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "tools/call",
    params: {
      name: "org2_thread_post",
      arguments: {
        threadId: threadID,
        message: "MCP background result",
        author: "Workflow worker",
        agentRef: "agent-profile-workflow-worker",
        idempotencyKey: "mcp-background-result",
      },
    },
  })}\n`);
  await serving;
  const mcpResponse = JSON.parse(responseText.trim());
  assert.equal(mcpResponse.id, 1);
  const queued = JSON.parse(mcpResponse.result.content[0].text);
  assert.equal(queued.applied, true);
  assert.equal(queued.message.authorAgentRef, "agent-profile-workflow-worker");
  assert.equal(fs.existsSync(queued.file), true);

  console.log("AI chat inbox tests passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
