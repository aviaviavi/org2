import assert from 'node:assert/strict';
import { parseInlinesFromText } from '../dist/parser.js';

const prose = 'Ordinary text with Unicode café ☕ and punctuation. '.repeat(20_000);
const start = performance.now();
assert.deepEqual(parseInlinesFromText(prose), [{ type: 'Text', value: prose }]);
const mixed = parseInlinesFromText(prose + ' *bold* [[id:coffee][recipe]] ' + prose);
assert.equal(mixed.filter(node => node.type === 'Emphasis').length, 1);
assert.equal(mixed.filter(node => node.type === 'Link').length, 1);
assert.equal(mixed[0].value, prose + ' ');
assert.equal(mixed.at(-1).value, ' ' + prose);
// Repeated potential URL openers should not allocate a suffix for every h.
const falseOpeners = 'h'.repeat(200_000);
assert.deepEqual(parseInlinesFromText(falseOpeners), [{ type: 'Text', value: falseOpeners }]);
const elapsed = performance.now() - start;
assert.ok(elapsed < 2_000 * Number(process.env.ORG2_PERF_BUDGET_SCALE || 1), `Long-prose inline parsing took ${elapsed.toFixed(0)}ms`);
console.log(`Inline parser: long plain/mixed Unicode prose and false URL openers passed in ${elapsed.toFixed(1)}ms`);
