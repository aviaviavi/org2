import fs from "node:fs";
import path from "node:path";
import { buildGeneratedArtifactMetadata, formatOrg2ArtifactPropertyDrawer, sha256Hex } from "./artifactMetadata.js";

export const ORG2_INGESTION_SCHEMA_VERSION = "org2-ingestion/v1" as const;

export type Org2IngestionSourceType = "slack" | "gmail" | "meeting" | "linear" | "github" | "note" | "demo" | "file" | "stdin" | "json" | (string & {});
export type Org2IngestionSensitivity = "public" | "internal" | "private" | "restricted";
export type Org2IngestionReviewStatus = "pending" | "in-review" | "accepted" | "rejected" | "promoted";

export interface Org2RawCaptureInput {
  sourceType: Org2IngestionSourceType;
  externalId: string;
  authors: string[];
  capturedAt?: string;
  occurredAt?: string;
  visibility?: string;
  sensitivity?: Org2IngestionSensitivity;
  sourceRef?: string;
  content: string;
}

export interface Org2RawCapture extends Required<Org2RawCaptureInput> {
  schemaVersion: typeof ORG2_INGESTION_SCHEMA_VERSION;
  contentHash: string;
  rawRef: string;
}

export interface Org2ReviewArtifact {
  schemaVersion: typeof ORG2_INGESTION_SCHEMA_VERSION;
  artifactRef: string;
  rawRef: string;
  sourceType: Org2IngestionSourceType;
  externalId: string;
  contentHash: string;
  reviewStatus: Org2IngestionReviewStatus;
  summary: string[];
  decisions: string[];
  todoCandidates: string[];
  entityCandidates: string[];
  claims: Array<{ text: string; citations: string[] }>;
  sourceCitations: string[];
}

export interface IngestDemoOptions {
  input: Org2RawCaptureInput;
  rawDir: string;
  reviewDir: string;
  now?: string;
  dryRun?: boolean;
}

export interface IngestDemoResult {
  rawCapture: Org2RawCapture;
  reviewArtifact: Org2ReviewArtifact;
  rawPath: string;
  reviewPath: string;
  rawCreated: boolean;
  reviewCreated: boolean;
  dryRun: boolean;
}

function safeSlug(raw: string): string {
  return String(raw || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_.-]+/g, "-")
    .replace(/^-+|-+$/g, "") || "capture";
}

function stableJson(value: unknown): string {
  return JSON.stringify(value, null, 2) + "\n";
}

function meaningfulLines(content: string): string[] {
  return content
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

function extractPrefixed(lines: string[], prefixes: string[]): string[] {
  const lowerPrefixes = prefixes.map((prefix) => prefix.toLowerCase());
  return lines
    .filter((line) => lowerPrefixes.some((prefix) => line.toLowerCase().startsWith(prefix)))
    .map((line) => line.replace(/^[A-Za-z ]+:/, "").replace(/^[-*]\s*\[[ xX]\]\s*/, "").trim())
    .filter(Boolean);
}

export function buildRawCapture(input: Org2RawCaptureInput, now = new Date().toISOString()): Org2RawCapture {
  const content = String(input.content || "").replace(/\r\n/g, "\n");
  const contentHash = sha256Hex(content);
  const sourceType = input.sourceType || "demo";
  const externalId = String(input.externalId || "").trim();
  if (!externalId) throw new Error("raw capture externalId is required");
  if (!content.trim()) throw new Error("raw capture content is required");

  return {
    schemaVersion: ORG2_INGESTION_SCHEMA_VERSION,
    sourceType,
    externalId,
    authors: Array.from(new Set((input.authors || []).map((a) => String(a).trim()).filter(Boolean))),
    capturedAt: input.capturedAt || now,
    occurredAt: input.occurredAt || input.capturedAt || now,
    visibility: input.visibility || "unspecified",
    sensitivity: input.sensitivity || "private",
    sourceRef: input.sourceRef || `${sourceType}:${externalId}`,
    content,
    contentHash,
    rawRef: `${sourceType}:${externalId}@sha256:${contentHash}`,
  };
}

export function buildReviewArtifact(raw: Org2RawCapture): Org2ReviewArtifact {
  const lines = meaningfulLines(raw.content);
  const citations = [`${raw.rawRef}#content`];
  const decisions = extractPrefixed(lines, ["decision:", "decided:"]);
  const todoCandidates = extractPrefixed(lines, ["todo:", "action:", "action item:"]);
  const entityCandidates = Array.from(new Set(lines.join(" ").match(/\b[A-Z][A-Za-z0-9_-]{2,}\b/g) || [])).slice(0, 12);
  const summary = lines.slice(0, 3).map((line) => line.replace(/^[-*]\s*/, ""));
  const claimLines = lines.filter((line) => /\b(is|are|will|must|should|decided|decision)\b/i.test(line)).slice(0, 6);

  return {
    schemaVersion: ORG2_INGESTION_SCHEMA_VERSION,
    artifactRef: `review:${raw.rawRef}`,
    rawRef: raw.rawRef,
    sourceType: raw.sourceType,
    externalId: raw.externalId,
    contentHash: raw.contentHash,
    reviewStatus: "pending",
    summary: summary.length > 0 ? summary : ["No summary candidates extracted."],
    decisions,
    todoCandidates,
    entityCandidates,
    claims: claimLines.map((text) => ({ text, citations })),
    sourceCitations: citations,
  };
}

export function renderReviewArtifactOrg(raw: Org2RawCapture, artifact: Org2ReviewArtifact, generatedAt?: string): string {
  const metadata = buildGeneratedArtifactMetadata({
    role: "report",
    generator: "org2 ingest demo",
    generatedAt: generatedAt || raw.capturedAt,
    provenance: [raw.rawRef, raw.sourceRef],
    sourceHashes: [{ kind: "artifact", value: raw.rawRef, sha256: raw.contentHash }],
    reviewStatus: "review-required",
  });
  const drawer = formatOrg2ArtifactPropertyDrawer(metadata, safeSlug(`ingest-${raw.sourceType}-${raw.externalId}`));
  const bulletList = (items: string[]) => items.length > 0 ? items.map((item) => `- ${item}`).join("\n") : "- None extracted.";
  const claims = artifact.claims.length > 0
    ? artifact.claims.map((claim) => `- ${claim.text} [cite:${claim.citations.join(", ")}]`).join("\n")
    : "- None extracted.";

  return `#+TITLE: Ingestion review: ${raw.sourceType}/${raw.externalId}\n${drawer}* Source\n- Raw ref: =${raw.rawRef}=\n- Source ref: ${raw.sourceRef}\n- Authors: ${raw.authors.join(", ") || "unknown"}\n- Occurred: ${raw.occurredAt}\n- Visibility: ${raw.visibility}\n- Sensitivity: ${raw.sensitivity}\n\n* Review status\n- Status: ${artifact.reviewStatus}\n- [ ] Verify extracted facts against raw capture.\n- [ ] Promote only selected durable notes/TODOs.\n\n* Summary\n${bulletList(artifact.summary)}\n\n* Decisions\n${bulletList(artifact.decisions)}\n\n* TODO candidates\n${bulletList(artifact.todoCandidates)}\n\n* Entity candidates\n${bulletList(artifact.entityCandidates)}\n\n* Claims\n${claims}\n\n* Source citations\n${bulletList(artifact.sourceCitations)}\n`;
}

export function ingestDemoSource(options: IngestDemoOptions): IngestDemoResult {
  const rawCapture = buildRawCapture(options.input, options.now);
  const reviewArtifact = buildReviewArtifact(rawCapture);
  const basename = `${safeSlug(rawCapture.sourceType)}-${safeSlug(rawCapture.externalId)}-${rawCapture.contentHash.slice(0, 12)}`;
  const rawPath = path.join(options.rawDir, `${basename}.json`);
  const reviewPath = path.join(options.reviewDir, `${basename}.org`);
  const rawCreated = !fs.existsSync(rawPath);
  const reviewCreated = !fs.existsSync(reviewPath);

  if (!options.dryRun) {
    fs.mkdirSync(options.rawDir, { recursive: true });
    fs.mkdirSync(options.reviewDir, { recursive: true });
    fs.writeFileSync(rawPath, stableJson(rawCapture), "utf8");
    fs.writeFileSync(reviewPath, renderReviewArtifactOrg(rawCapture, reviewArtifact, options.now), "utf8");
  }

  return { rawCapture, reviewArtifact, rawPath, reviewPath, rawCreated, reviewCreated, dryRun: Boolean(options.dryRun) };
}
