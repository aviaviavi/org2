const test = require('node:test');
const assert = require('node:assert/strict');

const {
  resolveWorkspaceFormatterPathFilters,
  buildWorkspaceFormatterCommandArgs,
  buildCurrentFileFormatterPreviewArgs,
  buildCurrentFileFormatterCheckArgs,
  buildCurrentFileFormatterApplyArgs,
  buildCurrentFileFormatterStdoutArgs,
} = require('../formatterArgs');

test('resolveWorkspaceFormatterPathFilters: trims filters and resolves relative config path from workspace root', () => {
  const out = resolveWorkspaceFormatterPathFilters({
    root: '/tmp/org-workspace',
    fileFilter: '  **/*.org  ',
    excludeFileFilter: '  archive/**  ',
    configFile: '  .org2fmt.json  ',
  });

  assert.deepEqual(out, {
    fileFilter: '**/*.org',
    excludeFileFilter: 'archive/**',
    configFile: '/tmp/org-workspace/.org2fmt.json',
  });
});

test('buildWorkspaceFormatterCommandArgs: check mode uses --dir/--recursive and includes optional file filters', () => {
  const out = buildWorkspaceFormatterCommandArgs({
    root: '/tmp/org-workspace',
    pathFilters: {
      fileFilter: '**/*.org',
      excludeFileFilter: 'archive/**',
      configFile: '',
    },
    mode: 'check',
  });

  assert.deepEqual(out, [
    'fmt',
    '--dir',
    '/tmp/org-workspace',
    '--recursive',
    '--check',
    '--file-match',
    '**/*.org',
    '--exclude-file',
    'archive/**',
  ]);
});

test('buildWorkspaceFormatterCommandArgs: apply mode prefers --config over --dir and keeps filter passthrough', () => {
  const out = buildWorkspaceFormatterCommandArgs({
    root: '/tmp/org-workspace',
    pathFilters: {
      fileFilter: 'notes/*.org2',
      excludeFileFilter: '',
      configFile: '/tmp/org-workspace/.org2fmt.json',
    },
    mode: 'apply',
  });

  assert.deepEqual(out, [
    'fmt',
    '--config',
    '/tmp/org-workspace/.org2fmt.json',
    '--apply',
    '--file-match',
    'notes/*.org2',
  ]);
});

test('buildCurrentFileFormatter*Args: emits stable CLI arg contracts for preview/check/apply/stdout fallback', () => {
  const filePath = '/tmp/org-workspace/notes/today.org';

  assert.deepEqual(buildCurrentFileFormatterPreviewArgs(filePath), ['fmt', '--file', filePath, '--format', 'json']);
  assert.deepEqual(buildCurrentFileFormatterCheckArgs(filePath), ['fmt', '--file', filePath, '--check']);
  assert.deepEqual(buildCurrentFileFormatterApplyArgs(filePath), ['fmt', '--file', filePath, '--apply']);
  assert.deepEqual(buildCurrentFileFormatterStdoutArgs(filePath), ['fmt', '--file', filePath]);
});
