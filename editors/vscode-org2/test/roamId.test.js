const test = require('node:test');
const assert = require('node:assert/strict');

const { parseRoamIdLink, extractRoamUuid, sanitizeBacklinkContextLine, sanitizeBacklinkContextText } = require('../roamId');

const UUID = '123E4567-E89B-12D3-A456-426614174000';
const UUID_LOWER = '123e4567-e89b-12d3-a456-426614174000';

test('parseRoamIdLink: parses valid org id links and normalizes id/title', () => {
  assert.deepEqual(parseRoamIdLink(`[[id:${UUID}][  Roadmap  ]]`), {
    id: UUID_LOWER,
    title: 'Roadmap',
  });
  assert.equal(parseRoamIdLink(`[[id:${UUID}]]`).id, UUID_LOWER);
  assert.equal(parseRoamIdLink('not-a-link'), null);
});

test('extractRoamUuid: supports raw UUID, id:UUID, id links, and embedded UUID text', () => {
  assert.equal(extractRoamUuid(UUID), UUID_LOWER);
  assert.equal(extractRoamUuid(`id:${UUID}`), UUID_LOWER);
  assert.equal(extractRoamUuid(`[[id:${UUID}][Roadmap]]`), UUID_LOWER);
  assert.equal(extractRoamUuid(`before ${UUID} after`), UUID_LOWER);
  assert.equal(extractRoamUuid('no uuid here'), '');
});

test('sanitizeBacklinkContextLine: strips id tokens and keeps readable context', () => {
  assert.equal(sanitizeBacklinkContextLine(`See [[id:${UUID}][Roadmap]] now.`), 'See Roadmap now.');
  assert.equal(sanitizeBacklinkContextLine(`xref id:${UUID} and id:${UUID_LOWER}`), 'xref and');
  assert.equal(sanitizeBacklinkContextLine(`[[id:${UUID}]]`), '');
});

test('sanitizeBacklinkContextText: compacts multiline context after per-line sanitization', () => {
  const raw = `[[id:${UUID}][Roadmap]]\n\n[[id:${UUID}]]\nKeep this line`;
  assert.equal(sanitizeBacklinkContextText(raw), 'Roadmap\nKeep this line');
});
