import type { CompiledCorpus, CompiledCorpusNode } from "./corpusCompile.js";

export type AgentInclude = "backlinks" | "neighbors" | "sources";

export type AgentContextOptions = {
  action: "context" | "search" | "fetch";
  query?: string;
  id?: string;
  limit?: number;
  maxChars?: number;
  include?: AgentInclude[];
};

type AgentSource = {
  file: string;
  sourceRange: { startLine: number; endLine: number };
  citation: string;
};

type AgentNode = {
  key: string;
  kind: "file" | "heading";
  id: string | null;
  title: string;
  path: string[];
  file: string;
  sourceRange: { startLine: number; endLine: number };
  citation: string;
  level?: number;
  todo?: string;
  tags: string[];
  aliases: string[];
  properties: Record<string, string>;
  snippet: string;
  score?: number;
  matchedTerms?: string[];
  sources?: AgentSource[];
  backlinks?: Array<{ sourceKey: string; sourceId: string | null; sourceTitle: string; file: string; line: number; citation: string; linkType: "id" | "wiki" }>;
  neighbors?: Array<{ key: string; id: string | null; title: string; file: string; citation: string; direction: "out" | "in"; linkType: "id" | "wiki" }>;
};

export type AgentPayload = {
  $schema: "org2:agent-context:v1";
  action: "context" | "search" | "fetch";
  query?: string;
  id?: string;
  limit: number;
  maxChars: number;
  corpus: { schemaVersion: string; rootDir: string; generatedAt: string; stats: CompiledCorpus["stats"] };
  results: AgentNode[];
  context?: { text: string; truncated: boolean; charCount: number; citations: AgentSource[] };
  errors: string[];
};

function normalizeId(raw: string | null | undefined): string {
  return String(raw || "").trim().toLowerCase();
}

function citationFor(node: Pick<CompiledCorpusNode, "file" | "sourceRange">): string {
  const end = node.sourceRange.endLine !== node.sourceRange.startLine ? `-${node.sourceRange.endLine}` : "";
  return `${node.file}:${node.sourceRange.startLine}${end}`;
}

function termsFor(query: string): string[] {
  return Array.from(new Set(String(query || "").toLowerCase().match(/[a-z0-9][a-z0-9_-]{1,}/g) || []));
}

function titlePathFor(corpus: CompiledCorpus, node: CompiledCorpusNode): string[] {
  if (node.kind === "file") return [node.title];
  return corpus.nodes
    .filter((candidate) => candidate.file === node.file && candidate.kind === "heading" && candidate.sourceRange.startLine <= node.sourceRange.startLine && (candidate.level || 0) <= (node.level || 0))
    .sort((a, b) => (a.level || 0) - (b.level || 0) || a.sourceRange.startLine - b.sourceRange.startLine)
    .filter((candidate, index, all) => index === all.length - 1 || (candidate.level || 0) < (all[index + 1]!.level || 0))
    .map((candidate) => candidate.title);
}

function scoreNode(node: CompiledCorpusNode, terms: string[]): { score: number; matchedTerms: string[] } {
  const haystack = [node.title, node.snippet, node.id || "", ...node.tags, ...node.aliases, ...Object.keys(node.properties), ...Object.values(node.properties)].join("\n").toLowerCase();
  const matchedTerms = terms.filter((term) => haystack.includes(term));
  let score = matchedTerms.length;
  for (const term of matchedTerms) {
    if (node.title.toLowerCase().includes(term)) score += 4;
    if ((node.id || "").toLowerCase() === term) score += 10;
    if (node.tags.some((tag) => tag.toLowerCase() === term)) score += 3;
  }
  return { score, matchedTerms };
}

function findNodeById(corpus: CompiledCorpus, id: string): CompiledCorpusNode | null {
  const needle = normalizeId(id);
  if (!needle) return null;
  return corpus.nodes.find((node) => normalizeId(node.id) === needle || normalizeId(node.key) === needle) || null;
}

function inferredBacklinksFor(corpus: CompiledCorpus, node: CompiledCorpusNode): NonNullable<AgentNode["backlinks"]> {
  const out = new Map<string, NonNullable<AgentNode["backlinks"]>[number]>();
  for (const backlink of node.backlinks) {
    out.set(`${backlink.sourceKey}:${backlink.line}`, { ...backlink, citation: `${backlink.file}:${backlink.line}` });
  }
  if (node.id) {
    const needle = normalizeId(node.id);
    for (const source of corpus.nodes) {
      if (source.key === node.key) continue;
      for (const link of source.links) {
        if (normalizeId(link.target.replace(/^id:/i, "")) !== needle) continue;
        out.set(`${source.key}:${link.line}`, {
          sourceKey: source.key,
          sourceId: source.id,
          sourceTitle: source.title,
          file: source.file,
          line: link.line,
          citation: `${source.file}:${link.line}`,
          linkType: "id",
        });
      }
    }
  }
  return Array.from(out.values()).sort((a, b) => a.citation.localeCompare(b.citation));
}

function neighborsFor(corpus: CompiledCorpus, node: CompiledCorpusNode): AgentNode["neighbors"] {
  const byId = new Map(corpus.nodes.filter((n) => n.id).map((n) => [normalizeId(n.id), n]));
  const byTitle = new Map(corpus.nodes.map((n) => [n.title.trim().toLowerCase(), n]));
  const out = new Map<string, NonNullable<AgentNode["neighbors"]>[number]>();
  for (const link of node.links) {
    const idTarget = link.type === "id" || /^id:/i.test(link.target) ? byId.get(normalizeId(link.target.replace(/^id:/i, ""))) : undefined;
    const target = idTarget || (link.type === "wiki" ? byTitle.get(link.target.trim().toLowerCase()) : undefined);
    if (!target) continue;
    const linkType = idTarget ? "id" : "wiki";
    out.set(`out:${target.key}`, { key: target.key, id: target.id, title: target.title, file: target.file, citation: citationFor(target), direction: "out", linkType });
  }
  for (const backlink of inferredBacklinksFor(corpus, node)) {
    const source = corpus.nodes.find((n) => n.key === backlink.sourceKey);
    if (!source) continue;
    out.set(`in:${source.key}`, { key: source.key, id: source.id, title: source.title, file: source.file, citation: citationFor(source), direction: "in", linkType: backlink.linkType });
  }
  return Array.from(out.values()).sort((a, b) => `${a.direction}:${a.file}:${a.citation}`.localeCompare(`${b.direction}:${b.file}:${b.citation}`));
}

function toAgentNode(corpus: CompiledCorpus, node: CompiledCorpusNode, include: Set<AgentInclude>, score?: { score: number; matchedTerms: string[] }): AgentNode {
  const source = { file: node.file, sourceRange: node.sourceRange, citation: citationFor(node) };
  return {
    key: node.key,
    kind: node.kind,
    id: node.id,
    title: node.title,
    path: titlePathFor(corpus, node),
    file: node.file,
    sourceRange: node.sourceRange,
    citation: source.citation,
    ...(node.level !== undefined ? { level: node.level } : {}),
    ...(node.todo ? { todo: node.todo } : {}),
    tags: node.tags,
    aliases: node.aliases,
    properties: node.properties,
    snippet: node.snippet,
    ...(score ? { score: score.score, matchedTerms: score.matchedTerms } : {}),
    ...(include.has("sources") ? { sources: [source] } : {}),
    ...(include.has("backlinks") ? { backlinks: inferredBacklinksFor(corpus, node) } : {}),
    ...(include.has("neighbors") ? { neighbors: neighborsFor(corpus, node) } : {}),
  };
}

export function buildAgentContextPayload(corpus: CompiledCorpus, opts: AgentContextOptions): AgentPayload {
  const include = new Set(opts.include || []);
  const limit = Math.max(1, Math.min(100, opts.limit || 10));
  const maxChars = Math.max(200, opts.maxChars || 12000);
  const errors: string[] = [];
  let selected: Array<{ node: CompiledCorpusNode; score?: { score: number; matchedTerms: string[] } }> = [];

  if (opts.action === "fetch") {
    const node = findNodeById(corpus, opts.id || "");
    if (node) selected = [{ node }];
    else errors.push(`No node found for id/key: ${opts.id || ""}`);
  } else {
    const terms = termsFor(opts.query || "");
    if (terms.length === 0) errors.push("Query must include at least one searchable term.");
    selected = corpus.nodes
      .map((node) => ({ node, score: scoreNode(node, terms) }))
      .filter((item) => (item.score?.score || 0) > 0)
      .sort((a, b) => (b.score!.score - a.score!.score) || a.node.file.localeCompare(b.node.file) || a.node.sourceRange.startLine - b.node.sourceRange.startLine)
      .slice(0, limit);
  }

  const results = selected.map((item) => toAgentNode(corpus, item.node, include, item.score));
  const payload: AgentPayload = {
    $schema: "org2:agent-context:v1",
    action: opts.action,
    ...(opts.query ? { query: opts.query } : {}),
    ...(opts.id ? { id: opts.id } : {}),
    limit,
    maxChars,
    corpus: { schemaVersion: corpus.schemaVersion, rootDir: corpus.rootDir, generatedAt: corpus.artifact.generatedAt, stats: corpus.stats },
    results,
    errors,
  };

  if (opts.action === "context") {
    const citations: AgentSource[] = [];
    let text = "";
    let truncated = false;
    for (const result of results) {
      const chunk = [`## ${result.title}`, `Source: ${result.citation}`, result.snippet].filter(Boolean).join("\n") + "\n\n";
      if (text.length + chunk.length > maxChars) {
        truncated = true;
        break;
      }
      text += chunk;
      citations.push({ file: result.file, sourceRange: result.sourceRange, citation: result.citation });
    }
    payload.context = { text: text.trimEnd(), truncated, charCount: text.trimEnd().length, citations };
  }

  return payload;
}
