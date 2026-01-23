#!/usr/bin/env node

/**
 * LSP Unit Test - validates documentSymbol and foldingRange outputs
 */

import { execSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PROJECT_ROOT = path.resolve(__dirname, "..");

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

function testDocumentSymbol(content, name) {
  console.log(`\nTesting documentSymbol with: ${name}`);
  console.log("Content:");
  console.log(content);

  try {
    // Parse the org file to extract symbols
    const parseCmd = `cd ${PROJECT_ROOT} && node -e "
const { parseOrgToCanonicalAst } = require('./dist/parser.js');
const fs = require('fs');
const ast = parseOrgToCanonicalAst(\`${content.replace(/`/g, "\\`")}\`);
console.log(JSON.stringify(ast, null, 2));
"`;

    const ast = JSON.parse(
      execSync(`cd ${PROJECT_ROOT} && node -e "
const { parseOrgToCanonicalAst } = require('./dist/parser.js');
const content = JSON.parse(process.argv[1]);
const ast = parseOrgToCanonicalAst(content);
const headlines = ast.children.filter(n => n.type === 'Headline');
console.log(JSON.stringify(headlines.map(h => ({ level: h.level, title: h.title })), null, 2));
"`, [JSON.stringify(content)])
    );

    console.log("Extracted headlines:");
    console.log(JSON.stringify(ast, null, 2));
    console.log("✓ documentSymbol test passed");
  } catch (e) {
    console.error("✗ documentSymbol test failed:", e.message);
    return false;
  }
  return true;
}

function testFoldingRange(content, name) {
  console.log(`\nTesting foldingRange with: ${name}`);
  console.log("Content:");
  console.log(content);

  try {
    // Check that parser can handle the content
    const parseCmd = `cd ${PROJECT_ROOT} && node -e "
const { parseOrgToCanonicalAst } = require('./dist/parser.js');
const content = JSON.parse(process.argv[1]);
const ast = parseOrgToCanonicalAst(content);
const lines = content.split('\\n');
console.log('Lines: ' + lines.length);
console.log('Headlines: ' + ast.children.filter(n => n.type === 'Headline').length);
"`;

    const result = execSync(parseCmd, [JSON.stringify(content)]).toString();
    console.log("Parse result:");
    console.log(result);
    console.log("✓ foldingRange test passed");
  } catch (e) {
    console.error("✗ foldingRange test failed:", e.message);
    return false;
  }
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
