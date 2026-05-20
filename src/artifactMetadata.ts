import crypto from "node:crypto";
import type { ArtifactRole } from "./artifactLint.js";

export const ORG2_ARTIFACT_METADATA_SCHEMA_VERSION = "org2-artifact-metadata/v1" as const;

export const ORG2_ARTIFACT_PROPERTY_NAMES = {
  id: "ID",
  schemaVersion: "ORG2_ARTIFACT_SCHEMA",
  role: "ORG2_ARTIFACT_ROLE",
  provenance: "ORG2_PROVENANCE",
  generator: "ORG2_GENERATOR",
  generatedAt: "ORG2_GENERATED_AT",
  sourceHashes: "ORG2_SOURCE_HASHES",
  reviewStatus: "ORG2_REVIEW_STATUS",
  aiJobId: "ORG2_AI_JOB_ID",
  aiTask: "ORG2_AI_TASK",
  promptTemplate: "ORG2_PROMPT_TEMPLATE",
  adapter: "ORG2_AI_ADAPTER",
  model: "ORG2_AI_MODEL",
} as const;

export const ORG2_ARTIFACT_REVIEW_STATUS_VALUES = ["generated", "review-required", "reviewed", "promoted"] as const;

export type Org2ArtifactReviewStatus = (typeof ORG2_ARTIFACT_REVIEW_STATUS_VALUES)[number];

export type Org2ArtifactProvenanceKind = "id" | "file" | "query" | "run" | "url" | "note" | "artifact";

export interface Org2ArtifactSourceHash {
  kind: Org2ArtifactProvenanceKind;
  value: string;
  sha256: string;
}

export interface Org2GeneratedArtifactMetadata {
  schemaVersion: typeof ORG2_ARTIFACT_METADATA_SCHEMA_VERSION;
  role: Extract<ArtifactRole, "compiled" | "view" | "report">;
  generator: string;
  generatedAt: string;
  provenance: string[];
  sourceHashes: Org2ArtifactSourceHash[];
  reviewStatus: Org2ArtifactReviewStatus;
  aiJobId?: string;
  aiTask?: string;
  promptTemplate?: string;
  adapter?: string;
  model?: string;
}

export interface BuildGeneratedArtifactMetadataOptions {
  role: Org2GeneratedArtifactMetadata["role"];
  generator: string;
  generatedAt?: string;
  provenance?: string[];
  sourceHashes?: Org2ArtifactSourceHash[];
  reviewStatus?: Org2ArtifactReviewStatus;
  aiJobId?: string;
  aiTask?: string;
  promptTemplate?: string;
  adapter?: string;
  model?: string;
}

function cleanOptional(raw: string | undefined): string | undefined {
  const value = String(raw || "").trim();
  return value || undefined;
}

export function sha256Hex(raw: string): string {
  return crypto.createHash("sha256").update(raw).digest("hex");
}

export function buildGeneratedArtifactMetadata(opts: BuildGeneratedArtifactMetadataOptions): Org2GeneratedArtifactMetadata {
  const generatedAt = String(opts.generatedAt || new Date().toISOString()).trim();
  const provenance = Array.from(new Set((opts.provenance || []).map((entry) => String(entry || "").trim()).filter(Boolean)));
  const sourceHashes = [...(opts.sourceHashes || [])]
    .map((entry) => ({
      kind: entry.kind,
      value: String(entry.value || "").trim(),
      sha256: String(entry.sha256 || "").trim().toLowerCase(),
    }))
    .filter((entry) => entry.value && entry.sha256);

  const metadata: Org2GeneratedArtifactMetadata = {
    schemaVersion: ORG2_ARTIFACT_METADATA_SCHEMA_VERSION,
    role: opts.role,
    generator: String(opts.generator || "").trim(),
    generatedAt,
    provenance,
    sourceHashes,
    reviewStatus: opts.reviewStatus || "generated",
  };

  const aiJobId = cleanOptional(opts.aiJobId);
  const aiTask = cleanOptional(opts.aiTask);
  const promptTemplate = cleanOptional(opts.promptTemplate);
  const adapter = cleanOptional(opts.adapter);
  const model = cleanOptional(opts.model);
  if (aiJobId) metadata.aiJobId = aiJobId;
  if (aiTask) metadata.aiTask = aiTask;
  if (promptTemplate) metadata.promptTemplate = promptTemplate;
  if (adapter) metadata.adapter = adapter;
  if (model) metadata.model = model;

  return metadata;
}

export function formatSourceHashEntry(entry: Org2ArtifactSourceHash): string {
  return `${entry.kind}:${String(entry.value || "").trim()}=sha256:${String(entry.sha256 || "").trim().toLowerCase()}`;
}

export function formatOrg2ArtifactPropertyDrawer(metadata: Org2GeneratedArtifactMetadata, id?: string): string {
  const lines = [":PROPERTIES:"];
  const trimmedId = String(id || "").trim();
  if (trimmedId) lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.id}: ${trimmedId}`);
  lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.schemaVersion}: ${metadata.schemaVersion}`);
  lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.role}: ${metadata.role}`);
  lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.provenance}: ${metadata.provenance.join(", ")}`);
  lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.generator}: ${metadata.generator}`);
  lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.generatedAt}: ${metadata.generatedAt}`);
  if (metadata.aiJobId) lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.aiJobId}: ${metadata.aiJobId}`);
  if (metadata.aiTask) lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.aiTask}: ${metadata.aiTask}`);
  if (metadata.promptTemplate) lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.promptTemplate}: ${metadata.promptTemplate}`);
  if (metadata.adapter) lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.adapter}: ${metadata.adapter}`);
  if (metadata.model) lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.model}: ${metadata.model}`);
  if (metadata.sourceHashes.length > 0) {
    lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.sourceHashes}: ${metadata.sourceHashes.map(formatSourceHashEntry).join(", ")}`);
  }
  lines.push(`:${ORG2_ARTIFACT_PROPERTY_NAMES.reviewStatus}: ${metadata.reviewStatus}`);
  lines.push(":END:");
  return `${lines.join("\n")}\n`;
}
