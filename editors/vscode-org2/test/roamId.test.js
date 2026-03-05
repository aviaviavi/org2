const test = require('node:test');
const assert = require('node:assert/strict');

const {
  parseRoamIdLink,
  extractRoamUuid,
  sanitizeBacklinkContextLine,
  sanitizeBacklinkContextText,
} = require('../roamId');

const UUID = '123e4567-e89b-12d3-a456-426614174000';

test('parseRoamIdLink supports titled id links', () => {
  assert.deepEqual(parseRoamIdLink(`[[id:${UUID}][My Node]]`), {
    id: UUID,
    title: 'My Node',
  });
});

test('extractRoamUuid accepts direct UUID, id: scheme, and UUID in text', () => {
  assert.equal(extractRoamUuid(UUID), UUID);
  assert.equal(extractRoamUuid(`id:${UUID}`), UUID);
  assert.equal(extractRoamUuid(`See node ${UUID} in context`), UUID);
});

test('sanitize backlink context strips raw id tokens and normalizes links', () => {
  assert.equal(sanitizeBacklinkContextLine(`before id:${UUID} after`), 'before after');
  assert.equal(sanitizeBacklinkContextLine(`[[id:${UUID}][Readable]] and more`), 'Readable and more');

  assert.equal(
    sanitizeBacklinkContextText(`line 1 id:${UUID}\n[[id:${UUID}][Node]]`),
    'line 1\nNode'
  );
});
