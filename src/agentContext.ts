import type { CompiledCorpus, CompiledCorpusNode } from "./corpusCompile.js";

export type AgentInclude = "backlinks" | "neighbors" | "sources";
export type AgentAction = "context" | "search" | "fetch" | "bundle";

export type AgentContextOptions = {
  action: AgentAction;
  query?: string;
  id?: string;
  limit?: number;
  maxChars?: number;
  include?: AgentInclude[];
  scope?: string;
  since?: string;
  sourceType?: string;
  reviewStatus?: string;
};

type AgentSource = {
  file: string;
  sourceRange: { startLine: number; endLine: number };
  citation: string;
};

type AgentFreshnessState = "fresh" | "stale" | "expired" | "unknown";
type AgentReviewState = "generated" | "review-required" | "reviewed" | "promoted" | "unknown";

type AgentClaimState = {
  reviewStatus: AgentReviewState;
  claimState: string | null;
  observedAt: string | null;
  validAsOf: string | null;
  staleAfter: string | null;
  expiresAt: string | null;
  freshness: AgentFreshnessState;
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
  claimState: AgentClaimState;
  sources?: AgentSource[];
  backlinks?: Array<{ sourceKey: string; sourceId: string | null; sourceTitle: string; file: string; line: number; citation: string; linkType: "id" | "wiki" }>;
  neighbors?: Array<{ key: string; id: string | null; title: string; file: string; citation: string; direction: "out" | "in"; linkType: "id" | "wiki" }>;
};

export type AgentPayload = {
  $schema: "org2:agent-context:v1";
  action: AgentAction;
  query?: string;
  id?: string;
  limit: number;
  maxChars: number;
  filters?: { scope?: string; since?: string; sourceType?: string; reviewStatus?: string };
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

function propertyValue(node: CompiledCorpusNode, names: string[]): string {
  for (const name of names) {
    const value = (node.effectiveProperties || node.properties)[name.toUpperCase()];
    if (value) return value;
  }
  return "";
}

function parseSinceCutoff(raw: string | undefined, now = new Date()): Date | null {
  const value = String(raw || "").trim().toLowerCase();
  if (!value) return null;
  const rel = /^(\d+)([dwmy])$/.exec(value);
  if (rel) {
    const amount = Number.parseInt(rel[1] || "0", 10);
    const unit = rel[2] || "d";
    const days = unit === "w" ? amount * 7 : unit === "m" ? amount * 30 : unit === "y" ? amount * 365 : amount;
    return new Date(now.getTime() - days * 24 * 60 * 60 * 1000);
  }
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function dateForNode(node: CompiledCorpusNode): Date | null {
  const raw = propertyValue(node, ["UPDATED", "DATE", "CREATED", "CLOSED"]) || node.planning.find((p) => p.kind === "CLOSED")?.raw || node.planning[0]?.raw || "";
  const match = String(raw).match(/(\d{4})-(\d{2})-(\d{2})/);
  if (!match) return null;
  const parsed = new Date(`${match[1]}-${match[2]}-${match[3]}T00:00:00Z`);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function nodeMatchesFilters(node: CompiledCorpusNode, opts: AgentContextOptions): boolean {
  if (opts.scope) {
    const raw = opts.scope.trim().toLowerCase();
    const [kind, valueRaw] = raw.includes(":") ? raw.split(/:(.*)/s, 2) : ["", raw];
    const value = (valueRaw || "").trim();
    const haystack = [node.title, node.file, node.snippet, node.id || "", ...node.tags, ...node.aliases, ...Object.values(node.effectiveProperties || node.properties)].join("\n").toLowerCase();
    if (kind === "project" && !node.tags.map((t) => t.toLowerCase()).includes(value) && propertyValue(node, ["PROJECT"]).toLowerCase() !== value && !haystack.includes(value)) return false;
    else if (kind === "person" && propertyValue(node, ["PERSON", "PEOPLE"]).toLowerCase() !== value && !haystack.includes(value)) return false;
    else if (kind === "entity" && !haystack.includes(value)) return false;
    else if (!kind && !haystack.includes(value)) return false;
  }
  if (opts.sourceType) {
    const wanted = opts.sourceType.trim().toLowerCase();
    const actual = (propertyValue(node, ["SOURCE_TYPE", "TYPE"]) || node.file.split(".").pop() || "").toLowerCase();
    if (actual !== wanted) return false;
  }
  if (opts.reviewStatus) {
    const actual = propertyValue(node, ["REVIEW_STATUS", "REVIEW", "STATUS"]).toLowerCase();
    if (actual !== opts.reviewStatus.trim().toLowerCase()) return false;
  }
  const cutoff = parseSinceCutoff(opts.since);
  if (cutoff) {
    const nodeDate = dateForNode(node);
    if (!nodeDate || nodeDate < cutoff) return false;
  }
  return true;
}

function parseDateMs(raw: string | null | undefined): number | null {
  const value = String(raw || "").trim();
  if (!value) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

function claimStateFor(node: CompiledCorpusNode, nowMs = Date.now()): AgentClaimState {
  const props = node.effectiveProperties || node.properties || {};
  const reviewStatus = String(props.ORG2_REVIEW_STATUS || "unknown").trim().toLowerCase() as AgentReviewState;
  const observedAt = props.ORG2_OBSERVED_AT || null;
  const validAsOf = props.ORG2_VALID_AS_OF || null;
  const staleAfter = props.ORG2_STALE_AFTER || null;
  const expiresAt = props.ORG2_EXPIRES_AT || null;
  const expiresMs = parseDateMs(expiresAt);
  const staleMs = parseDateMs(staleAfter);
  const freshness: AgentFreshnessState = expiresMs !== null && expiresMs < nowMs ? "expired" : staleMs !== null && staleMs < nowMs ? "stale" : (observedAt || validAsOf) ? "fresh" : "unknown";
  return {
    reviewStatus: ["generated", "review-required", "reviewed", "promoted"].includes(reviewStatus) ? reviewStatus : "unknown",
    claimState: props.ORG2_CLAIM_STATE || null,
    observedAt,
    validAsOf,
    staleAfter,
    expiresAt,
    freshness,
  };
}

function scoreNode(node: CompiledCorpusNode, terms: string[]): { score: number; matchedTerms: string[] } {
  const haystack = [node.title, node.snippet, node.id || "", ...node.tags, ...node.aliases, ...Object.keys(node.effectiveProperties || node.properties), ...Object.values(node.effectiveProperties || node.properties)].join("\n").toLowerCase();
  const matchedTerms = terms.filter((term) => haystack.includes(term));
  let score = matchedTerms.length;
  for (const term of matchedTerms) {
    if (node.title.toLowerCase().includes(term)) score += 4;
    if ((node.id || "").toLowerCase() === term) score += 10;
    if (node.tags.some((tag) => tag.toLowerCase() === term)) score += 3;
  }
  const claim = claimStateFor(node);
  if (claim.reviewStatus === "reviewed" || claim.reviewStatus === "promoted") score += 2;
  if (claim.freshness === "fresh") score += 1;
  if (claim.freshness === "stale") score -= 2;
  if (claim.freshness === "expired") score -= 4;
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
    properties: node.effectiveProperties || node.properties,
    snippet: node.snippet,
    ...(score ? { score: score.score, matchedTerms: score.matchedTerms } : {}),
    claimState: claimStateFor(node),
    ...(include.has("sources") ? { sources: [source] } : {}),
    ...(include.has("backlinks") ? { backlinks: inferredBacklinksFor(corpus, node) } : {}),
    ...(include.has("neighbors") ? { neighbors: neighborsFor(corpus, node) } : {}),
  };
}

function escapeMarkdown(raw: string): string {
  return String(raw || "").replace(/[\`]/g, "\\$&");
}

function uniqueSorted(values: Array<string | null | undefined>): string[] {
  return Array.from(new Set(values.map((value) => String(value || "").trim()).filter(Boolean))).sort((a, b) => a.localeCompare(b));
}

export function renderAgentContextPack(payload: AgentPayload, format: "markdown" | "org" = "markdown"): string {
  const isOrg = format === "org";
  const h1 = isOrg ? "*" : "#";
  const h2 = isOrg ? "**" : "##";
  const h3 = isOrg ? "***" : "###";
  const lines: string[] = [];
  const query = payload.query || payload.id || "";
  const results = payload.results || [];
  const timeline = results
    .map((node) => ({ node, date: String(node.properties.UPDATED || node.properties.DATE || node.properties.CREATED || node.properties.CLOSED || node.claimState.validAsOf || node.claimState.observedAt || "") }))
    .filter((item) => /\d{4}-\d{2}-\d{2}/.test(item.date))
    .sort((a, b) => b.date.localeCompare(a.date) || a.node.citation.localeCompare(b.node.citation))
    .slice(0, 8);
  const todos = results.filter((node) => Boolean(node.todo));
  const entityValues = uniqueSorted(results.flatMap((node) => [node.properties.PROJECT, node.properties.PERSON, node.properties.PEOPLE, ...node.tags, ...node.aliases]));
  const backlinkValues = uniqueSorted(results.flatMap((node) => (node.backlinks || []).map((link) => `${link.sourceTitle} (${link.citation})`)));
  const caveats = uniqueSorted([
    ...(payload.errors || []),
    ...(payload.context?.truncated ? [`Context text truncated at ${payload.maxChars} characters/budget.`] : []),
    ...results.filter((node) => node.claimState.freshness === "stale" || node.claimState.freshness === "expired").map((node) => `${node.title} is ${node.claimState.freshness} (${node.citation})`),
    ...(results.length === 0 ? ["No matching notes found for this query."] : []),
  ]);

  lines.push(`${h1} Org2 Context Pack`);
  lines.push("");
  lines.push(`${h2} Objective / query`);
  lines.push(query ? `- ${escapeMarkdown(query)}` : "- (not provided)");
  lines.push(`- Budget: ${payload.maxChars} chars`);
  lines.push(`- Corpus: ${payload.corpus.rootDir}`);
  lines.push("");
  lines.push(`${h2} Top cited notes`);
  if (results.length === 0) lines.push("- None");
  for (const node of results) {
    lines.push(`${h3} ${escapeMarkdown(node.title)}`);
    lines.push(`- Citation: ${node.citation}`);
    if (node.id) lines.push(`- ID: ${node.id}`);
    if (node.todo) lines.push(`- TODO: ${node.todo}`);
    if (node.tags.length) lines.push(`- Tags: ${node.tags.join(", ")}`);
    lines.push(`- Review/freshness: ${node.claimState.reviewStatus} / ${node.claimState.freshness}`);
    lines.push("");
    lines.push(node.snippet || "(no snippet)");
    lines.push("");
  }
  lines.push(`${h2} Recent timeline entries`);
  if (timeline.length === 0) lines.push("- None found");
  for (const item of timeline) lines.push(`- ${item.date.match(/\d{4}-\d{2}-\d{2}/)?.[0] || item.date}: ${item.node.title} (${item.node.citation})`);
  lines.push("");
  lines.push(`${h2} Active TODOs / scheduled items`);
  if (todos.length === 0) lines.push("- None found");
  for (const node of todos) lines.push(`- ${node.todo} ${node.title} (${node.citation})`);
  lines.push("");
  lines.push(`${h2} Related entities and backlinks`);
  if (entityValues.length === 0 && backlinkValues.length === 0) lines.push("- None found");
  for (const value of entityValues) lines.push(`- Entity: ${value}`);
  for (const value of backlinkValues.slice(0, 12)) lines.push(`- Backlink: ${value}`);
  lines.push("");
  lines.push(`${h2} Open questions / known uncertainty`);
  if (caveats.length === 0) lines.push("- None surfaced by org2; verify any task-specific assumptions before acting.");
  for (const caveat of caveats) lines.push(`- ${caveat}`);
  lines.push("");
  lines.push(`${h2} Suggested next actions`);
  if (results.length === 0) lines.push("- Broaden the query or scope and regenerate the context pack.");
  else {
    lines.push("- Start with the top cited notes above; cite file:line provenance when using facts.");
    lines.push("- Follow backlinks/neighbors for any decision that depends on missing context.");
    lines.push("- Refresh stale/expired claims before relying on them.");
  }
  lines.push("");
  return lines.join("\n");
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
      .filter((node) => nodeMatchesFilters(node, opts))
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
    ...((opts.scope || opts.since || opts.sourceType || opts.reviewStatus) ? { filters: { ...(opts.scope ? { scope: opts.scope } : {}), ...(opts.since ? { since: opts.since } : {}), ...(opts.sourceType ? { sourceType: opts.sourceType } : {}), ...(opts.reviewStatus ? { reviewStatus: opts.reviewStatus } : {}) } } : {}),
    corpus: { schemaVersion: corpus.schemaVersion, rootDir: corpus.rootDir, generatedAt: corpus.artifact.generatedAt, stats: corpus.stats },
    results,
    errors,
  };

  if (opts.action === "context" || opts.action === "bundle") {
    const citations: AgentSource[] = [];
    let text = "";
    let truncated = false;
    for (const result of results) {
      const chunk = [`## ${result.title}`, `Source: ${result.citation}`, `Review: ${result.claimState.reviewStatus}; freshness: ${result.claimState.freshness}`, result.snippet].filter(Boolean).join("\n") + "\n\n";
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
