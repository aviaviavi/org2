import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cli = path.join(repo, 'dist', 'cli.js');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-checkbox-progress-'));
const file = path.join(tmpDir, 'tasks.org2');

fs.writeFileSync(file, `#+TITLE: Tasks

* Launch checklist [1/3]
- [X] Draft announcement
- [ ] Review screenshots
- [ ] Ship

* Accurate [50%]
- [x] Done
- [ ] Remaining
`);

const compiled = JSON.parse(execFileSync('node', [cli, 'compile', 'corpus', '--dir', tmpDir, '--recursive'], { encoding: 'utf8' }));
const launch = compiled.nodes.find((node) => node.title === 'Launch checklist [1/3]');
assert.ok(launch, 'expected launch heading');
assert.equal(launch.checkboxProgress.total, 3);
assert.equal(launch.checkboxProgress.checked, 1);
assert.equal(launch.checkboxProgress.unchecked, 2);
assert.equal(launch.checkboxProgress.percent, 33);
assert.equal(launch.checkboxProgress.cookies[0].raw, '[1/3]');
assert.equal(launch.checkboxProgress.cookies[0].stale, false);
assert.equal(compiled.checkboxProgress.total, 5);
assert.equal(compiled.checkboxProgress.checked, 2);
assert.equal(compiled.checkboxIssues.length, 0);

fs.writeFileSync(file, `#+TITLE: Tasks

* Launch checklist [2/3]
- [X] Draft announcement
- [ ] Review screenshots
- [ ] Ship
`);
const stale = JSON.parse(execFileSync('node', [cli, 'lint', '--dir', tmpDir, '--recursive', '--format', 'json'], { encoding: 'utf8' }));
assert.ok(stale.issues.some((issue) => issue.rule === 'checkbox-progress-cookie-stale' && issue.message.includes('expected [1/3]')));

fs.writeFileSync(file, `* TODO Grandparent [1/3]
** TODO Parent [1/2]
- [x] item a
- [ ] item b
** TODO Sibling [0/1]
- [ ] item c
`);
const nested = JSON.parse(execFileSync('node', [cli, 'compile', 'corpus', '--file', file, '--format', 'json'], { encoding: 'utf8' }));
assert.deepEqual(nested.checkboxIssues, []);
const grandparent = nested.nodes.find((node) => node.title === 'Grandparent [1/3]');
assert.ok(grandparent.checkboxProgress.cookies.some((cookie) => cookie.line === 2 && cookie.stale), 'ancestor node retains its recursive diagnostic view');
const nestedLint = JSON.parse(execFileSync('node', [cli, 'lint', '--file', file, '--format', 'json'], { encoding: 'utf8' }));
assert.equal(nestedLint.issues.filter((issue) => issue.rule === 'checkbox-progress-cookie-stale').length, 0);

fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('Parent [1/2]', 'Parent [0/2]'));
const nestedStale = JSON.parse(execFileSync('node', [cli, 'compile', 'corpus', '--file', file, '--format', 'json'], { encoding: 'utf8' }));
assert.deepEqual(nestedStale.checkboxIssues.map(({ line, raw, expectedRaw, checked, total }) => ({ line, raw, expectedRaw, checked, total })), [
  { line: 2, raw: '[0/2]', expectedRaw: '[1/2]', checked: 1, total: 2 },
]);
const nestedStaleLint = JSON.parse(execFileSync('node', [cli, 'lint', '--file', file, '--format', 'json'], { encoding: 'utf8' }));
const nestedWarnings = nestedStaleLint.issues.filter((issue) => issue.rule === 'checkbox-progress-cookie-stale');
assert.equal(nestedWarnings.length, 1);
assert.equal(nestedWarnings[0].line, 2);
assert.match(nestedWarnings[0].message, /expected \[1\/2\] for 1\/2 checked boxes/);

fs.writeFileSync(file, `* Safe [1/1]
#+begin_src org
* Literal heading [0/1]
- [ ] literal checkbox
#+end_src
:PROPERTIES:
:EXAMPLE: [0/1]
:END:
- [X] real checkbox
`);
const opaque = JSON.parse(execFileSync('node', [cli, 'compile', 'corpus', '--file', file, '--format', 'json'], { encoding: 'utf8' }));
assert.deepEqual(opaque.checkboxIssues, []);
// Compile keeps raw heading candidates from examples so canonical consumers can
// reject them with a precise diagnostic; checkbox analysis still ignores them.
assert.equal(opaque.nodes.some((node) => node.title === 'Literal heading [0/1]'), true);
const safe = opaque.nodes.find((node) => node.title === 'Safe [1/1]');
assert.equal(safe.checkboxProgress.checked, 1);
assert.equal(safe.checkboxProgress.total, 1);
const opaqueLint = JSON.parse(execFileSync('node', [cli, 'lint', '--file', file, '--format', 'json'], { encoding: 'utf8' }));
assert.equal(opaqueLint.issues.filter((issue) => issue.rule === 'checkbox-progress-cookie-stale').length, 0);

console.log('✓ checkbox-progress');
