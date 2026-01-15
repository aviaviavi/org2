# tree-sitter-org2

A minimal Tree-sitter grammar scaffold for **Org2**.

## Status

This grammar is intentionally small and **non-normative**. It exists to support early editor experimentation (highlighting, folding, incremental parsing).

The canonical definition of Org2 remains the **spec + fixtures** (and any future canonical AST format). If there is any mismatch between this grammar and the spec/fixtures, the spec/fixtures win.

## What it parses (currently)

- Headlines: leading `*` stars, a single space, then title text
- Paragraph/text lines

## Development

```sh
npm install
npm test
```

`npm test` runs `tree-sitter test` using the corpus files in `test/corpus/`.
