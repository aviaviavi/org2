# Org2 Tools

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

## Fixture runner (spec v0)

Validates that each fixture pair exists and that the expected JSON conforms to the canonical AST schema.

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
