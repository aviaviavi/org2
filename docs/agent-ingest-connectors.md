# Scoped agent ingestion connectors

Org2's agent-memory pipeline treats Slack and Gmail as scoped inputs, not as unbounded history dumps. Connectors should start from explicit exports or fixtures, apply a time window and allowlist, and write review artifacts before anything is promoted into canonical notes.

## Principles

- Prefer recent bounded windows, such as the last 30–90 days.
- Require explicit Slack channels/threads or Gmail labels/mailboxes rather than ingesting every message.
- Preserve source metadata (`slack:`/`gmail:` IDs, timestamps, authors, URLs, labels/channels) for review and citation.
- Mark generated review packets `ORG2_REVIEW_STATUS: review-required`.
- Use sensitivity flags and redact private details before promotion.

## Fixture connectors

The first connector layer supports bounded fixture/export ingestion for Slack-like and Gmail-like JSON. It produces review packets containing decisions, people, projects, follow-ups, claims, and source links for human review.

These connectors intentionally do not call external APIs yet. Live API sync should build on the same interface and keep the same defaults: bounded, allowlisted, review-gated, and privacy-aware.
