import fs from "node:fs";
import path from "node:path";
import { buildGeneratedArtifactMetadata, sha256Hex, type Org2GeneratedArtifactMetadata } from "./artifactMetadata.js";
import { TODO_KEYWORDS } from "./todo.js";
import { extractClockReport, type OrgClockInterval, type OrgClockIssue } from "./clock.js";

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

export type CompiledCorpusEntity = {
  nodeKey: string;
  id: string | null;
  title: string;
  entityType: string;
  file: string;
  line: number;
  source: "property" | "tag";
};

export type CompiledCorpusRelation = {
  subjectKey: string;
  subjectId: string | null;
  subjectTitle: string;
  predicate: string;
  objectId: string | null;
  objectTitle?: string;
  objectRef: string;
  file: string;
  line: number;
  evidence: string;
  confidence: "explicit" | "inferred-pattern";
  method: string;
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
  clocks: OrgClockInterval[];
  clockIssues: OrgClockIssue[];
  links: CompiledCorpusLink[];
  backlinks: CompiledCorpusBacklink[];
  entityType?: string;
  snippet: string;
  snippetStartLine: number | null;
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
    entities: number;
    relations: number;
  };
  entities: CompiledCorpusEntity[];
  relations: CompiledCorpusRelation[];
  clocks: OrgClockInterval[];
  clockIssues: OrgClockIssue[];
  clockSummary: ReturnType<typeof extractClockReport>["summary"];
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

function extractSnippetWithLine(lines: string[], startIndex: number, endExclusive: number): { snippet: string; startLine: number | null } {
  let inDrawer = false;
  let inBlock = false;
  const parts: string[] = [];
  let snippetStartLine: number | null = null;
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
    if (snippetStartLine === null) snippetStartLine = i + 1;
    parts.push(trimmed.replace(/\s+/g, " "));
    if (parts.join(" ").length >= 240) break;
  }
  return { snippet: parts.join(" ").slice(0, 240), startLine: snippetStartLine };
}

function normalizeLabel(raw: string): string {
  return String(raw || "").trim().toLowerCase().replace(/\s+/g, " ");
}

function normalizeEntityType(raw: string | null | undefined): string | undefined {
  const value = String(raw || "").trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "_").replace(/^_+|_+$/g, "");
  return value || undefined;
}

function normalizePredicate(raw: string): string {
  return String(raw || "").trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "_").replace(/^_+|_+$/g, "");
}

function nodeEntityType(node: CompiledCorpusNode): string | undefined {
  const propertyType = normalizeEntityType(node.properties.ORG2_ENTITY_TYPE || node.properties.ENTITY_TYPE);
  if (propertyType) return propertyType;
  const typedTag = node.tags.find((tag) => /^type[-_:]/i.test(tag));
  return typedTag ? normalizeEntityType(typedTag.replace(/^type[-_:]/i, "")) : undefined;
}

function nodeLabels(node: CompiledCorpusNode): string[] {
  return Array.from(new Set([node.title, ...node.aliases].map((value) => value.trim()).filter(Boolean)));
}

export function compileCorpus(files: string[], opts?: { rootDir?: string; generatedAt?: string }): CompiledCorpus {
  const rootDir = path.resolve(opts?.rootDir || process.cwd());
  const sortedFiles = Array.from(new Set(files.map((file) => path.resolve(file)))).sort();
  const corpusFiles: CompiledCorpusFile[] = [];
  const nodes: CompiledCorpusNode[] = [];
  const clockReport = extractClockReport(sortedFiles, { rootDir });
  const clocksByNode = new Map<string, OrgClockInterval[]>();
  const clockIssuesByNode = new Map<string, OrgClockIssue[]>();
  for (const clock of clockReport.intervals) clocksByNode.set(clock.nodeKey, [...(clocksByNode.get(clock.nodeKey) || []), clock]);
  for (const issue of clockReport.issues) if (issue.nodeKey) clockIssuesByNode.set(issue.nodeKey, [...(clockIssuesByNode.get(issue.nodeKey) || []), issue]);

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
    const fileSnippet = extractSnippetWithLine(lines, 0, preambleEndExclusive);

    corpusFiles.push({ file, absolutePath: filePath, sha256: sha256(content), lineCount: lines.length, title, id });
    const fileKey = `file:${file}`;
    nodes.push({
      key: fileKey,
      kind: "file",
      file,
      sourceRange: { startLine: 1, endLine: Math.max(1, preambleEndExclusive) },
      id,
      title,
      tags: [],
      aliases,
      properties,
      planning: extractPlanning(lines, 0, preambleEndExclusive),
      clocks: clocksByNode.get(fileKey) || [],
      clockIssues: clockIssuesByNode.get(fileKey) || [],
      links: fileLinks,
      backlinks: [],
      snippet: fileSnippet.snippet,
      snippetStartLine: fileSnippet.startLine,
    });

    for (let i = 0; i < lines.length; i += 1) {
      const heading = parseHeading(lines[i] || "");
      if (!heading) continue;
      const endExclusive = headingEndExclusive(lines, i, heading.level);
      const drawer = propertyDrawerAfterHeading(lines, i);
      const headingProperties = drawer?.properties || {};
      const headingId = normalizeId(headingProperties.ID);
      const headingAliases = parseAliasTokens(headingProperties.ROAM_ALIASES || "");
      const headingSnippet = extractSnippetWithLine(lines, i + 1, endExclusive);
      const headingKey = `heading:${file}:${i + 1}`;
      const node: CompiledCorpusNode = {
        key: headingKey,
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
        clocks: clocksByNode.get(headingKey) || [],
        clockIssues: clockIssuesByNode.get(headingKey) || [],
        links: extractLinks(lines, i + 1, endExclusive),
        backlinks: [],
        snippet: headingSnippet.snippet,
        snippetStartLine: headingSnippet.startLine,
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
    node.entityType = nodeEntityType(node);
    node.backlinks.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.sourceKey.localeCompare(b.sourceKey));
  }

  const entities = buildEntityIndex(nodes);
  const relations = buildRelationIndex(nodes, byId, labels);

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
      entities: entities.length,
      relations: relations.length,
    },
    entities,
    relations,
    clocks: clockReport.intervals,
    clockIssues: clockReport.issues,
    clockSummary: clockReport.summary,
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

function buildEntityIndex(nodes: CompiledCorpusNode[]): CompiledCorpusEntity[] {
  return nodes
    .filter((node) => !!node.entityType)
    .map((node) => ({
      nodeKey: node.key,
      id: node.id,
      title: node.title,
      entityType: node.entityType!,
      file: node.file,
      line: node.sourceRange.startLine,
      source: ((node.properties.ORG2_ENTITY_TYPE || node.properties.ENTITY_TYPE) ? "property" : "tag") as "property" | "tag",
    }))
    .sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.title.localeCompare(b.title));
}

function parseRelationObject(raw: string): { objectRef: string; objectId: string | null; objectTitle?: string } {
  const value = String(raw || "").trim();
  const idMatch = /(?:^|\s)(?:id:)?([0-9a-fA-F-]{36})(?:\s|$)/.exec(value);
  if (idMatch) return { objectRef: `id:${String(idMatch[1]).toLowerCase()}`, objectId: String(idMatch[1]).toLowerCase() };
  const linkMatch = /\[\[([^\]\n]+?)(?:\]\[([^\]\n]*))?\]\]/.exec(value);
  if (linkMatch) {
    const target = String(linkMatch[1] || "").trim();
    const description = String(linkMatch[2] || "").trim();
    const linkId = /^id:([0-9a-fA-F-]{36})$/i.exec(target);
    return { objectRef: target, objectId: linkId ? String(linkId[1]).toLowerCase() : null, ...(description ? { objectTitle: description } : {}) };
  }
  return { objectRef: value, objectId: null };
}

function resolveLinkObject(rawTarget: string, rawDescription: string | undefined, byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): { objectId: string | null; objectRef: string; objectTitle?: string } {
  const target = String(rawTarget || "").trim();
  const description = String(rawDescription || "").trim();
  const idMatch = /^id:([0-9a-fA-F-]{36})$/i.exec(target);
  if (idMatch) {
    const objectId = String(idMatch[1]).toLowerCase();
    return { objectId, objectRef: `id:${objectId}`, objectTitle: description || byId.get(objectId)?.title };
  }
  const candidates = Array.from(labels.get(normalizeLabel(target)) || []);
  const objectId = candidates.length === 1 ? candidates[0] || null : null;
  return { objectId, objectRef: target, objectTitle: description || byId.get(objectId || "")?.title || target };
}

function addRelationOnce(relations: CompiledCorpusRelation[], relation: CompiledCorpusRelation): void {
  const key = `${relation.subjectKey}\0${relation.predicate}\0${relation.objectRef}\0${relation.file}\0${relation.line}\0${relation.method}`;
  if (relations.some((existing) => `${existing.subjectKey}\0${existing.predicate}\0${existing.objectRef}\0${existing.file}\0${existing.line}\0${existing.method}` === key)) return;
  relations.push(relation);
}

function nodeForResolvedObject(object: { objectId: string | null; objectRef: string; objectTitle?: string }, byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): CompiledCorpusNode | null {
  if (object.objectId && byId.has(object.objectId)) return byId.get(object.objectId)!;
  const titleCandidates = Array.from(labels.get(normalizeLabel(object.objectTitle || object.objectRef)) || []);
  return titleCandidates.length === 1 ? byId.get(titleCandidates[0]!) || null : null;
}

function resolveObjectByTitle(title: string, byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): { objectId: string | null; objectRef: string; objectTitle?: string } | null {
  const normalized = normalizeLabel(title);
  if (!normalized) return null;
  const candidates = Array.from(labels.get(normalized) || []);
  if (candidates.length === 1) {
    const node = byId.get(candidates[0]!);
    if (!node) return null;
    return { objectId: node.id || null, objectRef: node.id ? `id:${node.id}` : title, objectTitle: node.title };
  }

  // Some real corpora contain duplicate canonical notes for the same entity label
  // (for example, an .org and an .org2 version of the same company).  In that
  // case keep the textual object title instead of dropping the relation entirely;
  // title-based relation queries can still answer the question, while ID-based
  // queries stay conservative because there is no single safe ID to choose.
  const matchingNodes = candidates
    .map((id) => byId.get(id))
    .filter((node): node is CompiledCorpusNode => !!node && normalizeLabel(node.title) === normalized);
  if (matchingNodes.length > 1) return { objectId: null, objectRef: title, objectTitle: matchingNodes[0]!.title };
  return null;
}

function inferAdvisedObjectFromEvidence(evidence: string, subjectTitle: string, byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): { objectId: string | null; objectRef: string; objectTitle?: string; method: string } | null {
  const escapedSubject = subjectTitle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const patterns: Array<{ re: RegExp; method: string }> = [
    { re: new RegExp(`${escapedSubject}[^.\\n]{0,160}?\\b(?:has\\s+been\\s+)?advis(?:ing|or|er)\\b[^.\\n]{0,80}?\\b(?:startup|company|org(?:anization)?)\\b\\s*,?\\s+([A-Z][A-Za-z0-9&.-]*(?:\\s+[A-Z][A-Za-z0-9&.-]*){0,4})`, "i"), method: "pattern:linked-subject-advising-named-object" },
    { re: new RegExp(`${escapedSubject}[^.\\n]{0,160}?\\b(?:has\\s+been\\s+)?advis(?:ing|or|er)\\b[^.\\n]{0,80}?\\bfor\\b[^.\\n]{0,40}?([A-Z][A-Za-z0-9&.-]*(?:\\s+[A-Z][A-Za-z0-9&.-]*){0,4})`, "i"), method: "pattern:linked-subject-advising-for-object" },
  ];
  for (const pattern of patterns) {
    const match = pattern.re.exec(evidence);
    if (!match) continue;
    const title = String(match[1] || "").trim().replace(/[.,;:]+$/, "");
    const object = resolveObjectByTitle(title, byId, labels);
    if (object) return { ...object, method: pattern.method };
  }
  return null;
}


function inferLinkedTextAdvisorRelationsForNode(relations: CompiledCorpusRelation[], node: CompiledCorpusNode, byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): void {
  const evidence = node.snippet || node.title;
  if (!/\badvis(?:ing|or|er)\b/i.test(evidence)) return;
  for (const candidate of byId.values()) {
    if (candidate.key === node.key) continue;
    if (candidate.entityType && candidate.entityType !== "person") continue;
    if (!candidate.title || candidate.title.length < 4) continue;
    const titlePattern = new RegExp(`\\b${candidate.title.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i");
    if (!titlePattern.test(evidence)) continue;
    const advisedObject = inferAdvisedObjectFromEvidence(evidence, candidate.title, byId, labels);
    if (!advisedObject) continue;
    addRelationOnce(relations, {
      subjectKey: candidate.key,
      subjectId: candidate.id,
      subjectTitle: candidate.title,
      predicate: "advisor_to",
      objectId: advisedObject.objectId,
      ...(advisedObject.objectTitle ? { objectTitle: advisedObject.objectTitle } : {}),
      objectRef: advisedObject.objectRef,
      file: node.file,
      line: node.snippetStartLine || node.sourceRange.startLine,
      evidence,
      confidence: "inferred-pattern",
      method: `text-subject:${advisedObject.method}`,
    });
  }
}

function buildRelationIndex(nodes: CompiledCorpusNode[], byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): CompiledCorpusRelation[] {
  const relations: CompiledCorpusRelation[] = [];
  const fileNodesByFile = new Map(nodes.filter((node) => node.kind === "file").map((node) => [node.file, node]));
  const relationSubjectForNode = (node: CompiledCorpusNode): CompiledCorpusNode => {
    if (node.kind === "heading" && !node.id && /^(details?|notes?)$/i.test(node.title.trim())) return fileNodesByFile.get(node.file) || node;
    return node;
  };
  for (const node of nodes) {
    inferLinkedTextAdvisorRelationsForNode(relations, node, byId, labels);
    const explicitValues = Object.entries(node.properties).filter(([key]) => key === "ORG2_RELATION" || key.startsWith("ORG2_RELATION_"));
    for (const [key, value] of explicitValues) {
      const suffix = key === "ORG2_RELATION" ? "" : key.slice("ORG2_RELATION_".length);
      const parts = String(value || "").trim().split(/\s+/);
      const predicate = normalizePredicate(suffix || parts.shift() || "");
      if (!predicate || parts.length === 0) continue;
      const object = parseRelationObject(parts.join(" "));
      addRelationOnce(relations, {
        subjectKey: node.key,
        subjectId: node.id,
        subjectTitle: node.title,
        predicate,
        objectId: object.objectId,
        ...(object.objectTitle ? { objectTitle: object.objectTitle } : {}),
        objectRef: object.objectRef,
        file: node.file,
        line: node.sourceRange.startLine,
        evidence: `${key}: ${value}`,
        confidence: "explicit",
        method: "property",
      });
    }

    for (const link of node.links) {
      if (link.type !== "id" && link.type !== "wiki") continue;
      const object = resolveLinkObject(link.target, link.description, byId, labels);
      const title = (link.description || link.target).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const evidence = node.snippet || node.title;
      const patterns: Array<{ predicate: string; re: RegExp; method: string }> = [
        { predicate: "advisor_to", re: new RegExp(`\\b(?:advisor|adviser)\\s+(?:for|to|at)\\s+.*${title}`, "i"), method: "pattern:advisor-for-to-at" },
        { predicate: "advisor_to", re: new RegExp(`\\badvising\\s+.*${title}`, "i"), method: "pattern:advising" },
        { predicate: "advisor_to", re: new RegExp(`\\bstrategic\\s+(?:advisor|adviser)\\s+at\\s+.*${title}`, "i"), method: "pattern:strategic-advisor-at" },
      ];
      for (const pattern of patterns) {
        if (!pattern.re.test(evidence)) continue;
        const subject = relationSubjectForNode(node);
        addRelationOnce(relations, {
          subjectKey: subject.key,
          subjectId: subject.id,
          subjectTitle: subject.title,
          predicate: pattern.predicate,
          objectId: object.objectId,
          ...(object.objectTitle ? { objectTitle: object.objectTitle } : {}),
          objectRef: object.objectRef,
          file: node.file,
          line: link.line,
          evidence,
          confidence: "inferred-pattern",
          method: pattern.method,
        });
      }

      const linkedSubjectNode = nodeForResolvedObject(object, byId, labels);
      const linkedSubjectTitle = linkedSubjectNode?.title || object.objectTitle || "";
      if (linkedSubjectNode && linkedSubjectTitle) {
        const advisedObject = inferAdvisedObjectFromEvidence(evidence, linkedSubjectTitle, byId, labels);
        if (advisedObject) {
          addRelationOnce(relations, {
            subjectKey: linkedSubjectNode.key,
            subjectId: linkedSubjectNode.id,
            subjectTitle: linkedSubjectNode.title,
            predicate: "advisor_to",
            objectId: advisedObject.objectId,
            ...(advisedObject.objectTitle ? { objectTitle: advisedObject.objectTitle } : {}),
            objectRef: advisedObject.objectRef,
            file: node.file,
            line: link.line,
            evidence,
            confidence: "inferred-pattern",
            method: advisedObject.method,
          });
        }
      }
    }
  }
  return relations.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.subjectTitle.localeCompare(b.subjectTitle));
}

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
    const header = { schemaVersion: corpus.schemaVersion, generatedBy: corpus.generatedBy, artifact: corpus.artifact, rootDir: corpus.rootDir, stats: corpus.stats, entities: corpus.entities, relations: corpus.relations, index: corpus.index, indexState: corpus.indexState };
    return [header, ...corpus.nodes].map((entry) => JSON.stringify(entry)).join("\n") + "\n";
  }
  return JSON.stringify(corpus, null, 2) + "\n";
}
