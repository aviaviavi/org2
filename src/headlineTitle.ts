function normalizeHeadlineTodoToken(raw: string): string {
  return String(raw || "")
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

function isRecognizedHeadlineTodoKeyword(value: string): boolean {
  const key = normalizeHeadlineTodoToken(value);
  if (!key) return false;

  if (["TODO", "OPEN", "BACKLOG"].includes(key)) return true;
  if (["PROG", "IN_PROGRESS", "INPROGRESS", "DOING", "STARTED", "WAITING", "WAIT", "BLOCKED", "NEXT", "WIP", "HOLD", "ON_HOLD", "ONHOLD", "PAUSED", "PAUSE"].includes(key)) return true;
  if (["DONE", "COMPLETE", "COMPLETED", "FINISH", "FINISHED", "CLOSED", "RESOLVED"].includes(key)) return true;
  if (["CANCELED", "CANCELLED"].includes(key)) return true;

  return false;
}

export function stripRecognizedHeadlineTodoKeyword(headline: string): string {
  const text = String(headline || "").trim();
  if (!text) return "";

  const match = /^(\S+)\s+(.+)$/.exec(text);
  if (!match) return text;
  if (!isRecognizedHeadlineTodoKeyword(match[1] || "")) return text;
  return String(match[2] || "").trim();
}

export function stripHeadlinePriorityCookie(headline: string): string {
  return String(headline || "")
    .replace(/^\s*\[#([A-Z0-9])\]\s+/, "")
    .trim();
}

export function parseHeadlineTitleForRoam(line: string): string {
  const withoutStars = String(line || "").trim().replace(/^\*+\s+/, "");
  const withoutTags = withoutStars.replace(/\s+:[^\s:]+(?::[^\s:]+)*:\s*$/, "").trim();
  return stripHeadlinePriorityCookie(stripRecognizedHeadlineTodoKeyword(withoutTags));
}
