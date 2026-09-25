function string(value) {
  return typeof value === "string" ? value.trim() : "";
}

function commandText(params = {}) {
  if (typeof params === "string") return params;
  return string(params.command || params.cmd || params.source || params.code || params.input);
}

export function directGogDraftMutation(toolName, params = {}) {
  if (!/(?:^|[_.:])(exec|exec_command|bash|shell|terminal)$/i.test(toolName)) return null;
  const source = commandText(params);
  const match = source.match(/(?:^|[\s"'`;(])(?:\/[A-Za-z0-9._/-]+\/)?gog(?:-scarf-headless)?\s+gmail\s+drafts?\s+(create|update|edit|set)\b/i);
  if (!match) return null;
  return { operation: /create/i.test(match[1]) ? "create" : "update", command: source };
}

export function unsafeGmailDraftMutation(toolName, params = {}) {
  const direct = directGogDraftMutation(toolName, params);
  if (direct) return direct;
  const descriptor = [toolName, params?.action, params?.operation, params?.provider, params?.service]
    .map((value) => string(value))
    .filter(Boolean)
    .join(" ");
  const words = descriptor.replace(/[^A-Za-z0-9]+/g, " ");
  if (!/(?:gmail|google\s*mail)/i.test(words)) return null;
  if (!/\bdraft\b/i.test(words)) return null;
  const match = words.match(/\b(create|update|edit|set|save|upsert)\b/i);
  if (!match || /\b(send|delete|remove)\b/i.test(words)) return null;
  return { operation: /create|save/i.test(match[1]) ? "create" : "update", command: descriptor };
}

function escapeHtml(value) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function normalizePlainText(value) {
  return String(value ?? "").replace(/\r\n?/g, "\n").replace(/[ \t]+$/gm, "").replace(/\n+$/, "");
}

export function suspiciousHardWraps(value) {
  const paragraphs = normalizePlainText(value).split(/\n{2,}/);
  const problems = [];
  for (const paragraph of paragraphs) {
    const lines = paragraph.split("\n");
    if (lines.length < 2) continue;
    const list = lines.every((line) => /^\s*(?:[-*+] |\d+[.)] )/.test(line));
    const shortBlock = lines.every((line) => line.length <= 40);
    if (list || shortBlock) continue;
    const wrapped = lines.slice(0, -1).some((line) => line.length >= 55)
      || lines.some((line) => line.length >= 45 && !/[.!?:;,)]$/.test(line));
    if (wrapped) problems.push("body contains prose split across single newlines; use blank lines between paragraphs and let Gmail wrap prose visually");
  }
  return [...new Set(problems)];
}

export function plainTextToHtml(value) {
  const body = normalizePlainText(value);
  return body.split(/\n{2,}/).filter(Boolean).map((paragraph) => {
    const lines = paragraph.split("\n");
    if (lines.every((line) => /^\s*[-*+]\s+/.test(line))) {
      return `<ul>${lines.map((line) => `<li>${escapeHtml(line.replace(/^\s*[-*+]\s+/, ""))}</li>`).join("")}</ul>`;
    }
    if (lines.every((line) => /^\s*\d+[.)]\s+/.test(line))) {
      return `<ol>${lines.map((line) => `<li>${escapeHtml(line.replace(/^\s*\d+[.)]\s+/, ""))}</li>`).join("")}</ol>`;
    }
    return `<p>${lines.map(escapeHtml).join("<br>")}</p>`;
  }).join("");
}

function decodeBase64Url(value) {
  return Buffer.from(String(value || "").replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8");
}

function parts(payload, found = []) {
  if (!payload || typeof payload !== "object") return found;
  found.push(payload);
  for (const part of payload.parts || []) parts(part, found);
  return found;
}

export function header(payload, name) {
  return string((payload?.headers || []).find((item) => string(item?.name).toLowerCase() === name.toLowerCase())?.value);
}

export function validateSafeDraft(result, expected = {}) {
  const payload = result?.draft?.message?.payload || result?.message?.payload;
  if (!payload) return ["provider readback did not include an inspectable MIME payload"];
  const all = parts(payload);
  const plainPart = all.find((part) => part.mimeType === "text/plain" && part.body?.data);
  const htmlPart = all.find((part) => part.mimeType === "text/html" && part.body?.data);
  const problems = [];
  const plain = plainPart ? normalizePlainText(decodeBase64Url(plainPart.body.data)) : "";
  const html = htmlPart ? decodeBase64Url(htmlPart.body.data) : "";
  if (!plainPart) problems.push("draft has no text/plain fallback");
  if (!htmlPart) problems.push("draft has no text/html body");
  if (!all.some((part) => part.mimeType === "multipart/alternative")) problems.push("draft is not multipart/alternative");
  if (expected.body !== undefined && plain !== normalizePlainText(expected.body)) problems.push("provider plain-text readback differs from the requested body");
  if (expected.html !== undefined && html !== expected.html) problems.push("provider HTML readback differs from the generated fluid body");
  problems.push(...suspiciousHardWraps(plain));
  if (expected.account && !header(payload, "from").toLowerCase().includes(`<${expected.account.toLowerCase()}>`)) {
    problems.push(`From header does not match ${expected.account}`);
  }
  if (expected.to && header(payload, "to") !== expected.to) problems.push("provider To header differs from the requested recipients");
  if (expected.subject && header(payload, "subject") !== expected.subject) problems.push("provider Subject header differs from the requested subject");
  if (expected.threadId && (result?.draft?.message?.threadId || result?.message?.threadId) !== expected.threadId) {
    problems.push("provider thread ID differs from the requested thread");
  }
  if (expected.anchorMessageId && header(payload, "in-reply-to") !== expected.anchorMessageId) {
    problems.push("draft does not reply to the selected surviving message");
  }
  return [...new Set(problems)];
}
