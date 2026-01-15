# Org2 Tools

## Fixture runner (spec v0)

Validates that each fixture pair exists and that the expected JSON conforms to the canonical AST schema.

Run:

```bash
cd /path/to/org2
node tools/fixture-runner.mjs
```

Notes:
- This does **not** parse `.org` → AST yet (there is no reference parser in-repo yet).
- For now, it enforces:
  - every `spec/v0/tests/*.org` has a sibling `*.json` fixture (and vice versa)
  - each `*.json` conforms to `spec/v0/canonical-ast.schema.json`
