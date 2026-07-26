import crypto from "node:crypto";

export const APPROVAL_FINGERPRINT_PREFIX = "sha256:" as const;
export const APPROVAL_MATERIAL_KINDS = [
  "message",
  "command",
  "artifact-release",
  "external-action",
] as const;

export type ApprovalMaterialKind = (typeof APPROVAL_MATERIAL_KINDS)[number];

export interface AgentRunApprovalAttachment {
  name: string;
  path?: string;
  sha256: string;
}

export interface AgentRunApprovalArtifactRef {
  id: string;
  sha256: string;
}

export interface AgentRunApprovalRuntimeTarget {
  system: string;
  kind: string;
  id: string;
}

export interface AgentRunApprovalMaterial {
  kind: ApprovalMaterialKind;
  target?: string;
  content?: string;
  command?: {
    text: string;
    argv?: string[];
    cwd?: string;
  };
  attachments?: AgentRunApprovalAttachment[];
  artifacts?: AgentRunApprovalArtifactRef[];
  runtimeTarget?: AgentRunApprovalRuntimeTarget;
}

export interface AgentRunApprovalEffectReceipt {
  fingerprint: string;
  performedAt: string;
  system?: string;
  externalId?: string;
}

export interface AgentRunApprovalEffectReservation {
  fingerprint: string;
  materialDigest: string;
  toolCallId: string;
  reservedAt: string;
}

export interface ApprovalFingerprintSource {
  title: string;
  action: string;
  riskClass: string;
  requirementId?: string;
  requestedRole?: string;
  requestedFrom?: string;
  note?: string;
  material?: AgentRunApprovalMaterial;
}

export interface ApprovalReviewabilitySource {
  riskClass: string;
  note?: string;
  material?: AgentRunApprovalMaterial;
}

export type PendingApprovalShortcutMutation = "close" | "handoff" | "property";

export function assertPendingApprovalShortcutAllowed(
  approval: { queueId: string; fingerprint: string } | undefined,
  mutation: PendingApprovalShortcutMutation,
): void {
  if (!approval) return;
  if (mutation === "close") {
    throw new Error(
      `approval headings cannot be closed from the agenda TUI; use org2 approval decide ${approval.queueId} --expected-fingerprint ${approval.fingerprint}`,
    );
  }
  if (mutation === "handoff") {
    throw new Error(
      `approval handoff requires the canonical decision path; use org2 approval decide ${approval.queueId} --expected-fingerprint ${approval.fingerprint}`,
    );
  }
  throw new Error(
    `pending approval properties cannot be changed from the agenda TUI; review ${approval.queueId} and use org2 approval decide`,
  );
}

export interface LegacyHeadlineApprovalFingerprintSource {
  title: string;
  body: string;
  properties: Record<string, string>;
  status: string;
  todo?: string | null;
  pairedAction?: {
    mode: "existing" | "create";
    title: string;
    todo?: string | null;
    properties: Record<string, string>;
    body: string;
  } | null;
}

function optionalText(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function presentText(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function compareUtf8(left: string, right: string): number {
  return Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8"));
}

function normalizedSha256(value: unknown): string {
  const raw = String(value || "").trim().toLowerCase();
  if (/^[a-f0-9]{64}$/.test(raw)) return `${APPROVAL_FINGERPRINT_PREFIX}${raw}`;
  return raw;
}

function sortedAttachments(items: AgentRunApprovalAttachment[] | undefined): AgentRunApprovalAttachment[] | undefined {
  if (!items) return undefined;
  return items.map((item) => ({
    name: String(item.name || ""),
    ...(optionalText(item.path) ? { path: item.path } : {}),
    sha256: normalizedSha256(item.sha256),
  })).sort((left, right) => (
    compareUtf8(left.name, right.name)
    || compareUtf8(String(left.path || ""), String(right.path || ""))
    || compareUtf8(left.sha256, right.sha256)
  ));
}

function sortedArtifacts(items: AgentRunApprovalArtifactRef[] | undefined): AgentRunApprovalArtifactRef[] | undefined {
  if (!items) return undefined;
  return items.map((item) => ({
    id: String(item.id || ""),
    sha256: normalizedSha256(item.sha256),
  })).sort((left, right) => compareUtf8(left.id, right.id) || compareUtf8(left.sha256, right.sha256));
}

export function normalizeApprovalMaterial(material: AgentRunApprovalMaterial | undefined): AgentRunApprovalMaterial | undefined {
  if (!material) return undefined;
  return {
    kind: material.kind,
    ...(presentText(material.target) !== undefined ? { target: material.target } : {}),
    ...(presentText(material.content) !== undefined ? { content: material.content } : {}),
    ...(material.command ? {
      command: {
        text: material.command.text,
        ...(material.command.argv ? { argv: material.command.argv.map((item) => String(item)) } : {}),
        ...(presentText(material.command.cwd) !== undefined ? { cwd: material.command.cwd } : {}),
      },
    } : {}),
    ...(material.attachments ? { attachments: sortedAttachments(material.attachments) } : {}),
    ...(material.artifacts ? { artifacts: sortedArtifacts(material.artifacts) } : {}),
    ...(material.runtimeTarget ? {
      runtimeTarget: {
        system: String(material.runtimeTarget.system || ""),
        kind: String(material.runtimeTarget.kind || ""),
        id: String(material.runtimeTarget.id || ""),
      },
    } : {}),
  };
}

function stable(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stable);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => compareUtf8(left, right))
      .map(([key, item]) => [key, stable(item)]),
  );
}

export function stableJson(value: unknown): string {
  return JSON.stringify(stable(value));
}

export function approvalFingerprintSource(source: ApprovalFingerprintSource): Record<string, unknown> {
  return {
    title: String(source.title || ""),
    action: String(source.action || ""),
    riskClass: String(source.riskClass || ""),
    ...(optionalText(source.requirementId) ? { requirementId: optionalText(source.requirementId) } : {}),
    requestedRole: optionalText(source.requestedRole) ?? null,
    requestedFrom: optionalText(source.requestedFrom) ?? null,
    note: optionalText(source.note) ?? null,
    material: normalizeApprovalMaterial(source.material) ?? null,
  };
}

export function computeApprovalFingerprint(source: ApprovalFingerprintSource): string {
  const encoded = stableJson(approvalFingerprintSource(source));
  return `${APPROVAL_FINGERPRINT_PREFIX}${crypto.createHash("sha256").update(encoded, "utf8").digest("hex")}`;
}

export function computeApprovalMaterialDigest(material: AgentRunApprovalMaterial): string {
  const issues = approvalMaterialIssues(material);
  if (issues.length > 0) throw new Error(`invalid approval material: ${issues.join("; ")}`);
  const normalized = normalizeApprovalMaterial(material);
  if (!normalized) throw new Error("approval material is required");
  return `${APPROVAL_FINGERPRINT_PREFIX}${crypto.createHash("sha256").update(stableJson(normalized), "utf8").digest("hex")}`;
}

export function computeLegacyHeadlineApprovalFingerprint(source: LegacyHeadlineApprovalFingerprintSource): string {
  return computeApprovalFingerprint({
    title: String(source.title || ""),
    action: stableJson({
      body: String(source.body || ""),
      properties: source.properties || {},
      status: String(source.status || ""),
      todo: source.todo ?? null,
      pairedAction: source.pairedAction ?? null,
    }),
    riskClass: "canonical-write",
  });
}

export function isApprovalFingerprint(value: unknown): value is string {
  return typeof value === "string" && /^sha256:[a-f0-9]{64}$/.test(value);
}

export function approvalMaterialIssues(material: AgentRunApprovalMaterial | undefined): string[] {
  if (!material) return [];
  const issues: string[] = [];
  const unknownKeys = (
    value: Record<string, unknown>,
    allowed: readonly string[],
    label: string,
  ): void => {
    for (const key of Object.keys(value)) {
      if (!allowed.includes(key)) issues.push(`${label}${key} is not supported`);
    }
  };

  if (!isPlainObject(material)) return ["must be an object"];
  const raw = material as unknown as Record<string, unknown>;
  unknownKeys(raw, ["kind", "target", "content", "command", "attachments", "artifacts", "runtimeTarget"], "");
  if (typeof raw.kind !== "string" || !APPROVAL_MATERIAL_KINDS.includes(raw.kind as ApprovalMaterialKind)) {
    issues.push(`kind must be one of: ${APPROVAL_MATERIAL_KINDS.join(", ")}`);
  }
  for (const key of ["target", "content"] as const) {
    if (raw[key] !== undefined && typeof raw[key] !== "string") issues.push(`${key} must be a string`);
  }

  if (raw.command !== undefined) {
    if (!isPlainObject(raw.command)) {
      issues.push("command must be an object");
    } else {
      unknownKeys(raw.command, ["text", "argv", "cwd"], "command.");
      if (typeof raw.command.text !== "string" || !raw.command.text.trim()) {
        issues.push("command.text must be a non-empty string");
      }
      if (raw.command.argv !== undefined) {
        if (!Array.isArray(raw.command.argv)) {
          issues.push("command.argv must be an array");
        } else {
          for (const [index, value] of raw.command.argv.entries()) {
            if (typeof value !== "string") issues.push(`command.argv[${index}] must be a string`);
          }
        }
      }
      if (raw.command.cwd !== undefined && typeof raw.command.cwd !== "string") {
        issues.push("command.cwd must be a string");
      }
    }
  }

  if (raw.attachments !== undefined && !Array.isArray(raw.attachments)) {
    issues.push("attachments must be an array");
  }
  for (const [index, attachment] of (Array.isArray(raw.attachments) ? raw.attachments : []).entries()) {
    if (!isPlainObject(attachment)) {
      issues.push(`attachments[${index}] must be an object`);
      continue;
    }
    unknownKeys(attachment, ["name", "path", "sha256"], `attachments[${index}].`);
    if (typeof attachment.name !== "string" || !attachment.name.trim()) {
      issues.push(`attachments[${index}].name must be a non-empty string`);
    }
    if (attachment.path !== undefined && typeof attachment.path !== "string") {
      issues.push(`attachments[${index}].path must be a string`);
    }
    if (typeof attachment.sha256 !== "string" || !isApprovalFingerprint(normalizedSha256(attachment.sha256))) {
      issues.push(`attachments[${index}].sha256 must be a SHA-256 digest`);
    }
  }

  if (raw.artifacts !== undefined && !Array.isArray(raw.artifacts)) {
    issues.push("artifacts must be an array");
  }
  for (const [index, artifact] of (Array.isArray(raw.artifacts) ? raw.artifacts : []).entries()) {
    if (!isPlainObject(artifact)) {
      issues.push(`artifacts[${index}] must be an object`);
      continue;
    }
    unknownKeys(artifact, ["id", "sha256"], `artifacts[${index}].`);
    if (typeof artifact.id !== "string" || !artifact.id.trim()) {
      issues.push(`artifacts[${index}].id must be a non-empty string`);
    }
    if (typeof artifact.sha256 !== "string" || !isApprovalFingerprint(normalizedSha256(artifact.sha256))) {
      issues.push(`artifacts[${index}].sha256 must be a SHA-256 digest`);
    }
  }

  if (raw.runtimeTarget !== undefined) {
    if (!isPlainObject(raw.runtimeTarget)) {
      issues.push("runtimeTarget must be an object");
      return issues;
    }
    unknownKeys(raw.runtimeTarget, ["system", "kind", "id"], "runtimeTarget.");
    for (const key of ["system", "kind", "id"] as const) {
      if (typeof raw.runtimeTarget[key] !== "string" || !raw.runtimeTarget[key].trim()) {
        issues.push(`runtimeTarget.${key} must be a non-empty string`);
      }
    }
  }
  return issues;
}

export function hasExactApprovalMaterial(material: AgentRunApprovalMaterial | undefined): boolean {
  if (!material || approvalMaterialIssues(material).length > 0) return false;
  if (material.kind === "message") return Boolean(String(material.target || "").trim() && material.content !== undefined);
  if (material.kind === "command") return Boolean(String(material.command?.text || "").trim());
  if (material.kind === "artifact-release") return Boolean(material.artifacts?.length || material.attachments?.length);
  return Boolean(
    String(material.content || "").trim()
    || String(material.command?.text || "").trim()
    || material.artifacts?.length
    || material.attachments?.length,
  );
}

export function approvalReviewability(source: ApprovalReviewabilitySource): { canApprove: boolean; reason?: string } {
  if (source.riskClass !== "external-action" && source.riskClass !== "high-impact") return { canApprove: true };
  if (hasExactApprovalMaterial(source.material)) return { canApprove: true };
  return {
    canApprove: false,
    reason: "Bound typed review material is required for an external-action or high-impact approval.",
  };
}
