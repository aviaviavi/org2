import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const repo = path.dirname(fileURLToPath(import.meta.url));
const cli = path.join(repo, 'dist', 'cli.js');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-compile-corpus-'));

const projectId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const meetingId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const alphaId = 'cccccccc-cccc-cccc-cccc-cccccccccccc';

fs.writeFileSync(path.join(tmpDir, 'project.org2'), `#+TITLE: Project Hub
#+ROAM_ALIASES: "Hub" project-home

:PROPERTIES:
:ID: ${projectId}
:ORG2_ROLE: source
:END:

* TODO Alpha Work :work:alpha:
SCHEDULED: <2026-05-19 Tue> DEADLINE: <2026-05-20 Wed>
:PROPERTIES:
:ID: ${alphaId}
:ROAM_ALIASES: "Alpha Initiative"
:OWNER: Avi
:END:

Use [[Meeting Notes]] and [[id:${meetingId}][meeting]] for context.
`);
fs.writeFileSync(path.join(tmpDir, 'meeting.org2'), `#+TITLE: Meeting Notes

:PROPERTIES:
:ID: ${meetingId}
:END:

* DONE Kickoff
CLOSED: [2026-05-18 Mon 10:30]

Mention [[Alpha Initiative]] from here.
`);

const json = JSON.parse(execFileSync('node', [cli, 'compile', 'corpus', '--dir', tmpDir, '--recursive'], { encoding: 'utf8' }));
assert.equal(json.schemaVersion, 'org2-compiled-corpus/v1');
assert.equal(json.generatedBy, 'org2 compile corpus');
assert.equal(json.artifact.schemaVersion, 'org2-artifact-metadata/v1');
assert.equal(json.artifact.role, 'compiled');
assert.equal(json.artifact.generator, 'org2 compile corpus');
assert.equal(json.artifact.reviewStatus, 'generated');
assert.match(json.artifact.generatedAt, /^\d{4}-\d{2}-\d{2}T/);
assert.deepEqual(json.artifact.provenance.sort(), ['file:meeting.org2', 'file:project.org2']);
assert.equal(json.artifact.sourceHashes.length, 2);
assert.ok(json.artifact.sourceHashes.every((entry) => entry.kind === 'file' && /^[a-f0-9]{64}$/.test(entry.sha256)));
assert.equal(json.stats.files, 2);
assert.equal(json.files.length, 2);

const alpha = json.nodes.find((node) => node.id === alphaId);
assert.ok(alpha, 'expected heading node with explicit ID');
assert.equal(alpha.kind, 'heading');
assert.equal(alpha.title, 'Alpha Work');
assert.equal(alpha.todo, 'TODO');
assert.deepEqual(alpha.tags, ['work', 'alpha']);
assert.deepEqual(alpha.aliases, ['Alpha Initiative']);
assert.equal(alpha.properties.OWNER, 'Avi');
assert.equal(alpha.sourceRange.startLine, 9);
assert.ok(alpha.sourceRange.endLine >= alpha.sourceRange.startLine);
assert.ok(alpha.planning.some((entry) => entry.kind === 'SCHEDULED' && entry.raw.includes('2026-05-19')));
assert.ok(alpha.planning.some((entry) => entry.kind === 'DEADLINE' && entry.raw.includes('2026-05-20')));
assert.ok(alpha.links.some((link) => link.type === 'wiki' && link.target === 'Meeting Notes'));
assert.ok(alpha.links.some((link) => link.type === 'id' && link.target === `id:${meetingId}`));
assert.ok(alpha.backlinks.some((link) => link.sourceTitle === 'Kickoff' && link.linkType === 'wiki'));

const projectFile = json.nodes.find((node) => node.kind === 'file' && node.id === projectId);
assert.ok(projectFile, 'expected file node with ID from property drawer');
assert.deepEqual(projectFile.aliases, ['Hub', 'project-home']);
assert.equal(projectFile.properties.ORG2_ROLE, 'source');

const out = path.join(tmpDir, 'compiled', 'corpus.jsonl');
const stdout = execFileSync('node', [cli, 'compile', 'corpus', '--dir', tmpDir, '--recursive', '--format', 'jsonl', '--out', out], { encoding: 'utf8' });
assert.equal(stdout.trim(), out);
const jsonl = fs.readFileSync(out, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
assert.equal(jsonl[0].schemaVersion, 'org2-compiled-corpus/v1');
assert.equal(jsonl[0].artifact.schemaVersion, 'org2-artifact-metadata/v1');
assert.ok(jsonl.some((entry) => entry.id === alphaId && entry.file === 'project.org2'));

console.log('✓ compile-corpus');
