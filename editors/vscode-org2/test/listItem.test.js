const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizeInsertedListMarker, buildInsertedListItemPrefix } = require('../listItem');

test('normalizeInsertedListMarker keeps bullet markers unchanged', () => {
  assert.equal(normalizeInsertedListMarker('-'), '-');
  assert.equal(normalizeInsertedListMarker('+'), '+');
  assert.equal(normalizeInsertedListMarker('*'), '*');
});

test('normalizeInsertedListMarker resets ordered list markers to one', () => {
  assert.equal(normalizeInsertedListMarker('7.'), '1.');
  assert.equal(normalizeInsertedListMarker('42)'), '1)');
});

test('buildInsertedListItemPrefix preserves indentation/spacing and resets checkbox state', () => {
  assert.equal(buildInsertedListItemPrefix('  -    [X] done task'), '  -    [ ] ');
  assert.equal(buildInsertedListItemPrefix('\t+\t[-] partial task'), '\t+\t[ ] ');
});

test('buildInsertedListItemPrefix normalizes ordered markers for new sibling insertion', () => {
  assert.equal(buildInsertedListItemPrefix('   9. [x] done'), '   1. [ ] ');
  assert.equal(buildInsertedListItemPrefix('2) next thing'), '1) ');
});

test('buildInsertedListItemPrefix returns empty string for non-list lines', () => {
  assert.equal(buildInsertedListItemPrefix('plain paragraph text'), '');
  assert.equal(buildInsertedListItemPrefix(''), '');
});
