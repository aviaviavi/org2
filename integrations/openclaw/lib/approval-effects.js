import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const GMAIL_ALIASES = new Set(["gmail", "mail", "email"]);
const DRAFT_ALIASES = new Set(["draft", "drafts"]);
const GOG_EXECUTABLES = new Set(["gog", "/usr/local/bin/gog"]);
const CREATE_ACTIONS = new Map([
  ["add", "create"],
  ["create", "create"],
  ["edit", "update"],
  ["new", "create"],
  ["save", "save"],
  ["set", "update"],
  ["update", "update"],
  ["upsert", "upsert"],
]);
const SEND_ACTIONS = new Map([
  ["deliver", "send"],
  ["post", "send"],
  ["send", "send"],
]);
const SEND_BOOLEAN_OPTIONS = new Set(["--json", "--no-input"]);
const CREATE_BOOLEAN_OPTIONS = new Set(["--json", "--no-input"]);
const CREATE_VALUE_OPTIONS = new Set([
  "--attach",
  "--attachment",
  "--bcc",
  "--body",
  "--body-file",
  "--body-html",
  "--cc",
  "--draft-id",
  "--from",
  "--in-reply-to",
  "--references",
  "--reply-to",
  "--reply-to-message-id",
  "--subject",
  "--thread-id",
  "--to",
]);
const SUSPICIOUS_MAIL_EXECUTABLES = new Set([
  "mail",
  "mailx",
  "msmtp",
  "mutt",
  "neomutt",
  "sendmail",
  "swaks",
]);
const COMMAND_WRAPPERS = new Set([
  "bash",
  "command",
  "dash",
  "env",
  "eval",
  "fish",
  "nice",
  "nohup",
  "osascript",
  "perl",
  "python",
  "python3",
  "ruby",
  "sh",
  "sudo",
  "timeout",
  "xargs",
  "zsh",
]);

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

function literalText(value) {
  return typeof value === "string" ? value : "";
}

function commandInput(params = {}) {
  if (typeof params === "string") return { ok: true, source: params };
  const sources = ["command", "cmd", "source", "code", "input"]
    .map((key) => literalText(params?.[key]))
    .filter((value) => value.length > 0);
  const unique = [...new Set(sources)];
  if (unique.length > 1) {
    return {
      ok: false,
      source: unique.join("\n"),
      reason: "multiple conflicting shell command fields are not allowed",
    };
  }
  return { ok: true, source: unique[0] || "" };
}

function parseLiteralCommand(value) {
  const source = literalText(value).trim();
  if (!source) return { ok: false, reason: "the shell command is empty" };
  const words = [];
  let word = "";
  let quote = "";
  let escaped = false;
  let wordStarted = false;

  for (const character of source) {
    if (escaped) {
      if (character === "\n" || character === "\r") {
        return { ok: false, reason: "line continuations are not allowed" };
      }
      word += character;
      wordStarted = true;
      escaped = false;
      continue;
    }
    if (quote === "'") {
      if (character === "'") quote = "";
      else word += character;
      wordStarted = true;
      continue;
    }
    if (quote === '"') {
      if (character === '"') {
        quote = "";
        continue;
      }
      if (character === "$" || character === "`") {
        return { ok: false, reason: "shell expansion is not allowed" };
      }
      if (character === "\\") {
        escaped = true;
        continue;
      }
      word += character;
      wordStarted = true;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      wordStarted = true;
      continue;
    }
    if (character === "\\") {
      escaped = true;
      wordStarted = true;
      continue;
    }
    if (character === "$" || character === "`") {
      return { ok: false, reason: "shell expansion is not allowed" };
    }
    if (";&|<>()".includes(character) || character === "\n" || character === "\r") {
      return { ok: false, reason: "compound commands and shell control operators are not allowed" };
    }
    if (character === "#") {
      return { ok: false, reason: "shell comments are not allowed" };
    }
    if (/\s/.test(character)) {
      if (wordStarted) {
        words.push(word);
        word = "";
        wordStarted = false;
      }
      continue;
    }
    word += character;
    wordStarted = true;
  }
  if (quote) return { ok: false, reason: "unterminated shell quoting is not allowed" };
  if (escaped) return { ok: false, reason: "a trailing shell escape is not allowed" };
  if (wordStarted) words.push(word);
  return words.length > 0
    ? { ok: true, source, words }
    : { ok: false, reason: "the shell command is empty" };
}

function consumeAccountOption(words, index, state) {
  const word = words[index];
  let value;
  let consumed = 0;
  if (word === "--account" || word === "-a") {
    value = words[index + 1];
    consumed = 1;
  } else if (word.startsWith("--account=")) {
    value = word.slice("--account=".length);
  } else if (word.startsWith("-a=")) {
    value = word.slice(3);
  } else {
    return null;
  }
  if (state.account !== undefined) throw new Error("the Gmail account option must appear exactly once");
  if (!text(value) || String(value).startsWith("-")) throw new Error("the Gmail account must be a literal value");
  state.account = value;
  return consumed;
}

function consumeLongValueOption(words, index, allowed) {
  const word = words[index];
  const equals = word.indexOf("=");
  const name = equals < 0 ? word : word.slice(0, equals);
  if (!allowed.has(name)) return null;
  const value = equals < 0 ? words[index + 1] : word.slice(equals + 1);
  if (value === undefined || value === "") throw new Error(`${name} requires a literal value`);
  return { consumed: equals < 0 ? 1 : 0, name, value };
}

function parseGogDraftWords(words) {
  const executable = words[0];
  const service = String(words[1] || "").toLowerCase();
  const resource = String(words[2] || "").toLowerCase();
  const action = String(words[3] || "").toLowerCase();
  if (!GOG_EXECUTABLES.has(executable) || !GMAIL_ALIASES.has(service) || !DRAFT_ALIASES.has(resource)) return null;

  if (SEND_ACTIONS.has(action)) {
    const state = { account: undefined, draftId: undefined };
    for (let index = 4; index < words.length; index += 1) {
      const accountConsumed = consumeAccountOption(words, index, state);
      if (accountConsumed !== null) {
        index += accountConsumed;
        continue;
      }
      const word = words[index];
      if (SEND_BOOLEAN_OPTIONS.has(word)) continue;
      if (word.startsWith("-")) throw new Error(`unsupported Gmail draft send option ${word}`);
      if (state.draftId !== undefined) throw new Error("a Gmail draft send command must name exactly one draft");
      state.draftId = word;
    }
    if (!state.account) throw new Error("an explicit Gmail account is required");
    if (!state.draftId || !/^[A-Za-z0-9_-]+$/.test(state.draftId)) {
      throw new Error("the Gmail draft id must be one literal identifier");
    }
    return {
      kind: "send",
      executable,
      account: state.account,
      draftId: state.draftId,
      normalized: ["gog", "gmail", "drafts", "send", state.draftId, "--account", state.account],
    };
  }

  if (CREATE_ACTIONS.has(action)) {
    const normalizedAction = CREATE_ACTIONS.get(action);
    const state = { account: undefined, draftId: undefined };
    for (let index = 4; index < words.length; index += 1) {
      const accountConsumed = consumeAccountOption(words, index, state);
      if (accountConsumed !== null) {
        index += accountConsumed;
        continue;
      }
      const word = words[index];
      if (CREATE_BOOLEAN_OPTIONS.has(word)) continue;
      const option = consumeLongValueOption(words, index, CREATE_VALUE_OPTIONS);
      if (option) {
        if (option.name === "--draft-id") {
          if (state.draftId !== undefined) throw new Error("the Gmail draft id must appear exactly once");
          state.draftId = option.value;
        }
        index += option.consumed;
        continue;
      }
      if (!word.startsWith("-") && normalizedAction !== "create" && state.draftId === undefined) {
        state.draftId = word;
        continue;
      }
      throw new Error(`unsupported Gmail draft ${action} argument ${word}`);
    }
    if (!state.account) throw new Error("an explicit Gmail account is required");
    if (state.draftId !== undefined && !/^[A-Za-z0-9_-]+$/.test(state.draftId)) {
      throw new Error("the Gmail draft id must be one literal identifier");
    }
    return {
      kind: "create",
      executable,
      action: normalizedAction,
      account: state.account,
      draftId: state.draftId || "",
      normalized: ["gog", "gmail", "drafts", normalizedAction, "--account", state.account],
    };
  }

  return null;
}

function basename(value) {
  return String(value || "").split("/").pop().toLowerCase();
}

export function compareUtf8(left, right) {
  return Buffer.compare(Buffer.from(String(left), "utf8"), Buffer.from(String(right), "utf8"));
}

function canonicalValue(value) {
  if (Array.isArray(value)) return value.map((item) => canonicalValue(item));
  if (!value || typeof value !== "object" || Buffer.isBuffer(value)) return value;
  const normalized = {};
  const keys = Object.keys(value)
    .filter((key) => value[key] !== undefined)
    .sort(compareUtf8);
  for (const key of keys) normalized[key] = canonicalValue(value[key]);
  return normalized;
}

export function canonicalJson(value) {
  return JSON.stringify(canonicalValue(value));
}

function normalizedSha256(value) {
  const raw = String(value || "").trim().toLowerCase();
  return /^[a-f0-9]{64}$/.test(raw) ? `sha256:${raw}` : raw;
}

export function normalizeApprovalMaterial(material) {
  if (!material || typeof material !== "object" || Array.isArray(material)) return undefined;
  const normalized = {
    kind: material.kind,
    ...(typeof material.target === "string" ? { target: material.target } : {}),
    ...(typeof material.content === "string" ? { content: material.content } : {}),
    ...(material.command ? {
      command: {
        text: material.command.text,
        ...(Array.isArray(material.command.argv)
          ? { argv: material.command.argv.map((item) => String(item)) }
          : {}),
        ...(typeof material.command.cwd === "string" ? { cwd: material.command.cwd } : {}),
      },
    } : {}),
    ...(Array.isArray(material.attachments) ? {
      attachments: material.attachments.map((item) => ({
        name: String(item?.name || ""),
        ...(typeof item?.path === "string" && item.path.length > 0 ? { path: item.path } : {}),
        sha256: normalizedSha256(item?.sha256),
      })).sort((left, right) => (
        compareUtf8(left.name, right.name)
        || compareUtf8(left.path || "", right.path || "")
        || compareUtf8(left.sha256, right.sha256)
      )),
    } : {}),
    ...(Array.isArray(material.artifacts) ? {
      artifacts: material.artifacts.map((item) => ({
        id: String(item?.id || ""),
        sha256: normalizedSha256(item?.sha256),
      })).sort((left, right) => compareUtf8(left.id, right.id) || compareUtf8(left.sha256, right.sha256)),
    } : {}),
    ...(material.runtimeTarget ? {
      runtimeTarget: {
        system: String(material.runtimeTarget.system || ""),
        kind: String(material.runtimeTarget.kind || ""),
        id: String(material.runtimeTarget.id || ""),
      },
    } : {}),
  };
  return normalized;
}

export function approvalMaterialDigest(material) {
  const normalized = normalizeApprovalMaterial(material);
  if (!normalized) throw new Error("approval material is required");
  return digest(canonicalJson(normalized));
}

function suspiciousLiteralMailCommand(words) {
  const executable = basename(words[0]);
  const lowered = words.map((word) => String(word).toLowerCase());
  if (SUSPICIOUS_MAIL_EXECUTABLES.has(executable)) return true;
  if (lowered.some((word) => GMAIL_ALIASES.has(word))
    && lowered.some((word) => DRAFT_ALIASES.has(word))
    && lowered.some((word) => SEND_ACTIONS.has(word))) return true;
  if (executable === "gog" || lowered.includes("gog")) {
    const serviceIndex = lowered.findIndex((word) => GMAIL_ALIASES.has(word));
    if (serviceIndex >= 0 && lowered.slice(serviceIndex + 1).some((word) => (
      SEND_ACTIONS.has(word) || CREATE_ACTIONS.has(word) || /^--?(?:send|deliver|post)(?:=|$)/.test(word)
    ))) return true;
  }
  if (COMMAND_WRAPPERS.has(executable)
    && lowered.some((word) => /\b(?:gmail|email|mail)\b/.test(word))
    && lowered.some((word) => /\b(?:send|deliver|post)\b/.test(word))) return true;
  const joined = lowered.join(" ");
  if (/\bgmail\.users\.(?:messages|drafts)\.send\b/.test(joined)) return true;
  if (/(?:gmail\.googleapis\.com|www\.googleapis\.com\/gmail\/)/.test(joined)
    && /\b(?:send|deliver|post)\b/.test(joined)) return true;
  return lowered.some((word) => (
    /(?:gmail|e-?mail|mail)[_-]?(?:send|deliver|post)/.test(word)
    || /(?:send|deliver|post)[_-]?(?:gmail|e-?mail|mail)/.test(word)
  ));
}

function suspiciousInvalidSource(source) {
  return /\bgog\s+(?:gmail|mail|email)\b[\s\S]*\b(?:create|save|update|upsert|send|deliver|post)\b/i.test(source)
    || /\b(?:sendmail|mailx|msmtp|mutt|neomutt|swaks)\b/i.test(source)
    || /\bgmail\.users\.(?:messages|drafts)\.send\b/i.test(source)
    || /(?:gmail\.googleapis\.com|www\.googleapis\.com\/gmail\/)[\s\S]*\b(?:send|deliver|post)\b/i.test(source)
    || /\b(?:gmail|e-?mail|mail)[_-]?(?:send|deliver|post)\b/i.test(source)
    || /\b(?:send|deliver|post)[_-]?(?:gmail|e-?mail|mail)\b/i.test(source);
}

function effectKey(account, draftId) {
  return `gmail:gog:${account}:${draftId}`;
}

function normalizedProviderAccount(value) {
  const normalized = literalText(value).trim().normalize("NFC").toLowerCase();
  if (!normalized
    || /[\s\r\n\0]/.test(normalized)
    || normalized.indexOf("@") <= 0
    || normalized.lastIndexOf("@") !== normalized.indexOf("@")
    || normalized.endsWith("@")) {
    throw new Error("Gmail did not return one valid canonical provider account identity");
  }
  return normalized;
}

function deepValues(input, keys, depth = 0, found = []) {
  if (!input || typeof input !== "object" || depth > 6) return found;
  for (const [key, value] of Object.entries(input)) {
    if (keys.has(key) && typeof value === "string" && value.trim()) found.push(value);
  }
  for (const value of Object.values(input)) {
    if (value && typeof value === "object") deepValues(value, keys, depth + 1, found);
  }
  return found;
}

function accountSelectorKey(value) {
  return literalText(value).trim().normalize("NFC").toLowerCase();
}

function accountAliases(result) {
  const aliases = result?.aliases;
  if (aliases && typeof aliases === "object" && !Array.isArray(aliases)) {
    return Object.entries(aliases)
      .filter(([alias, account]) => text(alias) && text(account));
  }
  if (!Array.isArray(aliases)) return [];
  return aliases.map((item) => [
    text(item?.alias || item?.name),
    text(item?.email || item?.account),
  ]).filter(([alias, account]) => alias && account);
}

function storedAccountEmails(result) {
  const accounts = Array.isArray(result?.accounts)
    ? result.accounts
    : (Array.isArray(result) ? result : []);
  return accounts
    .map((item) => text(item?.email || item?.account))
    .filter(Boolean);
}

async function resolveGogAccountSelector(requested, { execute, gogExecutable }) {
  const { stdout: aliasesStdout } = await execute(gogExecutable, [
    "auth", "alias", "list", "--json", "--no-input",
  ], { maxBuffer: 2_000_000, timeout: 30_000 });
  const { stdout: accountsStdout } = await execute(gogExecutable, [
    "auth", "list", "--json", "--no-input",
  ], { maxBuffer: 2_000_000, timeout: 30_000 });
  const aliases = parseJsonText(aliasesStdout);
  const accounts = parseJsonText(accountsStdout);
  if (!aliases || !accounts) {
    throw new Error("gog did not return valid account alias and credential metadata");
  }

  const requestedKey = accountSelectorKey(requested);
  const mapped = [...new Set(accountAliases(aliases)
    .filter(([alias]) => accountSelectorKey(alias) === requestedKey)
    .map(([, account]) => accountSelectorKey(account)))];
  if (mapped.length > 1) {
    throw new Error("The Gmail account alias resolves to multiple credential identities");
  }
  const selectedKey = mapped[0] || requestedKey;
  const stored = [...new Set(storedAccountEmails(accounts)
    .map((account) => accountSelectorKey(account))
    .filter((account) => account === selectedKey))];
  return stored[0] || mapped[0] || requested;
}

export async function resolveGogAccountIdentity(account, options = {}) {
  const requested = literalText(account).trim();
  if (!requested || /[\r\n\0]/.test(requested)) {
    throw new Error("A literal Gmail account selector is required");
  }
  const execute = options.execFile || execFileAsync;
  const gogExecutable = options.gogExecutable || "gog";
  const selector = await resolveGogAccountSelector(requested, { execute, gogExecutable });
  const { stdout } = await execute(gogExecutable, [
    "api", "call", "gmail", "v1", "gmail.users.getProfile",
    "--params", JSON.stringify({ userId: "me" }),
    "--account", selector,
    "--json", "--no-input",
  ], { maxBuffer: 2_000_000, timeout: 30_000 });
  const result = parseJsonText(stdout);
  if (!result) throw new Error("Gmail did not return a canonical provider account identity");
  const identities = [...new Set(
    deepValues(result, new Set(["emailAddress", "email_address"]))
      .map((value) => normalizedProviderAccount(value)),
  )];
  if (identities.length !== 1) {
    throw new Error("Gmail did not return one unambiguous canonical provider account identity");
  }
  return identities[0];
}

function draftEffect(kind, parsed) {
  return {
    kind,
    key: effectKey(parsed.account, parsed.draftId),
    provider: "gmail:gog",
    gogExecutable: parsed.executable,
    account: parsed.account,
    draftId: parsed.draftId,
  };
}

export function gmailDraftEffect(account, draftId, gogExecutable = "/usr/local/bin/gog") {
  return draftEffect("outbound-draft-send", {
    account: text(account),
    draftId: text(draftId),
    executable: gogExecutable,
  });
}

function isShellTool(toolName) {
  return /^(exec|exec_command|bash)$/i.test(String(toolName || ""));
}

export function inspectOutboundEmailCommand(toolName, params = {}) {
  if (!isShellTool(toolName)) return { kind: "none" };
  const input = commandInput(params);
  const source = input.source;
  if (!input.ok) {
    return suspiciousInvalidSource(source)
      ? { kind: "blocked", reason: `Outbound Gmail commands must be unambiguous; ${input.reason}.` }
      : { kind: "none" };
  }
  const literal = parseLiteralCommand(source);
  if (!literal.ok) {
    return suspiciousInvalidSource(source)
      ? { kind: "blocked", reason: `Outbound Gmail commands must be one literal allowlisted command; ${literal.reason}.` }
      : { kind: "none" };
  }
  try {
    const parsed = parseGogDraftWords(literal.words);
    if (parsed?.kind === "send") return { kind: "send", effect: draftEffect("outbound-draft-send", parsed) };
    if (parsed?.kind === "create") return { kind: "create", parsed };
  } catch (error) {
    return {
      kind: "blocked",
      reason: `The Gmail draft command is outside the strict approval allowlist: ${error.message}.`,
    };
  }
  if (suspiciousLiteralMailCommand(literal.words)) {
    return {
      kind: "blocked",
      reason: "This looks like an outbound email command, but it is not the single allowlisted Gmail draft command.",
    };
  }
  return { kind: "none" };
}

function parseJsonText(value) {
  const raw = text(value);
  if (!raw) return undefined;
  const objectStart = raw.indexOf("{");
  for (const candidate of [raw, objectStart >= 0 ? raw.slice(objectStart) : ""]) {
    if (!candidate.startsWith("{")) continue;
    try { return JSON.parse(candidate); } catch {}
  }
  return undefined;
}

function resultObjects(result) {
  const found = [];
  if (result && typeof result === "object") found.push(result);
  for (const part of Array.isArray(result?.content) ? result.content : []) {
    if (part?.details && typeof part.details === "object") found.push(part.details);
    const parsed = parseJsonText(part?.text);
    if (parsed) found.push(parsed);
  }
  const parsed = parseJsonText(result);
  if (parsed) found.push(parsed);
  return found;
}

function deepText(input, keys, depth = 0) {
  if (!input || typeof input !== "object" || depth > 6) return "";
  for (const [key, value] of Object.entries(input)) {
    if (keys.has(key) && text(value)) return text(value);
  }
  for (const value of Object.values(input)) {
    if (!value || typeof value !== "object") continue;
    const match = deepText(value, keys, depth + 1);
    if (match) return match;
  }
  return "";
}

function resultDraftId(result) {
  for (const candidate of resultObjects(result)) {
    const draftId = deepText(candidate, new Set(["draftId", "draft_id"]));
    if (draftId) return draftId;
    if (text(candidate?.draft?.id)) return text(candidate.draft.id);
    if (text(candidate?.id) && candidate?.message && typeof candidate.message === "object") {
      return text(candidate.id);
    }
  }
  return "";
}

export function draftCreatedEffect(toolName, params = {}, result, error) {
  if (error) return null;
  const inspection = inspectOutboundEmailCommand(toolName, params);
  if (inspection.kind !== "create") return null;
  const draftId = resultDraftId(result) || inspection.parsed.draftId;
  if (!draftId || !/^[A-Za-z0-9_-]+$/.test(draftId)) return null;
  return draftEffect("outbound-draft-created", { ...inspection.parsed, draftId });
}

export function draftSendEffect(toolName, params = {}) {
  const inspection = inspectOutboundEmailCommand(toolName, params);
  return inspection.kind === "send" ? inspection.effect : null;
}

function decodeBase64url(data, description) {
  const source = literalText(data);
  if (!/^[A-Za-z0-9_-]*={0,2}$/.test(source) || source.length % 4 === 1) {
    throw new Error(`${description} returned invalid base64url data`);
  }
  const bytes = Buffer.from(source, "base64url");
  if (bytes.toString("base64url") !== source.replace(/=+$/, "")) {
    throw new Error(`${description} returned non-canonical base64url data`);
  }
  return bytes;
}

function digest(value) {
  const bytes = Buffer.isBuffer(value) ? value : Buffer.from(String(value || ""), "utf8");
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function orderedHeaders(headers) {
  return (Array.isArray(headers) ? headers : [])
    .map((item) => ({
      name: literalText(item?.name).trim(),
      value: literalText(item?.value),
    }))
    .filter((item) => item.name);
}

function headerValues(payload, name) {
  return orderedHeaders(payload?.headers)
    .filter((item) => item.name.toLowerCase() === name.toLowerCase())
    .map((item) => item.value);
}

function header(payload, name) {
  return headerValues(payload, name).join(", ").trim();
}

function flattenMimeParts(part, path = "0", found = []) {
  if (!part || typeof part !== "object") return found;
  const children = Array.isArray(part.parts) ? part.parts : [];
  found.push({ part, path });
  children.forEach((child, index) => flattenMimeParts(child, `${path}.${index}`, found));
  return found;
}

function contentDisposition(part) {
  return orderedHeaders(part?.headers)
    .find((item) => item.name.toLowerCase() === "content-disposition")?.value || "";
}

function attachmentName(part, path) {
  return literalText(part?.filename).trim() || `mime-part-${path}`;
}

async function exactMimeParts(payload, { execute, account, messageId, gogExecutable }) {
  const descriptors = flattenMimeParts(payload);
  const needsFetch = descriptors.some(({ part }) => text(part.body?.attachmentId));
  const scratch = needsFetch ? await mkdtemp(join(tmpdir(), "org2-gmail-approval-")) : "";
  try {
    const exact = [];
    for (let index = 0; index < descriptors.length; index += 1) {
      const { part, path } = descriptors[index];
      const data = part.body?.data;
      const attachmentId = text(part.body?.attachmentId);
      if (data !== undefined && attachmentId) {
        throw new Error(`Gmail MIME part ${path} returned both inline data and an attachment id`);
      }
      let bytes;
      if (data !== undefined) {
        bytes = decodeBase64url(data, `Gmail MIME part ${path}`);
      } else if (attachmentId) {
        if (!messageId) throw new Error(`Gmail MIME part ${path} needs a message id to fetch exact bytes`);
        const output = join(scratch, `part-${index}`);
        await execute(gogExecutable, [
          "gmail", "attachment", messageId, attachmentId,
          "--account", account,
          "--out", output,
          "--no-input",
        ], { maxBuffer: 2_000_000, timeout: 30_000 });
        bytes = await readFile(output);
      } else {
        if (Number(part.body?.size || 0) > 0) {
          throw new Error(`Gmail MIME part ${path} omitted ${part.body.size} bytes`);
        }
        bytes = Buffer.alloc(0);
      }
      const disposition = contentDisposition(part);
      const filename = literalText(part.filename).trim();
      const mimeType = text(part.mimeType) || "application/octet-stream";
      const isText = /^text\//i.test(mimeType);
      const isAttachment = Boolean(filename)
        || /\b(?:attachment|inline)\b/i.test(disposition)
        || (Boolean(attachmentId) && !isText);
      exact.push({
        path,
        mimeType,
        filename,
        disposition,
        headers: orderedHeaders(part.headers),
        size: bytes.length,
        sha256: digest(bytes),
        content: isText ? bytes.toString("utf8") : undefined,
        isAttachment,
        attachmentName: isAttachment ? attachmentName(part, path) : undefined,
      });
    }
    return exact;
  } finally {
    if (scratch) await rm(scratch, { recursive: true, force: true });
  }
}

function renderHeaders(headers) {
  return headers.length > 0
    ? headers.map((item) => `${item.name}: ${item.value}`).join("\n")
    : "(none)";
}

function renderMimePart(part) {
  return [
    `Part: ${part.path}`,
    `MIME-Type: ${part.mimeType}`,
    `Filename: ${part.filename || "(none)"}`,
    `Disposition: ${part.disposition || "(none)"}`,
    `Size: ${part.size}`,
    `SHA-256: ${part.sha256}`,
    "Part headers:",
    renderHeaders(part.headers),
    ...(part.content === undefined ? [] : ["Content:", part.content]),
  ].join("\n");
}

export function reviewContent(effect) {
  return [
    `Account: ${effect.account}`,
    `From: ${effect.from || "(none)"}`,
    `Sender: ${effect.sender || "(none)"}`,
    `Reply-To: ${effect.replyTo || "(none)"}`,
    `To: ${effect.destination}`,
    `Cc: ${effect.cc || "(none)"}`,
    `Bcc: ${effect.bcc || "(none)"}`,
    `Subject: ${effect.subject}`,
    `Draft ID: ${effect.draftId}`,
    `Message ID: ${effect.messageId || "(none)"}`,
    `Thread ID: ${effect.threadId || "(none)"}`,
    `In-Reply-To: ${effect.inReplyTo || "(none)"}`,
    `References: ${effect.references || "(none)"}`,
    "",
    "Message headers:",
    renderHeaders(effect.headers || []),
    "",
    "MIME bodies and parts:",
    ...(effect.mimeParts || []).map(renderMimePart),
  ].join("\n");
}

function structuredMimeContent(effect) {
  return {
    schema: "org2:gmail-draft-material:v1",
    account: effect.account,
    draftId: effect.draftId,
    messageId: effect.messageId,
    threadId: effect.threadId,
    rawSha256: effect.rawSha256,
    envelope: {
      from: effect.from,
      sender: effect.sender,
      replyTo: effect.replyTo,
      to: effect.destination,
      cc: effect.cc,
      bcc: effect.bcc,
      subject: effect.subject,
      inReplyTo: effect.inReplyTo,
      references: effect.references,
    },
    headers: effect.headers || [],
    mimeParts: (effect.mimeParts || []).map((part) => ({
      path: part.path,
      mimeType: part.mimeType,
      filename: part.filename,
      disposition: part.disposition,
      headers: part.headers,
      size: part.size,
      sha256: part.sha256,
      content: part.content,
      isAttachment: part.isAttachment,
      attachmentName: part.attachmentName,
    })),
  };
}

async function exactRawMessage({ execute, account, messageId, gogExecutable }) {
  const { stdout } = await execute(gogExecutable, [
    "gmail", "raw", messageId,
    "--format", "raw",
    "--account", account,
    "--json", "--no-input",
  ], { maxBuffer: 20_000_000, timeout: 30_000 });
  let result;
  try {
    result = JSON.parse(stdout);
  } catch {
    throw new Error(`Gmail message ${messageId} did not return valid raw JSON`);
  }
  const raw = [
    result?.raw,
    result?.message?.raw,
    result?.result?.raw,
    result?.data?.raw,
  ].find((value) => typeof value === "string" && value.length > 0);
  if (!raw) throw new Error(`Gmail message ${messageId} did not return an RFC822 raw payload`);
  const bytes = decodeBase64url(raw, `Gmail message ${messageId} raw payload`);
  if (bytes.length === 0) throw new Error(`Gmail message ${messageId} returned an empty RFC822 payload`);
  return {
    raw: bytes.toString("base64url"),
    sha256: digest(bytes),
  };
}

export async function hydrateGogDraftEffect(effect, options = {}) {
  const execute = options.execFile || execFileAsync;
  const gogExecutable = options.gogExecutable || effect.gogExecutable || "gog";
  const resolveAccountIdentity = options.resolveAccountIdentity || resolveGogAccountIdentity;
  const account = normalizedProviderAccount(await resolveAccountIdentity(effect.account, {
    execFile: execute,
    gogExecutable,
  }));
  effect = {
    ...effect,
    key: effectKey(account, effect.draftId),
    provider: "gmail:gog",
    gogExecutable,
    account,
  };
  const { stdout } = await execute(gogExecutable, [
    "gmail", "drafts", "get", effect.draftId,
    "--account", effect.account,
    "--json", "--no-input",
  ], { maxBuffer: 2_000_000, timeout: 30_000 });
  let result;
  try {
    result = JSON.parse(stdout);
  } catch {
    throw new Error(`Gmail draft ${effect.draftId} did not return valid JSON review material`);
  }
  const message = result.draft?.message || result.message;
  const payload = message?.payload;
  if (!payload) throw new Error(`Gmail draft ${effect.draftId} did not return exact review material`);
  const destination = header(payload, "to");
  const subject = header(payload, "subject");
  if (!destination || !subject) throw new Error(`Gmail draft ${effect.draftId} is missing its recipient or subject`);
  const messageId = text(message.id);
  const threadId = text(message.threadId || result.draft?.threadId || result.threadId);
  if (!messageId || !threadId) {
    throw new Error(`Gmail draft ${effect.draftId} is missing its message or thread identity`);
  }
  const mimeParts = await exactMimeParts(payload, {
    execute,
    account: effect.account,
    messageId,
    gogExecutable,
  });
  const rawMessage = await exactRawMessage({
    execute,
    account: effect.account,
    messageId,
    gogExecutable,
  });
  const { stdout: verifiedStdout } = await execute(gogExecutable, [
    "gmail", "drafts", "get", effect.draftId,
    "--account", effect.account,
    "--json", "--no-input",
  ], { maxBuffer: 2_000_000, timeout: 30_000 });
  let verifiedResult;
  try {
    verifiedResult = JSON.parse(verifiedStdout);
  } catch {
    throw new Error(`Gmail draft ${effect.draftId} did not return valid JSON during exact-material verification`);
  }
  const verifiedMessage = verifiedResult.draft?.message || verifiedResult.message;
  if (!verifiedMessage || canonicalJson(verifiedMessage) !== canonicalJson(message)) {
    throw new Error(`Gmail draft ${effect.draftId} changed while its exact review material was being read`);
  }
  const attachments = mimeParts
    .filter((part) => part.isAttachment)
    .map((part) => ({ name: part.attachmentName, sha256: part.sha256 }))
    .sort((left, right) => compareUtf8(left.name, right.name) || compareUtf8(left.sha256, right.sha256));
  const hydrated = {
    ...effect,
    destination,
    cc: header(payload, "cc"),
    bcc: header(payload, "bcc"),
    subject,
    from: header(payload, "from"),
    sender: header(payload, "sender"),
    replyTo: header(payload, "reply-to"),
    inReplyTo: header(payload, "in-reply-to"),
    references: header(payload, "references"),
    messageId,
    threadId,
    headers: orderedHeaders(payload.headers),
    mimeParts,
    attachments,
    rawMessage: rawMessage.raw,
    rawSha256: rawMessage.sha256,
  };
  const content = reviewContent(hydrated);
  const structuredContent = canonicalJson(structuredMimeContent(hydrated));
  const material = {
    kind: "message",
    target: destination,
    content: structuredContent,
    ...(attachments.length > 0 ? { attachments } : {}),
    runtimeTarget: {
      system: "gmail:gog",
      kind: "draft",
      id: effect.key,
    },
  };
  return {
    ...hydrated,
    reviewContent: content,
    structuredContent,
    materialDigest: approvalMaterialDigest(material),
    title: `Approve “${subject}” to ${destination}`.slice(0, 240),
    action: `Send Gmail draft ${effect.draftId} from ${effect.account} using the exact message and attachments shown in the bound approval material.`,
    note: content,
    material,
  };
}

export function sameApprovalMaterial(left, right) {
  return canonicalJson(normalizeApprovalMaterial(left) || null)
    === canonicalJson(normalizeApprovalMaterial(right) || null);
}

export function strictProviderMessageId(result, options = {}) {
  const parsed = typeof result === "string" ? parseJsonText(result) : result;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Gmail send did not return a JSON provider receipt");
  }
  const candidates = [
    parsed.messageId,
    parsed.message_id,
    parsed.message?.id,
    ...(options.allowTopLevelId ? [parsed.id] : []),
  ].filter((value) => typeof value === "string" && value.trim());
  const unique = [...new Set(candidates.map((value) => value.trim()))];
  if (unique.length !== 1 || !/^[A-Za-z0-9_-]+$/.test(unique[0])) {
    throw new Error("Gmail send did not return one unambiguous provider message id");
  }
  return unique[0];
}

export function strictProviderGmailSendReceipt(result) {
  const parsed = typeof result === "string" ? parseJsonText(result) : result;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Gmail send did not return a JSON provider receipt");
  }
  const messageId = strictProviderMessageId(parsed, { allowTopLevelId: true });
  const candidates = [
    parsed.threadId,
    parsed.thread_id,
    parsed.message?.threadId,
    parsed.message?.thread_id,
  ].filter((value) => typeof value === "string" && value.trim());
  const unique = [...new Set(candidates.map((value) => value.trim()))];
  if (unique.length !== 1 || !/^[A-Za-z0-9_-]+$/.test(unique[0])) {
    throw new Error("Gmail send did not return one unambiguous provider thread id");
  }
  return { messageId, threadId: unique[0] };
}
