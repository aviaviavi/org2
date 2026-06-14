# Cited local search

`org2 search` provides a local-first cited retrieval surface for humans and agents working over an Org2 corpus. It does not synthesize answers; it returns grounded matches with file/line citations and nearby org metadata.

## Examples

```sh
org2 search "open loops" --dir notes --recursive
org2 search "waiting on me" --dir notes --recursive --todo TODO --tag project --format json
org2 query "decision record" --file notes/decisions.org2 --context 2 --limit 10 --format json
```

Human-readable output is citation-first:

```text
notes/decisions.org2:42 Architecture decision [DONE :project:]
  We decided to ship local cited search first.
```

JSON output uses the `org2:search:v1` schema:

```json
{
  "$schema": "org2:search:v1",
  "query": "decision",
  "results": [
    {
      "file": "notes/decisions.org2",
      "line": 42,
      "lineEnd": 42,
      "heading": "Architecture decision",
      "headingLine": 40,
      "id": "abc-123",
      "todo": "DONE",
      "tags": ["project"],
      "snippet": "We decided to ship local cited search first.",
      "context": { "startLine": 41, "endLine": 43, "lines": ["..."] }
    }
  ]
}
```

## Flags

- `--dir DIR`, `--recursive`, `--file FILE`, `--files FILE ...` select the corpus. If omitted, `org2.json` is used when present.
- `--format text|json` chooses human or machine-readable output.
- `--todo TODO`, `--tag TAG`, and `--heading TEXT` filter by nearest containing heading metadata.
- `--limit N` caps matches (default: 50).
- `--context N` includes surrounding source lines in JSON and supports agent citation checks.

## Recency and salience tuning

`org2 agent search`, `org2 agent context`, and `org2 context` rank matched notes with configurable recency and salience signals in addition to keyword/title/tag matches. Defaults are `--recency-weight 1` and `--salience-weight 1`; set either weight to `0` to disable that signal.

Recency uses `UPDATED`, `DATE`, `CREATED`, `CLOSED`, or planning timestamps when present. Salience uses explicit `ORG2_SALIENCE`/`SALIENCE`/`IMPORTANCE`, pinned or important metadata, active TODO/SCHEDULED/DEADLINE state, backlinks/mentions, and project/entity scope proximity. JSON results include `ranking` and per-result `selectionReason`; rendered context packs include a “Selected because” line so agents can explain why each item was selected.

Examples:

```bash
org2 context "scarf support triage" --dir notes --recursive --recency-weight 2 --salience-weight 1
org2 agent search --query "pricing policy" --dir notes --salience-weight 3 --recency-weight 0 --format json
```

## Agent consumption guidance

Agents should treat search results as evidence, not answers. Quote or summarize only from returned `snippet`/`context`, preserve `file:line` citations, and run narrower follow-up searches when results are ambiguous or insufficient. Do not infer facts that are not grounded in cited lines.

## Claim provenance, review, and freshness metadata

Agents should prefer claims that are source-backed, reviewed, and fresh enough for the task. Org2 models this with optional org property drawer fields on files/headings and generated artifacts:

- `ORG2_PROVENANCE`: comma-separated refs like `file:notes/foo.org2`, `id:project-alpha`, `url:https://...`, `query:...`, or `artifact:...`.
- `ORG2_CLAIM_STATE`: one of `source-backed`, `inference`, `human-reviewed`, or `raw-source`.
- `ORG2_REVIEW_STATUS`: one of `generated`, `review-required`, `reviewed`, or `promoted`.
- `ORG2_OBSERVED_AT`: ISO date or timestamp when the source was observed.
- `ORG2_VALID_AS_OF`: ISO date or timestamp the claim was known valid.
- `ORG2_STALE_AFTER`: ISO date or timestamp after which the claim should be treated as stale.
- `ORG2_EXPIRES_AT`: ISO date or timestamp after which the claim should be treated as expired.

Generated `compiled`, `view`, and `report` artifacts must include provenance plus either `ORG2_OBSERVED_AT` or `ORG2_VALID_AS_OF`, and must set `ORG2_CLAIM_STATE`. The artifact linter reports missing or invalid values.

Agent context output exposes these fields as `claimState` for every result and includes a compact review/freshness line in text context. Search scoring gives a small boost to reviewed/promoted and fresh claims, and penalizes stale or expired claims so equally relevant fresh reviewed facts rank ahead of older generated ones.
