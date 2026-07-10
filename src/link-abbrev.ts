import type { DocumentNode } from "./ast.js";

export type LinkAbbreviationMap = Map<string, string>;

export type LinkAbbreviationRecord = Record<string, string>;

const LINK_LINE_RE = /^\s*#\+LINK:\s*([^\s]+)\s+(.*?)\s*$/i;
const ABBREVIATION_PREFIX_RE = /^[A-Za-z][A-Za-z0-9+.-]*$/;

const RESERVED_PREFIXES = new Set(["http", "https", "mailto", "file", "id"]);

type LinkAbbreviationEntry = {
  prefix: string;
  template: string;
};

function normalizePrefix(value: string): string {
  return String(value || "").trim().toLowerCase();
}

function normalizeTemplate(value: string): string {
  return String(value || "").trim();
}

function parseLinkAbbreviationEntry(prefixRaw: string, templateRaw: string): LinkAbbreviationEntry | null {
  const prefix = normalizePrefix(prefixRaw);
  const template = normalizeTemplate(templateRaw);
  if (!prefix || !template) return null;
  if (!ABBREVIATION_PREFIX_RE.test(prefix)) return null;
  return { prefix, template };
}

function parseLinkAbbreviationDefinition(raw: string): LinkAbbreviationEntry | null {
  const definition = String(raw || "").trim();
  if (!definition) return null;

  const match = /^([^\s]+)\s+(.+?)\s*$/.exec(definition);
  if (!match) return null;
  return parseLinkAbbreviationEntry(match[1] || "", match[2] || "");
}

function setIfValid(out: LinkAbbreviationMap, prefixRaw: string, templateRaw: string): void {
  const entry = parseLinkAbbreviationEntry(prefixRaw, templateRaw);
  if (!entry) return;
  out.set(entry.prefix, entry.template);
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

    const entry = parseLinkAbbreviationDefinition(node.valueRaw || "");
    if (!entry) continue;
    out.set(entry.prefix, entry.template);
  }

  return out;
}

export function collectLinkAbbreviationsFromText(text: string): LinkAbbreviationMap {
  const out: LinkAbbreviationMap = new Map();
  for (const line of String(text || "").split(/\r?\n/)) {
    const m = LINK_LINE_RE.exec(line);
    if (!m) continue;
    const entry = parseLinkAbbreviationEntry(m[1] || "", m[2] || "");
    if (!entry) continue;
    out.set(entry.prefix, entry.template);
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
