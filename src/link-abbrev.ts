import type { DocumentNode } from "./ast.js";

export type LinkAbbreviationMap = Map<string, string>;

export type LinkAbbreviationRecord = Record<string, string>;

const LINK_LINE_RE = /^\s*#\+LINK:\s*([^\s]+)\s+(.*?)\s*$/i;

const RESERVED_PREFIXES = new Set(["http", "https", "mailto", "file", "id"]);

function normalizePrefix(value: string): string {
  return String(value || "").trim().toLowerCase();
}

function normalizeTemplate(value: string): string {
  return String(value || "").trim();
}

function setIfValid(out: LinkAbbreviationMap, prefixRaw: string, templateRaw: string): void {
  const prefix = normalizePrefix(prefixRaw);
  const template = normalizeTemplate(templateRaw);
  if (!prefix || !template) return;
  out.set(prefix, template);
}

export function buildBuiltInLinkAbbreviations(linearTeam?: string): LinkAbbreviationMap {
  const out: LinkAbbreviationMap = new Map();
  out.set("gh", "https://github.com/%s");
  out.set("gl", "https://gitlab.com/%s");
  out.set("yt", "https://www.youtube.com/watch?v=%s");
  out.set("wiki", "https://en.wikipedia.org/wiki/%s");

  const team = String(linearTeam || "").trim();
  if (team) {
    out.set("linear", `https://linear.app/${team}/issue/%s`);
  }

  return out;
}

export function collectLinkAbbreviationsFromDoc(doc: DocumentNode): LinkAbbreviationMap {
  const out: LinkAbbreviationMap = new Map();

  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    if (String(node.keyRaw || "").trim().toUpperCase() !== "LINK") continue;

    const raw = String(node.valueRaw || "").trim();
    if (!raw) continue;

    const parts = raw.split(/\s+/);
    if (parts.length < 2) continue;

    const prefix = parts[0] || "";
    const template = raw.slice(prefix.length).trim();
    setIfValid(out, prefix, template);
  }

  return out;
}

export function collectLinkAbbreviationsFromText(text: string): LinkAbbreviationMap {
  const out: LinkAbbreviationMap = new Map();
  for (const line of String(text || "").split(/\r?\n/)) {
    const m = LINK_LINE_RE.exec(line);
    if (!m) continue;
    setIfValid(out, m[1] || "", m[2] || "");
  }
  return out;
}

export function collectLinkAbbreviationsFromRecord(record?: LinkAbbreviationRecord): LinkAbbreviationMap {
  const out: LinkAbbreviationMap = new Map();
  if (!record || typeof record !== "object") return out;

  for (const [prefix, template] of Object.entries(record)) {
    setIfValid(out, prefix, template);
  }

  return out;
}

export function mergeLinkAbbreviations(sources: Array<LinkAbbreviationMap | undefined | null>): LinkAbbreviationMap {
  const out: LinkAbbreviationMap = new Map();
  for (const source of sources) {
    if (!source) continue;
    for (const [prefix, template] of source.entries()) {
      out.set(prefix, template);
    }
  }
  return out;
}

export function expandLinkAbbreviationTarget(targetRaw: string, abbreviations?: LinkAbbreviationMap): string {
  const target = String(targetRaw || "").trim();
  if (!target || !abbreviations || abbreviations.size === 0) return target;

  const match = /^([A-Za-z][A-Za-z0-9+.-]*):(.*)$/.exec(target);
  if (!match) return target;

  const prefix = normalizePrefix(match[1]);
  if (!prefix || RESERVED_PREFIXES.has(prefix)) return target;

  const suffix = match[2] ?? "";
  const template = abbreviations.get(prefix);
  if (!template) return target;

  if (template.includes("%s")) {
    return template.replace(/%s/g, suffix);
  }

  return `${template}${suffix}`;
}
