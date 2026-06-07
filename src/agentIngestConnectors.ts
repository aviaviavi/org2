import { buildGeneratedArtifactMetadata, formatOrg2ArtifactPropertyDrawer, sha256Hex } from "./artifactMetadata.js";
import type { Org2RawCaptureInput } from "./ingestionPipeline.js";

export type AgentIngestSourceKind = "slack" | "gmail" | "email" | "message" | "calendar" | "meeting" | "browser" | (string & {});

export type AgentIngestAuthMode = "external" | "none";
export type AgentIngestPrivacyPolicy = "review-required" | "skip-private" | "redact-private";

export interface AgentIngestConnectorManifest {
  schemaVersion: "org2-connector/v1";
  id: string;
  sourceType: AgentIngestSourceKind;
  displayName: string;
  auth: {
    mode: AgentIngestAuthMode;
    note: string;
  };
  capabilities: {
    incrementalSync: boolean;
    dryRun: boolean;
    stableSourceIds: boolean;
    contentHashDedupe: boolean;
  };
  privacy: {
    defaultPolicy: AgentIngestPrivacyPolicy;
    sensitivityField?: string;
  };
}

export interface AgentIngestConnectorMetadata {
  kind: AgentIngestSourceKind;
  workspace?: string;
  channel?: string;
  thread?: string;
  mailbox?: string;
  label?: string;
  labels?: string[];
  messageId?: string;
  threadId?: string;
  subject?: string;
  unread?: boolean;
  starred?: boolean;
  url?: string;
  author?: string;
  recipients?: string[];
  timestamp: string;
  sensitivity?: "normal" | "private" | "sensitive";
}

export interface AgentIngestRecord {
  id: string;
  title: string;
  text: string;
  source: AgentIngestConnectorMetadata;
  rawPayload?: unknown;
  cursor?: string;
}

export interface AgentIngestFilterOptions {
  since?: string;
  until?: string;
  allowlist?: string[];
  labels?: string[];
  senders?: string[];
  domains?: string[];
  unread?: boolean;
  starred?: boolean;
  limit?: number;
  cursor?: string;
  dryRun?: boolean;
  privacyPolicy?: AgentIngestPrivacyPolicy;
  seenSourceIds?: string[];
  seenContentHashes?: string[];
}

export interface AgentIngestPreview {
  dryRun: boolean;
  cursor?: string;
  records: AgentIngestRecord[];
  skipped: Array<{ id: string; reason: "duplicate-source-id" | "duplicate-content-hash" | "privacy-policy" }>;
}

export interface AgentIngestConnector<TInput = unknown> {
  readonly kind: AgentIngestSourceKind;
  readonly manifest?: AgentIngestConnectorManifest;
  ingest(input: TInput, options?: AgentIngestFilterOptions): AgentIngestRecord[];
}

export function validateConnectorManifest(manifest: AgentIngestConnectorManifest): void {
  if (manifest.schemaVersion !== "org2-connector/v1") throw new Error("connector manifest schemaVersion must be org2-connector/v1");
  for (const [field, value] of Object.entries({ id: manifest.id, sourceType: manifest.sourceType, displayName: manifest.displayName })) {
    if (!String(value || "").trim()) throw new Error(`connector manifest ${field} is required`);
  }
  if (manifest.auth.mode !== "external" && manifest.auth.mode !== "none") throw new Error("connector manifest auth.mode must be external or none");
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function stringField(record: Record<string, unknown>, ...keys: string[]): string {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value.trim()) return value.trim();
    if (typeof value === "number") return String(value);
  }
  return "";
}

function stringArrayField(record: Record<string, unknown>, key: string): string[] {
  const value = record[key];
  if (!Array.isArray(value)) return [];
  return value.map((item) => String(item || "").trim()).filter(Boolean);
}

function normalizeInput(input: unknown): Record<string, unknown>[] {
  if (Array.isArray(input)) return input.map(asRecord);
  const record = asRecord(input);
  for (const key of ["messages", "threads", "items", "records"]) {
    const value = record[key];
    if (Array.isArray(value)) return value.map(asRecord);
  }
  return Object.keys(record).length > 0 ? [record] : [];
}

function timestampMs(value: string): number {
  const trimmed = String(value || "").trim();
  if (!trimmed) return Number.NaN;
  if (/^\d+(\.\d+)?$/.test(trimmed)) {
    const numeric = Number(trimmed);
    return numeric > 10_000_000_000 ? numeric : numeric * 1000;
  }
  return Date.parse(trimmed);
}

function inWindow(timestamp: string, options: AgentIngestFilterOptions): boolean {
  const current = timestampMs(timestamp);
  if (!Number.isFinite(current)) return false;
  const since = options.since ? timestampMs(options.since) : Number.NaN;
  const until = options.until ? timestampMs(options.until) : Number.NaN;
  if (Number.isFinite(since) && current < since) return false;
  if (Number.isFinite(until) && current > until) return false;
  return true;
}

function allowed(values: string[], options: AgentIngestFilterOptions): boolean {
  const allowlist = (options.allowlist || []).map((entry) => entry.toLowerCase());
  if (allowlist.length === 0) return true;
  return values.some((value) => allowlist.includes(value.toLowerCase()));
}

function emailAddressDomain(value: string): string {
  const match = String(value || "").toLowerCase().match(/@([^>\s]+)>?$/);
  return match?.[1] || "";
}

function matchesAny(values: string[], allowlist?: string[]): boolean {
  const allowedValues = (allowlist || []).map((entry) => entry.toLowerCase()).filter(Boolean);
  if (allowedValues.length === 0) return true;
  const normalized = values.map((value) => value.toLowerCase());
  return normalized.some((value) => allowedValues.includes(value));
}

function emailAllowed(record: AgentIngestRecord, options: AgentIngestFilterOptions): boolean {
  if (!matchesAny(record.source.labels || [record.source.label || ""], options.labels)) return false;
  if (!matchesAny([record.source.author || ""], options.senders)) return false;
  if (!matchesAny([emailAddressDomain(record.source.author || ""), ...(record.source.recipients || []).map(emailAddressDomain)], options.domains)) return false;
  if (typeof options.unread === "boolean" && record.source.unread !== options.unread) return false;
  if (typeof options.starred === "boolean" && record.source.starred !== options.starred) return false;
  return true;
}

function applyBoundedFilters(records: AgentIngestRecord[], options: AgentIngestFilterOptions = {}): AgentIngestRecord[] {
  const filtered = records.filter((record) => inWindow(record.source.timestamp, options)).filter((record) => {
    if (record.source.kind === "slack") return allowed([record.source.channel || "", record.source.thread || ""], options);
    if (record.source.kind === "gmail" || record.source.kind === "email") return allowed([record.source.mailbox || "", record.source.label || "", ...(record.source.labels || []), record.source.author || "", ...(record.source.recipients || [])], options) && emailAllowed(record, options);
    return allowed([record.source.mailbox || "", record.source.label || "", ...(record.source.recipients || [])], options);
  });
  const limit = Math.max(0, Math.trunc(Number(options.limit || filtered.length)));
  return filtered.slice(0, limit);
}


export function previewConnectorIngest(connector: AgentIngestConnector, input: unknown, options: AgentIngestFilterOptions = {}): AgentIngestPreview {
  if (connector.manifest) validateConnectorManifest(connector.manifest);
  const seenIds = new Set(options.seenSourceIds || []);
  const seenHashes = new Set(options.seenContentHashes || []);
  const skipped: AgentIngestPreview["skipped"] = [];
  const records: AgentIngestRecord[] = [];
  for (const record of connector.ingest(input, options)) {
    const hash = sha256Hex(record.text);
    if ((options.privacyPolicy || connector.manifest?.privacy.defaultPolicy) === "skip-private" && (record.source.sensitivity === "private" || record.source.sensitivity === "sensitive")) {
      skipped.push({ id: record.id, reason: "privacy-policy" });
      continue;
    }
    if (seenIds.has(`${record.source.kind}:${record.id}`)) {
      skipped.push({ id: record.id, reason: "duplicate-source-id" });
      continue;
    }
    if (seenHashes.has(hash)) {
      skipped.push({ id: record.id, reason: "duplicate-content-hash" });
      continue;
    }
    seenIds.add(`${record.source.kind}:${record.id}`);
    seenHashes.add(hash);
    records.push(record);
  }
  return { dryRun: options.dryRun !== false, cursor: records.at(-1)?.cursor || records.at(-1)?.source.timestamp || options.cursor, records, skipped };
}

export function connectorRecordsToRawCaptureInputs(records: AgentIngestRecord[], capturedAt?: string): Org2RawCaptureInput[] {
  return records.map((record) => ({
    sourceType: record.source.kind,
    externalId: record.id,
    authors: [record.source.author || "unknown"].filter(Boolean),
    capturedAt,
    occurredAt: record.source.timestamp,
    visibility: record.source.workspace || record.source.mailbox || "connector",
    sensitivity: record.source.sensitivity === "sensitive" ? "restricted" : record.source.sensitivity === "private" ? "private" : "internal",
    sourceRef: record.source.url || `${record.source.kind}:${record.id}`,
    content: record.text,
  }));
}

export class SlackFixtureConnector implements AgentIngestConnector {
  readonly kind = "slack" as const;
  readonly manifest: AgentIngestConnectorManifest = {
    schemaVersion: "org2-connector/v1",
    id: "fixture.slack",
    sourceType: this.kind,
    displayName: "Slack fixture connector",
    auth: { mode: "external", note: "Fixture input is exported outside org2 core; real Slack auth belongs in a connector/plugin." },
    capabilities: { incrementalSync: true, dryRun: true, stableSourceIds: true, contentHashDedupe: true },
    privacy: { defaultPolicy: "review-required", sensitivityField: "sensitivity" },
  };

  ingest(input: unknown, options: AgentIngestFilterOptions = {}): AgentIngestRecord[] {
    const records = normalizeInput(input).map((message, index) => {
      const channel = stringField(message, "channel", "channel_name");
      const thread = stringField(message, "thread_ts", "thread", "ts");
      const timestamp = stringField(message, "ts", "timestamp", "datetime", "thread_ts");
      const author = stringField(message, "user", "username", "author");
      const text = stringField(message, "text", "body");
      return {
        id: stringField(message, "id", "client_msg_id") || `slack-${channel || "unknown"}-${timestamp || index}`,
        title: `Slack ${channel || "message"}${thread ? ` thread ${thread}` : ""}`,
        text,
        cursor: timestamp,
        rawPayload: message,
        source: {
          kind: this.kind,
          workspace: stringField(message, "workspace", "team"),
          channel,
          thread,
          messageId: stringField(message, "id", "client_msg_id"),
          url: stringField(message, "permalink", "url"),
          author,
          timestamp,
          sensitivity: (stringField(message, "sensitivity") as AgentIngestConnectorMetadata["sensitivity"]) || undefined,
        },
      } satisfies AgentIngestRecord;
    }).filter((record) => record.text && record.source.timestamp);
    return applyBoundedFilters(records, options);
  }
}

export class GmailFixtureConnector implements AgentIngestConnector {
  readonly kind = "gmail" as const;
  readonly manifest: AgentIngestConnectorManifest = {
    schemaVersion: "org2-connector/v1",
    id: "fixture.gmail",
    sourceType: this.kind,
    displayName: "Gmail fixture connector",
    auth: { mode: "external", note: "Fixture input is exported outside org2 core; OAuth/API access belongs in an optional connector/plugin." },
    capabilities: { incrementalSync: true, dryRun: true, stableSourceIds: true, contentHashDedupe: true },
    privacy: { defaultPolicy: "review-required", sensitivityField: "sensitivity" },
  };

  ingest(input: unknown, options: AgentIngestFilterOptions = {}): AgentIngestRecord[] {
    const rows = normalizeInput(input).flatMap((item) => Array.isArray(item.messages) ? (item.messages as unknown[]).map(asRecord).map((message) => ({ ...message, threadId: stringField(item, "threadId", "id"), subject: stringField(message, "subject") || stringField(item, "subject") })) : [item]);
    const records = rows.map((message, index) => {
      const timestamp = stringField(message, "date", "timestamp", "internalDate");
      const subject = stringField(message, "subject") || "Gmail message";
      const from = stringField(message, "from", "author");
      const recipients = [...stringArrayField(message, "to"), ...stringArrayField(message, "cc")];
      const labels = stringArrayField(message, "labels");
      const threadId = stringField(message, "threadId", "thread_id");
      const id = stringField(message, "id", "messageId") || `gmail-${threadId || timestamp || index}`;
      return {
        id,
        title: threadId ? `${subject} (${threadId})` : subject,
        text: stringField(message, "text", "body", "snippet"),
        cursor: `${timestamp}#${id}`,
        source: {
          kind: this.kind,
          mailbox: stringField(message, "mailbox") || "gmail",
          label: labels[0],
          labels,
          messageId: id,
          threadId,
          subject,
          url: stringField(message, "url", "permalink"),
          author: from,
          recipients,
          timestamp,
          unread: Boolean(message.unread),
          starred: Boolean(message.starred),
          sensitivity: (stringField(message, "sensitivity") as AgentIngestConnectorMetadata["sensitivity"]) || undefined,
        },
      } satisfies AgentIngestRecord;
    }).filter((record) => record.text && record.source.timestamp);
    return applyBoundedFilters(records, options);
  }
}

function extractCandidates(records: AgentIngestRecord[]): { summaries: string[]; todos: string[] } {
  const summaries: string[] = [];
  const todos: string[] = [];
  for (const record of records) {
    const firstSentence = record.text.split(/(?<=[.!?])\s+/).find(Boolean);
    if (firstSentence) summaries.push(`${record.title}: ${firstSentence.slice(0, 180)}`);
    for (const line of record.text.split(/\r?\n/)) {
      if (/\b(todo|follow up|follow-up|action|please|can you|need to)\b/i.test(line)) todos.push(`${record.source.kind}:${record.id} — ${line.trim()}`);
    }
  }
  return { summaries, todos };
}

export function renderIngestReviewArtifact(records: AgentIngestRecord[], opts: { title?: string; generatedAt?: string } = {}): string {
  const provenance = records.map((record) => `${record.source.kind}:${record.id}`);
  const metadata = buildGeneratedArtifactMetadata({
    role: "report",
    generator: "org2-agent-ingest-fixture",
    generatedAt: opts.generatedAt,
    provenance,
    sourceHashes: records.map((record) => ({ kind: "artifact", value: `${record.source.kind}:${record.id}`, sha256: sha256Hex(record.text) })),
    reviewStatus: "review-required",
    aiTask: "ingest-review-packet",
  });
  const lines = [`#+TITLE: ${opts.title || "Scoped ingestion review packet"}`, formatOrg2ArtifactPropertyDrawer(metadata), "* Review checklist", "- [ ] Confirm this scoped import is allowed and bounded.", "- [ ] Redact private/sensitive details before promotion.", "- [ ] Promote only verified decisions, people, projects, follow-ups, and claims."];
  const candidates = extractCandidates(records);
  if (candidates.summaries.length || candidates.todos.length) {
    lines.push("", "* Generated candidates (review required)", ...candidates.summaries.map((summary) => `- Summary candidate: ${summary}`), ...candidates.todos.map((todo) => `- TODO candidate: ${todo}`));
  }
  lines.push("", "* Source records");
  for (const record of records) {
    const source = record.source;
    lines.push(`** ${record.title}`, `:PROPERTIES:`, `:ORG2_SOURCE_KIND: ${source.kind}`, `:ORG2_SOURCE_ID: ${record.id}`, `:ORG2_SOURCE_TIMESTAMP: ${source.timestamp}`);
    if (source.channel) lines.push(`:ORG2_SLACK_CHANNEL: ${source.channel}`);
    if (source.thread) lines.push(`:ORG2_SLACK_THREAD: ${source.thread}`);
    if (source.mailbox) lines.push(`:ORG2_GMAIL_MAILBOX: ${source.mailbox}`);
    if (source.label) lines.push(`:ORG2_GMAIL_LABEL: ${source.label}`);
    if (source.labels?.length) lines.push(`:ORG2_EMAIL_LABELS: ${source.labels.join(",")}`);
    if (source.threadId) lines.push(`:ORG2_EMAIL_THREAD_ID: ${source.threadId}`);
    if (source.subject) lines.push(`:ORG2_EMAIL_SUBJECT: ${source.subject}`);
    if (typeof source.unread === "boolean") lines.push(`:ORG2_EMAIL_UNREAD: ${source.unread}`);
    if (typeof source.starred === "boolean") lines.push(`:ORG2_EMAIL_STARRED: ${source.starred}`);
    if (source.url) lines.push(`:ORG2_SOURCE_URL: ${source.url}`);
    if (source.sensitivity) lines.push(`:ORG2_SENSITIVITY: ${source.sensitivity}`);
    lines.push(`:END:`, record.text, "");
  }
  return `${lines.join("\n").replace(/\n{3,}/g, "\n\n").trim()}\n`;
}
