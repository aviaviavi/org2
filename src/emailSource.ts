/**
 * Email as an external sync source.
 *
 * A corpus declares an `email` profile in `celorga.json` `externalSources` with
 * non-secret account settings (IMAP host, port, security, username,
 * mailboxes, and optionally the account's SMTP submission server for
 * reference). Celorga reads mail over IMAP itself (no crawler binary), stages
 * new messages as raw captures plus review-required Celorga packets through the
 * same import pipeline as Slack and Notion, and keeps a machine-local
 * UIDVALIDITY/UID cursor so later syncs fetch only new mail.
 *
 * Passwords never enter the corpus: they come from `ORG2_EMAIL_PASSWORD`, a
 * machine-local binding (`passwordEnv` or `passwordCommand`), or the Celorga app's
 * Keychain, which passes them in the environment for one sync. Messages are
 * fetched with BODY.PEEK so syncing never marks mail as read.
 */
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import tls from "node:tls";
import { spawnSync } from "node:child_process";
import type { Org2ExternalSourceConfig } from "./config.js";
import type { AgentIngestRecord } from "./agentIngestConnectors.js";
import { org2CorpusIndexDir } from "./indexPaths.js";
import { brandEnv, nameAliases, schemaMatches } from "./brandNames.js";

export const EMAIL_SOURCE_STATE_SCHEMA = "org2:email-source-state:v1" as const;
export const DEFAULT_EMAIL_PASSWORD_ENV = "ORG2_EMAIL_PASSWORD";

export type EmailSecurity = "tls" | "starttls" | "none";

export interface EmailSourceSettings {
  host: string;
  port: number;
  security: EmailSecurity;
  username: string;
  mailboxes: string[];
  maxMessageBytes: number;
  smtp?: { host: string; port: number; security: EmailSecurity };
}

export interface EmailCredentialBinding {
  passwordEnv?: string;
  passwordCommand?: string;
}

function isLoopback(host: string): boolean {
  return ["127.0.0.1", "localhost", "::1"].includes(host.toLowerCase());
}

/** Validates and normalizes a profile's `email` block. */
export function emailSourceSettings(id: string, profile: Org2ExternalSourceConfig): EmailSourceSettings {
  const raw = profile.email;
  if (!raw || typeof raw !== "object") throw new Error(`external source ${id} requires an email block with host and username`);
  const host = String(raw.host || "").trim();
  const username = String(raw.username || "").trim();
  if (!host) throw new Error(`external source ${id} email.host is required`);
  if (!username) throw new Error(`external source ${id} email.username is required`);
  const security = (raw.security || (raw.port === 143 ? "starttls" : "tls")) as EmailSecurity;
  if (!["tls", "starttls", "none"].includes(security)) throw new Error(`external source ${id} email.security must be tls, starttls, or none`);
  if (security === "none" && !isLoopback(host)) {
    throw new Error(`external source ${id} email.security none is allowed only for a loopback test server`);
  }
  const port = Number(raw.port || (security === "tls" ? 993 : 143));
  if (!Number.isInteger(port) || port <= 0 || port > 65_535) throw new Error(`external source ${id} email.port is invalid`);
  const mailboxes = (Array.isArray(raw.mailboxes) && raw.mailboxes.length ? raw.mailboxes : ["INBOX"]).map((item) => String(item).trim()).filter(Boolean);
  const maxMessageBytes = Math.max(4_096, Math.min(Number(raw.maxMessageBytes || 512_000), 10_000_000));
  const smtp = raw.smtp && typeof raw.smtp === "object" && raw.smtp.host
    ? { host: String(raw.smtp.host), port: Number(raw.smtp.port || 587), security: (raw.smtp.security || "starttls") as EmailSecurity }
    : undefined;
  return { host, port, security, username, mailboxes, maxMessageBytes, ...(smtp ? { smtp } : {}) };
}

/** Resolves the account password without persisting it. */
export function resolveEmailPassword(binding: EmailCredentialBinding, env: NodeJS.ProcessEnv = process.env): { password?: string; source: string } {
  const envName = binding.passwordEnv || DEFAULT_EMAIL_PASSWORD_ENV;
  const envPassword = brandEnv(envName, env);
  if (envPassword) return { password: envPassword, source: `env:${nameAliases(envName).find((name) => env[name] === envPassword) ?? envName}` };
  if (binding.passwordCommand) {
    const child = spawnSync("/bin/sh", ["-c", binding.passwordCommand], { encoding: "utf8", timeout: 30_000, env });
    const password = child.status === 0 ? String(child.stdout || "").replace(/\r?\n$/u, "") : "";
    if (password) return { password, source: "password-command" };
    return { source: "password-command (failed)" };
  }
  return { source: `missing (set ${envName}, bind --password-env/--password-command, or save it in the Celorga app)` };
}

export function emailCredentialAvailable(binding: EmailCredentialBinding, env: NodeJS.ProcessEnv = process.env): boolean {
  return Boolean(brandEnv(binding.passwordEnv || DEFAULT_EMAIL_PASSWORD_ENV, env)) || Boolean(binding.passwordCommand);
}

// MARK: - IMAP client

interface ImapResponseLine {
  text: string;
  literals: Buffer[];
}

export class ImapError extends Error {}

/** A minimal IMAP4rev1 client: enough to log in, select, search, and fetch. */
export class ImapClient {
  private socket!: net.Socket | tls.TLSSocket;
  private buffer = Buffer.alloc(0);
  private waiters: Array<() => void> = [];
  private closedError: Error | null = null;
  private tagCounter = 0;

  constructor(private readonly settings: Pick<EmailSourceSettings, "host" | "port" | "security">, private readonly timeoutMs = 30_000) {}

  async connect(): Promise<string> {
    const { host, port, security } = this.settings;
    this.socket = await new Promise<net.Socket | tls.TLSSocket>((resolve, reject) => {
      const onError = (error: Error) => reject(error);
      const socket = security === "tls"
        ? tls.connect({ host, port, servername: net.isIP(host) ? undefined : host }, () => resolve(socket))
        : net.connect({ host, port }, () => resolve(socket));
      socket.once("error", onError);
      socket.setTimeout(this.timeoutMs, () => socket.destroy(new ImapError(`IMAP connection to ${host}:${port} timed out`)));
    });
    this.attach(this.socket);
    const greeting = await this.readLine();
    if (!/^\* (OK|PREAUTH)/iu.test(greeting.text)) throw new ImapError(`unexpected IMAP greeting: ${greeting.text.slice(0, 200)}`);
    if (security === "starttls") {
      await this.command("STARTTLS");
      const plain = this.socket as net.Socket;
      plain.removeAllListeners("data");
      this.socket = await new Promise<tls.TLSSocket>((resolve, reject) => {
        const secure = tls.connect({ socket: plain, servername: net.isIP(host) ? undefined : host }, () => resolve(secure));
        secure.once("error", reject);
      });
      this.buffer = Buffer.alloc(0);
      this.attach(this.socket);
    }
    return greeting.text;
  }

  private attach(socket: net.Socket | tls.TLSSocket): void {
    socket.on("data", (chunk: Buffer) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.wake();
    });
    socket.on("error", (error) => { this.closedError = error; this.wake(); });
    socket.on("close", () => { this.closedError ??= new ImapError("IMAP connection closed"); this.wake(); });
  }

  private wake(): void {
    const waiters = this.waiters;
    this.waiters = [];
    for (const waiter of waiters) waiter();
  }

  private async waitForData(): Promise<void> {
    if (this.closedError) throw this.closedError;
    await new Promise<void>((resolve) => this.waiters.push(resolve));
    if (this.closedError && this.buffer.length === 0) throw this.closedError;
  }

  /** Reads one logical response line, collecting `{n}` literals. */
  private async readLine(): Promise<ImapResponseLine> {
    let text = "";
    const literals: Buffer[] = [];
    for (;;) {
      const newline = this.buffer.indexOf("\r\n");
      if (newline < 0) { await this.waitForData(); continue; }
      const segment = this.buffer.subarray(0, newline).toString("utf8");
      const literal = /\{(\d+)\}$/u.exec(segment);
      if (!literal) {
        this.buffer = this.buffer.subarray(newline + 2);
        return { text: text + segment, literals };
      }
      const size = Number(literal[1]);
      while (this.buffer.length < newline + 2 + size) await this.waitForData();
      literals.push(Buffer.from(this.buffer.subarray(newline + 2, newline + 2 + size)));
      text += `${segment.slice(0, literal.index)}\u0000${literals.length - 1}\u0000`;
      this.buffer = this.buffer.subarray(newline + 2 + size);
    }
  }

  async command(command: string): Promise<ImapResponseLine[]> {
    if (/[\r\n]/u.test(command)) throw new ImapError("IMAP command contains a line break");
    const tag = `O${String(++this.tagCounter).padStart(4, "0")}`;
    this.socket.write(`${tag} ${command}\r\n`);
    const untagged: ImapResponseLine[] = [];
    for (;;) {
      const line = await this.readLine();
      if (line.text.startsWith(`${tag} `)) {
        const status = line.text.slice(tag.length + 1);
        if (!/^OK\b/iu.test(status)) {
          const verb = command.split(" ")[0];
          throw new ImapError(`IMAP ${verb} failed: ${status.replace(/^(NO|BAD)\s*/iu, "").slice(0, 300) || status}`);
        }
        return untagged;
      }
      untagged.push(line);
    }
  }

  async login(username: string, password: string): Promise<void> {
    await this.command(`LOGIN ${imapQuote(username)} ${imapQuote(password)}`);
  }

  async select(mailbox: string): Promise<{ uidValidity: number; exists: number }> {
    const lines = await this.command(`EXAMINE ${imapQuote(mailbox)}`);
    let uidValidity = 0;
    let exists = 0;
    for (const line of lines) {
      const validity = /\[UIDVALIDITY (\d+)\]/iu.exec(line.text);
      if (validity) uidValidity = Number(validity[1]);
      const count = /^\* (\d+) EXISTS/iu.exec(line.text);
      if (count) exists = Number(count[1]);
    }
    return { uidValidity, exists };
  }

  async uidSearch(criteria: string): Promise<number[]> {
    const lines = await this.command(`UID SEARCH ${criteria}`);
    return lines.flatMap((line) => {
      const match = /^\* SEARCH\b(.*)$/iu.exec(line.text);
      return match ? match[1]!.trim().split(/\s+/u).filter(Boolean).map(Number).filter(Number.isFinite) : [];
    });
  }

  async uidFetch(uids: number[], maxBytes: number): Promise<FetchedMessage[]> {
    if (!uids.length) return [];
    const lines = await this.command(`UID FETCH ${uids.join(",")} (UID INTERNALDATE RFC822.SIZE FLAGS BODY.PEEK[]<0.${maxBytes}>)`);
    return lines.flatMap((line) => {
      if (!/^\* \d+ FETCH /iu.test(line.text)) return [];
      const uid = Number(/\bUID (\d+)/iu.exec(line.text)?.[1] ?? Number.NaN);
      if (!Number.isFinite(uid)) return [];
      const internalDate = /INTERNALDATE "([^"]+)"/iu.exec(line.text)?.[1];
      const size = Number(/RFC822\.SIZE (\d+)/iu.exec(line.text)?.[1] ?? 0);
      const flags = (/FLAGS \(([^)]*)\)/iu.exec(line.text)?.[1] ?? "").split(/\s+/u).filter(Boolean);
      const bodyLiteral = /BODY\[\](?:<\d+>)? \u0000(\d+)\u0000/u.exec(line.text);
      const bodyQuoted = /BODY\[\](?:<\d+>)? "((?:[^"\\]|\\.)*)"/u.exec(line.text);
      const raw = bodyLiteral ? line.literals[Number(bodyLiteral[1])]! : Buffer.from(bodyQuoted ? bodyQuoted[1]!.replace(/\\(.)/gu, "$1") : "", "utf8");
      return [{ uid, internalDate, size, flags, raw, truncated: size > raw.length }];
    });
  }

  async logout(): Promise<void> {
    try { await this.command("LOGOUT"); } catch { /* the server may close first */ }
    this.socket.end();
  }

  destroy(): void {
    this.socket?.destroy();
  }
}

export interface FetchedMessage {
  uid: number;
  internalDate?: string;
  size: number;
  flags: string[];
  raw: Buffer;
  truncated: boolean;
}

export function imapQuote(value: string): string {
  if (/[\r\n\0]/u.test(value)) throw new ImapError("IMAP strings cannot contain line breaks");
  return `"${value.replace(/\\/gu, "\\\\").replace(/"/gu, '\\"')}"`;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export function imapDate(date: Date): string {
  return `${date.getUTCDate()}-${MONTHS[date.getUTCMonth()]}-${date.getUTCFullYear()}`;
}

// MARK: - RFC 5322 / MIME parsing

function decodeBytes(bytes: Buffer, charset: string | undefined): string {
  const label = (charset || "utf-8").trim().toLowerCase().replace(/^"|"$/gu, "");
  try {
    return new TextDecoder(label === "us-ascii" ? "utf-8" : label).decode(bytes);
  } catch {
    return bytes.toString("latin1");
  }
}

export function decodeQuotedPrintable(input: string): Buffer {
  const soft = input.replace(/=\r?\n/gu, "");
  const bytes: number[] = [];
  for (let index = 0; index < soft.length; index += 1) {
    const char = soft[index]!;
    if (char === "=" && /^[0-9A-Fa-f]{2}$/u.test(soft.slice(index + 1, index + 3))) {
      bytes.push(parseInt(soft.slice(index + 1, index + 3), 16));
      index += 2;
    } else {
      for (const byte of Buffer.from(char, "utf8")) bytes.push(byte);
    }
  }
  return Buffer.from(bytes);
}

/** Decodes RFC 2047 encoded words such as `=?UTF-8?B?...?=`. */
export function decodeMimeWords(value: string): string {
  return value
    .replace(/\?=\s+=\?/gu, "?==?")
    .replace(/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/gu, (_whole, charset: string, encoding: string, data: string) => {
      const bytes = encoding.toLowerCase() === "b"
        ? Buffer.from(data, "base64")
        : decodeQuotedPrintable(data.replace(/_/gu, " "));
      return decodeBytes(bytes, charset.split("*")[0]);
    });
}

interface MimePart {
  headers: Map<string, string>;
  body: Buffer;
}

function splitHeaders(raw: Buffer): MimePart {
  let separator = raw.indexOf("\r\n\r\n");
  let skip = 4;
  if (separator < 0) { separator = raw.indexOf("\n\n"); skip = 2; }
  const headerText = (separator < 0 ? raw : raw.subarray(0, separator)).toString("latin1");
  const body = separator < 0 ? Buffer.alloc(0) : raw.subarray(separator + skip);
  const headers = new Map<string, string>();
  const unfolded = headerText.replace(/\r?\n[ \t]+/gu, " ");
  for (const line of unfolded.split(/\r?\n/u)) {
    const colon = line.indexOf(":");
    if (colon <= 0) continue;
    const key = line.slice(0, colon).trim().toLowerCase();
    if (!headers.has(key)) headers.set(key, line.slice(colon + 1).trim());
  }
  return { headers, body };
}

function headerParameter(value: string | undefined, name: string): string | undefined {
  if (!value) return undefined;
  const match = new RegExp(`;\\s*${name}\\*?=\\s*(?:"([^"]*)"|([^;\\s]+))`, "iu").exec(value);
  return match ? (match[1] ?? match[2]) : undefined;
}

function decodePartBody(part: MimePart): string {
  const encoding = (part.headers.get("content-transfer-encoding") || "7bit").toLowerCase();
  const charset = headerParameter(part.headers.get("content-type"), "charset");
  let bytes = part.body;
  if (encoding === "base64") bytes = Buffer.from(part.body.toString("latin1").replace(/\s+/gu, ""), "base64");
  else if (encoding === "quoted-printable") bytes = decodeQuotedPrintable(part.body.toString("latin1"));
  return decodeBytes(bytes, charset);
}

export function htmlToText(html: string): string {
  return html
    .replace(/<(script|style|head)[\s\S]*?<\/\1>/giu, "")
    .replace(/<br\s*\/?>/giu, "\n")
    .replace(/<\/(p|div|li|tr|h[1-6])>/giu, "\n")
    .replace(/<[^>]+>/gu, "")
    .replace(/&nbsp;/gu, " ")
    .replace(/&amp;/gu, "&")
    .replace(/&lt;/gu, "<")
    .replace(/&gt;/gu, ">")
    .replace(/&quot;/gu, '"')
    .replace(/&#39;/gu, "'")
    .replace(/[ \t]+\n/gu, "\n")
    .replace(/\n{3,}/gu, "\n\n")
    .trim();
}

/** The best readable text in a MIME entity: text/plain, else text/html as text. */
function bestText(part: MimePart, depth = 0): { text: string; kind: "plain" | "html" | "none" } {
  const type = (part.headers.get("content-type") || "text/plain").toLowerCase();
  const disposition = (part.headers.get("content-disposition") || "").toLowerCase();
  if (disposition.startsWith("attachment")) return { text: "", kind: "none" };
  if (type.startsWith("multipart/") && depth < 8) {
    const boundary = headerParameter(part.headers.get("content-type"), "boundary");
    if (!boundary) return { text: "", kind: "none" };
    const delimiter = `--${boundary}`;
    const raw = part.body.toString("latin1");
    const pieces = raw.split(delimiter).slice(1).filter((piece) => !piece.startsWith("--"));
    let html = "";
    for (const piece of pieces) {
      const child = splitHeaders(Buffer.from(piece.replace(/^\r?\n/u, ""), "latin1"));
      const found = bestText(child, depth + 1);
      if (found.kind === "plain" && found.text.trim()) return found;
      if (found.kind === "html" && !html) html = found.text;
    }
    return html ? { text: html, kind: "html" } : { text: "", kind: "none" };
  }
  if (type.startsWith("text/html")) return { text: htmlToText(decodePartBody(part)), kind: "html" };
  if (type.startsWith("text/")) return { text: decodePartBody(part), kind: "plain" };
  return { text: "", kind: "none" };
}

function addresses(value: string | undefined): string[] {
  if (!value) return [];
  return decodeMimeWords(value).split(/,(?=(?:[^"]*"[^"]*")*[^"]*$)/u).map((item) => item.trim()).filter(Boolean);
}

function parseInternalDate(value: string | undefined): number {
  if (!value) return Number.NaN;
  return Date.parse(value.replace(/^(\d{1,2})-(\w{3})-(\d{4})/u, "$1 $2 $3"));
}

export interface ParsedEmail {
  messageId?: string;
  subject: string;
  from: string;
  to: string[];
  cc: string[];
  date: string;
  inReplyTo?: string;
  references: string[];
  text: string;
}

export function parseEmail(raw: Buffer, fallbackDate?: string): ParsedEmail {
  const message = splitHeaders(raw);
  const header = (name: string) => message.headers.get(name);
  const dateMs = Date.parse(header("date") || "");
  const internalMs = parseInternalDate(fallbackDate);
  const date = Number.isFinite(dateMs) ? new Date(dateMs) : Number.isFinite(internalMs) ? new Date(internalMs) : new Date(0);
  const ids = (value: string | undefined) => (value?.match(/<[^>]+>/gu) ?? []).map((id) => id.trim());
  const text = bestText(message).text.replace(/\r\n/gu, "\n").trim();
  return {
    ...(ids(header("message-id"))[0] ? { messageId: ids(header("message-id"))[0] } : {}),
    subject: decodeMimeWords(header("subject") || "").trim() || "(no subject)",
    from: addresses(header("from"))[0] || "unknown sender",
    to: addresses(header("to")),
    cc: addresses(header("cc")),
    date: date.toISOString(),
    ...(ids(header("in-reply-to"))[0] ? { inReplyTo: ids(header("in-reply-to"))[0] } : {}),
    references: ids(header("references")),
    text,
  };
}

// MARK: - Cursor state

interface MailboxCursor {
  uidValidity: number;
  lastUid: number;
  syncedAt: string;
}

interface EmailSourceState {
  schema: typeof EMAIL_SOURCE_STATE_SCHEMA;
  profile: string;
  account: string;
  mailboxes: Record<string, MailboxCursor>;
}

export function emailSourceStatePath(root: string, profileId: string): string {
  return path.join(org2CorpusIndexDir(root), `source-email-${profileId.replace(/[^A-Za-z0-9_.-]/gu, "_")}-state.json`);
}

export function readEmailSourceState(root: string, profileId: string, account: string): EmailSourceState {
  try {
    const value = JSON.parse(fs.readFileSync(emailSourceStatePath(root, profileId), "utf8")) as EmailSourceState;
    if (schemaMatches(value.schema, EMAIL_SOURCE_STATE_SCHEMA) && value.account === account && value.mailboxes) return value;
  } catch { /* first sync */ }
  return { schema: EMAIL_SOURCE_STATE_SCHEMA, profile: profileId, account, mailboxes: {} };
}

function writeEmailSourceState(root: string, state: EmailSourceState): void {
  const file = emailSourceStatePath(root, state.profile);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, file);
}

// MARK: - Fetching records

export interface EmailFetchOptions {
  root: string;
  profileId: string;
  settings: EmailSourceSettings;
  password: string;
  sinceTimestamp?: number;
  limit: number;
  /** Advance the machine-local cursor (only when the import is applied). */
  advanceCursor: boolean;
  timeoutMs?: number;
  now?: Date;
}

export interface EmailFetchResult {
  records: AgentIngestRecord[];
  mailboxes: Array<{ mailbox: string; uidValidity: number; fetched: number; lastUid: number; reset: boolean }>;
}

export async function fetchEmailRecords(options: EmailFetchOptions): Promise<EmailFetchResult> {
  const { settings } = options;
  const account = `${settings.username}@${settings.host}:${settings.port}`;
  const state = readEmailSourceState(options.root, options.profileId, account);
  const client = new ImapClient(settings, options.timeoutMs);
  const records: AgentIngestRecord[] = [];
  const summaries: EmailFetchResult["mailboxes"] = [];
  const now = options.now ?? new Date();
  try {
    await client.connect();
    await client.login(settings.username, options.password);
    for (const mailbox of settings.mailboxes) {
      const selected = await client.select(mailbox);
      const cursor = state.mailboxes[mailbox];
      const reset = Boolean(cursor && cursor.uidValidity !== selected.uidValidity);
      let uids: number[];
      if (cursor && !reset) {
        uids = (await client.uidSearch(`UID ${cursor.lastUid + 1}:*`)).filter((uid) => uid > cursor.lastUid);
      } else {
        const since = new Date(options.sinceTimestamp ?? now.getTime() - 14 * 86_400_000);
        uids = await client.uidSearch(`SINCE ${imapDate(since)}`);
      }
      uids = [...new Set(uids)].sort((a, b) => a - b).slice(-options.limit);
      let fetched = 0;
      for (let offset = 0; offset < uids.length; offset += 50) {
        const batch = uids.slice(offset, offset + 50);
        for (const message of await client.uidFetch(batch, settings.maxMessageBytes)) {
          const parsed = parseEmail(message.raw, message.internalDate);
          if (options.sinceTimestamp !== undefined && !cursor && Date.parse(parsed.date) < options.sinceTimestamp) continue;
          const id = parsed.messageId ? `${mailbox}:${parsed.messageId}` : `${mailbox}:${selected.uidValidity}:${message.uid}`;
          const text = parsed.text.length > 20_000 ? `${parsed.text.slice(0, 20_000)}\n…[truncated]` : parsed.text;
          records.push({
            id,
            title: `${parsed.subject} · ${parsed.from}`,
            text: text || `(no readable text${message.truncated ? "; message truncated" : ""})`,
            cursor: `${parsed.date}#${id}`,
            rawPayload: {
              mailbox,
              uid: message.uid,
              uidValidity: selected.uidValidity,
              size: message.size,
              truncated: message.truncated,
              flags: message.flags,
              messageId: parsed.messageId ?? null,
              subject: parsed.subject,
              from: parsed.from,
              to: parsed.to,
              cc: parsed.cc,
              date: parsed.date,
              inReplyTo: parsed.inReplyTo ?? null,
              references: parsed.references,
            },
            source: {
              kind: "email",
              mailbox,
              service: "imap",
              ...(parsed.messageId ? { messageId: parsed.messageId } : {}),
              threadId: parsed.references[0] ?? parsed.inReplyTo ?? parsed.messageId,
              subject: parsed.subject,
              author: parsed.from,
              recipients: [...parsed.to, ...parsed.cc],
              unread: !message.flags.some((flag) => flag.toLowerCase() === "\\seen"),
              starred: message.flags.some((flag) => flag.toLowerCase() === "\\flagged"),
              timestamp: parsed.date,
            },
          });
          fetched += 1;
        }
      }
      const lastUid = Math.max(reset ? 0 : cursor?.lastUid ?? 0, ...uids, 0);
      summaries.push({ mailbox, uidValidity: selected.uidValidity, fetched, lastUid, reset });
      state.mailboxes[mailbox] = { uidValidity: selected.uidValidity, lastUid, syncedAt: now.toISOString() };
    }
    await client.logout();
  } catch (error) {
    client.destroy();
    throw error;
  }
  if (options.advanceCursor) writeEmailSourceState(options.root, state);
  return { records, mailboxes: summaries };
}

/** Connects and logs in to verify settings and credentials. */
export async function checkEmailSource(settings: EmailSourceSettings, password: string, timeoutMs = 30_000): Promise<{ greeting: string; mailboxes: Array<{ mailbox: string; exists: number }> }> {
  const client = new ImapClient(settings, timeoutMs);
  try {
    const greeting = await client.connect();
    await client.login(settings.username, password);
    const mailboxes = [];
    for (const mailbox of settings.mailboxes) mailboxes.push({ mailbox, exists: (await client.select(mailbox)).exists });
    await client.logout();
    return { greeting: greeting.slice(0, 200), mailboxes };
  } catch (error) {
    client.destroy();
    throw error;
  }
}
