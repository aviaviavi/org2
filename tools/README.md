# Org2 Tools

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
