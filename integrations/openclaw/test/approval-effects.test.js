import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { access, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import {
  approvalMaterialDigest,
  canonicalJson,
  compareUtf8,
  draftCreatedEffect,
  draftSendEffect,
  hydrateGogDraftEffect,
  inspectOutboundEmailCommand,
  resolveGogAccountIdentity,
  reviewContent,
  sameApprovalMaterial,
  strictProviderGmailSendReceipt,
  strictProviderMessageId,
} from "../lib/approval-effects.js";

function base64url(value) {
  return Buffer.from(value, "utf8").toString("base64url");
}

function sha256(value) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

function effect() {
  return {
    key: "gmail:gog:owner@example.com:draft-1",
    provider: "gmail:gog",
    account: "owner@example.com",
    draftId: "draft-1",
  };
}

test("recognizes only explicit single gog Gmail draft commands with an account", () => {
  const created = draftCreatedEffect(
    "exec_command",
    { cmd: "gog gmail drafts create --account owner@example.com --to person@example.com --subject Update --body Hello" },
    JSON.stringify({ draftId: "draft-1" }),
  );
  assert.equal(created.key, "gmail:gog:owner@example.com:draft-1");
  assert.equal(draftSendEffect("exec", {
    command: "gog gmail drafts send draft-1 --account owner@example.com",
  }).draftId, "draft-1");
  assert.equal(draftCreatedEffect("exec", {
    command: "gh api graphql -f query='mutation CreateDraft { id }'",
  }, JSON.stringify({ id: "not-a-mail-draft" })), null);
  assert.equal(draftSendEffect("exec", { command: "node send-draft-report.mjs" }), null);
  assert.equal(draftSendEffect("exec", { command: "gog gmail drafts send draft-1" }), null);
  assert.equal(inspectOutboundEmailCommand("exec", {
    command: "gog gmail drafts send draft-1",
  }).kind, "blocked");
  assert.equal(inspectOutboundEmailCommand("exec", {
    command: "printf '%s' 'gog gmail drafts send fake-id --account nobody@example.com'",
  }).kind, "none");
});

test("normalizes only the official gog Gmail draft aliases", () => {
  const variants = [
    "gog mail draft post draft-1 -a owner@example.com",
    "gog email drafts deliver draft-1 --account=owner@example.com --json",
    "gog gmail draft send draft-1 -a=owner@example.com --no-input",
  ];
  for (const source of variants) {
    const inspection = inspectOutboundEmailCommand("exec_command", { cmd: source });
    assert.equal(inspection.kind, "send", source);
    assert.equal(inspection.effect.account, "owner@example.com", source);
    assert.equal(inspection.effect.draftId, "draft-1", source);
  }
  assert.equal(draftCreatedEffect(
    "exec",
    { command: "gog email draft new -a owner@example.com --to person@example.com --subject Hi --body-html '<p>Hello</p>'" },
    JSON.stringify({ draft: { id: "draft-2" } }),
  ).draftId, "draft-2");
  assert.equal(draftCreatedEffect(
    "exec",
    { command: "gog mail drafts edit draft-2 --account owner@example.com --reply-to-message-id message-1 --body Updated --subject Hi" },
    JSON.stringify({ id: "draft-2", message: { id: "message-2" } }),
  ).draftId, "draft-2");
  const canonicalBinary = inspectOutboundEmailCommand("exec", {
    command: "/usr/local/bin/gog gmail drafts send draft-1 --account owner@example.com",
  });
  assert.equal(canonicalBinary.kind, "send");
  assert.equal(canonicalBinary.effect.gogExecutable, "/usr/local/bin/gog");
  assert.equal(inspectOutboundEmailCommand("exec", {
    command: "/tmp/gog gmail drafts send draft-1 --account owner@example.com",
  }).kind, "blocked");
  assert.equal(inspectOutboundEmailCommand("exec", {
    command: "gog gmail messages send message-1 --account owner@example.com",
  }).kind, "blocked");
});

test("rejects compound, expanded, aliased, and alternate outbound email commands", () => {
  const blocked = [
    "gog gmail drafts create --account owner@example.com --to person@example.com --subject Hi --body Hello && gog gmail drafts send draft-1 --account owner@example.com",
    "gog gmail drafts update draft-1 --account owner@example.com --body Changed; gog gmail drafts send draft-1 --account owner@example.com",
    "gog gmail drafts send \"$DRAFT_ID\" --account owner@example.com",
    "alias gsend='gog gmail drafts send'; gsend draft-1 --account owner@example.com",
    "bash -c 'gog gmail drafts send draft-1 --account owner@example.com'",
    "python3 -c 'run(\"gog gmail drafts send draft-1 --account owner@example.com\")'",
    "gog gmail send --to person@example.com --account owner@example.com --body Hello",
    "sendmail person@example.com",
    "curl -X POST https://gmail.googleapis.com/gmail/v1/users/me/drafts/send",
    "curl -X POST https://www.googleapis.com/gmail/v1/users/me/drafts/send",
    "gog api call gmail v1 gmail.users.messages.send --params '{\"userId\":\"me\"}' --body @message.json --allow-write --force --account owner@example.com",
    "gog api call gmail v1 gmail.users.messages.send --body @message.json --account owner@example.com && printf done",
    "/tmp/harmless gmail drafts send draft-1 --account owner@example.com",
    "/tmp/renamed-binary mail draft deliver draft-1 --account owner@example.com",
    "node gmail-send.mjs",
  ];
  for (const source of blocked) {
    const inspection = inspectOutboundEmailCommand("exec_command", { cmd: source });
    assert.equal(inspection.kind, "blocked", source);
    assert.equal(draftSendEffect("exec_command", { cmd: source }), null, source);
    assert.equal(
      draftCreatedEffect("exec_command", { cmd: source }, JSON.stringify({ draftId: "draft-1" })),
      null,
      source,
    );
  }
  assert.equal(inspectOutboundEmailCommand("exec_command", {
    command: "printf safe",
    cmd: "gog gmail drafts send draft-1 --account owner@example.com",
  }).kind, "blocked");
  assert.equal(draftCreatedEffect(
    "exec_command",
    { cmd: "gog gmail drafts create --account owner@example.com --to person@example.com --subject Hi --body Hello" },
    JSON.stringify({ id: "message-not-draft" }),
  ), null);
});

test("hydrates exact Gmail review material before an approval can exist", async () => {
  const draftJson = JSON.stringify({
    draft: {
      message: {
        id: "message-1",
        threadId: "thread-1",
        payload: {
          mimeType: "text/plain",
          headers: [
            { name: "To", value: "person@example.com" },
            { name: "Cc", value: "copy@example.com" },
            { name: "Subject", value: "Readable update" },
          ],
          body: { data: base64url("Hello there.\n") },
        },
      },
    },
  });
  const exact = await hydrateGogDraftEffect(effect(), {
    resolveAccountIdentity: async () => "owner@example.com",
    execFile: async (_command, args) => {
      if (args[1] === "raw") {
        return { stdout: JSON.stringify({ raw: base64url("To: person@example.com\r\nSubject: Readable update\r\n\r\nHello there.\n") }) };
      }
      assert.deepEqual(args, [
        "gmail", "drafts", "get", "draft-1",
        "--account", "owner@example.com",
        "--json", "--no-input",
      ]);
      return { stdout: draftJson };
    },
  });
  assert.match(exact.reviewContent, /Account: owner@example\.com/);
  assert.match(exact.reviewContent, /To: person@example\.com\nCc: copy@example\.com/);
  assert.match(exact.reviewContent, /Subject: Readable update/);
  assert.match(exact.reviewContent, /MIME-Type: text\/plain[\s\S]*Hello there\./);
  assert.equal(exact.material.kind, "message");
  assert.equal(exact.material.runtimeTarget.id, "gmail:gog:owner@example.com:draft-1");
  assert.match(JSON.parse(exact.material.content).rawSha256, /^sha256:[a-f0-9]{64}$/);
  assert.match(exact.materialDigest, /^sha256:[a-f0-9]{64}$/);
  assert.equal(exact.materialDigest, approvalMaterialDigest(exact.material));
  assert.equal(sameApprovalMaterial(exact.material, { ...exact.material }), true);
  assert.equal(sameApprovalMaterial(exact.material, { ...exact.material, content: "changed" }), false);
});

async function hydrateFixture(overrides = {}) {
  const attachmentBytes = Buffer.from(overrides.attachment ?? "attachment-v1", "utf8");
  let attachmentOutput = "";
  const draftJson = JSON.stringify({
    draft: {
      message: {
        id: "message-1",
        threadId: overrides.threadId ?? "thread-1",
        payload: {
          mimeType: "multipart/mixed",
          headers: [
            { name: "From", value: overrides.from ?? "Owner <owner@example.com>" },
            { name: "Sender", value: "delegated@example.com" },
            { name: "Reply-To", value: overrides.replyTo ?? "replies@example.com" },
            { name: "To", value: overrides.to ?? "person@example.com" },
            { name: "Cc", value: "copy@example.com" },
            { name: "Bcc", value: "audit@example.com" },
            { name: "Subject", value: "Complete update" },
            { name: "Message-ID", value: "<draft-message@example.com>" },
            { name: "In-Reply-To", value: overrides.inReplyTo ?? "<prior@example.com>" },
            { name: "References", value: "<root@example.com> <prior@example.com>" },
          ],
          parts: [
            {
              mimeType: "text/plain",
              headers: [{ name: "Content-Type", value: "text/plain; charset=UTF-8" }],
              body: { data: base64url(overrides.plain ?? "Plain body") },
            },
            {
              mimeType: "text/html",
              headers: [{ name: "Content-Type", value: "text/html; charset=UTF-8" }],
              body: { data: base64url(overrides.html ?? "<p>HTML body</p>") },
            },
            {
              mimeType: "application/pdf",
              filename: overrides.filename ?? "report.pdf",
              headers: [
                { name: "Content-Disposition", value: "attachment; filename=\"report.pdf\"" },
                { name: "Content-Type", value: "application/pdf" },
              ],
              body: { attachmentId: "attachment-1", size: attachmentBytes.length },
            },
          ],
        },
      },
    },
  });
  const hydrated = await hydrateGogDraftEffect(effect(), {
    resolveAccountIdentity: async () => "owner@example.com",
    execFile: async (_command, args) => {
      if (args[1] === "drafts") {
        return { stdout: draftJson };
      }
      if (args[1] === "raw") {
        return {
          stdout: JSON.stringify({
            raw: Buffer.from(JSON.stringify({
              ...overrides,
              attachment: attachmentBytes.toString("base64"),
            }), "utf8").toString("base64url"),
          }),
        };
      }
      assert.deepEqual(args.slice(0, 7), [
        "gmail", "attachment", "message-1", "attachment-1",
        "--account", "owner@example.com", "--out",
      ]);
      assert.equal(args.at(-1), "--no-input");
      attachmentOutput = args[7];
      await writeFile(attachmentOutput, attachmentBytes);
      return { stdout: "" };
    },
  });
  return { hydrated, attachmentOutput };
}

test("binds account, sender, thread metadata, all MIME bodies, and attachment bytes", async () => {
  const { hydrated, attachmentOutput } = await hydrateFixture();
  assert.match(hydrated.reviewContent, /Account: owner@example\.com/);
  assert.match(hydrated.reviewContent, /From: Owner <owner@example\.com>/);
  assert.match(hydrated.reviewContent, /Sender: delegated@example\.com/);
  assert.match(hydrated.reviewContent, /Reply-To: replies@example\.com/);
  assert.match(hydrated.reviewContent, /Thread ID: thread-1/);
  assert.match(hydrated.reviewContent, /In-Reply-To: <prior@example\.com>/);
  assert.match(hydrated.reviewContent, /References: <root@example\.com> <prior@example\.com>/);
  assert.match(hydrated.reviewContent, /MIME-Type: text\/plain[\s\S]*Content:\nPlain body/);
  assert.match(hydrated.reviewContent, /MIME-Type: text\/html[\s\S]*Content:\n<p>HTML body<\/p>/);
  assert.match(hydrated.reviewContent, /Filename: report\.pdf[\s\S]*SHA-256: sha256:[a-f0-9]{64}/);
  assert.deepEqual(hydrated.material.attachments, [{
    name: "report.pdf",
    sha256: sha256(Buffer.from("attachment-v1", "utf8")),
  }]);
  await assert.rejects(access(dirname(attachmentOutput)), { code: "ENOENT" });
});

test("any recipient, body, sender, thread, or attachment change changes exact material", async () => {
  const baseline = (await hydrateFixture()).hydrated;
  const variants = [
    { to: "other@example.com" },
    { from: "Other Sender <other@example.com>" },
    { replyTo: "other-replies@example.com" },
    { inReplyTo: "<different@example.com>" },
    { threadId: "thread-2" },
    { plain: "Changed plain body" },
    { html: "<p>Changed HTML body</p>" },
    { attachment: "attachment-v2" },
    { filename: "renamed.pdf" },
  ];
  for (const changed of variants) {
    const current = (await hydrateFixture(changed)).hydrated;
    assert.notEqual(current.materialDigest, baseline.materialDigest, JSON.stringify(changed));
    assert.equal(sameApprovalMaterial(current.material, baseline.material), false, JSON.stringify(changed));
  }
});

test("fails closed when attachment bytes cannot be fetched exactly and cleans scratch data", async () => {
  let attachmentOutput = "";
  await assert.rejects(hydrateGogDraftEffect(effect(), {
    resolveAccountIdentity: async () => "owner@example.com",
    execFile: async (_command, args) => {
      if (args[1] === "drafts") {
        return {
          stdout: JSON.stringify({
            draft: {
              message: {
                id: "message-1",
                threadId: "thread-1",
                payload: {
                  headers: [
                    { name: "To", value: "person@example.com" },
                    { name: "Subject", value: "Attachment" },
                  ],
                  parts: [{
                    mimeType: "application/octet-stream",
                    filename: "data.bin",
                    body: { attachmentId: "attachment-1", size: 10 },
                  }],
                },
              },
            },
          }),
        };
      }
      attachmentOutput = args[args.indexOf("--out") + 1];
      throw new Error("attachment unavailable");
    },
  }), /attachment unavailable/);
  await assert.rejects(access(dirname(attachmentOutput)), { code: "ENOENT" });
});

test("extracts the provider receipt id after a successful send", () => {
  assert.equal(strictProviderMessageId(JSON.stringify({ messageId: "message-1" })), "message-1");
  assert.equal(strictProviderMessageId(JSON.stringify({ message: { id: "message-1" } })), "message-1");
  assert.throws(() => strictProviderMessageId(JSON.stringify({ id: "ambiguous-generic-id" })), /provider message id/);
  assert.equal(strictProviderMessageId(JSON.stringify({ id: "message-1" }), { allowTopLevelId: true }), "message-1");
  assert.throws(() => strictProviderMessageId(JSON.stringify({
    messageId: "message-1",
    message: { id: "message-2" },
  })), /unambiguous/);
});

test("resolves gog aliases and account case to one canonical provider mailbox identity", async () => {
  const calls = [];
  const execute = async (_command, args) => {
    calls.push(args);
    if (args[0] === "auth" && args[1] === "alias") {
      return {
        stdout: JSON.stringify({
          aliases: {
            work: "Owner@Example.com",
            primary: "owner@example.com",
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
    return {
      stdout: JSON.stringify({
        result: { emailAddress: "Owner@Example.COM" },
      }),
    };
  };
  const first = await resolveGogAccountIdentity("work", {
    execFile: execute,
    gogExecutable: "/canonical/gog",
  });
  const second = await resolveGogAccountIdentity("PRIMARY", {
    execFile: execute,
    gogExecutable: "/canonical/gog",
  });
  const caseVariant = await resolveGogAccountIdentity("OWNER@EXAMPLE.COM", {
    execFile: execute,
    gogExecutable: "/canonical/gog",
  });
  assert.equal(first, "owner@example.com");
  assert.equal(second, first);
  assert.equal(caseVariant, first);
  const profiles = calls.filter((args) => args[4] === "gmail.users.getProfile");
  assert.equal(profiles.length, 3);
  assert.equal(profiles[0][profiles[0].indexOf("--account") + 1], "owner@example.com");
  assert.equal(profiles[1][profiles[1].indexOf("--account") + 1], "owner@example.com");
  assert.equal(profiles[2][profiles[2].indexOf("--account") + 1], "owner@example.com");
});

test("requires a Gmail send receipt to carry one message and thread identity", () => {
  assert.deepEqual(
    strictProviderGmailSendReceipt(JSON.stringify({
      id: "message-1",
      threadId: "thread-1",
    })),
    { messageId: "message-1", threadId: "thread-1" },
  );
  assert.throws(
    () => strictProviderGmailSendReceipt(JSON.stringify({ id: "message-1" })),
    /provider thread id/,
  );
});

test("structured MIME authority cannot collide through reviewer prose rendering", () => {
  const shared = {
    account: "owner@example.com",
    destination: "person@example.com",
    subject: "Header structure",
    draftId: "draft-1",
    mimeParts: [],
  };
  const oneHeader = { ...shared, headers: [{ name: "X-Test", value: "one\nY-Test: two" }] };
  const twoHeaders = {
    ...shared,
    headers: [
      { name: "X-Test", value: "one" },
      { name: "Y-Test", value: "two" },
    ],
  };
  assert.equal(reviewContent(oneHeader), reviewContent(twoHeaders));
  const left = canonicalJson({ schema: "org2:gmail-draft-material:v1", headers: oneHeader.headers });
  const right = canonicalJson({ schema: "org2:gmail-draft-material:v1", headers: twoHeaders.headers });
  assert.notEqual(left, right);
  assert.notEqual(sha256(left), sha256(right));
});

test("canonical ordering is UTF-8 ordinal for non-BMP names and object keys", () => {
  const names = ["😀.txt", "\uE000.txt"].sort(compareUtf8);
  assert.deepEqual(names, ["\uE000.txt", "😀.txt"]);
  assert.equal(canonicalJson({ "😀": 2, "\uE000": 1 }), `{"\uE000":1,"😀":2}`);
  const rawDigest = "a".repeat(64);
  const first = {
    kind: "message",
    content: "",
    attachments: [
      { name: "😀.txt", sha256: `sha256:${rawDigest}` },
      { name: "\uE000.txt", sha256: rawDigest.toUpperCase() },
    ],
  };
  const reordered = {
    attachments: [...first.attachments].reverse(),
    content: "",
    kind: "message",
  };
  assert.equal(approvalMaterialDigest(first), approvalMaterialDigest(reordered));
});
