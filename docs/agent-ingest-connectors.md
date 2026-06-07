# Scoped agent ingestion connectors

Org2's agent-memory pipeline treats Slack, Gmail, messages, meetings, and other external sources as scoped inputs, not as unbounded history dumps. Core stays source-agnostic: API credentials, OAuth, device export tools, crawlers, and service-specific rate limits belong in optional connectors/plugins outside org2 core.

## Connector contract

A connector is TypeScript/JSON-first and advertises a manifest:

```ts
interface AgentIngestConnectorManifest {
  schemaVersion: "org2-connector/v1";
  id: string;
  sourceType: string;
  displayName: string;
  auth: { mode: "external" | "none"; note: string };
  capabilities: {
    incrementalSync: boolean;
    dryRun: boolean;
    stableSourceIds: boolean;
    contentHashDedupe: boolean;
  };
  privacy: {
    defaultPolicy: "review-required" | "skip-private" | "redact-private";
    sensitivityField?: string;
  };
}
```

Connector output is normalized to `AgentIngestRecord` values with:

- stable source ID (`kind:id`) for idempotency;
- cursor/timestamp for incremental sync;
- source metadata such as authors, recipients, channel/mailbox/labels/thread, subject, unread/starred state, URL, timestamp, and sensitivity;
- raw payload kept as connector provenance, not promoted into durable notes;
- text content that can be converted into `Org2RawCaptureInput` and fed to the unified `org2 ingest` pipeline.

## Principles

- Prefer recent bounded windows, such as the last 30–90 days.
- Require explicit Slack channels/threads, Gmail labels/mailboxes, message threads, or meeting IDs rather than ingesting every record.
- Preserve source metadata (`slack:`/`gmail:` IDs, timestamps, authors, URLs, labels/channels) for review and citation.
- Support dry-run/preview before writing corpus artifacts.
- Deduplicate by stable source ID and content hash.
- Mark generated review packets `ORG2_REVIEW_STATUS: review-required`.
- Use sensitivity flags and privacy policy hooks before promotion.

## Fixture connectors

The fixture connectors support bounded export ingestion for Slack-like, Gmail-like, and SMS/iMessage/WhatsApp-like JSON. They prove the contract without live external auth:

- `SlackFixtureConnector.manifest`, `GmailFixtureConnector.manifest`, and `MessageThreadFixtureConnector.manifest` declare external auth expectations.
- `GmailFixtureConnector` accepts either flat message exports or multi-message thread exports and emits stable message IDs plus timestamp/message cursors for incremental sync.
- `MessageThreadFixtureConnector` accepts selected direct/group thread exports with service, conversation ID/title, participants, sender, timestamp, URL, sensitivity, and stable message IDs.
- Message filtering can be scoped by service, conversation ID/title, participant, date windows, capture policy, and `limit`.
- Email filtering can be scoped by labels, exact senders, sender/recipient domains, unread/starred state, date windows, and `limit`.
- `previewConnectorIngest()` validates manifests, applies privacy policy, and reports skipped duplicates.
- `connectorRecordsToRawCaptureInputs()` adapts connector records into the same raw capture shape used by `org2 ingest`.
- `renderIngestReviewArtifact()` marks generated summaries and TODO candidates as review-required before promotion.

These connectors intentionally do not call external APIs. Live API sync should build on the same interface and keep the same defaults: bounded, allowlisted, review-gated, idempotent, and privacy-aware.

## Capture policy layer

Connector previews can accept a `policy` object before any raw capture inputs or review artifacts are written. The policy layer is source-agnostic and is intended for connector/plugin code to apply after external auth/export and before org2 core ingestion.

Supported controls:

- `sourceAllowlist` / `sourceDenylist`
- participant and email `domains` filters
- `since` / `until` date windows
- `maxCount` dry-run/import caps
- `sensitiveRedactions` regex rules applied to preview text
- `retentionDays` reporting
- `defaultReviewStatus`, defaulting to `review-required`

`previewConnectorIngest()` returns a `policyReport` with accepted/skipped counts, sample accepted IDs, redaction counts, and skip reasons so dry-runs can explain what would be captured.
