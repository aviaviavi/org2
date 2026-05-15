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

## Agent consumption guidance

Agents should treat search results as evidence, not answers. Quote or summarize only from returned `snippet`/`context`, preserve `file:line` citations, and run narrower follow-up searches when results are ambiguous or insufficient. Do not infer facts that are not grounded in cited lines.
