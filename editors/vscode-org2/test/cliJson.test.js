const test = require('node:test');
const assert = require('node:assert/strict');

const { parseCliJsonPayload, parseChangedFlagFromCliJson } = require('../cliJson');

test('parseCliJsonPayload parses direct JSON output', () => {
  assert.deepEqual(parseCliJsonPayload('{"changed":false,"id":"abc"}'), { changed: false, id: 'abc' });
});

test('parseCliJsonPayload parses trailing compact JSON line after noisy output', () => {
  const stdout = ['info: syncing roam db', 'warn: slow filesystem', '{"changed":true,"id":"xyz"}'].join('\n');
  assert.deepEqual(parseCliJsonPayload(stdout), { changed: true, id: 'xyz' });
});

test('parseCliJsonPayload parses trailing multi-line JSON block after noisy output', () => {
  const stdout = ['note: refreshed cache', '{', '  "changed": false,', '  "id": "file-id",', '  "meta": {"source": "roam"}', '}'].join('\n');

  assert.deepEqual(parseCliJsonPayload(stdout), {
    changed: false,
    id: 'file-id',
    meta: { source: 'roam' },
  });
});

test('parseCliJsonPayload parses trailing multi-line JSON array block', () => {
  const stdout = ['log: backlinks query complete', '[', '  {"line": 10},', '  {"line": 20}', ']'].join('\n');

  assert.deepEqual(parseCliJsonPayload(stdout), [{ line: 10 }, { line: 20 }]);
});

test('parseCliJsonPayload parses compact JSON line when noisy output follows it', () => {
  const stdout = ['info: sync start', '{"changed":false,"id":"abc"}', 'info: sync complete'].join('\n');

  assert.deepEqual(parseCliJsonPayload(stdout), { changed: false, id: 'abc' });
});

test('parseCliJsonPayload parses multi-line JSON block when noisy output follows it', () => {
  const stdout = ['trace: before', '{', '  "changed": true,', '  "id": "xyz"', '}', 'trace: after'].join('\n');

  assert.deepEqual(parseCliJsonPayload(stdout), { changed: true, id: 'xyz' });
});

test('parseChangedFlagFromCliJson returns changed flag only when explicit boolean', () => {
  assert.equal(parseChangedFlagFromCliJson('{"changed":true}'), true);
  assert.equal(parseChangedFlagFromCliJson('{"changed":false}'), false);
  assert.equal(parseChangedFlagFromCliJson(['note: before', '{"changed":false}', 'note: after'].join('\n')), false);
  assert.equal(parseChangedFlagFromCliJson('{"changed":"false"}'), undefined);
  assert.equal(parseChangedFlagFromCliJson('[{"changed":false}]'), undefined);
  assert.equal(parseChangedFlagFromCliJson('not json at all'), undefined);
});
