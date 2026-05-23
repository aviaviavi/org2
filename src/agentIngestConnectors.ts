import { buildGeneratedArtifactMetadata, formatOrg2ArtifactPropertyDrawer, sha256Hex } from "./artifactMetadata.js";

export type AgentIngestSourceKind = "slack" | "gmail";

export interface AgentIngestConnectorMetadata {
  kind: AgentIngestSourceKind;
  workspace?: string;
  channel?: string;
  thread?: string;
  mailbox?: string;
  label?: string;
  messageId?: string;
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
}

export interface AgentIngestFilterOptions {
  since?: string;
  until?: string;
  allowlist?: string[];
  limit?: number;
}

export interface AgentIngestConnector<TInput = unknown> {
  readonly kind: AgentIngestSourceKind;
  ingest(input: TInput, options?: AgentIngestFilterOptions): AgentIngestRecord[];
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

function applyBoundedFilters(records: AgentIngestRecord[], options: AgentIngestFilterOptions = {}): AgentIngestRecord[] {
  const filtered = records.filter((record) => inWindow(record.source.timestamp, options)).filter((record) => {
    if (record.source.kind === "slack") return allowed([record.source.channel || "", record.source.thread || ""], options);
    return allowed([record.source.mailbox || "", record.source.label || "", ...(record.source.recipients || [])], options);
  });
  const limit = Math.max(0, Math.trunc(Number(options.limit || filtered.length)));
  return filtered.slice(0, limit);
}

export class SlackFixtureConnector implements AgentIngestConnector {
  readonly kind = "slack" as const;

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

  ingest(input: unknown, options: AgentIngestFilterOptions = {}): AgentIngestRecord[] {
    const records = normalizeInput(input).map((message, index) => {
      const timestamp = stringField(message, "date", "timestamp", "internalDate");
      const subject = stringField(message, "subject") || "Gmail message";
      const from = stringField(message, "from", "author");
      const recipients = [...stringArrayField(message, "to"), ...stringArrayField(message, "cc")];
      const labels = stringArrayField(message, "labels");
      return {
        id: stringField(message, "id", "messageId") || `gmail-${timestamp || index}`,
        title: subject,
        text: stringField(message, "text", "body", "snippet"),
        source: {
          kind: this.kind,
          mailbox: stringField(message, "mailbox") || "gmail",
          label: labels[0],
          messageId: stringField(message, "id", "messageId", "threadId"),
          url: stringField(message, "url", "permalink"),
          author: from,
          recipients,
          timestamp,
          sensitivity: (stringField(message, "sensitivity") as AgentIngestConnectorMetadata["sensitivity"]) || undefined,
        },
      } satisfies AgentIngestRecord;
    }).filter((record) => record.text && record.source.timestamp);
    return applyBoundedFilters(records, options);
  }
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
  const lines = [`#+TITLE: ${opts.title || "Scoped ingestion review packet"}`, formatOrg2ArtifactPropertyDrawer(metadata), "* Review checklist", "- [ ] Confirm this scoped import is allowed and bounded.", "- [ ] Redact private/sensitive details before promotion.", "- [ ] Promote only verified decisions, people, projects, follow-ups, and claims.", "", "* Source records"];
  for (const record of records) {
    const source = record.source;
    lines.push(`** ${record.title}`, `:PROPERTIES:`, `:ORG2_SOURCE_KIND: ${source.kind}`, `:ORG2_SOURCE_ID: ${record.id}`, `:ORG2_SOURCE_TIMESTAMP: ${source.timestamp}`);
    if (source.channel) lines.push(`:ORG2_SLACK_CHANNEL: ${source.channel}`);
    if (source.thread) lines.push(`:ORG2_SLACK_THREAD: ${source.thread}`);
    if (source.mailbox) lines.push(`:ORG2_GMAIL_MAILBOX: ${source.mailbox}`);
    if (source.label) lines.push(`:ORG2_GMAIL_LABEL: ${source.label}`);
    if (source.url) lines.push(`:ORG2_SOURCE_URL: ${source.url}`);
    if (source.sensitivity) lines.push(`:ORG2_SENSITIVITY: ${source.sensitivity}`);
    lines.push(`:END:`, record.text, "");
  }
  return `${lines.join("\n").replace(/\n{3,}/g, "\n\n").trim()}\n`;
}
