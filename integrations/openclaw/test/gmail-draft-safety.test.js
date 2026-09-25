import assert from "node:assert/strict";
import test from "node:test";

import {
  directGogDraftMutation,
  plainTextToHtml,
  suspiciousHardWraps,
  unsafeGmailDraftMutation,
  validateSafeDraft,
} from "../lib/gmail-draft-safety.js";

function encoded(value) {
  return Buffer.from(value, "utf8").toString("base64url");
}

test("blocks direct gog draft creation and update across exec envelopes", () => {
  assert.equal(directGogDraftMutation("exec", { command: "gog gmail drafts create --to x@example.com" }).operation, "create");
  assert.equal(directGogDraftMutation("bash", { cmd: "/usr/local/bin/gog gmail drafts update draft-1 --subject Hi" }).operation, "update");
  assert.equal(directGogDraftMutation("exec", {
    source: `await tools.exec_command({cmd: "/Users/avi/openclaw/slack/scripts/gog-scarf-headless gmail drafts create --to x@example.com"})`,
  }).operation, "create");
  assert.equal(directGogDraftMutation("functions.exec", {
    source: `await tools.exec_command({cmd: "gog gmail drafts update draft-1 --subject Hi"})`,
  }).operation, "update");
  assert.equal(directGogDraftMutation("exec", { command: "node integrations/openclaw/bin/gmail-draft-safe.mjs create --body-file body.txt" }), null);
});

test("blocks Gmail connector draft mutations but not reads, sends, or unrelated drafts", () => {
  assert.equal(unsafeGmailDraftMutation("mcp__gmail__create_draft", {}).operation, "create");
  assert.equal(unsafeGmailDraftMutation("google_mail", { action: "update_draft" }).operation, "update");
  assert.equal(unsafeGmailDraftMutation("mcp__gmail__get_draft", {}), null);
  assert.equal(unsafeGmailDraftMutation("mcp__gmail__send_draft", {}), null);
  assert.equal(unsafeGmailDraftMutation("notion_create_draft", {}), null);
  assert.equal(unsafeGmailDraftMutation("exec", { command: "node integrations/openclaw/bin/gmail-draft-safe.mjs create --body-file body.txt" }), null);
});

test("renders fluid HTML while retaining intentional structure", () => {
  assert.equal(
    plainTextToHtml("Hi Pat,\n\nA long prose paragraph that Gmail should wrap according to the reader's viewport.\n\nThanks,\nAvi"),
    "<p>Hi Pat,</p><p>A long prose paragraph that Gmail should wrap according to the reader's viewport.</p><p>Thanks,<br>Avi</p>",
  );
  assert.equal(plainTextToHtml("- One\n- Two"), "<ul><li>One</li><li>Two</li></ul>");
});

test("rejects hard-wrapped prose but permits signatures and lists", () => {
  assert.notEqual(suspiciousHardWraps("This prose was hard wrapped by an unsafe MIME path at a fixed column\nand the next fragment continued on another physical line.").length, 0);
  assert.deepEqual(suspiciousHardWraps("Thanks,\nAvi"), []);
  assert.deepEqual(suspiciousHardWraps("- One\n- Two"), []);
});

test("requires multipart alternative provider readback with exact fluid content", () => {
  const body = "Hi Pat,\n\nThis stays fluid.\n\nThanks,\nAvi";
  const html = plainTextToHtml(body);
  const payload = {
    mimeType: "multipart/alternative",
    headers: [
      { name: "From", value: "Avi Press <avi@scarf.sh>" },
      { name: "To", value: "pat@example.com" },
      { name: "Subject", value: "Follow-up" },
      { name: "In-Reply-To", value: "<original@example.com>" },
    ],
    parts: [
      { mimeType: "text/plain", body: { data: encoded(body) } },
      { mimeType: "text/html", body: { data: encoded(html) } },
    ],
  };
  const result = { draft: { message: { threadId: "thread-1", payload } } };
  assert.deepEqual(validateSafeDraft(result, {
    account: "avi@scarf.sh",
    to: "pat@example.com",
    subject: "Follow-up",
    body,
    html,
    threadId: "thread-1",
    anchorMessageId: "<original@example.com>",
  }), []);
  assert.notEqual(validateSafeDraft({ draft: { message: { payload: { ...payload, parts: payload.parts.slice(0, 1) } } } }).length, 0);
});
