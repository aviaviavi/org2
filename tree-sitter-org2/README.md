# tree-sitter-org2

A minimal Tree-sitter grammar scaffold for **Org2**.

## Status

This Tree-sitter implementation is intentionally small and **non-normative**. It exists to support editor highlighting, folding, and incremental parsing.

The normative language bundle is `spec/v0/GRAMMAR.ebnf`, `PARSING.org`, `SPEC.org`, `canonical-ast.schema.json`, and the conformance cases and fixtures. This Tree-sitter grammar should track that contract, but it is not a substitute for the canonical lossless AST parser.

## What it parses (currently)

- Headlines and paragraph/text lines
- Source, export, arbitrary special, and dynamic block markers
- LaTeX environment markers, drawers, tables, and list items
- Footnote definitions, fixed-width lines, horizontal rules, and diary sexps
- Keywords and comments

## Neovim (nvim-treesitter)

This repo includes Tree-sitter queries for Neovim under `queries/org2/`:

- `queries/org2/highlights.scm`
- `queries/org2/folds.scm`

### Install the parser

Because this repo currently ships only `grammar.js` (no pre-generated `src/parser.c`), `nvim-treesitter` needs to generate the C parser during installation.

Add this to your Neovim config (Lua):

```lua
local parser_config = require("nvim-treesitter.parsers").get_parser_configs()

parser_config.org2 = {
  install_info = {
    -- This is a monorepo; point at the `tree-sitter-org2` subdir.
    url = "https://github.com/aviaviavi/org2", 
    files = { "src/parser.c" },
    branch = "main",
    generate_requires_npm = true,
    requires_generate_from_grammar = true,
  },
  filetype = "org2",
}

vim.treesitter.language.register("org2", "org2")
```

Then install it:

```vim
:TSInstall org2
```

### Enable highlighting + folding

Enable Tree-sitter highlighting (and optional folding):

```lua
require("nvim-treesitter.configs").setup({
  highlight = { enable = true },
  indent = { enable = false },
})

-- Optional: use Tree-sitter for folding.
vim.wo.foldmethod = "expr"
vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
```

If you use a different file extension than `*.org2`, ensure your filetype is set to `org2`.

## Development

```sh
npm install
npm test
```

`npm test` regenerates the non-checked-in parser and runs `tree-sitter test`
using the corpus files in `test/corpus/`.
