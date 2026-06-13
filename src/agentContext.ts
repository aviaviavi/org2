import type { CompiledCorpus, CompiledCorpusEntityProfile, CompiledCorpusNode } from "./corpusCompile.js";

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
  recencyWeight?: number;
  salienceWeight?: number;
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

type AgentContextAttachment = {
  type: "id" | "file" | "url" | "session" | "artifact" | "entity" | "report" | "ticket" | "note" | "other";
  ref: string;
  label?: string;
  line?: number;
  source: "property" | "link";
  target?: {
    key: string;
    kind: "file" | "heading";
    id: string | null;
    title: string;
    file: string;
    sourceRange: { startLine: number; endLine: number };
    citation: string;
  };
};

type AgentThreadMetadata = {
  agent?: string;
  session?: string;
  status?: string;
  transcript?: string;
  storage?: "summary" | "transcript" | "external" | "mixed" | "unknown";
  contextAttachments: AgentContextAttachment[];
};

type AgentRelatedThread = {
  key: string;
  id: string | null;
  title: string;
  agent?: string;
  session?: string;
  status?: string;
  file: string;
  sourceRange: { startLine: number; endLine: number };
  citation: string;
  matchingAttachments: AgentContextAttachment[];
};

type AgentDataLinkKind = "data-link" | "warehouse-query" | "dataset" | "sql-view" | "event-stream" | "timeline-link";

type AgentDataLinkMetadata = {
  kind: AgentDataLinkKind;
  system?: string;
  engine?: string;
  source?: string;
  path?: string;
  queryId?: string;
  query?: string;
  queryHash?: string;
  params?: unknown;
  paramsRaw?: string;
  artifact?: string;
  result?: string;
  rowCount?: number;
  lastRun?: string;
  freshness?: string;
  materialized?: string;
};

type AgentRelatedDataLink = {
  key: string;
  id: string | null;
  title: string;
  kind: AgentDataLinkKind;
  file: string;
  sourceRange: { startLine: number; endLine: number };
  citation: string;
  dataLink: AgentDataLinkMetadata;
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
  selectionReason?: string[];
  claimState: AgentClaimState;
  thread?: AgentThreadMetadata;
  relatedThreads?: AgentRelatedThread[];
  dataLink?: AgentDataLinkMetadata;
  relatedDataLinks?: AgentRelatedDataLink[];
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
  ranking?: { recencyWeight: number; salienceWeight: number };
  corpus: { schemaVersion: string; rootDir: string; generatedAt: string; stats: CompiledCorpus["stats"] };
  results: AgentNode[];
  entityProfiles?: CompiledCorpusEntityProfile[];
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

function numericProperty(node: CompiledCorpusNode, names: string[]): number | null {
  const raw = propertyValue(node, names);
  if (!raw) return null;
  if (/^(true|yes|pinned|important)$/i.test(raw)) return 1;
  const parsed = Number.parseFloat(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

function recencyScoreFor(node: CompiledCorpusNode, nowMs = Date.now()): { score: number; reason: string | null } {
  const date = dateForNode(node);
  if (!date) return { score: 0, reason: null };
  const ageDays = Math.max(0, (nowMs - date.getTime()) / (24 * 60 * 60 * 1000));
  const score = Math.max(0, 3 - Math.log2(1 + ageDays / 14));
  return { score, reason: `dated ${date.toISOString().slice(0, 10)} (${score.toFixed(2)} recency)` };
}

function salienceScoreFor(corpus: CompiledCorpus, node: CompiledCorpusNode, opts: AgentContextOptions): { score: number; reasons: string[] } {
  let score = 0;
  const reasons: string[] = [];
  const explicit = numericProperty(node, ["ORG2_SALIENCE", "SALIENCE", "IMPORTANCE", "PRIORITY"]);
  if (explicit !== null) { score += explicit * 3; reasons.push(`explicit salience ${explicit}`); }
  const pinned = numericProperty(node, ["ORG2_PINNED", "PINNED", "IMPORTANT"]);
  if (pinned !== null && pinned > 0) { score += 4; reasons.push("pinned/important metadata"); }
  if (node.todo && !/^(DONE|CANCELLED|CANCELED)$/i.test(node.todo)) { score += 2; reasons.push(`active TODO ${node.todo}`); }
  const activePlanning = node.planning.filter((p) => p.kind === "SCHEDULED" || p.kind === "DEADLINE");
  if (activePlanning.length) { score += Math.min(3, activePlanning.length * 1.5); reasons.push("scheduled/deadline planning"); }
  const backlinkCount = inferredBacklinksFor(corpus, node).length;
  if (backlinkCount) { const backlinkScore = Math.min(3, Math.log2(backlinkCount + 1)); score += backlinkScore; reasons.push(`${backlinkCount} backlink/mention${backlinkCount === 1 ? "" : "s"}`); }
  if (opts.scope) {
    const scope = opts.scope.toLowerCase().replace(/^[^:]+:/, "").trim();
    const values = [propertyValue(node, ["PROJECT", "PERSON", "PEOPLE", "ENTITY"]), ...node.tags, ...node.aliases].join(" ").toLowerCase();
    if (scope && values.includes(scope)) { score += 2; reasons.push(`near scoped entity/project '${scope}'`); }
  }
  return { score, reasons };
}

function scoreNode(corpus: CompiledCorpus, node: CompiledCorpusNode, terms: string[], opts: AgentContextOptions): { score: number; matchedTerms: string[]; selectionReason: string[] } {
  const haystack = [node.title, node.snippet, node.id || "", ...node.tags, ...node.aliases, ...Object.keys(node.effectiveProperties || node.properties), ...Object.values(node.effectiveProperties || node.properties)].join("\n").toLowerCase();
  const matchedTerms = terms.filter((term) => haystack.includes(term));
  const selectionReason: string[] = matchedTerms.length ? [`matched ${matchedTerms.length} query term${matchedTerms.length === 1 ? "" : "s"}: ${matchedTerms.join(", ")}`] : [];
  let score = matchedTerms.length;
  for (const term of matchedTerms) {
    if (node.title.toLowerCase().includes(term)) { score += 4; selectionReason.push(`title contains '${term}'`); }
    if ((node.id || "").toLowerCase() === term) { score += 10; selectionReason.push(`id exactly matches '${term}'`); }
    if (node.tags.some((tag) => tag.toLowerCase() === term)) { score += 3; selectionReason.push(`tag matches '${term}'`); }
  }
  const claim = claimStateFor(node);
  if (claim.reviewStatus === "reviewed" || claim.reviewStatus === "promoted") { score += 2; selectionReason.push(`${claim.reviewStatus} claim`); }
  if (claim.freshness === "fresh") { score += 1; selectionReason.push("fresh claim"); }
  if (claim.freshness === "stale") { score -= 2; selectionReason.push("penalized stale claim"); }
  if (claim.freshness === "expired") { score -= 4; selectionReason.push("penalized expired claim"); }
  const recencyWeight = Number.isFinite(opts.recencyWeight) ? opts.recencyWeight! : 1;
  const salienceWeight = Number.isFinite(opts.salienceWeight) ? opts.salienceWeight! : 1;
  const recency = recencyScoreFor(node);
  if (recency.score && recencyWeight) { score += recency.score * recencyWeight; if (recency.reason) selectionReason.push(`${recency.reason} × recency weight ${recencyWeight}`); }
  const salience = salienceScoreFor(corpus, node, opts);
  if (salience.score && salienceWeight) selectionReason.push(...salience.reasons.map((reason) => `${reason} × salience weight ${salienceWeight}`));
  score += salience.score * salienceWeight;
  return { score, matchedTerms, selectionReason };
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

function normalizeTypedKind(raw: string | null | undefined): string {
  return String(raw || "").trim().toLowerCase().replace(/_/g, "-");
}

function kindPropertyFor(node: CompiledCorpusNode): string {
  const props = node.properties || {};
  return normalizeTypedKind(props.KIND || props.ORG2_KIND || props.TYPE || props.ORG2_TYPE);
}

function isAgentThreadNode(node: CompiledCorpusNode): boolean {
  return kindPropertyFor(node) === "agent-thread";
}

function attachmentTypeFor(raw: string): AgentContextAttachment["type"] {
  const type = raw.trim().toLowerCase().replace(/_/g, "-");
  if (type === "id" || type === "file" || type === "url" || type === "session" || type === "artifact" || type === "entity" || type === "report" || type === "ticket" || type === "note") return type;
  return "other";
}

function parseContextAttachmentToken(raw: string, source: AgentContextAttachment["source"]): AgentContextAttachment | null {
  const value = String(raw || "").trim();
  if (!value) return null;
  const match = /^([A-Za-z][A-Za-z0-9_-]*):(.*)$/.exec(value);
  if (!match) return { type: "other", ref: value, source };
  const prefix = String(match[1] || "").trim();
  const refTail = String(match[2] || "").trim();
  if (!refTail) return null;
  const type = attachmentTypeFor(prefix);
  return { type, ref: `${prefix}:${refTail}`, source };
}

function parseContextAttachmentList(raw: string | undefined): AgentContextAttachment[] {
  if (!raw) return [];
  return String(raw)
    .split(/[;,]/)
    .map((token) => parseContextAttachmentToken(token, "property"))
    .filter((item): item is AgentContextAttachment => !!item);
}

function attachmentFromLink(link: CompiledCorpusNode["links"][number]): AgentContextAttachment | null {
  if (link.type === "id" || /^id:/i.test(link.target)) {
    const target = link.target.replace(/^id:/i, "").trim();
    if (!target) return null;
    return { type: "id", ref: `id:${target}`, ...(link.description ? { label: link.description } : {}), line: link.line, source: "link" };
  }
  if (link.type === "file") return { type: "file", ref: link.target, ...(link.description ? { label: link.description } : {}), line: link.line, source: "link" };
  if (link.type === "url") return { type: "url", ref: link.target, ...(link.description ? { label: link.description } : {}), line: link.line, source: "link" };
  if (link.type === "wiki") return { type: "note", ref: link.target, ...(link.description ? { label: link.description } : {}), line: link.line, source: "link" };
  return null;
}

function mergeAttachments(attachments: AgentContextAttachment[]): AgentContextAttachment[] {
  const byRef = new Map<string, AgentContextAttachment>();
  for (const attachment of attachments) {
    const key = `${attachment.type}\0${attachment.ref.toLowerCase()}`;
    const existing = byRef.get(key);
    if (!existing) {
      byRef.set(key, attachment);
      continue;
    }
    byRef.set(key, {
      ...existing,
      ...(existing.label ? {} : attachment.label ? { label: attachment.label } : {}),
      ...(existing.line !== undefined ? {} : attachment.line !== undefined ? { line: attachment.line } : {}),
    });
  }
  return Array.from(byRef.values()).sort((a, b) => a.type.localeCompare(b.type) || a.ref.localeCompare(b.ref) || (a.line || 0) - (b.line || 0));
}

function normalizeFileRef(raw: string): string {
  return String(raw || "")
    .trim()
    .replace(/^file:/i, "")
    .replace(/^\.\//, "");
}

function refTail(raw: string): string {
  const value = String(raw || "").trim();
  const match = /^[A-Za-z][A-Za-z0-9_-]*:(.*)$/.exec(value);
  return String(match ? match[1] : value).trim();
}

function nodeHasExactLabel(node: CompiledCorpusNode, raw: string): boolean {
  const needle = normalizeLabel(raw);
  if (!needle) return false;
  return normalizeLabel(node.title) === needle || node.aliases.some((alias) => normalizeLabel(alias) === needle);
}

function attachmentTargetFor(corpus: CompiledCorpus, attachment: AgentContextAttachment): AgentContextAttachment["target"] | undefined {
  let target: CompiledCorpusNode | undefined;
  if (attachment.type === "id") {
    const id = attachment.ref.replace(/^id:/i, "");
    target = corpus.nodes.find((node) => node.id && normalizeId(node.id) === normalizeId(id));
  } else if (attachment.type === "note") {
    const noteTitle = attachment.ref.trim().toLowerCase();
    target = corpus.nodes.find((node) => node.title.trim().toLowerCase() === noteTitle);
  } else if (attachment.type === "file") {
    const wanted = normalizeFileRef(attachment.ref);
    target = corpus.nodes.find((node) => normalizeFileRef(node.file) === wanted) || corpus.nodes.find((node) => normalizeFileRef(node.file).endsWith(`/${wanted}`));
  } else if (attachment.type !== "url" && attachment.type !== "session") {
    const tail = refTail(attachment.ref);
    target = corpus.nodes.find((node) => (node.id && normalizeId(node.id) === normalizeId(tail)) || nodeHasExactLabel(node, tail));
  }
  if (!target) return undefined;
  return {
    key: target.key,
    kind: target.kind,
    id: target.id,
    title: target.title,
    file: target.file,
    sourceRange: target.sourceRange,
    citation: citationFor(target),
  };
}

function resolveAttachmentTargets(corpus: CompiledCorpus, attachments: AgentContextAttachment[]): AgentContextAttachment[] {
  return attachments.map((attachment) => {
    const target = attachmentTargetFor(corpus, attachment);
    return target ? { ...attachment, target } : attachment;
  });
}

function normalizeThreadStorage(raw: string | undefined): AgentThreadMetadata["storage"] | undefined {
  const value = String(raw || "").trim().toLowerCase();
  if (!value) return undefined;
  if (value === "summary" || value === "transcript" || value === "external" || value === "mixed") return value;
  return "unknown";
}

function agentThreadMetadataFor(corpus: CompiledCorpus, node: CompiledCorpusNode): AgentThreadMetadata | undefined {
  if (!isAgentThreadNode(node)) return undefined;
  const props = node.effectiveProperties || node.properties || {};
  const propertyAttachments = [
    ...parseContextAttachmentList(props.CONTEXT),
    ...parseContextAttachmentList(props.ORG2_CONTEXT),
    ...parseContextAttachmentList(props.CONTEXT_ATTACHMENTS),
    ...parseContextAttachmentList(props.ORG2_CONTEXT_ATTACHMENTS),
  ];
  const linkAttachments = node.links.map(attachmentFromLink).filter((item): item is AgentContextAttachment => !!item);
  const contextAttachments = resolveAttachmentTargets(corpus, mergeAttachments([...propertyAttachments, ...linkAttachments]));
  return {
    ...(props.AGENT || props.ORG2_AGENT ? { agent: props.AGENT || props.ORG2_AGENT } : {}),
    ...(props.SESSION || props.ORG2_SESSION ? { session: props.SESSION || props.ORG2_SESSION } : {}),
    ...(props.STATUS || props.ORG2_STATUS ? { status: props.STATUS || props.ORG2_STATUS } : {}),
    ...(props.TRANSCRIPT || props.TRANSCRIPT_ARTIFACT || props.ORG2_TRANSCRIPT ? { transcript: props.TRANSCRIPT || props.TRANSCRIPT_ARTIFACT || props.ORG2_TRANSCRIPT } : {}),
    ...(normalizeThreadStorage(props.STORAGE || props.TRANSCRIPT_STORAGE || props.ORG2_STORAGE) ? { storage: normalizeThreadStorage(props.STORAGE || props.TRANSCRIPT_STORAGE || props.ORG2_STORAGE) } : {}),
    contextAttachments,
  };
}

function attachmentMatchesNode(node: CompiledCorpusNode, attachment: AgentContextAttachment): boolean {
  if (attachment.target?.key === node.key) return true;
  if (attachment.type === "id" && node.id && normalizeId(refTail(attachment.ref)) === normalizeId(node.id)) return true;
  if (attachment.type === "file" && node.kind === "file") {
    const wanted = normalizeFileRef(attachment.ref);
    const actual = normalizeFileRef(node.file);
    return actual === wanted || actual.endsWith(`/${wanted}`);
  }
  if (attachment.type === "note" && nodeHasExactLabel(node, attachment.ref)) return true;
  if (attachment.type !== "url" && attachment.type !== "session") {
    const tail = refTail(attachment.ref);
    return Boolean((node.id && normalizeId(tail) === normalizeId(node.id)) || nodeHasExactLabel(node, tail));
  }
  return false;
}

function relatedThreadsFor(corpus: CompiledCorpus, node: CompiledCorpusNode): AgentRelatedThread[] {
  if (isAgentThreadNode(node)) return [];
  const out: AgentRelatedThread[] = [];
  for (const candidate of corpus.nodes) {
    if (candidate.key === node.key || !isAgentThreadNode(candidate)) continue;
    const thread = agentThreadMetadataFor(corpus, candidate);
    if (!thread) continue;
    const matchingAttachments = thread.contextAttachments.filter((attachment) => attachmentMatchesNode(node, attachment));
    if (matchingAttachments.length === 0) continue;
    out.push({
      key: candidate.key,
      id: candidate.id,
      title: candidate.title,
      ...(thread.agent ? { agent: thread.agent } : {}),
      ...(thread.session ? { session: thread.session } : {}),
      ...(thread.status ? { status: thread.status } : {}),
      file: candidate.file,
      sourceRange: candidate.sourceRange,
      citation: citationFor(candidate),
      matchingAttachments,
    });
  }
  return out.sort((a, b) => a.title.localeCompare(b.title) || a.citation.localeCompare(b.citation));
}

function dataLinkKindFor(node: CompiledCorpusNode): AgentDataLinkKind | null {
  const kind = kindPropertyFor(node);
  if (kind === "data-link" || kind === "warehouse-query" || kind === "dataset" || kind === "sql-view" || kind === "event-stream" || kind === "timeline-link") return kind;
  return null;
}

function parseDataParams(raw: string | undefined): Pick<AgentDataLinkMetadata, "params" | "paramsRaw"> {
  const value = String(raw || "").trim();
  if (!value) return {};
  try {
    return { params: JSON.parse(value) };
  } catch {
    return { paramsRaw: value };
  }
}

function numericDataProperty(props: Record<string, string>, names: string[]): number | undefined {
  for (const name of names) {
    const raw = props[name];
    if (!raw) continue;
    const parsed = Number.parseInt(String(raw).replace(/,/g, "").trim(), 10);
    if (Number.isFinite(parsed)) return parsed;
  }
  return undefined;
}

function stringDataProperty(props: Record<string, string>, names: string[]): string | undefined {
  for (const name of names) {
    const value = String(props[name] || "").trim();
    if (value) return value;
  }
  return undefined;
}

function dataLinkMetadataFor(node: CompiledCorpusNode): AgentDataLinkMetadata | undefined {
  const kind = dataLinkKindFor(node);
  if (!kind) return undefined;
  const props = node.effectiveProperties || node.properties || {};
  const rowCount = numericDataProperty(props, ["ROW_COUNT", "ROWS", "ORG2_ROW_COUNT"]);
  const system = stringDataProperty(props, ["SYSTEM", "SOURCE_SYSTEM", "ORG2_SYSTEM"]);
  const engine = stringDataProperty(props, ["ENGINE", "ORG2_ENGINE"]);
  const source = stringDataProperty(props, ["SOURCE", "DATA_SOURCE", "URI", "URL"]);
  const sourcePath = stringDataProperty(props, ["PATH", "FILE"]);
  const queryId = stringDataProperty(props, ["QUERY_ID", "SQL_ID", "VIEW_ID"]);
  const query = stringDataProperty(props, ["QUERY", "SQL"]);
  const queryHash = stringDataProperty(props, ["QUERY_HASH", "HASH", "SOURCE_HASH"]);
  const artifact = stringDataProperty(props, ["ARTIFACT", "RESULT_ARTIFACT", "OUTPUT"]);
  const result = stringDataProperty(props, ["RESULT", "RESULTS", "MATERIALIZED_RESULT"]);
  const lastRun = stringDataProperty(props, ["LAST_RUN", "RAN_AT", "UPDATED_AT", "ORG2_LAST_RUN"]);
  const freshness = stringDataProperty(props, ["FRESHNESS", "STATUS"]);
  const materialized = stringDataProperty(props, ["MATERIALIZED", "MATERIALIZATION"]);
  return {
    kind,
    ...(system ? { system } : {}),
    ...(engine ? { engine } : {}),
    ...(source ? { source } : {}),
    ...(sourcePath ? { path: sourcePath } : {}),
    ...(queryId ? { queryId } : {}),
    ...(query ? { query } : {}),
    ...(queryHash ? { queryHash } : {}),
    ...parseDataParams(stringDataProperty(props, ["PARAMS", "PARAMETERS", "ARGS"])),
    ...(artifact ? { artifact } : {}),
    ...(result ? { result } : {}),
    ...(rowCount !== undefined ? { rowCount } : {}),
    ...(lastRun ? { lastRun } : {}),
    ...(freshness ? { freshness } : {}),
    ...(materialized ? { materialized } : {}),
  };
}

function headingSubtreeEndLine(corpus: CompiledCorpus, node: CompiledCorpusNode): number {
  if (node.kind !== "heading") return Number.POSITIVE_INFINITY;
  const nextPeerOrAncestor = corpus.nodes
    .filter((candidate) => candidate.file === node.file && candidate.kind === "heading" && candidate.sourceRange.startLine > node.sourceRange.startLine && (candidate.level || 0) <= (node.level || 0))
    .sort((a, b) => a.sourceRange.startLine - b.sourceRange.startLine)[0];
  return nextPeerOrAncestor ? nextPeerOrAncestor.sourceRange.startLine - 1 : Number.POSITIVE_INFINITY;
}

function isDescendantDataLink(corpus: CompiledCorpus, node: CompiledCorpusNode, candidate: CompiledCorpusNode): boolean {
  if (candidate.key === node.key || candidate.file !== node.file || !dataLinkKindFor(candidate)) return false;
  if (node.kind === "file") return true;
  if (candidate.kind !== "heading") return false;
  const nodeLevel = node.level || 0;
  const candidateLevel = candidate.level || 0;
  return candidate.sourceRange.startLine > node.sourceRange.startLine && candidate.sourceRange.startLine <= headingSubtreeEndLine(corpus, node) && candidateLevel > nodeLevel;
}

function relatedDataLinksFor(corpus: CompiledCorpus, node: CompiledCorpusNode): AgentRelatedDataLink[] {
  if (dataLinkKindFor(node)) return [];
  const out: AgentRelatedDataLink[] = [];
  for (const candidate of corpus.nodes) {
    if (!isDescendantDataLink(corpus, node, candidate)) continue;
    const dataLink = dataLinkMetadataFor(candidate);
    if (!dataLink) continue;
    out.push({
      key: candidate.key,
      id: candidate.id,
      title: candidate.title,
      kind: dataLink.kind,
      file: candidate.file,
      sourceRange: candidate.sourceRange,
      citation: citationFor(candidate),
      dataLink,
    });
  }
  return out.sort((a, b) => a.citation.localeCompare(b.citation) || a.title.localeCompare(b.title));
}

function toAgentNode(corpus: CompiledCorpus, node: CompiledCorpusNode, include: Set<AgentInclude>, score?: { score: number; matchedTerms: string[]; selectionReason?: string[] }): AgentNode {
  const source = { file: node.file, sourceRange: node.sourceRange, citation: citationFor(node) };
  const thread = agentThreadMetadataFor(corpus, node);
  const relatedThreads = relatedThreadsFor(corpus, node);
  const dataLink = dataLinkMetadataFor(node);
  const relatedDataLinks = relatedDataLinksFor(corpus, node);
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
    ...(score ? { score: score.score, matchedTerms: score.matchedTerms, selectionReason: score.selectionReason || [] } : {}),
    claimState: claimStateFor(node),
    ...(thread ? { thread } : {}),
    ...(relatedThreads.length ? { relatedThreads } : {}),
    ...(dataLink ? { dataLink } : {}),
    ...(relatedDataLinks.length ? { relatedDataLinks } : {}),
    ...(include.has("sources") ? { sources: [source] } : {}),
    ...(include.has("backlinks") ? { backlinks: inferredBacklinksFor(corpus, node) } : {}),
    ...(include.has("neighbors") ? { neighbors: neighborsFor(corpus, node) } : {}),
  };
}


function normalizeLabel(raw: string): string {
  return String(raw || "").trim().toLowerCase().replace(/\s+/g, " ");
}

function profilesForSelection(corpus: CompiledCorpus, selectedNodes: CompiledCorpusNode[], query = ""): CompiledCorpusEntityProfile[] {
  const keys = new Set(selectedNodes.map((node) => node.key));
  const queryLabel = normalizeLabel(query);
  const out = new Map<string, CompiledCorpusEntityProfile>();
  for (const profile of corpus.entityProfiles || []) {
    const labels = [profile.canonicalName, ...profile.aliases].map(normalizeLabel);
    if (profile.nodeKeys.some((key) => keys.has(key)) || (queryLabel && labels.includes(queryLabel))) out.set(profile.entityId, profile);
  }
  return Array.from(out.values()).sort((a, b) => a.canonicalName.localeCompare(b.canonicalName) || a.entityId.localeCompare(b.entityId));
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
  const relatedThreads = Array.from(
    results
      .flatMap((node) => node.relatedThreads || [])
      .reduce((byKey, thread) => byKey.set(thread.key, thread), new Map<string, AgentRelatedThread>())
      .values(),
  ).sort((a, b) => a.title.localeCompare(b.title) || a.citation.localeCompare(b.citation));
  const directDataLinks: AgentRelatedDataLink[] = results
    .filter((node): node is AgentNode & { dataLink: AgentDataLinkMetadata } => Boolean(node.dataLink))
    .map((node) => ({
      key: node.key,
      id: node.id,
      title: node.title,
      kind: node.dataLink.kind,
      file: node.file,
      sourceRange: node.sourceRange,
      citation: node.citation,
      dataLink: node.dataLink,
    }));
  const relatedDataLinks = Array.from(
    [...directDataLinks, ...results.flatMap((node) => node.relatedDataLinks || [])]
      .reduce((byKey, dataLink) => byKey.set(dataLink.key, dataLink), new Map<string, AgentRelatedDataLink>())
      .values(),
  ).sort((a, b) => a.citation.localeCompare(b.citation) || a.title.localeCompare(b.title));
  const profiles = payload.entityProfiles || [];
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
    if (node.selectionReason?.length) lines.push(`- Selected because: ${node.selectionReason.join("; ")}`);
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
  for (const profile of profiles) {
    lines.push(`- Profile: ${profile.canonicalName} (${profile.type})${profile.aliases.length ? `; aliases: ${profile.aliases.join(", ")}` : ""}`);
    if (profile.reviewNeeded.length) lines.push(`  - Review needed: ${profile.reviewNeeded.map((item) => item.message).join("; ")}`);
  }
  for (const value of backlinkValues.slice(0, 12)) lines.push(`- Backlink: ${value}`);
  lines.push("");
  lines.push(`${h2} Related agent threads`);
  if (relatedThreads.length === 0) lines.push("- None found");
  for (const thread of relatedThreads) {
    const details = [
      thread.id ? `id: ${thread.id}` : "",
      thread.agent ? `agent: ${thread.agent}` : "",
      thread.session ? `session: ${thread.session}` : "",
      thread.status ? `status: ${thread.status}` : "",
    ].filter(Boolean);
    const attachments = uniqueSorted(thread.matchingAttachments.map((attachment) => attachment.ref));
    lines.push(`- ${thread.title} (${thread.citation})${details.length ? `; ${details.join("; ")}` : ""}`);
    if (attachments.length) lines.push(`  - Matching attachments: ${attachments.join(", ")}`);
  }
  lines.push("");
  lines.push(`${h2} Related data links`);
  if (relatedDataLinks.length === 0) lines.push("- None found");
  for (const item of relatedDataLinks) {
    const details = [
      `kind: ${item.kind}`,
      item.id ? `id: ${item.id}` : "",
      item.dataLink.system ? `system: ${item.dataLink.system}` : "",
      item.dataLink.engine ? `engine: ${item.dataLink.engine}` : "",
      item.dataLink.queryId ? `query: ${item.dataLink.queryId}` : "",
      item.dataLink.artifact ? `artifact: ${item.dataLink.artifact}` : "",
      item.dataLink.result ? `result: ${item.dataLink.result}` : "",
      item.dataLink.rowCount !== undefined ? `rows: ${item.dataLink.rowCount}` : "",
      item.dataLink.lastRun ? `last run: ${item.dataLink.lastRun}` : "",
      item.dataLink.freshness ? `freshness: ${item.dataLink.freshness}` : "",
    ].filter(Boolean);
    lines.push(`- ${item.title} (${item.citation})${details.length ? `; ${details.join("; ")}` : ""}`);
  }
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
  let selected: Array<{ node: CompiledCorpusNode; score?: { score: number; matchedTerms: string[]; selectionReason?: string[] } }> = [];

  if (opts.action === "fetch") {
    const node = findNodeById(corpus, opts.id || "");
    if (node) selected = [{ node }];
    else errors.push(`No node found for id/key: ${opts.id || ""}`);
  } else {
    const terms = termsFor(opts.query || "");
    if (terms.length === 0) errors.push("Query must include at least one searchable term.");
    selected = corpus.nodes
      .filter((node) => nodeMatchesFilters(node, opts))
      .map((node) => ({ node, score: scoreNode(corpus, node, terms, opts) }))
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
    ranking: { recencyWeight: Number.isFinite(opts.recencyWeight) ? opts.recencyWeight! : 1, salienceWeight: Number.isFinite(opts.salienceWeight) ? opts.salienceWeight! : 1 },
    corpus: { schemaVersion: corpus.schemaVersion, rootDir: corpus.rootDir, generatedAt: corpus.artifact.generatedAt, stats: corpus.stats },
    results,
    entityProfiles: profilesForSelection(corpus, selected.map((item) => item.node), opts.query || opts.id || ""),
    errors,
  };

  if (opts.action === "context" || opts.action === "bundle") {
    const citations: AgentSource[] = [];
    let text = "";
    let truncated = false;
    for (const result of results) {
      const reasons = result.selectionReason?.length ? `Selected because: ${result.selectionReason.join("; ")}` : "";
      const chunk = [`## ${result.title}`, `Source: ${result.citation}`, `Review: ${result.claimState.reviewStatus}; freshness: ${result.claimState.freshness}`, reasons, result.snippet].filter(Boolean).join("\n") + "\n\n";
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
