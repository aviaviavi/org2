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
const advisorId = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
const linkedAdvisorId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';

fs.writeFileSync(path.join(tmpDir, 'project.org2'), `#+TITLE: Project Hub
#+ROAM_ALIASES: "Hub" project-home

:PROPERTIES:
:ID: ${projectId}
:ORG2_ROLE: source
:ORG2_ENTITY_TYPE: company
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
fs.writeFileSync(path.join(tmpDir, 'advisor.org2'), `#+TITLE: Ada Advisor

:PROPERTIES:
:ID: ${advisorId}
:ORG2_ENTITY_TYPE: person
:ORG2_RELATION: advisor_to id:${projectId}
:END:

- Advisor to [[id:${projectId}][Project Hub]]

* Details
`);
fs.writeFileSync(path.join(tmpDir, 'linked-advisor.org2'), `#+TITLE: Linked Advisor

:PROPERTIES:
:ID: ${linkedAdvisorId}
:ORG2_ENTITY_TYPE: person
:END:
`);
fs.writeFileSync(path.join(tmpDir, 'meeting.org2'), `#+TITLE: Meeting Notes

:PROPERTIES:
:ID: ${meetingId}
:END:

* DONE Kickoff
CLOSED: [2026-05-18 Mon 10:30]

Mention [[Alpha Initiative]] from here.
[[id:${linkedAdvisorId}][Linked Advisor]] has been advising for my new startup, Project Hub.
`);

const json = JSON.parse(execFileSync('node', [cli, 'compile', 'corpus', '--dir', tmpDir, '--recursive'], { encoding: 'utf8' }));
assert.equal(json.schemaVersion, 'org2-compiled-corpus/v1');
assert.equal(json.generatedBy, 'org2 compile corpus');
assert.equal(json.artifact.schemaVersion, 'org2-artifact-metadata/v1');
assert.equal(json.artifact.role, 'compiled');
assert.equal(json.artifact.generator, 'org2 compile corpus');
assert.equal(json.artifact.reviewStatus, 'generated');
assert.match(json.artifact.generatedAt, /^\d{4}-\d{2}-\d{2}T/);
assert.deepEqual(json.artifact.provenance.sort(), ['file:advisor.org2', 'file:linked-advisor.org2', 'file:meeting.org2', 'file:project.org2']);
assert.equal(json.artifact.sourceHashes.length, 4);
assert.ok(json.artifact.sourceHashes.every((entry) => entry.kind === 'file' && /^[a-f0-9]{64}$/.test(entry.sha256)));
assert.equal(json.stats.files, 4);
assert.equal(json.files.length, 4);

const alpha = json.nodes.find((node) => node.id === alphaId);
assert.ok(alpha, 'expected heading node with explicit ID');
assert.equal(alpha.kind, 'heading');
assert.equal(alpha.title, 'Alpha Work');
assert.equal(alpha.todo, 'TODO');
assert.deepEqual(alpha.tags, ['work', 'alpha']);
assert.deepEqual(alpha.aliases, ['Alpha Initiative']);
assert.equal(alpha.properties.OWNER, 'Avi');
assert.equal(alpha.sourceRange.startLine, 10);
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
assert.equal(projectFile.entityType, 'company');
assert.ok(json.entities.some((entity) => entity.id === projectId && entity.entityType === 'company'));
assert.ok(json.entities.some((entity) => entity.id === advisorId && entity.entityType === 'person'));
assert.ok(json.relations.some((relation) => relation.subjectId === advisorId && relation.objectId === projectId && relation.predicate === 'advisor_to' && relation.confidence === 'explicit'));
assert.ok(json.relations.some((relation) => relation.subjectId === advisorId && relation.objectId === projectId && relation.predicate === 'advisor_to' && relation.confidence === 'inferred-pattern'));
assert.ok(json.relations.some((relation) => relation.subjectId === linkedAdvisorId && relation.objectId === projectId && relation.predicate === 'advisor_to' && relation.method === 'pattern:linked-subject-advising-named-object' && relation.line === 11));
const relationQuery = execFileSync('node', [cli, 'query', 'relations', '--object', projectId, '--predicate', 'advisor_to', '--dir', tmpDir, '--recursive', '--format', 'json'], { encoding: 'utf8' });
const relationJson = JSON.parse(relationQuery);
assert.equal(relationJson.$schema, 'org2:relation-query:v1');
assert.ok(relationJson.relations.some((relation) => relation.subjectTitle === 'Ada Advisor' && relation.predicate === 'advisor_to'));
assert.ok(relationJson.relations.some((relation) => relation.subjectTitle === 'Linked Advisor' && relation.predicate === 'advisor_to'));
const relationLinkQuery = execFileSync('node', [cli, 'query', 'relations', '--object', `[[id:${projectId}][Project Hub]]`, '--predicate', 'advisor_to', '--dir', tmpDir, '--recursive', '--format', 'json'], { encoding: 'utf8' });
const relationLinkJson = JSON.parse(relationLinkQuery);
assert.ok(relationLinkJson.relations.some((relation) => relation.subjectTitle === 'Ada Advisor' && relation.objectId === projectId));

const out = path.join(tmpDir, 'compiled', 'corpus.jsonl');
const stdout = execFileSync('node', [cli, 'compile', 'corpus', '--dir', tmpDir, '--recursive', '--format', 'jsonl', '--out', out], { encoding: 'utf8' });
assert.equal(stdout.trim(), out);
const jsonl = fs.readFileSync(out, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
assert.equal(jsonl[0].schemaVersion, 'org2-compiled-corpus/v1');
assert.equal(jsonl[0].artifact.schemaVersion, 'org2-artifact-metadata/v1');
assert.ok(jsonl[0].entities.some((entity) => entity.id === advisorId && entity.entityType === 'person'));
assert.ok(jsonl[0].relations.some((relation) => relation.subjectId === advisorId && relation.predicate === 'advisor_to'));
assert.ok(jsonl.some((entry) => entry.id === alphaId && entry.file === 'project.org2'));

console.log('✓ compile-corpus');
