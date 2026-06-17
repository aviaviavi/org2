#!/usr/bin/env node

/**
 * Test suite for LSP diagnostics feature
 * Tests parseOrgWithDiagnostics and the LSP diagnostic reporting
 */

import { parseOrgWithDiagnostics } from '../dist/parser.js';
import assert from 'assert';

console.log('=== Testing parseOrgWithDiagnostics ===\n');

// Test 1: Valid org file has no diagnostics
console.log('Test 1: Valid org content');
const validOrg = `* Headline 1
Some content

** Nested headline
- List item
- Another item
`;
const result1 = parseOrgWithDiagnostics(validOrg);
assert.strictEqual(result1.diagnostics.length, 0, 'Valid org should have no diagnostics');
assert.strictEqual(result1.ast.type, 'Document', 'Should return valid AST');
console.log('✓ Valid org has no diagnostics\n');

// Test 2: CRLF line endings produce diagnostic
console.log('Test 2: Invalid line endings (CRLF)');
const crlfOrg = '* Headline\r\nContent\r\n';
const result2 = parseOrgWithDiagnostics(crlfOrg);
assert(result2.diagnostics.length > 0, 'CRLF should produce diagnostics');
const crlfDiag = result2.diagnostics[0];
assert(crlfDiag.line === 1, 'Error should be on line 1');
assert(crlfDiag.column === 1, 'Error should be at column 1');
assert(crlfDiag.message.includes('CRLF'), 'Error message should mention CRLF');
console.log(`✓ CRLF error detected at ${crlfDiag.line}:${crlfDiag.column}: ${crlfDiag.message}\n`);

// Test 3: Invalid headline produces diagnostic
console.log('Test 3: Invalid headline');
const invalidHeadline = `Normal paragraph
*Invalid (no space after star)
More content`;
const result3 = parseOrgWithDiagnostics(invalidHeadline);
assert(result3.diagnostics.length > 0, 'Invalid headline should produce diagnostics');
const headlineDiag = result3.diagnostics[0];
assert(headlineDiag.message.includes('headline'), 'Error message should mention headline', headlineDiag.message);
assert(headlineDiag.line > 0, 'Error should have valid line number');
assert(headlineDiag.column > 0, 'Error should have valid column number');
console.log(`✓ Headline error detected at ${headlineDiag.line}:${headlineDiag.column}: ${headlineDiag.message}\n`);

// Test 4: Tab character in keyword line produces diagnostic
console.log('Test 4: Tab character in keyword line');
const tabOrg = `#+TITLE:\tMyTitle
Content`;
const result4 = parseOrgWithDiagnostics(tabOrg);
assert(result4.diagnostics.length > 0, 'Tab character in keyword line should produce diagnostics');
const tabDiag = result4.diagnostics[0];
assert(tabDiag.message.includes('tab'), 'Error message should mention tab');
console.log(`✓ Tab error detected at ${tabDiag.line}:${tabDiag.column}: ${tabDiag.message}\n`);

// Test 5: Parse errors don't crash, return empty document with diagnostics
console.log('Test 5: Graceful degradation on parse error');
const result5 = parseOrgWithDiagnostics(crlfOrg);
assert(result5.ast.type === 'Document', 'Should always return Document even with errors');
assert(Array.isArray(result5.ast.children), 'Should return valid AST structure');
console.log('✓ Returns valid empty document with diagnostics\n');

// Test 6: Multiple errors (if parser catches them)
console.log('Test 6: Parse result structure');
const result6 = parseOrgWithDiagnostics(validOrg);
assert(result6.ast !== undefined, 'Result should have ast property');
assert(Array.isArray(result6.diagnostics), 'Result should have diagnostics array');
assert(result6.diagnostics.every(d => 
  typeof d.line === 'number' && typeof d.column === 'number' && typeof d.message === 'string'
), 'All diagnostics should have line, column, and message');
console.log('✓ Parse result has correct structure\n');

console.log('=== All tests passed! ===');
