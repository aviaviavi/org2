# Ingest pipeline

`org2 ingest` captures local external context into corpus zones without promoting it directly into durable notes.

Flow:

1. raw capture JSON lands in `raw/ingest/` with source type, timestamp, source ref, content hash, generator-safe provenance, and sensitivity.
2. deterministic extraction writes a review packet in `views/ingest/`.
3. the review packet is marked review-required; humans or agents promote only verified material into `notes/` later.

By default, the command is a dry-run. Add `--apply` to write artifacts.

## Human-driven capture

```sh
org2 ingest --file meeting-notes.txt --corpus ~/notes --author Ada
org2 ingest --file meeting-notes.txt --corpus ~/notes --author Ada --apply
```

Example output:

```text
dry-run: file:meeting-notes.txt@sha256:...
raw: /Users/me/notes/raw/ingest/file-meeting-notes.txt-....json
view: /Users/me/notes/views/ingest/file-meeting-notes.txt-....org
review: pending (generated artifact remains review-required before promotion to notes/)
```

## Agent-driven capture

Agents can pass bounded local context through stdin or structured JSON fixtures:

```sh
cat context.txt | org2 ingest --stdin --corpus ./corpus --source-type note --apply --format json
org2 ingest --json scoped-export.json --corpus ./corpus --apply --format json
```

Structured JSON may be:

```json
{
  "sourceType": "meeting",
  "externalId": "sync-2026-06-07",
  "authors": ["Ada"],
  "occurredAt": "2026-06-07T17:00:00.000Z",
  "sensitivity": "private",
  "sourceRef": "fixture:sync-2026-06-07",
  "content": "Decision: keep generated artifacts review gated"
}
```

Connectors should stay outside core and feed this command/API with already-authorized, scoped exports. Keep imports bounded, preserve provenance, and avoid writing generated summaries or TODOs into `notes/` until review is complete.
