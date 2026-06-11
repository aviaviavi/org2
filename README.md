# Org2

Docs website: https://org2.avi.press/

For now, the canonical project docs live on the website.

## Development

Run the full test suite with:

```sh
npm test
```

The canonical test layout is `test/<feature>/` for feature-focused Node test scripts and nearby fixtures, with legacy top-level `test-*.mjs` files migrated incrementally as their areas change. Agent/context-pack coverage now lives under `test/agent/`; run a targeted agent test with `node test/agent/test-agent-context.mjs` after `npm run build`.
