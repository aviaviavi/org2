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

console.log('✓ checkbox-progress');
