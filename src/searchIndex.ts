import fs from "node:fs";
import path from "node:path";
import { parseHeadlineTitleForRoam } from "./headlineTitle.js";
import { defaultSearchIndexPath } from "./indexPaths.js";
import { normalizeTodoKeyword } from "./todo.js";

export { defaultSearchIndexPath };

export type Org2SearchIndexFile = {
  path: string;
  relativePath: string;
  modifiedMs: number;
  byteCount: number;
  lines: string[];
};

export type Org2SearchIndex = {
  $schema: "org2:search-index:v1";
  version: 1;
  rootDir: string;
  recursive: boolean;
  includeArchives: boolean;
  builtAt: string;
  files: Org2SearchIndexFile[];
};

export type Org2SearchIndexBuildResult = {
  index: Org2SearchIndex;
  path: string;
  fileCount: number;
  lineCount: number;
  byteCount: number;
  skippedFiles: number;
};

export type Org2SearchResultPayload = {
  $schema: "org2:search:v1";
  query: string;
  mode: "line" | "subtree";
  sort: string;
  dateFrom?: string;
  dateTo?: string;
  fileZones?: string[];
  index?: {
    mode: "auto" | "never" | "rebuild";
    used: boolean;
    path?: string;
    builtAt?: string;
    stale?: boolean;
  };
  results: Org2SearchHit[];
};

export type Org2SearchHit = {
  file: string;
  line: number;
  lineEnd: number;
  heading?: string;
  headingLine?: number;
  headingLevel?: number;
  headingAncestry: SearchHeadingRef[];
  id?: string;
  todo?: string;
  tags: string[];
  snippet: string;
  context: { startLine: number; endLine: number; lines: string[] };
  sourceRange: { startLine: number; endLine: number };
  matchedLines: { line: number; snippet: string }[];
  date?: string;
  sortDate?: string;
  answerContext?: string;
};

export type Org2SearchOptions = {
  query: string;
  context: number;
  limit: number;
  todoFilters: Set<string>;
  tagFilters: Set<string>;
  fileZoneFilters: string[];
  headingNeedle: string;
  sort: string;
  dateFrom: string;
  dateTo: string;
  subtree: boolean;
  answerContext: boolean;
};

type SearchHeading = { line: number; level: number; title: string; todo?: string; tags: string[]; id?: string };
type SearchHeadingRef = { level: number; title: string; line: number; lineNumber: number };

export function buildSearchIndex(options: {
  rootDir: string;
  files: string[];
  recursive: boolean;
  includeArchives: boolean;
}): Org2SearchIndexBuildResult {
  const rootDir = path.resolve(options.rootDir);
  const indexPath = defaultSearchIndexPath(rootDir);
  const indexedFiles: Org2SearchIndexFile[] = [];
  let lineCount = 0;
  let byteCount = 0;
  let skippedFiles = 0;

  for (const file of options.files) {
    const absolutePath = path.resolve(file);
    try {
      const stat = fs.statSync(absolutePath);
      if (!stat.isFile()) continue;
      const raw = fs.readFileSync(absolutePath, "utf8").replace(/\r\n/g, "\n");
      const lines = raw.split("\n");
      lineCount += lines.length;
      byteCount += stat.size;
      indexedFiles.push({
        path: absolutePath,
        relativePath: relativeIndexPath(rootDir, absolutePath),
        modifiedMs: Math.trunc(stat.mtimeMs),
        byteCount: stat.size,
        lines,
      });
    } catch {
      skippedFiles += 1;
    }
  }

  const index: Org2SearchIndex = {
    $schema: "org2:search-index:v1",
    version: 1,
    rootDir,
    recursive: options.recursive,
    includeArchives: options.includeArchives,
    builtAt: new Date().toISOString(),
    files: indexedFiles.sort((a, b) => a.path.localeCompare(b.path)),
  };

  return { index, path: indexPath, fileCount: indexedFiles.length, lineCount, byteCount, skippedFiles };
}

export function writeSearchIndex(result: Org2SearchIndexBuildResult): void {
  fs.mkdirSync(path.dirname(result.path), { recursive: true });
  const tmpPath = `${result.path}.${process.pid}.tmp`;
  fs.writeFileSync(tmpPath, JSON.stringify(result.index, null, 2) + "\n", "utf8");
  fs.renameSync(tmpPath, result.path);
}

export function loadFreshSearchIndex(options: {
  rootDir: string;
  files: string[];
  recursive: boolean;
  includeArchives: boolean;
}): { index: Org2SearchIndex; path: string } | null {
  const rootDir = path.resolve(options.rootDir);
  const indexPath = defaultSearchIndexPath(rootDir);
  let parsed: Org2SearchIndex;
  try {
    parsed = JSON.parse(fs.readFileSync(indexPath, "utf8")) as Org2SearchIndex;
  } catch {
    return null;
  }

  if (parsed.$schema !== "org2:search-index:v1" || parsed.version !== 1) return null;
  if (path.resolve(parsed.rootDir) !== rootDir) return null;
  if (parsed.recursive !== options.recursive) return null;
  if (parsed.includeArchives !== options.includeArchives) return null;

  const expected = new Map(options.files.map((file) => [path.resolve(file), true]));
  if (expected.size !== parsed.files.length) return null;

  for (const indexedFile of parsed.files) {
    const absolutePath = path.resolve(indexedFile.path);
    if (!expected.has(absolutePath)) return null;
    try {
      const stat = fs.statSync(absolutePath);
      if (!stat.isFile()) return null;
      if (Math.trunc(stat.mtimeMs) !== indexedFile.modifiedMs || stat.size !== indexedFile.byteCount) return null;
    } catch {
      return null;
    }
  }

  return { index: parsed, path: indexPath };
}

export function searchIndexedCorpus(index: Org2SearchIndex, options: Org2SearchOptions): Org2SearchHit[] {
  const hits: Org2SearchHit[] = [];
  const needle = options.query.toLowerCase();
  const fileZoneFilters = options.fileZoneFilters.map((zone) => zone.toLowerCase()).filter(Boolean);

  for (const file of index.files) {
    const normalizedFile = file.path.toLowerCase();
    if (fileZoneFilters.length && !fileZoneFilters.some((zone) => normalizedFile.includes(zone))) continue;
    collectSearchHitsForLines(file.path, file.lines, needle, options, hits);
    if (hits.length >= options.limit && normalizedSort(options.sort) === "scan") break;
  }

  return sortAndLimitSearchHits(hits, options.sort, options.limit);
}

export function searchFilesByScan(files: string[], options: Org2SearchOptions): { hits: Org2SearchHit[]; skippedFileCount: number } {
  const hits: Org2SearchHit[] = [];
  const subtreeHits = new Map<string, Org2SearchHit>();
  const needle = options.query.toLowerCase();
  const fileZoneFilters = options.fileZoneFilters.map((zone) => zone.toLowerCase()).filter(Boolean);
  let skippedFileCount = 0;

  for (const filePath of files) {
    try {
      const normalizedFile = filePath.toLowerCase();
      if (fileZoneFilters.length && !fileZoneFilters.some((zone) => normalizedFile.includes(zone))) continue;
      const raw = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n");
      const fileHits: Org2SearchHit[] = [];
      collectSearchHitsForLines(filePath, raw.split("\n"), needle, options, fileHits, subtreeHits);
      hits.push(...fileHits);
    } catch {
      skippedFileCount += 1;
    }
  }

  return {
    hits: sortAndLimitSearchHits(options.subtree ? Array.from(subtreeHits.values()) : hits, options.sort, options.limit),
    skippedFileCount,
  };
}

export function searchPayload(options: {
  query: string;
  subtree: boolean;
  sort: string;
  dateFrom: string;
  dateTo: string;
  fileZones: string[];
  index?: Org2SearchResultPayload["index"];
  results: Org2SearchHit[];
}): Org2SearchResultPayload {
  return {
    $schema: "org2:search:v1",
    query: options.query,
    mode: options.subtree ? "subtree" : "line",
    sort: normalizedSort(options.sort),
    ...(options.dateFrom ? { dateFrom: options.dateFrom } : {}),
    ...(options.dateTo ? { dateTo: options.dateTo } : {}),
    ...(options.fileZones.length ? { fileZones: options.fileZones } : {}),
    ...(options.index ? { index: options.index } : {}),
    results: options.results,
  };
}

function collectSearchHitsForLines(
  filePath: string,
  lines: string[],
  needle: string,
  options: Org2SearchOptions,
  hits: Org2SearchHit[],
  subtreeHits = new Map<string, Org2SearchHit>(),
): void {
  const stack: SearchHeading[] = [];

  for (let j = 0; j < lines.length; j += 1) {
    const line = lines[j] || "";
    const parsed = parseSearchHeading(line);
    if (parsed) {
      while (stack.length && stack[stack.length - 1]!.level >= parsed.level) stack.pop();
      stack.push({ line: j, ...parsed });
    }

    const current = stack[stack.length - 1];
    const idMatch = /^:ID:\s*(\S+)\s*$/.exec(line.trim());
    if (idMatch && current) current.id = idMatch[1];
    if (!line.toLowerCase().includes(needle)) continue;
    if (options.todoFilters.size && (!current?.todo || !options.todoFilters.has(current.todo.toUpperCase()))) continue;
    if (
      options.tagFilters.size &&
      !Array.from(options.tagFilters).every((tag) => current?.tags.map((t) => t.toLowerCase()).includes(tag))
    ) continue;
    if (options.headingNeedle && !(current?.title || "").toLowerCase().includes(options.headingNeedle)) continue;

    const fileDate = dateKeyFromFile(filePath);
    const headingEnd = subtreeEndLine(lines, current, j);
    const headingDate = current ? dateKeyFromLines(lines, current.line, headingEnd) : dateKeyFromLines(lines, j, j);
    const sortDate = headingDate || fileDate;
    if (!inDateWindow(sortDate, options.dateFrom, options.dateTo)) continue;

    const headingAncestry: SearchHeadingRef[] = stack.map((h) => ({
      level: h.level,
      title: h.title,
      line: h.line,
      lineNumber: h.line + 1,
    }));

    const sourceStart = options.subtree && current ? current.line : j;
    const sourceEnd = options.subtree && current ? headingEnd : j;
    const start = options.subtree ? sourceStart : Math.max(0, j - options.context);
    const end = options.subtree ? sourceEnd : Math.min(lines.length - 1, j + options.context);
    const key = `${filePath}:${sourceStart + 1}:${sourceEnd + 1}`;
    const match = { line: j + 1, snippet: line.trim() };

    if (options.subtree) {
      const existing = subtreeHits.get(key);
      if (existing) {
        existing.matchedLines.push(match);
        if (!existing.snippet && match.snippet) existing.snippet = match.snippet;
        continue;
      }
    }

    const hit: Org2SearchHit = {
      file: filePath,
      line: options.subtree ? sourceStart + 1 : j + 1,
      lineEnd: options.subtree ? sourceEnd + 1 : j + 1,
      heading: current?.title,
      headingLine: current ? current.line + 1 : undefined,
      headingLevel: current?.level,
      headingAncestry,
      id: current?.id,
      todo: current?.todo,
      tags: current?.tags || [],
      snippet: line.trim(),
      context: { startLine: start + 1, endLine: end + 1, lines: lines.slice(start, end + 1) },
      sourceRange: { startLine: sourceStart + 1, endLine: sourceEnd + 1 },
      matchedLines: [match],
      date: sortDate || undefined,
      sortDate: sortDate || undefined,
      ...(options.answerContext ? { answerContext: lines.slice(start, end + 1).join("\n") } : {}),
    };

    if (options.subtree) subtreeHits.set(key, hit);
    hits.push(hit);
  }
}

function sortAndLimitSearchHits(hits: Org2SearchHit[], sort: string, limit: number): Org2SearchHit[] {
  const normalized = normalizedSort(sort);
  if (["date-desc", "newest", "recent"].includes(normalized)) {
    hits.sort((a, b) => (b.sortDate || "").localeCompare(a.sortDate || "") || a.file.localeCompare(b.file) || a.line - b.line);
  } else if (["date-asc", "oldest"].includes(normalized)) {
    hits.sort((a, b) => (a.sortDate || "").localeCompare(b.sortDate || "") || a.file.localeCompare(b.file) || a.line - b.line);
  }
  return hits.slice(0, limit);
}

function parseSearchHeading(line: string): Omit<SearchHeading, "line"> | null {
  const m = /^(\*+)\s+(.*)$/.exec(line);
  if (!m) return null;
  let rest = (m[2] || "").trim();
  const tagMatch = /\s+:([A-Za-z0-9_@#%:.-]+):\s*$/.exec(rest);
  const tags = tagMatch ? (tagMatch[1] || "").split(":").filter(Boolean) : [];
  if (tagMatch) rest = rest.slice(0, tagMatch.index).trim();
  const parts = rest.split(/\s+/);
  const todo = normalizeTodoKeyword(parts[0]);
  if (todo) rest = parts.slice(1).join(" ").trim();
  return { level: (m[1] || "").length, title: parseHeadlineTitleForRoam(`${m[1]} ${rest}`), todo, tags };
}

function subtreeEndLine(lines: string[], heading: SearchHeading | undefined, matchLine: number): number {
  if (!heading) return matchLine;
  for (let j = heading.line + 1; j < lines.length; j += 1) {
    const parsed = parseSearchHeading(lines[j] || "");
    if (parsed && parsed.level <= heading.level) return Math.max(heading.line, j - 1);
  }
  return Math.max(heading.line, lines.length - 1);
}

function dateKeyFromFile(file: string): string {
  const base = path.basename(file);
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(base) || /^(\d{4})(\d{2})(\d{2})/.exec(base);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : "";
}

function dateKeyFromLines(lines: string[], start: number, end: number): string {
  for (let j = Math.max(0, start); j <= Math.min(lines.length - 1, end); j += 1) {
    const found = extractDateFromTimestamp(lines[j] || "");
    if (found) return found;
  }
  return "";
}

function extractDateFromTimestamp(raw: string): string | null {
  const match = raw.match(/(\d{4})-(\d{2})-(\d{2})/);
  return match ? match[0] : null;
}

function inDateWindow(date: string, dateFrom: string, dateTo: string): boolean {
  if (!dateFrom && !dateTo) return true;
  if (!date) return false;
  if (dateFrom && date < dateFrom) return false;
  if (dateTo && date > dateTo) return false;
  return true;
}

function normalizedSort(sort: string): string {
  return String(sort || "scan").toLowerCase();
}

function relativeIndexPath(rootDir: string, absolutePath: string): string {
  const relative = path.relative(rootDir, absolutePath);
  return relative && !relative.startsWith("..") && !path.isAbsolute(relative) ? relative : path.basename(absolutePath);
}
