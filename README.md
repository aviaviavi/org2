# Org2

## Human briefings

`org2 brief` turns the same compiled corpus and agent-context retrieval substrate used by `org2 agent/context` into a human-facing briefing with file:line citations.

Examples:

```sh
org2 brief today --dir notes --recursive
org2 brief project copper --dir notes --recursive --limit 8
org2 brief project copper --dir notes --out views/copper-brief.org --format org
```

Briefings are source-agnostic: they cite underlying notes/raw sources and mark generated synthesis as `[review-required]` unless you rely directly on cited, deterministically sourced lines. Agents can use the JSON form for the same selection:

```sh
org2 brief project copper --dir notes --format json
```


Docs website: https://org2.avi.press/

For now, the canonical project docs live on the website.
