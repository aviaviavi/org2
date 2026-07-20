import { createHash } from "node:crypto";

function object(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function string(value) {
  return typeof value === "string" ? value.trim() : "";
}

function operation(toolName, params = {}) {
  if (toolName === "clawlink_call_tool") return string(params.tool);
  if (/^(exec|exec_command|bash)$/i.test(toolName)) {
    return string(params.command || params.cmd || params.source || params.code || params.input);
  }
  return [toolName, params.action, params.operation].map(string).filter(Boolean).join(" ");
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
    || commandDraftId(params.command || params.cmd || params.source || params.code || params.input, mode);
}

function account(params) {
  return deepValue(params, new Set(["account", "accountId", "account_id", "connectionId"])) || "default";
}

function destination(params) {
  return deepValue(params, new Set(["to", "recipient", "recipients", "channel", "channelId", "conversationId"])) || "external recipient";
}

function subject(params) {
  return deepValue(params, new Set(["subject", "title"])) || "external message";
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
  if (toolName === "clawlink_call_tool") return `clawlink:${op.split(/[_:.]/)[0] || "external"}`;
  if (/gog\s+gmail/i.test(op)) return "gmail:gog";
  return toolName;
}

function effectKey(providerName, accountName, draftId) {
  return `${providerName}:${accountName}:${draftId}`;
}

export function draftCreatedEffect(toolName, params = {}, result, error) {
  const op = operation(toolName, params);
  if (error || !isDraftCreate(op)) return null;
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
    fingerprint: fingerprint(params),
  };
}

export function draftSendEffect(toolName, params = {}) {
  const op = operation(toolName, params);
  if (!isDraftSend(op)) return null;
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
  return `Approve ${effect.subject} draft to ${effect.destination}`.slice(0, 240);
}

export function approvalAction(effect) {
  return `Send the ${effect.provider} draft ${effect.draftId} to ${effect.destination}. Content fingerprint: ${effect.fingerprint}`;
}
