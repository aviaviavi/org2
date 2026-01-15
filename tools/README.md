# Org2 Tools

## Fixture runner (spec v0)

Validates that each fixture pair exists and that the expected JSON conforms to the canonical AST schema.

Run (schema-only):

```bash
cd /path/to/org2
node tools/fixture-runner.mjs
```

Run end-to-end parse + exact JSON match:

```bash
cd /path/to/org2
npm install
npm run build
node tools/fixture-runner.mjs --e2e
```

Notes:
- By default it validates:
  - every `spec/v0/tests/*.org` has a sibling `*.json` fixture (and vice versa)
  - each `*.json` conforms to `spec/v0/canonical-ast.schema.json`
- With `--e2e` it also parses `.org` → AST using the reference parser and compares it to the sibling `*.json` (exact match).
