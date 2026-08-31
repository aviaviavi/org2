# Org2 Tools

## Coordinated OpenOrg releases

`release-openorg.mjs` is the resumable release orchestrator for npm, VS Code, notarized Apple Silicon and Intel DMGs, GitHub Releases, TestFlight, Scarf-backed downloads, and the generated site. It prints a read-only plan by default:

```bash
npm run release:openorg -- patch \
  --ios-build 25 \
  --notes /absolute/path/to/release-notes.md
```

Add `--execute` only after reviewing the plan. Long validation and packaging lanes run concurrently, each writes its own log under `/tmp/openorg-release-VERSION/`, and successful phases are checkpointed in `state.json`. Rerunning the same command resumes from the last completed phase.

The normal iOS path requires `OPENORG_ASC_ISSUER_ID`, `OPENORG_ASC_KEY_ID`, and `OPENORG_ASC_PRIVATE_KEY_PATH` so the build is reliably assigned to both TestFlight groups. Before submission, the workflow also marks demo credentials as unnecessary and supplies the canonical beta-review note explaining that optional AI chat is relayed through a locally installed macOS companion. macOS publication requires the existing `OPENORG_NOTARY_KEYCHAIN_PROFILE`, the Sparkle EdDSA signing key stored under the `org.org2.workspace` Keychain account, and `ORG2_GOOGLE_OAUTH_CLIENT_JSON` pointing at the protected OpenOrg Desktop OAuth client JSON. The release build reads that JSON without copying it into source and fails closed if the shared Google client is absent. Each release signs architecture-specific update feeds and publishes them with the site. Run `npm run release:openorg -- --help` for repair and partial-run options.

## Documentation coverage check

`npm run docs:check` builds the CLI, verifies that every top-level help family is represented in `org2 agent capabilities`, and checks that the canonical agent/documentation entry points exist. GitHub Pages CI runs the same check before publishing.

## Generated artifact check

Verifies that source-controlled generated artifacts are current.

```bash
cd /path/to/org2
npm run check:generated
```

The check rebuilds `dist/`, validates spec fixtures end-to-end, republishes the docs site, then fails if tracked generated outputs changed:

- `dist/` is TypeScript build output and is source-controlled for the npm CLI/package entrypoints.
- `site/` is the published HTML docs site generated from `docs/site/*.org` and source-controlled for static hosting.
- `spec/v0/tests/*.json` are compiled expected AST fixtures paired with `*.org` inputs and are source-controlled as executable spec data.

Disposable generated output should stay outside the repository, be ignored, or live in local corpus zones such as `compiled/` / `views/` unless it is intentionally promoted into a reviewed fixture or published artifact.

## Release download synchronization

`sync-release-downloads.mjs` reads GitHub Release assets, generates the canonical downloads page with Scarf Gateway links for OpenOrg disk images and registry links for the VS Code and npm packages, and maintains an idempotent direct-download block in GitHub release notes. Its default mode is read-only:

```bash
node tools/sync-release-downloads.mjs
```

Use `--apply-page` to update `docs/site/downloads.org`, `--apply-release-notes` for the authorized GitHub write, or `--check` as a no-drift gate. GitHub Releases remains the underlying artifact host.

## Fixture runner (spec v0)

Validates that each fixture pair exists and that the expected JSON conforms to the canonical AST schema.

Before fixture validation, `npm run fixtures` also runs
`tools/check-language-spec.mjs`. That check validates the normative
`GRAMMAR.ebnf` production graph, required contextual-rule sections in
`PARSING.org`, canonical AST references, and the shape of
`parsing-cases.json`. `test/test-language-spec.mjs` then runs every focused
ambiguity case against the production parser.

Run the language-contract checks independently with:

```bash
npm run check:language-spec
npm run test:language-spec
```

### Run (default: auto)

Auto mode will run end-to-end validation if the reference parser is available at `dist/parse.js`; otherwise it runs schema-only.

```bash
cd /path/to/org2
npm test
```

### Run (schema-only)

```bash
cd /path/to/org2
node tools/fixture-runner.mjs --schema-only
```

### Run (force end-to-end)

```bash
cd /path/to/org2
npm install
npm run build
node tools/fixture-runner.mjs --e2e
```

Notes:
- Always validates:
  - every `spec/v0/tests/*.org` has a sibling `*.json` fixture (and vice versa)
  - each `*.json` conforms to `spec/v0/canonical-ast.schema.json`
- With `--e2e` it also parses `.org` → AST using the reference parser and compares it to the sibling `*.json` (exact match).
