import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cli = path.join(repo, 'dist', 'cli.js');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-clock-'));
const file = path.join(tmpDir, 'work.org2');
fs.writeFileSync(file, `#+TITLE: Work

* Project Alpha :project:work:
** TODO Build parser :dev:
CLOCK: [2026-05-26 Tue 09:00]--[2026-05-26 Tue 10:30] =>  1:30
CLOCK: [2026-05-26 Tue 10:00]--[2026-05-26 Tue 11:00] =>  1:00
CLOCK: [bad]
** DONE Review :review:
CLOCK: [2026-05-27 Wed 13:00]--[2026-05-27 Wed 13:30] =>  0:30
`);

const ast = JSON.parse(execFileSync('node', [path.join(repo, 'dist', 'parse.js'), file], { encoding: 'utf8' }));
const project = ast.children.find((n) => n.type === 'Headline');
const build = project.children.find((n) => n.type === 'Headline' && n.title.some((t) => t.value === 'Build parser'));
assert.equal(build.children.filter((n) => n.type === 'Clock').length, 3);

const printed = execFileSync('node', [cli, 'fmt', '--file', file], { encoding: 'utf8' });
assert.match(printed, /CLOCK: \[2026-05-26 Tue 09:00\]--\[2026-05-26 Tue 10:30\]/);

const compiled = JSON.parse(execFileSync('node', [cli, 'compile', 'corpus', '--dir', tmpDir], { encoding: 'utf8' }));
assert.equal(compiled.clocks.length, 3);
assert.equal(compiled.clockSummary.totalMinutes, 180);
assert.equal(compiled.clockSummary.byDay['2026-05-26'], 150);
assert.equal(compiled.clockSummary.byProject['Project Alpha'], 180);
assert.ok(compiled.clockIssues.some((i) => i.type === 'malformed-clock' && i.line === 7));
assert.ok(compiled.clockIssues.some((i) => i.type === 'overlapping-clock' && i.line === 6));
const buildNode = compiled.nodes.find((n) => n.kind === 'heading' && n.title === 'Build parser');
assert.equal(buildNode.clocks.length, 2);
assert.ok(buildNode.clockIssues.some((i) => i.type === 'malformed-clock'));

const report = JSON.parse(execFileSync('node', [cli, 'clock', '--dir', tmpDir, '--format', 'json'], { encoding: 'utf8' }));
assert.equal(report.schemaVersion, 'org2-clock-report/v1');
assert.equal(report.summary.byTag.dev, 150);
assert.equal(report.summary.byFile['work.org2'], 180);
const queryReport = JSON.parse(execFileSync('node', [cli, 'query', 'clocks', '--dir', tmpDir, '--format', 'json'], { encoding: 'utf8' }));
assert.deepEqual(queryReport.summary, report.summary);

const text = execFileSync('node', [cli, 'clock', '--dir', tmpDir], { encoding: 'utf8' });
assert.match(text, /Total: 3:00/);
assert.match(text, /By heading:/);
assert.match(text, /Project Alpha: 3:00/);

console.log('✓ clock');
