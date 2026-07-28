import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

function object(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function string(value) {
  return typeof value === "string" ? value.trim() : "";
}

function embeddedCommand(value) {
  const source = string(value);
  const match = source.match(/\b(?:cmd|command)\s*:\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)/s);
  if (!match) return source;
  const literal = match[1];
  if (literal.startsWith('"')) {
    try { return JSON.parse(literal); } catch {}
  }
  return literal.slice(1, -1)
    .replace(/\\([\\'"`])/g, "$1")
    .replace(/\\n/g, "\n")
    .replace(/\\t/g, "\t");
}

function command(params = {}) {
  if (typeof params === "string") return embeddedCommand(params);
  return embeddedCommand(params.command || params.cmd || params.source || params.code || params.input);
}

function operation(toolName, params = {}) {
  if (/^(exec|exec_command|bash)$/i.test(toolName)) {
    return command(params);
  }
  return [toolName, params.action, params.operation].map(string).filter(Boolean).join(" ");
}

function shellWords(value) {
  const words = [];
  let word = "";
  let quote = "";
  let escaped = false;
  for (const character of string(value)) {
    if (escaped) { word += character; escaped = false; continue; }
    if (character === "\\" && quote !== "'") { escaped = true; continue; }
    if (quote) {
      if (character === quote) quote = "";
      else word += character;
      continue;
    }
    if (character === "'" || character === '"') { quote = character; continue; }
    if (/\s/.test(character)) {
      if (word) { words.push(word); word = ""; }
      continue;
    }
    word += character;
  }
  if (word) words.push(word);
  return words;
}

function commandOption(params, name) {
  const words = shellWords(command(params));
  const index = words.findIndex((word) => word === `--${name}` || word.startsWith(`--${name}=`));
  if (index < 0) return "";
  return words[index].includes("=") ? words[index].slice(words[index].indexOf("=") + 1) : string(words[index + 1]);
}

function isDraftCreate(value) {
  return /draft/i.test(value) && /(create|save|update|upsert)/i.test(value) && !/(send|delete|remove)/i.test(value);
}

function isDraftSend(value) {
  return /draft/i.test(value) && /(send|deliver)/i.test(value);
}

function parseJsonText(value) {
  const text = string(value);
  if (!text) return undefined;
  for (const candidate of [text, text.slice(text.indexOf("{")).trim()]) {
    if (!candidate.startsWith("{")) continue;
    try { return JSON.parse(candidate); } catch {}
  }
  return undefined;
}

function resultObjects(result) {
  const found = [];
  if (result && typeof result === "object") found.push(result);
  const content = Array.isArray(result?.content) ? result.content : [];
  for (const part of content) {
    if (part?.details && typeof part.details === "object") found.push(part.details);
    const parsed = parseJsonText(part?.text);
    if (parsed) found.push(parsed);
  }
  const parsed = parseJsonText(result);
  if (parsed) found.push(parsed);
  return found;
}

function deepValue(input, keys, depth = 0) {
  if (!input || typeof input !== "object" || depth > 6) return "";
  for (const [key, value] of Object.entries(input)) {
    if (keys.has(key) && string(value)) return string(value);
  }
  for (const value of Object.values(input)) {
    if (!value || typeof value !== "object") continue;
    const match = deepValue(value, keys, depth + 1);
    if (match) return match;
  }
  return "";
}

function commandDraftId(command, mode) {
  const pattern = mode === "send"
    ? /gmail\s+drafts?\s+send\s+["']?([A-Za-z0-9_-]+)/i
    : /(?:draftId|draft_id)["'=:\s]+([A-Za-z0-9_-]+)/i;
  return string(command).match(pattern)?.[1] || "";
}

function draftIdFromResult(result) {
  const preferred = new Set(["draftId", "draft_id"]);
  const fallback = new Set(["id"]);
  for (const candidate of resultObjects(result)) {
    const preferredId = deepValue(candidate, preferred);
    if (preferredId) return preferredId;
  }
  for (const candidate of resultObjects(result)) {
    const fallbackId = deepValue(candidate, fallback);
    if (fallbackId) return fallbackId;
  }
  return "";
}

function draftIdFromParams(params, mode) {
  return deepValue(params, new Set(["draftId", "draft_id"]))
    || commandDraftId(command(params), mode);
}

function account(params) {
  return deepValue(params, new Set(["account", "accountId", "account_id", "connectionId"]))
    || commandOption(params, "account")
    || "default";
}

function destination(params) {
  return deepValue(params, new Set(["to", "recipient", "recipients", "channel", "channelId", "conversationId"]))
    || commandOption(params, "to")
    || "external recipient";
}

function subject(params) {
  return deepValue(params, new Set(["subject", "title"]))
    || commandOption(params, "subject")
    || "external message";
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value)
    .filter(([key]) => !["confirmed", "confirmation", "timeoutMs"].includes(key))
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, item]) => [key, stable(item)]));
}

function fingerprint(params) {
  return createHash("sha256").update(JSON.stringify(stable(params))).digest("hex");
}

function provider(toolName, op) {
  if (/gog\s+gmail/i.test(op)) return "gmail:gog";
  return toolName;
}

function isShellTool(toolName) {
  return /^(exec|exec_command|bash)$/i.test(toolName);
}

function effectKey(providerName, accountName, draftId) {
  return `${providerName}:${accountName}:${draftId}`;
}

export function draftCreatedEffect(toolName, params = {}, result, error) {
  const op = operation(toolName, params);
  if (error || !isDraftCreate(op)) return null;
  // Shell results commonly contain unrelated generic `id` fields. Only the
  // explicitly supported gog Gmail command is safe to classify as a draft;
  // connector tools remain discoverable from their draft-specific names.
  if (isShellTool(toolName) && !/\bgog\s+gmail\s+drafts?\s+(?:create|save|update|upsert)\b/i.test(op)) return null;
  const draftId = draftIdFromResult(result) || draftIdFromParams(params, "create");
  if (!draftId) return null;
  const providerName = provider(toolName, op);
  const accountName = account(params);
  return {
    kind: "outbound-draft-created",
    key: effectKey(providerName, accountName, draftId),
    provider: providerName,
    account: accountName,
    draftId,
    destination: destination(params),
    subject: subject(params),
    body: deepValue(params, new Set(["body", "text", "bodyText", "body_text"])) || commandOption(params, "body"),
    fingerprint: fingerprint(params),
  };
}

export function draftSendEffect(toolName, params = {}) {
  const op = operation(toolName, params);
  if (!isDraftSend(op)) return null;
  if (isShellTool(toolName) && !/\bgog\s+gmail\s+drafts?\s+(?:send|deliver)\b/i.test(op)) return null;
  const draftId = draftIdFromParams(params, "send");
  if (!draftId) return null;
  const providerName = provider(toolName, op);
  const accountName = account(params);
  return {
    kind: "outbound-draft-send",
    key: effectKey(providerName, accountName, draftId),
    provider: providerName,
    account: accountName,
    draftId,
  };
}

export function approvalTitle(effect) {
  return `Approve “${effect.subject}” to ${effect.destination}`.slice(0, 240);
}

export function approvalContext(effect) {
  return [
    `entity:email:${effect.destination}`,
    `artifact:${effect.provider}:${effect.draftId}`,
  ];
}

export function approvalAction(effect) {
  const fields = [
    `To: ${effect.destination}`,
    `Cc: ${effect.cc || "(none)"}`,
    `Bcc: ${effect.bcc || "(none)"}`,
    `Subject: ${effect.subject}`,
    "",
    "Body:",
    effect.body || "(Body unavailable; open the provider draft before approving.)",
    "",
    `Provider draft: ${effect.provider}:${effect.draftId}`,
    `Content fingerprint: ${effect.fingerprint}`,
  ];
  return fields.join("\n");
}

function decodeBody(data) {
  if (!string(data)) return "";
  try { return Buffer.from(data.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8"); } catch { return ""; }
}

function messageBody(payload) {
  if (!payload || typeof payload !== "object") return "";
  if (payload.mimeType === "text/plain" && payload.body?.data) return decodeBody(payload.body.data);
  for (const part of payload.parts || []) {
    const body = messageBody(part);
    if (body) return body;
  }
  return decodeBody(payload.body?.data);
}

function header(payload, name) {
  return string((payload?.headers || []).find((item) => string(item?.name).toLowerCase() === name.toLowerCase())?.value);
}

export async function hydrateGogDraftEffect(effect) {
  if (effect.provider !== "gmail:gog" || !effect.account || effect.account === "default") return effect;
  try {
    const { stdout } = await execFileAsync("gog", [
      "gmail", "drafts", "get", effect.draftId,
      "--account", effect.account,
      "--json", "--no-input",
    ], { maxBuffer: 2_000_000 });
    const result = JSON.parse(stdout);
    const payload = result.draft?.message?.payload || result.message?.payload;
    if (!payload) return effect;
    const readable = {
      ...effect,
      destination: header(payload, "to") || effect.destination,
      cc: header(payload, "cc"),
      bcc: header(payload, "bcc"),
      subject: header(payload, "subject") || effect.subject,
      body: messageBody(payload) || effect.body,
    };
    readable.fingerprint = fingerprint({
      to: readable.destination,
      cc: readable.cc,
      bcc: readable.bcc,
      subject: readable.subject,
      body: readable.body,
    });
    return readable;
  } catch {
    return effect;
  }
}
