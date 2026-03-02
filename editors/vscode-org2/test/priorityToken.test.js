const test = require('node:test');
const assert = require('node:assert/strict');

const { updateHeadlinePriorityToken, normalizeOrgPriorityToken } = require('../priorityToken');

test('normalizeOrgPriorityToken accepts plain and bracketed values', () => {
  assert.equal(normalizeOrgPriorityToken('a'), 'A');
  assert.equal(normalizeOrgPriorityToken('[#b]'), 'B');
  assert.equal(normalizeOrgPriorityToken(''), '');
  assert.equal(normalizeOrgPriorityToken('nope'), '');
});

test('updateHeadlinePriorityToken inserts priority after TODO keyword', () => {
  const out = updateHeadlinePriorityToken('* TODO Ship it', 'A');
  assert.equal(out.changed, true);
  assert.equal(out.lineText, '* TODO [#A] Ship it');
});

test('updateHeadlinePriorityToken replaces existing priority token', () => {
  const out = updateHeadlinePriorityToken('* TODO [#C] Ship it', 'B');
  assert.equal(out.changed, true);
  assert.equal(out.lineText, '* TODO [#B] Ship it');
});

test('updateHeadlinePriorityToken clears existing priority token', () => {
  const out = updateHeadlinePriorityToken('* TODO [#A] Ship it', '');
  assert.equal(out.changed, true);
  assert.equal(out.lineText, '* TODO Ship it');
});

test('updateHeadlinePriorityToken works for headline without TODO keyword', () => {
  const out = updateHeadlinePriorityToken('* Inbox item', 'C');
  assert.equal(out.changed, true);
  assert.equal(out.lineText, '* [#C] Inbox item');
});

test('updateHeadlinePriorityToken ignores non-headline lines', () => {
  const line = 'not a heading';
  const out = updateHeadlinePriorityToken(line, 'A');
  assert.equal(out.changed, false);
  assert.equal(out.lineText, line);
});
