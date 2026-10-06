#!/usr/bin/env node
// Email (IMAP) as an external sync source: configuration, credential
// handling, read-only incremental fetch, MIME decoding, and staging through
// the shared review-required import pipeline. Uses a local fake IMAP server.
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { decodeMimeWords, emailSourceSettings, parseEmail, imapQuote } from "../dist/emailSource.js";

const repo = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-email-source-"));
const corpus = path.join(root, "corpus");
const indexHome = path.join(root, "index");
fs.mkdirSync(corpus, { recursive: true });

// Pure parsing.
assert.equal(decodeMimeWords("=?UTF-8?B?Q2Fmw6kgbWVldGluZw==?="), "Café meeting");
assert.equal(decodeMimeWords("=?ISO-8859-1?Q?caf=E9_time?="), "café time");
assert.equal(imapQuote('a"b\\c'), '"a\\"b\\\\c"');
assert.throws(() => imapQuote("a\r\nb"));
assert.throws(() => emailSourceSettings("m", { type: "email", email: { host: "mail.example.com", username: "a", security: "none" } }), /loopback/);
assert.equal(emailSourceSettings("m", { type: "email", email: { host: "imap.example.com", username: "a" } }).port, 993);
const multipart = parseEmail(Buffer.from([
  "From: \"Ada Lovelace\" <ada@example.com>",
  "To: avi@example.com, \"Bo, Jr\" <bo@example.com>",
  "Subject: =?UTF-8?Q?Q4_plan_=E2=9C=85?=",
  "Date: Sun, 04 Oct 2026 10:00:00 -0700",
  "Message-ID: <m2@example.com>",
  "References: <m1@example.com>",
  "MIME-Version: 1.0",
  "Content-Type: multipart/alternative; boundary=\"b1\"",
  "",
  "--b1",
  "Content-Type: text/html; charset=utf-8",
  "",
  "<p>HTML only</p>",
  "--b1",
  "Content-Type: text/plain; charset=utf-8",
  "Content-Transfer-Encoding: quoted-printable",
  "",
  "Plan: ship =E2=9C=85 by Friday.=",
  "",
  "--b1--",
  "",
].join("\r\n")));
assert.equal(multipart.subject, "Q4 plan ✅");
assert.equal(multipart.from, "\"Ada Lovelace\" <ada@example.com>");
assert.deepEqual(multipart.to, ["avi@example.com", "\"Bo, Jr\" <bo@example.com>"]);
assert.equal(multipart.text, "Plan: ship ✅ by Friday.");
assert.equal(multipart.references[0], "<m1@example.com>");
assert.equal(multipart.date, "2026-10-04T17:00:00.000Z");
assert.equal(parseEmail(Buffer.from("Subject: x\r\nContent-Type: text/html\r\n\r\n<b>Hi</b><br>there&amp;")).text, "Hi\nthere&");

// A fake IMAP server.
const now = new Date();
const recent = new Date(now.getTime() - 2 * 86_400_000).toUTCString();
const messages = new Map([
  [7, { flags: "\\Seen", body: `From: Ada <ada@example.com>\r\nTo: avi@example.com\r\nSubject: =?UTF-8?B?Q2Fmw6kgbWVldGluZw==?=\r\nDate: ${recent}\r\nMessage-ID: <a1@example.com>\r\n\r\nLet's meet at the café.\r\n` }],
  [9, { flags: "\\Flagged", body: `From: Bo <bo@example.com>\r\nTo: avi@example.com\r\nSubject: Contract\r\nDate: ${recent}\r\nMessage-ID: <b1@example.com>\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n${Buffer.from("Signed copy attached.").toString("base64")}\r\n` }],
]);
const commands = [];
const server = net.createServer((socket) => {
  socket.write("* OK fake IMAP ready\r\n");
  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let newline;
    while ((newline = buffer.indexOf("\r\n")) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 2);
      const [tag, verb, ...rest] = line.split(" ");
      const args = rest.join(" ");
      commands.push(`${verb} ${args}`.replace(/"hunter2"/, '"***"'));
      const upper = verb.toUpperCase();
      if (upper === "LOGIN") {
        socket.write(args === '"avi@example.com" "hunter2"' ? `${tag} OK logged in\r\n` : `${tag} NO [AUTHENTICATIONFAILED] Invalid credentials\r\n`);
      } else if (upper === "EXAMINE") {
        socket.write(`* ${messages.size} EXISTS\r\n* OK [UIDVALIDITY 42] ok\r\n${tag} OK [READ-ONLY] done\r\n`);
      } else if (upper === "UID" && args.startsWith("SEARCH SINCE")) {
        socket.write(`* SEARCH ${[...messages.keys()].join(" ")}\r\n${tag} OK search\r\n`);
      } else if (upper === "UID" && args.startsWith("SEARCH UID")) {
        const from = Number(/UID (\d+):\*/.exec(args)[1]);
        const found = [...messages.keys()].filter((uid) => uid >= from);
        socket.write(`* SEARCH ${(found.length ? found : [Math.max(...messages.keys())]).join(" ")}\r\n${tag} OK search\r\n`);
      } else if (upper === "UID" && args.startsWith("FETCH")) {
        assert.match(args, /BODY\.PEEK\[\]<0\.\d+>/, "fetches never mark mail as read");
        const uids = /FETCH ([\d,]+)/.exec(args)[1].split(",").map(Number);
        let index = 0;
        for (const uid of uids) {
          const message = messages.get(uid);
          if (!message) continue;
          const bytes = Buffer.from(message.body, "utf8");
          socket.write(`* ${++index} FETCH (UID ${uid} INTERNALDATE "04-Oct-2026 10:00:00 +0000" RFC822.SIZE ${bytes.length} FLAGS (${message.flags}) BODY[]<0> {${bytes.length}}\r\n`);
          socket.write(bytes);
          socket.write(")\r\n");
        }
        socket.write(`${tag} OK fetch\r\n`);
      } else if (upper === "LOGOUT") {
        socket.write(`* BYE\r\n${tag} OK bye\r\n`);
        socket.end();
      } else {
        socket.write(`${tag} BAD unknown\r\n`);
      }
    }
  });
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;

function cli(args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [path.join(repo, "dist/cli.js"), ...args, "--dir", corpus], {
      env: { ...process.env, ORG2_INDEX_HOME: indexHome, ORG2_EMAIL_PASSWORD: "", ...env },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("exit", (status) => resolve({ status, stdout, stderr }));
  });
}

try {
  fs.writeFileSync(path.join(corpus, "org2.json"), `${JSON.stringify({ agendaFiles: ["*.org"] }, null, 2)}\n`);
  const preview = JSON.parse((await cli(["source", "add-email", "mail", "--host", "127.0.0.1", "--port", String(port), "--security", "none", "--username", "avi@example.com", "--smtp-host", "smtp.example.com", "--json"])).stdout);
  assert.equal(preview.applied, false);
  assert.equal(JSON.parse(fs.readFileSync(path.join(corpus, "org2.json"), "utf8")).externalSources, undefined);
  const added = await cli(["source", "add-email", "mail", "--host", "127.0.0.1", "--port", String(port), "--security", "none", "--username", "avi@example.com", "--smtp-host", "smtp.example.com", "--apply", "--json"]);
  assert.equal(added.status, 0, added.stderr);
  const config = JSON.parse(fs.readFileSync(path.join(corpus, "org2.json"), "utf8"));
  assert.equal(config.externalSources.mail.type, "email");
  assert.equal(config.externalSources.mail.email.smtp.host, "smtp.example.com");
  assert.ok(!JSON.stringify(config).includes("hunter2"), "no secret in the corpus");

  const listed = JSON.parse((await cli(["source", "list", "--json"])).stdout);
  assert.equal(listed[0].type, "email");
  assert.equal(listed[0].ready, true);
  assert.equal(listed[0].credentialAvailable, false);
  assert.equal(listed[0].email.mailboxes[0], "INBOX");

  // Missing and wrong passwords fail clearly.
  const missing = JSON.parse((await cli(["source", "doctor", "mail", "--json"])).stdout);
  assert.equal(missing.ok, false);
  assert.match(missing.sources[0].doctorError, /no password/);
  const wrong = JSON.parse((await cli(["source", "doctor", "mail", "--json"], { ORG2_EMAIL_PASSWORD: "nope" })).stdout);
  assert.match(wrong.sources[0].doctorError, /Invalid credentials/);
  const doctor = await cli(["source", "doctor", "mail", "--json"], { ORG2_EMAIL_PASSWORD: "hunter2" });
  assert.equal(doctor.status, 0, doctor.stdout + doctor.stderr);
  assert.equal(JSON.parse(doctor.stdout).sources[0].mailboxes[0].exists, 2);

  // A machine-local password command works too.
  const bound = await cli(["source", "bind", "mail", "--password-command", "printf hunter2", "--apply", "--json"]);
  assert.equal(bound.status, 0, bound.stderr);
  assert.equal(JSON.parse((await cli(["source", "list", "--json"])).stdout)[0].credentialAvailable, true);

  // Preview import does not write or advance the cursor.
  const importPreview = JSON.parse((await cli(["source", "import", "mail", "--json"])).stdout);
  assert.equal(importPreview.results[0].ok, true, JSON.stringify(importPreview));
  assert.equal(importPreview.results[0].imported.acceptedCount, 2);
  assert.equal(fs.existsSync(path.join(corpus, "raw")), false);

  // Sync stages raw captures and review packets and advances the cursor.
  const synced = JSON.parse((await cli(["source", "sync", "mail", "--ingest", "--apply", "--json"])).stdout);
  assert.equal(synced.results[0].ok, true, JSON.stringify(synced));
  assert.equal(synced.results[0].imported.acceptedCount, 2);
  const rawDir = path.join(corpus, "raw/connectors/email/mail");
  const reviewDir = path.join(corpus, "views/connectors/email/mail");
  const rawFiles = fs.readdirSync(rawDir);
  assert.equal(rawFiles.length, 1);
  const raw = JSON.parse(fs.readFileSync(path.join(rawDir, rawFiles[0]), "utf8"));
  assert.equal(raw.sourceType, "email");
  const ada = raw.records.find((record) => record.source.messageId === "<a1@example.com>");
  assert.equal(ada.title, "Café meeting · Ada <ada@example.com>");
  assert.equal(ada.text, "Let's meet at the café.");
  assert.equal(ada.source.unread, false);
  const bo = raw.records.find((record) => record.source.messageId === "<b1@example.com>");
  assert.equal(bo.text, "Signed copy attached.");
  assert.equal(bo.source.starred, true);
  assert.equal(bo.source.unread, true);
  const review = fs.readFileSync(path.join(reviewDir, fs.readdirSync(reviewDir)[0]), "utf8");
  assert.match(review, /review-required/);
  assert.match(review, /Café meeting/);
  const status = JSON.parse((await cli(["source", "status", "mail", "--json"])).stdout);
  assert.equal(status.sources[0].crawlerStatus.state, "synced");
  assert.equal(status.sources[0].crawlerStatus.counts[0].value, 9);

  // Incremental: only new mail is fetched, and earlier packets are kept.
  messages.set(12, { flags: "", body: `From: Cy <cy@example.com>\r\nSubject: New\r\nDate: ${recent}\r\nMessage-ID: <c1@example.com>\r\n\r\nFresh.\r\n` });
  commands.length = 0;
  const again = JSON.parse((await cli(["source", "sync", "mail", "--ingest", "--apply", "--json"])).stdout);
  assert.equal(again.results[0].ok, true, JSON.stringify(again));
  assert.equal(again.results[0].mailboxes[0].fetched, 1);
  assert.ok(commands.some((command) => command.startsWith("UID SEARCH UID 10:*")));
  assert.ok(commands.some((command) => /FETCH 12 /.test(command)));
  const merged = JSON.parse(fs.readFileSync(path.join(rawDir, fs.readdirSync(rawDir)[0]), "utf8"));
  assert.deepEqual(merged.records.map((record) => record.source.messageId).sort(), ["<a1@example.com>", "<b1@example.com>", "<c1@example.com>"]);
  // Nothing new: nothing fetched, nothing removed.
  const idle = JSON.parse((await cli(["source", "sync", "mail", "--ingest", "--apply", "--json"])).stdout);
  assert.equal(idle.results[0].mailboxes[0].fetched, 0);
  assert.equal(JSON.parse(fs.readFileSync(path.join(rawDir, fs.readdirSync(rawDir)[0]), "utf8")).records.length, 3);
  assert.ok(commands.every((command) => !/STORE|SELECT /i.test(command)), "sync never changes flags or selects read-write");

  console.log("email source ok");
} finally {
  server.close();
  fs.rmSync(root, { recursive: true, force: true });
}
