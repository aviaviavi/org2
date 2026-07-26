import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { approvalMaterialDigest } from "../lib/approval-effects.js";
import {
  createGmailDraftSendTool,
  resolveCanonicalGogExecutable,
} from "../lib/gmail-draft-send-tool.js";

function base64url(value) {
  return Buffer.from(value, "utf8").toString("base64url");
}

function draftPayload() {
  return JSON.stringify({
    draft: {
      message: {
        id: "draft-message-1",
        threadId: "thread-1",
        payload: {
          mimeType: "text/plain",
          headers: [
            { name: "From", value: "Owner <owner@example.com>" },
            { name: "To", value: "person@example.com" },
            { name: "Subject", value: "Approved update" },
          ],
          body: { data: base64url("Exact body") },
        },
      },
    },
  });
}

function rawPayload(body = "Exact body") {
  return JSON.stringify({
    raw: base64url([
      "From: Owner <owner@example.com>",
      "To: person@example.com",
      "Subject: Approved update",
      "Content-Type: text/plain; charset=utf-8",
      "",
      body,
    ].join("\r\n")),
  });
}

function isProfileCall(args) {
  return args[0] === "api"
    && args[1] === "call"
    && args[4] === "gmail.users.getProfile";
}

function profilePayload() {
  return JSON.stringify({ emailAddress: "Owner@Example.COM" });
}

function accountResolutionResponse(args) {
  if (args[0] === "auth" && args[1] === "alias" && args[2] === "list") {
    return {
      stdout: JSON.stringify({
        aliases: {
          work: "owner@example.com",
          primary: "OWNER@EXAMPLE.COM",
        },
      }),
    };
  }
  if (args[0] === "auth" && args[1] === "list") {
    return {
      stdout: JSON.stringify({
        accounts: [{ email: "owner@example.com" }],
      }),
    };
  }
  if (isProfileCall(args)) return { stdout: profilePayload() };
  return null;
}

test("typed sender binds final params, reserves, executes one canonical command, and records the receipt", async () => {
  const calls = [];
  let reserved;
  let recorded;
  const lifecycle = {
    reserveDraftSend: async (effect, details) => { reserved = { effect, details }; },
    recordDraftSent: async (effect, details) => { recorded = { effect, details }; },
  };
  const tool = createGmailDraftSendTool({
    lifecycle,
    gogExecutable: "/configured/gog",
    realpath: async (path) => {
      assert.equal(path, "/configured/gog");
      return "/canonical/gog";
    },
    execFile: async (command, args) => {
      calls.push({ command, args });
      const accountResolution = accountResolutionResponse(args);
      if (accountResolution) return accountResolution;
      if (args[1] === "drafts" && args[2] === "get") return { stdout: draftPayload() };
      if (args[1] === "raw") return { stdout: rawPayload() };
      if (args[0] === "api" && args[1] === "call") {
        const bodyArg = args[args.indexOf("--body") + 1];
        const body = JSON.parse(await readFile(bodyArg.slice(1), "utf8"));
        assert.equal(Buffer.from(body.raw, "base64url").toString("utf8").endsWith("\r\nExact body"), true);
        assert.equal(body.threadId, "thread-1");
        return { stdout: JSON.stringify({ id: "provider-message-1", threadId: "thread-1" }) };
      }
      throw new Error(`unexpected gog call: ${args.join(" ")}`);
    },
  });

  const output = await tool.execute("tool-call-1", {
    account: "work",
    draftId: "draft-1",
  });
  assert.equal(output.details.messageId, "provider-message-1");
  assert.equal(output.details.threadId, "thread-1");
  assert.equal(output.details.account, "owner@example.com");
  assert.equal(reserved.details.toolCallId, "tool-call-1");
  assert.equal(recorded.details.toolCallId, "tool-call-1");
  assert.equal(recorded.details.externalId, "provider-message-1");
  assert.equal(reserved.effect.material.runtimeTarget.id, reserved.effect.key);
  assert.match(JSON.parse(reserved.effect.material.content).rawSha256, /^sha256:[a-f0-9]{64}$/);
  assert.equal(
    reserved.effect.materialDigest,
    approvalMaterialDigest(reserved.effect.material),
  );
  assert.deepEqual(calls.map((call) => call.command), [
    "/canonical/gog",
    "/canonical/gog",
    "/canonical/gog",
    "/canonical/gog",
    "/canonical/gog",
    "/canonical/gog",
    "/canonical/gog",
  ]);
  assert.deepEqual(calls[2].args.slice(0, 5), [
    "api", "call", "gmail", "v1", "gmail.users.getProfile",
  ]);
  assert.equal(calls[2].args[calls[2].args.indexOf("--account") + 1], "owner@example.com");
  assert.deepEqual(calls[6].args.slice(0, 7), [
    "api", "call", "gmail", "v1", "gmail.users.messages.send",
    "--params", JSON.stringify({ userId: "me" }),
  ]);
  assert.deepEqual(calls[6].args.slice(-6), [
    "--allow-write", "--force",
    "--account", "owner@example.com",
    "--json", "--no-input",
  ]);
  assert.equal(output.details.draftRetained, true);
});

test("two account aliases for one mailbox share one authorization and therefore one provider send", async () => {
  let reservation;
  let sends = 0;
  const effectKeys = [];
  const lifecycle = {
    reserveDraftSend: async (effect, { toolCallId }) => {
      effectKeys.push(effect.key);
      await new Promise((resolve) => setTimeout(resolve, 5));
      if (reservation) throw new Error("unresolved effect reservation");
      reservation = toolCallId;
    },
    recordDraftSent: async () => {},
  };
  const tool = createGmailDraftSendTool({
    lifecycle,
    realpath: async () => "/canonical/gog",
    execFile: async (_command, args) => {
      const accountResolution = accountResolutionResponse(args);
      if (accountResolution) return accountResolution;
      if (args[1] === "drafts" && args[2] === "get") return { stdout: draftPayload() };
      if (args[1] === "raw") return { stdout: rawPayload() };
      sends += 1;
      return { stdout: JSON.stringify({ id: `provider-${sends}`, threadId: "thread-1" }) };
    },
  });
  const outcomes = await Promise.allSettled([
    tool.execute("tool-a", { account: "work", draftId: "draft-1" }),
    tool.execute("tool-b", { account: "PRIMARY", draftId: "draft-1" }),
  ]);
  assert.equal(outcomes.filter((item) => item.status === "fulfilled").length, 1);
  assert.equal(outcomes.filter((item) => item.status === "rejected").length, 1);
  assert.equal(sends, 1);
  assert.deepEqual([...new Set(effectKeys)], ["gmail:gog:owner@example.com:draft-1"]);
});

test("an ambiguous provider result leaves the durable reservation unconsumed", async () => {
  let reservations = 0;
  let receipts = 0;
  const tool = createGmailDraftSendTool({
    lifecycle: {
      reserveDraftSend: async () => { reservations += 1; },
      recordDraftSent: async () => { receipts += 1; },
    },
    realpath: async () => "/canonical/gog",
    execFile: async (_command, args) => {
      const accountResolution = accountResolutionResponse(args);
      if (accountResolution) return accountResolution;
      if (args[1] === "drafts" && args[2] === "get") return { stdout: draftPayload() };
      if (args[1] === "raw") return { stdout: rawPayload() };
      return { stdout: JSON.stringify({ messageId: "one", id: "conflicting-two" }) };
    },
  });
  await assert.rejects(
    tool.execute("tool-uncertain", { account: "owner@example.com", draftId: "draft-1" }),
    /provider message id/,
  );
  assert.equal(reservations, 1);
  assert.equal(receipts, 0);
});

test("a provider thread mismatch leaves the durable reservation unresolved", async () => {
  let reservations = 0;
  let receipts = 0;
  const tool = createGmailDraftSendTool({
    lifecycle: {
      reserveDraftSend: async () => { reservations += 1; },
      recordDraftSent: async () => { receipts += 1; },
    },
    realpath: async () => "/canonical/gog",
    execFile: async (_command, args) => {
      const accountResolution = accountResolutionResponse(args);
      if (accountResolution) return accountResolution;
      if (args[1] === "drafts" && args[2] === "get") return { stdout: draftPayload() };
      if (args[1] === "raw") return { stdout: rawPayload() };
      return {
        stdout: JSON.stringify({
          id: "provider-wrong-thread",
          threadId: "thread-2",
        }),
      };
    },
  });
  await assert.rejects(
    tool.execute("tool-thread-mismatch", {
      account: "owner@example.com",
      draftId: "draft-1",
    }),
    /different thread[\s\S]*reservation remains unresolved/,
  );
  assert.equal(reservations, 1);
  assert.equal(receipts, 0);
});

test("typed sender sends the exact reviewed RFC822 snapshot even if the provider draft changes after reservation", async () => {
  let providerBody = "Exact body";
  let sentBody = "";
  let recorded = false;
  const tool = createGmailDraftSendTool({
    lifecycle: {
      reserveDraftSend: async () => { providerBody = "Changed after review"; },
      recordDraftSent: async () => { recorded = true; },
    },
    realpath: async () => "/canonical/gog",
    execFile: async (_command, args) => {
      const accountResolution = accountResolutionResponse(args);
      if (accountResolution) return accountResolution;
      if (args[1] === "drafts" && args[2] === "get") return { stdout: draftPayload() };
      if (args[1] === "raw") return { stdout: rawPayload(providerBody) };
      const bodyArg = args[args.indexOf("--body") + 1];
      const body = JSON.parse(await readFile(bodyArg.slice(1), "utf8"));
      sentBody = Buffer.from(body.raw, "base64url").toString("utf8");
      return { stdout: JSON.stringify({ id: "provider-exact", threadId: "thread-1" }) };
    },
  });
  await tool.execute("tool-exact", { account: "owner@example.com", draftId: "draft-1" });
  assert.match(sentBody, /\r\nExact body$/);
  assert.doesNotMatch(sentBody, /Changed after review/);
  assert.equal(recorded, true);
});

test("canonical gog resolution rejects relative executables", async () => {
  await assert.rejects(resolveCanonicalGogExecutable("gog", async () => "/canonical/gog"), /absolute/);
});
