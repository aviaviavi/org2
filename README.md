# Org2

Docs website: https://org2.avi.press/

For now, the canonical project docs live on the website.

## Development

Run the full test suite with:

```sh
npm test
```

Build or update the local macOS app bundle with:

```sh
make macos-app
```

The equivalent npm script is `npm run build:macos-app`.

By default this writes to `~/Applications/Org2Workspace.app` and signs it with
bundle id `org.org2.workspace`. Override those with `ORG2_WORKSPACE_APP_PATH` or
`ORG2_WORKSPACE_BUNDLE_ID` when needed. On Apple Silicon it builds arm64 by
default; override with `ORG2_WORKSPACE_SWIFT_ARCH` if needed.

The canonical test layout is `test/<feature>/` for feature-focused Node test scripts and nearby fixtures, with legacy top-level `test-*.mjs` files migrated incrementally as their areas change. Agent/context-pack coverage now lives under `test/agent/`; run a targeted agent test with `node test/agent/test-agent-context.mjs` after `npm run build`.
