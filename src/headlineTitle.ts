import { normalizeTodoKeyword } from "./todo.js";

function isRecognizedHeadlineTodoKeyword(value: string): boolean {
  return normalizeTodoKeyword(value) !== undefined;
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
