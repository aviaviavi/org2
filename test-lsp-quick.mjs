#!/usr/bin/env node

/**
 * Quick LSP test to verify basic functionality
 */

import { parseOrgToCanonicalAst } from "./dist/parser.js";

const testContent = `* First Headline
Some content here.

** Nested Headline
Nested content.

* Second Headline
More content.

#+BEGIN_SRC typescript
const x = 1;
#+END_SRC

- List item 1
- List item 2
`;

console.log("=== Quick LSP Test ===\n");

try {
  const ast = parseOrgToCanonicalAst(testContent);

  console.log("✓ Parser works");
  console.log(`✓ Found ${ast.children.length} top-level nodes`);

  const headlines = ast.children.filter((n) => n.type === "Headline");
  console.log(`✓ Found ${headlines.length} headlines`);

  const srcBlocks = ast.children.filter((n) => n.type === "SrcBlock");
  console.log(`✓ Found ${srcBlocks.length} source blocks`);

  const lists = ast.children.filter((n) => n.type === "List");
  console.log(`✓ Found ${lists.length} lists`);

  // Extract document symbols
  const symbols = [];
  for (const node of ast.children) {
    if (node.type === "Headline") {
      const titleText = node.title
        .map((n) => (n.type === "Text" ? n.value : ""))
        .join("");
      symbols.push({
        name: titleText || `Headline (level ${node.level})`,
        level: node.level,
        children: node.children.filter((c) => c.type === "Headline").length,
      });
    }
  }

  console.log("\nDocument Symbols:");
  console.log(JSON.stringify(symbols, null, 2));

  console.log("\n✓ All tests passed!");
  process.exit(0);
} catch (e) {
  console.error("✗ Test failed:", e.message);
  process.exit(1);
}
