import { ORG2_ARTIFACT_REVIEW_STATUS_VALUES, ORG2_CLAIM_STATE_VALUES } from "./artifactMetadata.js";
import { parseIsoCalendarDate } from "./calendarDate.js";

export type ArtifactRole = "raw" | "canonical" | "compiled" | "view" | "report";

export const ARTIFACT_ROLE_VALUES: ArtifactRole[] = ["raw", "canonical", "compiled", "view", "report"];

export interface ArtifactLintIssue {
  severity: "error" | "warning";
  rule: string;
  file: string;
  line: number; // 1-based
  message: string;
}

export interface ArtifactProvenanceRef {
  file: string;
  line: number; // 1-based
  kind: string;
  value: string;
}

export interface ArtifactIdRef {
  file: string;
  line: number; // 1-based
  id: string;
}

export interface ArtifactDuplicateIdIssue {
  id: string;
  refs: ArtifactIdRef[];
}

const PROVENANCE_ENTRY_KINDS = ["id", "file", "query", "run", "url", "note", "artifact"] as const;
const SHA256_SOURCE_HASH_RE = /^([a-z][a-z0-9_-]*):(\S.+)=sha256:([a-fA-F0-9]{64})$/;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const ISO_DATE_TIME_RE =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?(?:Z|[+-]\d{2}:\d{2})$/;
const CORPUS_FLOW_ROLE_BY_DIR = new Map<string, ArtifactRole>([
  ["raw", "raw"],
  ["notes", "canonical"],
  ["compiled", "compiled"],
  ["views", "view"],
  ["publish", "report"],
]);

function normalizePropertyValue(raw: string): string {
  return String(raw || "").trim();
}

function parsePropertyLine(rawLine: string): { key: string; value: string } | null {
  const match = /^:([A-Za-z0-9_\-]+):\s*(.*?)\s*$/.exec(String(rawLine || ""));
  if (!match) return null;
  return {
    key: String(match[1] || "").toUpperCase(),
    value: String(match[2] || ""),
  };
}

function collectFilePropertyDrawers(lines: string[]): Array<{ startLine: number; properties: Map<string, string> }> {
  const drawers: Array<{ startLine: number; properties: Map<string, string> }> = [];

  let idx = 0;
  while (idx < lines.length && !/^(\*+)\s+/.test(lines[idx] || "")) {
    const trimmed = (lines[idx] || "").trim();
    if (!trimmed || trimmed.startsWith("#")) {
      idx += 1;
      continue;
    }

    if (trimmed !== ":PROPERTIES:") {
      idx += 1;
      continue;
    }

    const props = new Map<string, string>();
    let endIndex = idx;
    for (let i = idx + 1; i < lines.length; i += 1) {
      endIndex = i;
      const innerTrimmed = (lines[i] || "").trim();
      if (innerTrimmed === ":END:") {
        drawers.push({
          startLine: idx + 1,
          properties: props,
        });
        break;
      }

      const parsed = parsePropertyLine(innerTrimmed);
      if (parsed) props.set(parsed.key, normalizePropertyValue(parsed.value));
    }

    idx = Math.max(endIndex + 1, idx + 1);
  }

  return drawers;
}

function collectHeadlinePropertyDrawers(lines: string[]): Array<{ startLine: number; properties: Map<string, string> }> {
  const drawers: Array<{ startLine: number; properties: Map<string, string> }> = [];

  let currentHeadlineLine = -1;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] || "";

    if (/^(\*+)\s+/.test(line)) {
      currentHeadlineLine = i;
      continue;
    }

    if (line.trim() !== ":PROPERTIES:") continue;

    const prev = (lines[i - 1] || "").trim();
    const prev2 = (lines[i - 2] || "").trim();
    const belongsToHeadline =
      currentHeadlineLine >= 0 && (i - 1 === currentHeadlineLine || (prev === "" && i - 2 === currentHeadlineLine && prev2 !== ""));

    if (!belongsToHeadline) continue;

    const properties = new Map<string, string>();
    let endIndex = i;
    for (let j = i + 1; j < lines.length; j += 1) {
      endIndex = j;
      const trimmed = (lines[j] || "").trim();
      if (trimmed === ":END:") break;
      const parsed = parsePropertyLine(trimmed);
      if (parsed) properties.set(parsed.key, normalizePropertyValue(parsed.value));
    }

    drawers.push({
      startLine: i + 1,
      properties,
    });

    i = endIndex;
  }

  return drawers;
}

function parseArtifactRole(raw: string): ArtifactRole | null {
  const normalized = String(raw || "").trim().toLowerCase();
  if (!normalized) return null;
  if (ARTIFACT_ROLE_VALUES.includes(normalized as ArtifactRole)) return normalized as ArtifactRole;
  return null;
}

function splitProvenance(raw: string): string[] {
  return String(raw || "")
    .split(/[,;]+/)
    .map((part) => part.trim())
    .filter(Boolean);
}

function parseProvenanceEntry(entry: string): { kind: string; value: string } | null {
  const match = /^([a-z][a-z0-9_-]*):(\S.*)$/.exec(String(entry || "").trim());
  if (!match) return null;
  return {
    kind: String(match[1] || "").toLowerCase(),
    value: String(match[2] || "").trim(),
  };
}

function isValidProvenanceEntry(entry: string): boolean {
  const parsed = parseProvenanceEntry(entry);
  if (!parsed) return false;
  return PROVENANCE_ENTRY_KINDS.includes(parsed.kind as (typeof PROVENANCE_ENTRY_KINDS)[number]);
}

function isValidClaimState(raw: string): boolean {
  const value = String(raw || "").trim().toLowerCase();
  return ORG2_CLAIM_STATE_VALUES.includes(value as (typeof ORG2_CLAIM_STATE_VALUES)[number]);
}

function isValidGeneratedAt(raw: string): boolean {
  const value = String(raw || "").trim();
  if (!value) return false;
  if (!ISO_DATE_RE.test(value) && !ISO_DATE_TIME_RE.test(value)) return false;
  return parseIsoCalendarDate(value.slice(0, 10)) !== null;
}

function splitSourceHashes(raw: string): string[] {
  return String(raw || "")
    .split(/[,;]+/)
    .map((part) => part.trim())
    .filter(Boolean);
}

function isValidSourceHashEntry(entry: string): boolean {
  const match = SHA256_SOURCE_HASH_RE.exec(String(entry || "").trim());
  if (!match) return false;
  const kind = String(match[1] || "").toLowerCase();
  return PROVENANCE_ENTRY_KINDS.includes(kind as (typeof PROVENANCE_ENTRY_KINDS)[number]);
}

function isValidReviewStatus(raw: string): boolean {
  const value = String(raw || "").trim().toLowerCase();
  return ORG2_ARTIFACT_REVIEW_STATUS_VALUES.includes(value as (typeof ORG2_ARTIFACT_REVIEW_STATUS_VALUES)[number]);
}

function inferExpectedArtifactRoleFromPath(filePath: string): { dir: string; role: ArtifactRole } | null {
  const normalized = String(filePath || "").replace(/\\/g, "/");
  const segments = normalized.split("/").map((segment) => segment.trim().toLowerCase()).filter(Boolean);

  for (let i = segments.length - 2; i >= 0; i -= 1) {
    const dir = segments[i] || "";
    const role = CORPUS_FLOW_ROLE_BY_DIR.get(dir);
    if (role) {
      return { dir, role };
    }
  }

  return null;
}

function evaluateArtifactProperties(
  props: Map<string, string>,
  filePath: string,
  line: number,
  issues: ArtifactLintIssue[],
): void {
  const roleRaw = normalizePropertyValue(props.get("ORG2_ARTIFACT_ROLE") || "");
  const provenanceRaw = normalizePropertyValue(props.get("ORG2_PROVENANCE") || "");
  const generatedAtRaw = normalizePropertyValue(props.get("ORG2_GENERATED_AT") || "");
  const generatorRaw = normalizePropertyValue(props.get("ORG2_GENERATOR") || "");
  const sourceHashesRaw = normalizePropertyValue(props.get("ORG2_SOURCE_HASHES") || "");
  const reviewStatusRaw = normalizePropertyValue(props.get("ORG2_REVIEW_STATUS") || "");
  const idRaw = normalizePropertyValue(props.get("ID") || "");
  const claimStateRaw = normalizePropertyValue(props.get("ORG2_CLAIM_STATE") || "");
  const observedAtRaw = normalizePropertyValue(props.get("ORG2_OBSERVED_AT") || "");
  const validAsOfRaw = normalizePropertyValue(props.get("ORG2_VALID_AS_OF") || "");
  const staleAfterRaw = normalizePropertyValue(props.get("ORG2_STALE_AFTER") || "");
  const expiresAtRaw = normalizePropertyValue(props.get("ORG2_EXPIRES_AT") || "");

  const role = parseArtifactRole(roleRaw);
  if (roleRaw && !role) {
    issues.push({
      severity: "error",
      rule: "artifact-role-invalid",
      file: filePath,
      line,
      message: `Invalid ORG2_ARTIFACT_ROLE '${roleRaw}'. Expected one of: ${ARTIFACT_ROLE_VALUES.join(", ")}`,
    });
  }

  const expectedRoleFromPath = inferExpectedArtifactRoleFromPath(filePath);
  if (expectedRoleFromPath && !role) {
    issues.push({
      severity: "warning",
      rule: "artifact-role-path-missing",
      file: filePath,
      line,
      message: `Files under '${expectedRoleFromPath.dir}/' should set ORG2_ARTIFACT_ROLE '${expectedRoleFromPath.role}' to match the raw -> notes -> compiled -> views -> publish corpus flow.`,
    });
  }

  if (expectedRoleFromPath && role && role !== expectedRoleFromPath.role) {
    issues.push({
      severity: "warning",
      rule: "artifact-role-path-mismatch",
      file: filePath,
      line,
      message: `Files under '${expectedRoleFromPath.dir}/' should use ORG2_ARTIFACT_ROLE '${expectedRoleFromPath.role}', but found '${role}'.`,
    });
  }

  const provenanceEntries = splitProvenance(provenanceRaw);
  if (provenanceRaw && provenanceEntries.length === 0) {
    issues.push({
      severity: "warning",
      rule: "artifact-provenance-empty",
      file: filePath,
      line,
      message: "ORG2_PROVENANCE is set but empty after normalization.",
    });
  }

  for (const entry of provenanceEntries) {
    if (!isValidProvenanceEntry(entry)) {
      issues.push({
        severity: "error",
        rule: "artifact-provenance-entry-invalid",
        file: filePath,
        line,
        message: `Invalid ORG2_PROVENANCE entry '${entry}'. Expected '<kind>:<value>' where kind is one of: ${PROVENANCE_ENTRY_KINDS.join(", ")}`,
      });
    }
  }

  if (role && ["compiled", "view", "report"].includes(role) && provenanceEntries.length === 0) {
    issues.push({
      severity: "error",
      rule: "artifact-provenance-missing",
      file: filePath,
      line,
      message: `Artifacts with role '${role}' must set ORG2_PROVENANCE.`,
    });
  }

  if (generatedAtRaw && !isValidGeneratedAt(generatedAtRaw)) {
    issues.push({
      severity: "error",
      rule: "artifact-generated-at-invalid",
      file: filePath,
      line,
      message: `Invalid ORG2_GENERATED_AT '${generatedAtRaw}'. Expected ISO date (YYYY-MM-DD) or ISO timestamp (YYYY-MM-DDTHH:MM[:SS][.sss]Z|±HH:MM).`,
    });
  }

  const sourceHashEntries = splitSourceHashes(sourceHashesRaw);
  if (sourceHashesRaw && sourceHashEntries.length === 0) {
    issues.push({
      severity: "warning",
      rule: "artifact-source-hashes-empty",
      file: filePath,
      line,
      message: "ORG2_SOURCE_HASHES is set but empty after normalization.",
    });
  }

  for (const entry of sourceHashEntries) {
    if (!isValidSourceHashEntry(entry)) {
      issues.push({
        severity: "error",
        rule: "artifact-source-hash-entry-invalid",
        file: filePath,
        line,
        message: `Invalid ORG2_SOURCE_HASHES entry '${entry}'. Expected '<kind>:<value>=sha256:<64 hex chars>' where kind is one of: ${PROVENANCE_ENTRY_KINDS.join(", ")}`,
      });
    }
  }

  if (reviewStatusRaw && !isValidReviewStatus(reviewStatusRaw)) {
    issues.push({
      severity: "error",
      rule: "artifact-review-status-invalid",
      file: filePath,
      line,
      message: `Invalid ORG2_REVIEW_STATUS '${reviewStatusRaw}'. Expected one of: ${ORG2_ARTIFACT_REVIEW_STATUS_VALUES.join(", ")}`,
    });
  }

  if (claimStateRaw && !isValidClaimState(claimStateRaw)) {
    issues.push({
      severity: "error",
      rule: "artifact-claim-state-invalid",
      file: filePath,
      line,
      message: `Invalid ORG2_CLAIM_STATE '${claimStateRaw}'. Expected one of: ${ORG2_CLAIM_STATE_VALUES.join(", ")}`,
    });
  }

  for (const [field, value] of Object.entries({ ORG2_OBSERVED_AT: observedAtRaw, ORG2_VALID_AS_OF: validAsOfRaw, ORG2_STALE_AFTER: staleAfterRaw, ORG2_EXPIRES_AT: expiresAtRaw })) {
    if (value && !isValidGeneratedAt(value)) {
      issues.push({
        severity: "error",
        rule: "artifact-freshness-date-invalid",
        file: filePath,
        line,
        message: `Invalid ${field} '${value}'. Expected ISO date or timestamp.`,
      });
    }
  }

  if (
    role &&
    ["compiled", "view", "report"].includes(role) &&
    generatedAtRaw &&
    generatorRaw &&
    (!reviewStatusRaw || reviewStatusRaw === "generated" || reviewStatusRaw === "review-required")
  ) {
    issues.push({
      severity: "warning",
      rule: "artifact-generated-unreviewed",
      file: filePath,
      line,
      message: `Generated artifact has ORG2_REVIEW_STATUS '${reviewStatusRaw || "missing"}'; review it and set ORG2_REVIEW_STATUS to 'reviewed' before promotion, or 'promoted' after acceptance.`,
    });
  }

  if (role && ["compiled", "view", "report"].includes(role) && !generatedAtRaw) {
    issues.push({
      severity: "warning",
      rule: "artifact-generated-at-missing",
      file: filePath,
      line,
      message: `Artifacts with role '${role}' should set ORG2_GENERATED_AT to record when they were produced.`,
    });
  }

  if (role && ["compiled", "view", "report"].includes(role) && !generatorRaw) {
    issues.push({
      severity: "warning",
      rule: "artifact-generator-missing",
      file: filePath,
      line,
      message: `Artifacts with role '${role}' should set ORG2_GENERATOR to record what produced them.`,
    });
  }

  if (role && ["compiled", "view", "report"].includes(role) && !claimStateRaw) {
    issues.push({
      severity: "error",
      rule: "artifact-claim-state-missing",
      file: filePath,
      line,
      message: `Generated artifacts with role '${role}' must set ORG2_CLAIM_STATE to distinguish source-backed facts, inference, or reviewed notes.`,
    });
  }

  if (role && ["compiled", "view", "report"].includes(role) && !observedAtRaw && !validAsOfRaw) {
    issues.push({
      severity: "error",
      rule: "artifact-freshness-missing",
      file: filePath,
      line,
      message: `Generated artifacts with role '${role}' must set ORG2_OBSERVED_AT or ORG2_VALID_AS_OF for freshness scoring.`,
    });
  }

  if (role && ["raw", "canonical"].includes(role) && generatedAtRaw) {
    issues.push({
      severity: "warning",
      rule: "artifact-generated-at-unexpected",
      file: filePath,
      line,
      message: `Artifacts with role '${role}' should not set ORG2_GENERATED_AT; generated timestamps belong on compiled/view/report outputs.`,
    });
  }

  if (role && ["raw", "canonical"].includes(role) && generatorRaw) {
    issues.push({
      severity: "warning",
      rule: "artifact-generator-unexpected",
      file: filePath,
      line,
      message: `Artifacts with role '${role}' should not set ORG2_GENERATOR; generator metadata belongs on compiled/view/report outputs.`,
    });
  }

  if (!role && provenanceEntries.length > 0) {
    issues.push({
      severity: "warning",
      rule: "artifact-role-missing",
      file: filePath,
      line,
      message: "ORG2_PROVENANCE is present but ORG2_ARTIFACT_ROLE is missing.",
    });
  }

  if (role && ["canonical", "compiled", "view", "report"].includes(role) && !idRaw) {
    issues.push({
      severity: "warning",
      rule: "artifact-id-missing",
      file: filePath,
      line,
      message: `Artifacts with role '${role}' should set ID for stable identity.`,
    });
  }
}

function collectArtifactProvenanceRefsFromProperties(
  props: Map<string, string>,
  filePath: string,
  line: number,
  refs: ArtifactProvenanceRef[],
): void {
  const provenanceRaw = normalizePropertyValue(props.get("ORG2_PROVENANCE") || "");
  const provenanceEntries = splitProvenance(provenanceRaw);

  for (const entry of provenanceEntries) {
    const parsed = parseProvenanceEntry(entry);
    if (!parsed) continue;
    refs.push({
      file: filePath,
      line,
      kind: parsed.kind,
      value: parsed.value,
    });
  }
}

function collectArtifactIdsFromProperties(
  props: Map<string, string>,
  filePath: string,
  line: number,
  refs: ArtifactIdRef[],
): void {
  const idRaw = normalizePropertyValue(props.get("ID") || "");
  if (!idRaw) return;

  refs.push({
    file: filePath,
    line,
    id: idRaw.toLowerCase(),
  });
}

export function collectArtifactProvenanceRefsInText(content: string, filePath: string): ArtifactProvenanceRef[] {
  const lines = content.replace(/\r\n/g, "\n").split("\n");
  const refs: ArtifactProvenanceRef[] = [];

  for (const fileDrawer of collectFilePropertyDrawers(lines)) {
    collectArtifactProvenanceRefsFromProperties(fileDrawer.properties, filePath, fileDrawer.startLine, refs);
  }

  const headlineDrawers = collectHeadlinePropertyDrawers(lines);
  for (const drawer of headlineDrawers) {
    collectArtifactProvenanceRefsFromProperties(drawer.properties, filePath, drawer.startLine, refs);
  }

  return refs;
}

export function collectArtifactIdsInText(content: string, filePath: string): ArtifactIdRef[] {
  const lines = content.replace(/\r\n/g, "\n").split("\n");
  const refs: ArtifactIdRef[] = [];

  for (const fileDrawer of collectFilePropertyDrawers(lines)) {
    collectArtifactIdsFromProperties(fileDrawer.properties, filePath, fileDrawer.startLine, refs);
  }

  const headlineDrawers = collectHeadlinePropertyDrawers(lines);
  for (const drawer of headlineDrawers) {
    collectArtifactIdsFromProperties(drawer.properties, filePath, drawer.startLine, refs);
  }

  return refs;
}

export function lintArtifactMetadataInText(content: string, filePath: string): ArtifactLintIssue[] {
  const lines = content.replace(/\r\n/g, "\n").split("\n");
  const issues: ArtifactLintIssue[] = [];

  const fileDrawers = collectFilePropertyDrawers(lines);
  const fileIdDrawers = fileDrawers.filter((drawer) => normalizePropertyValue(drawer.properties.get("ID") || ""));
  if (fileIdDrawers.length > 1) {
    issues.push({
      severity: "error",
      rule: "file-multiple-id-drawers",
      file: filePath,
      line: fileIdDrawers[1]!.startLine,
      message: `File has ${fileIdDrawers.length} file-level property drawers with ID values before the first headline; keep exactly one canonical file ID.`,
    });
  }
  for (const fileDrawer of fileDrawers) {
    evaluateArtifactProperties(fileDrawer.properties, filePath, fileDrawer.startLine, issues);
  }

  const headlineDrawers = collectHeadlinePropertyDrawers(lines);
  for (const drawer of headlineDrawers) {
    evaluateArtifactProperties(drawer.properties, filePath, drawer.startLine, issues);
  }

  return issues;
}

export function findDuplicateArtifactIds(refs: ArtifactIdRef[]): ArtifactDuplicateIdIssue[] {
  const refsById = new Map<string, ArtifactIdRef[]>();

  for (const ref of refs) {
    const normalizedId = String(ref.id || "").trim().toLowerCase();
    if (!normalizedId) continue;
    const existing = refsById.get(normalizedId) || [];
    existing.push(ref);
    refsById.set(normalizedId, existing);
  }

  return Array.from(refsById.entries())
    .filter(([, idRefs]) => idRefs.length > 1)
    .map(([id, idRefs]) => ({
      id,
      refs: [...idRefs].sort((a, b) => {
        const fileCmp = a.file.localeCompare(b.file);
        if (fileCmp !== 0) return fileCmp;
        return a.line - b.line;
      }),
    }))
    .sort((a, b) => a.id.localeCompare(b.id));
}
