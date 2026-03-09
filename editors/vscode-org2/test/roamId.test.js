const test = require('node:test');
const assert = require('node:assert/strict');

const {
  parseRoamIdScheme,
  parseRoamIdLink,
  extractRoamUuid,
  sanitizeBacklinkContextLine,
  sanitizeBacklinkContextText,
} = require('../roamId');

const UUID = '123e4567-e89b-12d3-a456-426614174000';

test('parseRoamIdScheme/parseRoamIdLink: parse strict Org-roam id inputs', () => {
  assert.equal(parseRoamIdScheme(`id:${UUID.toUpperCase()}`), UUID);
  assert.equal(parseRoamIdScheme(UUID), '');

  assert.deepEqual(parseRoamIdLink(`[[id:${UUID.toUpperCase()}][Roadmap]]`), { id: UUID, title: 'Roadmap' });
  assert.deepEqual(parseRoamIdLink(`[[id:${UUID}]]`), { id: UUID, title: '' });
  assert.equal(parseRoamIdLink('[[https://example.com][Roadmap]]'), null);
});

test('extractRoamUuid: resolves uuid from direct/id-scheme/id-link/embedded text forms', () => {
  assert.equal(extractRoamUuid(UUID.toUpperCase()), UUID);
  assert.equal(extractRoamUuid(`id:${UUID}`), UUID);
  assert.equal(extractRoamUuid(`[[id:${UUID}][Roadmap]]`), UUID);
  assert.equal(extractRoamUuid(`See ${UUID} for details`), UUID);
  assert.equal(extractRoamUuid('no id here'), '');
});

test('sanitizeBacklinkContextLine/Text: strips id tokens and normalizes id links', () => {
  assert.equal(
    sanitizeBacklinkContextLine(`Link [[id:${UUID}][Roadmap]] and id:${UUID} (keep punctuation ! )`),
    'Link Roadmap and (keep punctuation! )',
  );
  assert.equal(sanitizeBacklinkContextLine(`Bare [[id:${UUID}]] token`), 'Bare token');

  assert.equal(
    sanitizeBacklinkContextText(`  [[id:${UUID}][Alpha]]  \n\n id:${UUID} beta  \n`),
    'Alpha\nbeta',
  );
});
