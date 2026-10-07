const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  findExecutableOnPath,
  isExplicitlyConfigured,
  resolveDefaultCliExecutable
} = require('../cliExecutable');

test('default org2 command prefers celorga when it is on PATH', () => {
  const lookups = [];
  const command = resolveDefaultCliExecutable('org2', {
    findExecutable: (name) => {
      lookups.push(name);
      return name === 'celorga' ? '/usr/local/bin/celorga' : null;
    }
  });
  assert.equal(command, 'celorga');
  assert.deepEqual(lookups, ['celorga']);
});

test('default org2 command falls back to org2 when celorga is missing', () => {
  assert.equal(resolveDefaultCliExecutable('org2', { findExecutable: () => null }), 'org2');
  assert.equal(resolveDefaultCliExecutable('', { findExecutable: () => null }), 'org2');
});

test('explicit or custom commands are never rewritten', () => {
  const findExecutable = () => '/usr/local/bin/celorga';
  assert.equal(resolveDefaultCliExecutable('org2', { explicitlyConfigured: true, findExecutable }), 'org2');
  assert.equal(resolveDefaultCliExecutable('node', { findExecutable }), 'node');
  assert.equal(resolveDefaultCliExecutable('/opt/bin/org2', { findExecutable }), '/opt/bin/org2');
});

test('isExplicitlyConfigured detects user, workspace, and folder values', () => {
  assert.equal(isExplicitlyConfigured(undefined), false);
  assert.equal(isExplicitlyConfigured({ key: 'org2.agenda.command', defaultValue: 'org2' }), false);
  assert.equal(isExplicitlyConfigured({ defaultValue: 'org2', globalValue: 'org2' }), true);
  assert.equal(isExplicitlyConfigured({ defaultValue: 'org2', workspaceValue: 'node' }), true);
  assert.equal(isExplicitlyConfigured({ defaultValue: 'org2', workspaceFolderValue: 'org2' }), true);
});

test('findExecutableOnPath finds executables in PATH order', { skip: process.platform === 'win32' }, () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'celorga-cli-path-'));
  try {
    const first = path.join(root, 'a');
    const second = path.join(root, 'b');
    fs.mkdirSync(first);
    fs.mkdirSync(second);
    fs.writeFileSync(path.join(first, 'celorga'), '#!/bin/sh\n', { mode: 0o644 });
    fs.writeFileSync(path.join(second, 'celorga'), '#!/bin/sh\n', { mode: 0o755 });
    const env = { PATH: [first, second].join(':') };
    assert.equal(findExecutableOnPath('celorga', { env, platform: 'darwin' }), path.join(second, 'celorga'));
    assert.equal(findExecutableOnPath('missing', { env, platform: 'darwin' }), null);
    assert.equal(findExecutableOnPath('celorga', { env: {}, platform: 'darwin' }), null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('findExecutableOnPath honors PATHEXT on Windows', () => {
  const seen = [];
  const found = findExecutableOnPath('celorga', {
    env: { Path: 'C:\\npm;C:\\tools', PATHEXT: '.EXE;.CMD' },
    platform: 'win32',
    isExecutable: (candidate) => {
      seen.push(candidate);
      return candidate === 'C:\\tools\\celorga.CMD';
    }
  });
  assert.equal(found, 'C:\\tools\\celorga.CMD');
  assert.deepEqual(seen.slice(0, 3), ['C:\\npm\\celorga', 'C:\\npm\\celorga.EXE', 'C:\\npm\\celorga.CMD']);
});
