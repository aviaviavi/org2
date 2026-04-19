import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const repo = '/Users/avi/dev/org2';
const cli = path.join(repo, 'dist', 'cli.js');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-roam-linkify-'));

const alphaId = '11111111-1111-1111-1111-111111111111';
const gammaId = '22222222-2222-2222-2222-222222222222';
const deltaId = '33333333-3333-3333-3333-333333333333';

fs.writeFileSync(path.join(tmpDir, 'alpha.org2'), `#+TITLE: Alpha Topic\n\n:PROPERTIES:\n:ID: ${alphaId}\n:END:\n\nAlpha Topic stands alone here.\n`);
fs.writeFileSync(path.join(tmpDir, 'delta.org2'), `#+TITLE: Delta Topic\n#+ROAM_ALIASES: D Topic\n\n:PROPERTIES:\n:ID: ${deltaId}\n:END:\n\n`);
fs.writeFileSync(path.join(tmpDir, 'notes.org2'), `#+TITLE: Notes\n\nWe discussed Alpha Topic yesterday.\nAlpha Topic came up twice.\nD Topic is shorthand.\n[[Alpha Topic]] already linked.\n#+begin_src text\nAlpha Topic inside code should stay plain.\n#+end_src\n`);
fs.writeFileSync(path.join(tmpDir, 'ambiguous.org2'), `#+TITLE: Alpha Topic\n\n:PROPERTIES:\n:ID: ${gammaId}\n:END:\n\nA duplicate node title exists here.\n`);

const preview = JSON.parse(execFileSync('node', [cli, 'roam', 'linkify', '--dir', tmpDir, '--recursive', '--format', 'json'], { encoding: 'utf8' }));
assert.equal(preview.action, 'linkify');
assert.equal(preview.changedFileCount, 1);
assert.equal(preview.replacementCount, 1);
assert.ok(preview.ambiguousSkipCount >= 1);

execFileSync('node', [cli, 'roam', 'linkify', '--dir', tmpDir, '--recursive', '--apply', '--format', 'json'], { encoding: 'utf8' });

const notes = fs.readFileSync(path.join(tmpDir, 'notes.org2'), 'utf8');
assert.match(notes, /We discussed Alpha Topic yesterday\./);
assert.match(notes, /Alpha Topic came up twice\./);
assert.match(notes, /\[\[id:33333333-3333-3333-3333-333333333333\]\[D Topic\]\] is shorthand\./);
assert.match(notes, /\[\[Alpha Topic\]\] already linked\./);
assert.match(notes, /#\+begin_src text\nAlpha Topic inside code should stay plain\./);

console.log('✓ roam-linkify');
