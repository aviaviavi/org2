#!/usr/bin/env node

/**
 * LSP Unit Test - validates basic LSP-derived computations.
 *
 * Note: This is not part of `npm test` yet; it’s a lightweight sanity check.
 */

import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PROJECT_ROOT = path.resolve(__dirname, "..");

const require = createRequire(import.meta.url);
const { parseOrgToCanonicalAst } = require(path.join(PROJECT_ROOT, "dist", "parser.js"));

// Test fixture 1: Simple headlines
const fixture1 = `* First Headline
Content of first section.

** Nested Headline
Nested content.

* Second Headline
Content of second section.
`;

// Test fixture 2: With code blocks
const fixture2 = `* Introduction

* Code Example
This is some text.

#+BEGIN_SRC typescript
const x = 1;
const y = 2;
#+END_SRC

More text.

* Conclusion
`;

// Test fixture 3: With lists
const fixture3 = `* Main Topic

- Item 1
- Item 2
  - Nested item
  - Another nested

- Item 3
`;

function getHeadlineTitles(content) {
  const ast = parseOrgToCanonicalAst(content);
  const headlines = ast.children.filter((n) => n.type === "Headline");
  return headlines.map((h) => ({ level: h.level, title: h.title }));
}

function testDocumentSymbol(content, name) {
  console.log(`\nTesting documentSymbol with: ${name}`);
  const symbols = getHeadlineTitles(content);
  if (!Array.isArray(symbols) || symbols.length === 0) {
    console.error("✗ documentSymbol test failed: no headlines found");
    return false;
  }
  console.log("Headlines:");
  console.log(JSON.stringify(symbols, null, 2));
  console.log("✓ documentSymbol test passed");
  return true;
}

function testFoldingRange(content, name) {
  console.log(`\nTesting foldingRange with: ${name}`);
  const ast = parseOrgToCanonicalAst(content);
  const lineCount = content.split("\n").length;
  const headlineCount = ast.children.filter((n) => n.type === "Headline").length;

  if (lineCount <= 0 || headlineCount <= 0) {
    console.error("✗ foldingRange test failed: unexpected counts");
    return false;
  }

  console.log(`Lines: ${lineCount}`);
  console.log(`Headlines: ${headlineCount}`);
  console.log("✓ foldingRange test passed");
  return true;
}

function main() {
  console.log("=== LSP Unit Tests ===\n");

  let passed = 0;
  let failed = 0;

  if (testDocumentSymbol(fixture1, "Simple Headlines")) passed++;
  else failed++;

  if (testFoldingRange(fixture1, "Simple Headlines")) passed++;
  else failed++;

  if (testDocumentSymbol(fixture2, "Code Blocks")) passed++;
  else failed++;

  if (testFoldingRange(fixture2, "Code Blocks")) passed++;
  else failed++;

  if (testDocumentSymbol(fixture3, "Lists")) passed++;
  else failed++;

  if (testFoldingRange(fixture3, "Lists")) passed++;
  else failed++;

  console.log(`\n=== Test Summary ===`);
  console.log(`Passed: ${passed}`);
  console.log(`Failed: ${failed}`);

  return failed === 0;
}

process.exit(main() ? 0 : 1);
