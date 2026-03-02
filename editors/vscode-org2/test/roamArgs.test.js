const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildRoamBacklinksArgs,
  buildRoamNodeNewArgs,
  buildRoamDbSyncPreviewArgs,
  buildRoamDbSyncApplyArgs,
} = require('../roamArgs');

test('buildRoamBacklinksArgs: emits stable roam backlinks CLI args for current file ID lookups', () => {
  assert.deepEqual(buildRoamBacklinksArgs('123e4567-e89b-12d3-a456-426614174000', '/tmp/org-roam'), [
    'roam',
    'backlinks',
    '--id',
    '123e4567-e89b-12d3-a456-426614174000',
    '--dir',
    '/tmp/org-roam',
    '--recursive',
    '--format',
    'json',
  ]);
});

test('buildRoamNodeNewArgs: emits stable roam node creation args with json/apply contract', () => {
  assert.deepEqual(buildRoamNodeNewArgs('/tmp/org-roam', 'Roadmap'), [
    'roam',
    'node',
    'new',
    '--dir',
    '/tmp/org-roam',
    '--title',
    'Roadmap',
    '--format',
    'json',
    '--apply',
  ]);
});

test('buildRoamDbSyncPreviewArgs/buildRoamDbSyncApplyArgs: preserve recursive opt-in and mode-specific flags', () => {
  assert.deepEqual(buildRoamDbSyncPreviewArgs('/tmp/org-roam', false), ['roam', 'db-sync', '--dir', '/tmp/org-roam', '--format', 'json']);
  assert.deepEqual(buildRoamDbSyncPreviewArgs('/tmp/org-roam', true), [
    'roam',
    'db-sync',
    '--dir',
    '/tmp/org-roam',
    '--format',
    'json',
    '--recursive',
  ]);

  assert.deepEqual(buildRoamDbSyncApplyArgs('/tmp/org-roam', false), ['roam', 'db-sync', '--dir', '/tmp/org-roam', '--format', 'json', '--apply']);
  assert.deepEqual(buildRoamDbSyncApplyArgs('/tmp/org-roam', true), [
    'roam',
    'db-sync',
    '--dir',
    '/tmp/org-roam',
    '--format',
    'json',
    '--apply',
    '--recursive',
  ]);
});
