import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const repo = path.dirname(fileURLToPath(import.meta.url));
const cli = path.join(repo, 'dist', 'cli.js');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-effort-'));
const file = path.join(tmpDir, 'work.org2');
fs.writeFileSync(file, `#+TITLE: Work

* TODO Build parser :dev:project:
:PROPERTIES:
:EFFORT: 1:30
:END:
SCHEDULED: <2026-05-26 Tue 09:00>
* TODO Review docs :docs:
:PROPERTIES:
:EFFORT: 45m
:END:
DEADLINE: <2026-05-26 Tue>
* TODO Invalid estimate :dev:
:PROPERTIES:
:EFFORT: someday
:END:
SCHEDULED: <2026-05-27 Wed>
`);

const compiled = JSON.parse(execFileSync('node', [cli, 'compile', 'corpus', '--dir', tmpDir], { encoding: 'utf8' }));
assert.equal(compiled.effortSummary.totalMinutes, 135);
assert.equal(compiled.effortSummary.byProject['Build parser'], 90);
assert.equal(compiled.effortSummary.byProject['Review docs'], 45);
assert.equal(compiled.effortSummary.byTag.dev, 90);
assert.equal(compiled.effortSummary.byTag.docs, 45);
assert.equal(compiled.effortSummary.byFile['work.org2'], 135);
const buildNode = compiled.nodes.find((n) => n.title === 'Build parser');
assert.deepEqual(buildNode.effort, { raw: '1:30', minutes: 90 });
assert.equal(compiled.nodes.find((n) => n.title === 'Invalid estimate').effort, undefined);

const agenda = JSON.parse(execFileSync('node', [cli, 'agenda', '--dir', tmpDir, '--from', '2026-05-26', '--days', '2', '--group', 'tags', '--workload', '--format', 'json'], { encoding: 'utf8' }));
assert.equal(agenda.workload.totalMinutes, 135);
assert.equal(agenda.workload.byDate['2026-05-26'], 135);
assert.equal(agenda.workload.byGroup['Tags: dev,project'], 90);
assert.equal(agenda.workload.byGroup['Tags: docs'], 45);
assert.equal(agenda.workload.byTag.dev, 90);
assert.equal(agenda.days[0].items[0].effort, '1:30');

const lint = JSON.parse(execFileSync('node', [cli, 'lint', '--dir', tmpDir, '--format', 'json'], { encoding: 'utf8' }));
assert.ok(lint.issues.some((i) => i.rule === 'effort-malformed' && i.line === 15 && /someday/.test(i.message)));

console.log('✓ effort');
