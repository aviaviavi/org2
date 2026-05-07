# Org2

Docs website: https://aviaviavi.github.io/org2/

For now, the canonical project docs live on the website.

### Cited search

Org2 includes local cited retrieval for shared knowledge-base workflows:

```sh
org2 search "waiting on me" --dir notes --recursive
org2 search "decision" --dir notes --recursive --todo DONE --format json
org2 query "project alpha" --file notes/projects.org2 --context 2
```

Search results are grounded in source locations (`file:line`) and JSON output includes heading/title, node ID when found, TODO state, tags, snippets, and context. See [docs/search.md](docs/search.md) for agent-safe consumption guidance.
