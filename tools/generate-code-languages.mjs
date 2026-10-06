#!/usr/bin/env node
// Writes the shared code-highlighting language table consumed by OpenOrg's
// native source editor. Run after changing src/codeHighlight.ts:
//   npm run build && node tools/generate-code-languages.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { codeLanguageTable, tokenizeCode } from "../dist/codeHighlight.js";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const CODE_LANGUAGE_TABLE_PATH = path.join(repo, "apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/Resources/CodeLanguages.json");

export const CODE_HIGHLIGHT_PARITY_PATH = path.join(repo, "test/fixtures/code-highlight-parity.json");

export function renderCodeLanguageTable() {
  return `${JSON.stringify(codeLanguageTable(), null, 1)}\n`;
}

/** Expected typed tokens (UTF-16 offsets) that the native tokenizer must reproduce. */
const PARITY_SAMPLES = [
  ["python", 'import os\n# note\n@cache\ndef run(self, n=0x1F):\n    """multi\n    line"""\n    return "a" if n else None\n'],
  ["swift", 'struct A: View {\n  let x = 42 // c\n  func f() -> String { "s" }\n}\n'],
  ["json", '{"key": [1, true, null, "v"]}\n'],
  ["markdown", "# Title\n> quote\n- item **bold** [link](https://x) `code`\n"],
  ["diff", "@@ -1 +1 @@\n-old\n+new\n same\n"],
  ["markup", '<a href="x">t &amp; u</a><!-- c -->\n'],
  ["shell", 'echo "$HOME" ${X} # c\n'],
  ["hcl", 'resource "aws" "x" {\n  count = 2 # c\n}\n'],
  ["yaml", "name: demo\nlist:\n  - 1\n"],
  ["sql", "SELECT id FROM t WHERE x = 1; -- c\n"],
  ["ini", "[core]\neditor = vim ; note\n"],
  ["latex", "\\section{A} $x$ % c\n"],
  ["ruby", "def ok?\n  defined?(x) && :sym\nend\n"],
];

export function renderCodeHighlightParity() {
  const fixtures = PARITY_SAMPLES.map(([language, source]) => {
    let position = 0;
    const tokens = [];
    for (const token of tokenizeCode(source, language)) {
      if (token.kind) tokens.push([token.kind, position, token.text.length]);
      position += token.text.length;
    }
    return { language, source, tokens };
  });
  return `${JSON.stringify(fixtures, null, 1)}\n`;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const check = process.argv.includes("--check");
  for (const [file, rendered] of [[CODE_LANGUAGE_TABLE_PATH, renderCodeLanguageTable()], [CODE_HIGHLIGHT_PARITY_PATH, renderCodeHighlightParity()]]) {
    const current = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
    if (check) {
      if (current !== rendered) {
        console.error(`${path.relative(repo, file)} is stale; run node tools/generate-code-languages.mjs`);
        process.exit(1);
      }
    } else {
      fs.writeFileSync(file, rendered);
      console.log(`wrote ${path.relative(repo, file)}`);
    }
  }
  if (check) console.log("OK: code language table and parity fixture are current");
}
