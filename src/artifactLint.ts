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

function parseTopFilePropertyDrawer(lines: string[]): { startLine: number; properties: Map<string, string> } | null {
  let idx = 0;
  while (idx < lines.length) {
    const trimmed = (lines[idx] || "").trim();
    if (!trimmed || trimmed.startsWith("#")) {
      idx += 1;
      continue;
    }
    break;
  }

  if ((lines[idx] || "").trim() !== ":PROPERTIES:") return null;

  const props = new Map<string, string>();
  for (let i = idx + 1; i < lines.length; i += 1) {
    const trimmed = (lines[i] || "").trim();
    if (trimmed === ":END:") {
      return {
        startLine: idx + 1,
        properties: props,
      };
    }

    const parsed = parsePropertyLine(trimmed);
    if (parsed) props.set(parsed.key, normalizePropertyValue(parsed.value));
  }

  return null;
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

function evaluateArtifactProperties(
  props: Map<string, string>,
  filePath: string,
  line: number,
  issues: ArtifactLintIssue[],
): void {
  const roleRaw = normalizePropertyValue(props.get("ORG2_ARTIFACT_ROLE") || "");
  const provenanceRaw = normalizePropertyValue(props.get("ORG2_PROVENANCE") || "");
  const idRaw = normalizePropertyValue(props.get("ID") || "");

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

  const topFileDrawer = parseTopFilePropertyDrawer(lines);
  if (topFileDrawer) {
    collectArtifactProvenanceRefsFromProperties(topFileDrawer.properties, filePath, topFileDrawer.startLine, refs);
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

  const topFileDrawer = parseTopFilePropertyDrawer(lines);
  if (topFileDrawer) {
    collectArtifactIdsFromProperties(topFileDrawer.properties, filePath, topFileDrawer.startLine, refs);
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

  const topFileDrawer = parseTopFilePropertyDrawer(lines);
  if (topFileDrawer) {
    evaluateArtifactProperties(topFileDrawer.properties, filePath, topFileDrawer.startLine, issues);
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
