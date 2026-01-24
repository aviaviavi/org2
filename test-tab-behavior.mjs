#!/usr/bin/env node
import { parseOrgWithDiagnostics } from './dist/parser.js';

// Test different tab placements
const tests = [
  { name: 'Tab in headline', content: '* Headline\twith\ttabs\nContent' },
  { name: 'Tab in keyword line', content: '#+TITLE:\tMyTitle\n' },
  { name: 'Tab in paragraph', content: 'Normal paragraph\nWith\ttab\nMore' },
];

for (const test of tests) {
  const result = parseOrgWithDiagnostics(test.content);
  console.log(`\n${test.name}:`);
  console.log(`  Diagnostics: ${result.diagnostics.length}`);
  if (result.diagnostics.length > 0) {
    result.diagnostics.forEach((d, i) => {
      console.log(`    [${i}] ${d.line}:${d.column} - ${d.message}`);
    });
  }
}
