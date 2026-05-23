import fs from "node:fs";
import path from "node:path";
import { buildGeneratedArtifactMetadata, sha256Hex, type Org2GeneratedArtifactMetadata } from "./artifactMetadata.js";
import { TODO_KEYWORDS } from "./todo.js";

export type CompiledCorpusLink = {
  type: "id" | "wiki" | "file" | "url" | "other";
  target: string;
  description?: string;
  line: number;
};

export type CompiledCorpusBacklink = {
  sourceKey: string;
  sourceId: string | null;
  sourceTitle: string;
  file: string;
  line: number;
  linkType: "id" | "wiki";
};

export type CompiledCorpusNode = {
  key: string;
  kind: "file" | "heading";
  file: string;
  sourceRange: { startLine: number; endLine: number };
  id: string | null;
  title: string;
  level?: number;
  todo?: string;
  tags: string[];
  aliases: string[];
  properties: Record<string, string>;
  planning: Array<{ kind: "SCHEDULED" | "DEADLINE" | "CLOSED"; raw: string; line: number }>;
  links: CompiledCorpusLink[];
  backlinks: CompiledCorpusBacklink[];
  snippet: string;
};

export type CompiledCorpusFile = {
  file: string;
  absolutePath: string;
  sha256: string;
  lineCount: number;
  title: string;
  id: string | null;
};

export type CompiledCorpusIndexState = {
  mode: "full" | "incremental";
  status: "fresh" | "stale";
  cacheFile?: string;
  reusedFiles: number;
  parsedFiles: number;
  deletedFiles: number;
  reason?: string;
};

export type CompiledCorpusLookupIndex = {
  ids: Record<string, string[]>;
  titles: Record<string, string[]>;
  tags: Record<string, string[]>;
  dates: Record<string, string[]>;
  files: Record<string, string[]>;
};

export type CompiledCorpus = {
  schemaVersion: "org2-compiled-corpus/v1";
  generatedBy: "org2 compile corpus";
  artifact: Org2GeneratedArtifactMetadata;
  rootDir: string;
  files: CompiledCorpusFile[];
  nodes: CompiledCorpusNode[];
  stats: {
    files: number;
    nodes: number;
    headings: number;
    links: number;
    backlinks: number;
  };
  index?: CompiledCorpusLookupIndex;
  indexState?: CompiledCorpusIndexState;
};

function normalizeText(raw: string): string {
  return String(raw || "").replace(/\r\n/g, "\n");
}

function normalizeId(raw: string | null | undefined): string | null {
  const value = String(raw || "").trim().toLowerCase();
  return value || null;
}

function slashPath(raw: string): string {
  return raw.replace(/\\/g, "/");
}

function relativePath(rootDir: string, filePath: string): string {
  const rel = path.relative(rootDir, filePath);
  return slashPath(rel && !rel.startsWith("..") ? rel : filePath);
}

function sha256(raw: string): string {
  return sha256Hex(raw);
}

function parseAliasTokens(raw: string): string[] {
  const out: string[] = [];
  const re = /"([^"]+)"|'([^']+)'|([^\s,]+)/g;
  let match: RegExpExecArray | null;
  while ((match = re.exec(raw)) !== null) {
    const value = String(match[1] || match[2] || match[3] || "").trim();
    if (value) out.push(value);
  }
  return Array.from(new Set(out));
}

function parseKeywordValue(lines: string[], key: string, maxLines: number): string | null {
  const re = new RegExp(`^#\\+${key}:\\s*(.*?)\\s*$`, "i");
  for (let i = 0; i < Math.min(lines.length, maxLines); i += 1) {
    const match = re.exec((lines[i] || "").trim());
    if (match) return String(match[1] || "").trim();
  }
  return null;
}

function parseKeywordAliases(lines: string[], maxLines: number): string[] {
  const aliases: string[] = [];
  for (let i = 0; i < Math.min(lines.length, maxLines); i += 1) {
    const match = /^#\+roam_alias(?:es)?:\s*(.*?)\s*$/i.exec((lines[i] || "").trim());
    if (match) aliases.push(...parseAliasTokens(match[1] || ""));
  }
  return Array.from(new Set(aliases));
}

function parsePropertyDrawerAt(lines: string[], startIndex: number): { properties: Record<string, string>; endIndex: number } | null {
  if ((lines[startIndex] || "").trim().toUpperCase() !== ":PROPERTIES:") return null;
  const properties: Record<string, string> = {};
  for (let i = startIndex + 1; i < lines.length; i += 1) {
    const trimmed = (lines[i] || "").trim();
    if (trimmed.toUpperCase() === ":END:") return { properties, endIndex: i };
    const match = /^:([^:\s]+):\s*(.*?)\s*$/.exec(trimmed);
    if (match) properties[String(match[1] || "").toUpperCase()] = String(match[2] || "").trim();
  }
  return null;
}

function findFilePropertyDrawer(lines: string[]): { properties: Record<string, string>; endIndex: number } | null {
  const firstHeadline = lines.findIndex((line) => /^\*+\s+/.test(line || ""));
  const scanEnd = firstHeadline === -1 ? lines.length : firstHeadline;
  for (let i = 0; i < scanEnd; i += 1) {
    if ((lines[i] || "").trim().toUpperCase() === ":PROPERTIES:") return parsePropertyDrawerAt(lines, i);
  }
  return null;
}

function headingLevel(line: string): number {
  const match = /^(\*+)\s+/.exec(line);
  return match ? (match[1] || "").length : 0;
}

function stripTags(raw: string): { title: string; tags: string[] } {
  const match = /\s+(:[A-Za-z0-9_@#%:]+:)\s*$/.exec(raw);
  if (!match) return { title: raw.trim(), tags: [] };
  const tags = String(match[1] || "")
    .split(":")
    .map((value) => value.trim())
    .filter(Boolean);
  return { title: raw.slice(0, match.index).trim(), tags };
}

function parseHeading(line: string): { level: number; title: string; todo?: string; tags: string[] } | null {
  const match = /^(\*+)\s+(.*?)\s*$/.exec(line);
  if (!match) return null;
  const level = (match[1] || "").length;
  let rest = String(match[2] || "").trim();
  const tagStripped = stripTags(rest);
  rest = tagStripped.title;
  let todo: string | undefined;
  const first = rest.split(/\s+/)[0] || "";
  if ((TODO_KEYWORDS as readonly string[]).includes(first.toUpperCase())) {
    todo = first.toUpperCase();
    rest = rest.slice(first.length).trim();
  }
  return { level, title: rest, todo, tags: tagStripped.tags };
}

function headingEndExclusive(lines: string[], startIndex: number, level: number): number {
  for (let i = startIndex + 1; i < lines.length; i += 1) {
    const nextLevel = headingLevel(lines[i] || "");
    if (nextLevel > 0 && nextLevel <= level) return i;
  }
  return lines.length;
}

function propertyDrawerAfterHeading(lines: string[], headingIndex: number): { properties: Record<string, string>; endIndex: number } | null {
  let i = headingIndex + 1;
  while (i < lines.length) {
    const trimmed = (lines[i] || "").trim();
    if (!trimmed || /^(SCHEDULED|DEADLINE|CLOSED):/i.test(trimmed)) {
      i += 1;
      continue;
    }
    break;
  }
  return parsePropertyDrawerAt(lines, i);
}

function extractPlanning(lines: string[], startIndex: number, endExclusive: number): Array<{ kind: "SCHEDULED" | "DEADLINE" | "CLOSED"; raw: string; line: number }> {
  const out: Array<{ kind: "SCHEDULED" | "DEADLINE" | "CLOSED"; raw: string; line: number }> = [];
  for (let i = startIndex; i < endExclusive; i += 1) {
    const line = lines[i] || "";
    const re = /\b(SCHEDULED|DEADLINE|CLOSED):\s*(.*?)(?=\s+\b(?:SCHEDULED|DEADLINE|CLOSED):|$)/g;
    let match: RegExpExecArray | null;
    while ((match = re.exec(line)) !== null) {
      const kind = match[1] as "SCHEDULED" | "DEADLINE" | "CLOSED";
      out.push({ kind, raw: String(match[2] || "").trim(), line: i + 1 });
    }
  }
  return out;
}

function linkType(target: string): CompiledCorpusLink["type"] {
  const value = target.trim();
  const lower = value.toLowerCase();
  if (/^id:[0-9a-f-]{36}$/i.test(value)) return "id";
  if (lower.startsWith("file:")) return "file";
  if (lower.startsWith("http://") || lower.startsWith("https://")) return "url";
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(value) && value && !value.startsWith("/") && !value.startsWith("./") && !value.startsWith("../") && !value.startsWith("#")) return "wiki";
  return "other";
}

function extractLinks(lines: string[], startIndex: number, endExclusive: number): CompiledCorpusLink[] {
  const links: CompiledCorpusLink[] = [];
  let inBlock = false;
  for (let i = startIndex; i < endExclusive; i += 1) {
    const line = lines[i] || "";
    const trimmed = line.trim();
    if (/^#\+begin_/i.test(trimmed)) {
      inBlock = true;
      continue;
    }
    if (/^#\+end_/i.test(trimmed)) {
      inBlock = false;
      continue;
    }
    if (inBlock) continue;

    const bracketRe = /\[\[([^\]\n]+?)(?:\]\[([^\]\n]*))?\]\]/g;
    let match: RegExpExecArray | null;
    const bracketRanges: Array<{ start: number; end: number }> = [];
    while ((match = bracketRe.exec(line)) !== null) {
      const target = String(match[1] || "").trim();
      if (!target) continue;
      bracketRanges.push({ start: match.index, end: match.index + match[0].length });
      const link: CompiledCorpusLink = { type: linkType(target), target, line: i + 1 };
      const description = String(match[2] || "").trim();
      if (description) link.description = description;
      links.push(link);
    }

    const bareIdRe = /\bid:([0-9a-fA-F-]{36})\b/g;
    while ((match = bareIdRe.exec(line)) !== null) {
      const start = match.index;
      if (bracketRanges.some((range) => start >= range.start && start < range.end)) continue;
      links.push({ type: "id", target: `id:${String(match[1] || "").toLowerCase()}`, line: i + 1 });
    }
  }
  return links.sort((a, b) => a.line - b.line || a.target.localeCompare(b.target));
}

function extractSnippet(lines: string[], startIndex: number, endExclusive: number): string {
  let inDrawer = false;
  let inBlock = false;
  const parts: string[] = [];
  for (let i = startIndex; i < endExclusive; i += 1) {
    const line = lines[i] || "";
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (/^\*+\s+/.test(line)) continue;
    if (trimmed.toUpperCase() === ":PROPERTIES:") {
      inDrawer = true;
      continue;
    }
    if (inDrawer) {
      if (trimmed.toUpperCase() === ":END:") inDrawer = false;
      continue;
    }
    if (/^#\+begin_/i.test(trimmed)) {
      inBlock = true;
      continue;
    }
    if (/^#\+end_/i.test(trimmed)) {
      inBlock = false;
      continue;
    }
    if (inBlock) continue;
    if (/^(SCHEDULED|DEADLINE|CLOSED):/i.test(trimmed)) continue;
    if (/^#\+/.test(trimmed)) continue;
    parts.push(trimmed.replace(/\s+/g, " "));
    if (parts.join(" ").length >= 240) break;
  }
  return parts.join(" ").slice(0, 240);
}

function normalizeLabel(raw: string): string {
  return String(raw || "").trim().toLowerCase().replace(/\s+/g, " ");
}

function nodeLabels(node: CompiledCorpusNode): string[] {
  return Array.from(new Set([node.title, ...node.aliases].map((value) => value.trim()).filter(Boolean)));
}

export function compileCorpus(files: string[], opts?: { rootDir?: string; generatedAt?: string }): CompiledCorpus {
  const rootDir = path.resolve(opts?.rootDir || process.cwd());
  const sortedFiles = Array.from(new Set(files.map((file) => path.resolve(file)))).sort();
  const corpusFiles: CompiledCorpusFile[] = [];
  const nodes: CompiledCorpusNode[] = [];

  for (const filePath of sortedFiles) {
    const raw = fs.readFileSync(filePath, "utf8");
    const content = normalizeText(raw);
    const lines = content.split("\n");
    const file = relativePath(rootDir, filePath);
    const title = parseKeywordValue(lines, "title", 80) || path.basename(filePath).replace(/\.(org2|org)$/i, "");
    const fileDrawer = findFilePropertyDrawer(lines);
    const keywordId = normalizeId(parseKeywordValue(lines, "id", 30));
    const drawerId = normalizeId(fileDrawer?.properties.ID);
    const id = keywordId || drawerId;
    const aliases = Array.from(new Set([...parseKeywordAliases(lines, 80), ...parseAliasTokens(fileDrawer?.properties.ROAM_ALIASES || "")]));
    const properties = fileDrawer?.properties || {};
    const firstHeadingIndex = lines.findIndex((line) => /^\*+\s+/.test(line || ""));
    const preambleEndExclusive = firstHeadingIndex === -1 ? lines.length : firstHeadingIndex;
    const fileLinks = extractLinks(lines, 0, preambleEndExclusive);

    corpusFiles.push({ file, absolutePath: filePath, sha256: sha256(content), lineCount: lines.length, title, id });
    nodes.push({
      key: `file:${file}`,
      kind: "file",
      file,
      sourceRange: { startLine: 1, endLine: Math.max(1, preambleEndExclusive) },
      id,
      title,
      tags: [],
      aliases,
      properties,
      planning: extractPlanning(lines, 0, preambleEndExclusive),
      links: fileLinks,
      backlinks: [],
      snippet: extractSnippet(lines, 0, preambleEndExclusive),
    });

    for (let i = 0; i < lines.length; i += 1) {
      const heading = parseHeading(lines[i] || "");
      if (!heading) continue;
      const endExclusive = headingEndExclusive(lines, i, heading.level);
      const drawer = propertyDrawerAfterHeading(lines, i);
      const headingProperties = drawer?.properties || {};
      const headingId = normalizeId(headingProperties.ID);
      const headingAliases = parseAliasTokens(headingProperties.ROAM_ALIASES || "");
      const node: CompiledCorpusNode = {
        key: `heading:${file}:${i + 1}`,
        kind: "heading",
        file,
        sourceRange: { startLine: i + 1, endLine: Math.max(i + 1, endExclusive) },
        id: headingId,
        title: heading.title,
        level: heading.level,
        tags: heading.tags,
        aliases: headingAliases,
        properties: headingProperties,
        planning: extractPlanning(lines, i + 1, endExclusive),
        links: extractLinks(lines, i + 1, endExclusive),
        backlinks: [],
        snippet: extractSnippet(lines, i + 1, endExclusive),
      };
      if (heading.todo) node.todo = heading.todo;
      nodes.push(node);
    }
  }

  const byId = new Map<string, CompiledCorpusNode>();
  const labels = new Map<string, Set<string>>();
  for (const node of nodes) {
    if (node.id && !byId.has(node.id)) byId.set(node.id, node);
    if (!node.id) continue;
    for (const label of nodeLabels(node)) {
      const key = normalizeLabel(label);
      if (!key) continue;
      const set = labels.get(key) || new Set<string>();
      set.add(node.id);
      labels.set(key, set);
    }
  }

  for (const source of nodes) {
    for (const link of source.links) {
      let targetId: string | null = null;
      let resolvedBy: "id" | "wiki" | null = null;
      if (link.type === "id") {
        targetId = normalizeId(link.target.replace(/^id:/i, ""));
        resolvedBy = "id";
      } else if (link.type === "wiki") {
        const candidates = Array.from(labels.get(normalizeLabel(link.target)) || []);
        if (candidates.length === 1) {
          targetId = candidates[0] || null;
          resolvedBy = "wiki";
        }
      }
      if (!targetId || !resolvedBy) continue;
      const target = byId.get(targetId);
      if (!target) continue;
      target.backlinks.push({
        sourceKey: source.key,
        sourceId: source.id,
        sourceTitle: source.title,
        file: source.file,
        line: link.line,
        linkType: resolvedBy,
      });
    }
  }

  for (const node of nodes) {
    node.backlinks.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.sourceKey.localeCompare(b.sourceKey));
  }

  const totalLinks = nodes.reduce((sum, node) => sum + node.links.length, 0);
  const totalBacklinks = nodes.reduce((sum, node) => sum + node.backlinks.length, 0);
  const sortedNodes = nodes.sort((a, b) => a.file.localeCompare(b.file) || a.sourceRange.startLine - b.sourceRange.startLine || a.kind.localeCompare(b.kind));
  return {
    schemaVersion: "org2-compiled-corpus/v1",
    generatedBy: "org2 compile corpus",
    artifact: buildGeneratedArtifactMetadata({
      role: "compiled",
      generator: "org2 compile corpus",
      generatedAt: opts?.generatedAt,
      provenance: corpusFiles.map((file) => `file:${file.file}`),
      sourceHashes: corpusFiles.map((file) => ({ kind: "file", value: file.file, sha256: file.sha256 })),
      reviewStatus: "generated",
      claimState: "source-backed",
      observedAt: opts?.generatedAt,
      validAsOf: opts?.generatedAt,
    }),
    rootDir,
    files: corpusFiles.sort((a, b) => a.file.localeCompare(b.file)),
    nodes: sortedNodes,
    stats: {
      files: corpusFiles.length,
      nodes: nodes.length,
      headings: nodes.filter((node) => node.kind === "heading").length,
      links: totalLinks,
      backlinks: totalBacklinks,
    },
    index: buildLookupIndex(sortedNodes),
    indexState: { mode: "full", status: "fresh", reusedFiles: 0, parsedFiles: corpusFiles.length, deletedFiles: 0 },
  };
}


type IncrementalCorpusCache = {
  schemaVersion: "org2-incremental-corpus-cache/v1";
  rootDir: string;
  files: Array<{ file: string; absolutePath: string; size: number; mtimeMs: number; sha256: string }>;
  corpus: CompiledCorpus;
};

function buildLookupIndex(nodes: CompiledCorpusNode[]): CompiledCorpusLookupIndex {
  const index: CompiledCorpusLookupIndex = { ids: {}, titles: {}, tags: {}, dates: {}, files: {} };
  const add = (bucket: Record<string, string[]>, key: string, value: string) => { const normalized = normalizeLabel(key); if (!normalized) return; (bucket[normalized] ||= []).push(value); };
  for (const node of nodes) {
    if (node.id) add(index.ids, node.id, node.key);
    add(index.titles, node.title, node.key);
    add(index.files, node.file, node.key);
    for (const tag of node.tags) add(index.tags, tag, node.key);
    for (const plan of node.planning) for (const match of plan.raw.matchAll(/\d{4}-\d{2}-\d{2}/g)) add(index.dates, match[0] || "", node.key);
  }
  for (const bucket of Object.values(index)) for (const key of Object.keys(bucket)) bucket[key] = Array.from(new Set(bucket[key])).sort();
  return index;
}

function fileFingerprint(filePath: string, rootDir: string): { file: string; absolutePath: string; size: number; mtimeMs: number; sha256: string } {
  const stat = fs.statSync(filePath);
  return { file: relativePath(rootDir, filePath), absolutePath: filePath, size: stat.size, mtimeMs: stat.mtimeMs, sha256: "" };
}

function withIndexState(corpus: CompiledCorpus, state: CompiledCorpusIndexState): CompiledCorpus {
  return { ...corpus, index: buildLookupIndex(corpus.nodes), indexState: state };
}

export function compileCorpusIncremental(files: string[], opts: { rootDir?: string; cacheFile: string; generatedAt?: string }): CompiledCorpus {
  const rootDir = path.resolve(opts.rootDir || process.cwd());
  const sortedFiles = Array.from(new Set(files.map((file) => path.resolve(file)))).sort();
  const cacheFile = path.resolve(opts.cacheFile);
  const current = sortedFiles.map((filePath) => fileFingerprint(filePath, rootDir));
  let cache: IncrementalCorpusCache | null = null;
  let reason: string | undefined;
  try {
    if (fs.existsSync(cacheFile)) {
      const parsed = JSON.parse(fs.readFileSync(cacheFile, "utf8")) as IncrementalCorpusCache;
      if (parsed.schemaVersion === "org2-incremental-corpus-cache/v1" && parsed.rootDir === rootDir && parsed.corpus && Array.isArray(parsed.files)) cache = parsed;
      else reason = "cache schema or rootDir mismatch";
    }
  } catch (err) { reason = `cache unreadable: ${err instanceof Error ? err.message : String(err)}`; }
  const same = cache && cache.files.length === current.length && current.every((entry, i) => { const cached = cache!.files[i]; return cached && cached.file === entry.file && cached.absolutePath === entry.absolutePath && cached.size === entry.size && cached.mtimeMs === entry.mtimeMs; });
  if (same) return withIndexState(cache!.corpus, { mode: "incremental", status: "fresh", cacheFile, reusedFiles: current.length, parsedFiles: 0, deletedFiles: 0 });
  const deletedFiles = cache ? cache.files.filter((entry) => !current.some((now) => now.file === entry.file)).length : 0;
  const corpus = compileCorpus(sortedFiles, { rootDir, generatedAt: opts.generatedAt });
  const result = withIndexState(corpus, { mode: "incremental", status: reason ? "stale" : "fresh", cacheFile, reusedFiles: 0, parsedFiles: current.length, deletedFiles, ...(reason ? { reason } : {}) });
  try { fs.mkdirSync(path.dirname(cacheFile), { recursive: true }); fs.writeFileSync(cacheFile, JSON.stringify({ schemaVersion: "org2-incremental-corpus-cache/v1", rootDir, files: current, corpus: result }, null, 2) + "\n"); }
  catch (err) { return withIndexState(corpus, { mode: "incremental", status: "stale", cacheFile, reusedFiles: 0, parsedFiles: current.length, deletedFiles, reason: `cache write failed: ${err instanceof Error ? err.message : String(err)}` }); }
  return result;
}

export function renderCompiledCorpus(corpus: CompiledCorpus, format: "json" | "jsonl" = "json"): string {
  if (format === "jsonl") {
    const header = { schemaVersion: corpus.schemaVersion, generatedBy: corpus.generatedBy, artifact: corpus.artifact, rootDir: corpus.rootDir, stats: corpus.stats, index: corpus.index, indexState: corpus.indexState };
    return [header, ...corpus.nodes].map((entry) => JSON.stringify(entry)).join("\n") + "\n";
  }
  return JSON.stringify(corpus, null, 2) + "\n";
}
