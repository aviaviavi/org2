import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const repo = path.dirname(fileURLToPath(import.meta.url));
const cli = path.join(repo, 'dist', 'cli.js');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-lint-graph-health-'));

const alphaId = '11111111-1111-1111-1111-111111111111';
const betaId = '22222222-2222-2222-2222-222222222222';
const dupeOneId = '33333333-3333-3333-3333-333333333333';
const dupeTwoId = '44444444-4444-4444-4444-444444444444';
const compiledId = '55555555-5555-5555-5555-555555555555';

fs.mkdirSync(path.join(tmpDir, 'notes'));
fs.mkdirSync(path.join(tmpDir, 'compiled'));

fs.writeFileSync(path.join(tmpDir, 'alpha.org2'), `#+TITLE: Alpha

:PROPERTIES:
:ID: ${alphaId}
:END:

Good link: [[Beta]].
Broken links: [[Missing Topic]], [[Shared]], and [[id:99999999-9999-9999-9999-999999999999][Missing ID]].
`);

fs.writeFileSync(path.join(tmpDir, 'beta.org2'), `#+TITLE: Beta

:PROPERTIES:
:ID: ${betaId}
:END:

Links back to [[Alpha]].
`);

fs.writeFileSync(path.join(tmpDir, 'dupe-one.org2'), `#+TITLE: Dupe One
#+ROAM_ALIASES: Shared

:PROPERTIES:
:ID: ${dupeOneId}
:END:
`);

fs.writeFileSync(path.join(tmpDir, 'dupe-two.org2'), `#+TITLE: Dupe Two
#+ROAM_ALIASES: Shared

:PROPERTIES:
:ID: ${dupeTwoId}
:END:
`);

fs.writeFileSync(path.join(tmpDir, 'notes', 'source.org2'), `#+TITLE: Canonical Source

This canonical note changed after the compiled output was generated.
`);

fs.writeFileSync(path.join(tmpDir, 'compiled', 'report.org2'), `#+TITLE: Compiled Report

:PROPERTIES:
:ID: ${compiledId}
:ORG2_ARTIFACT_ROLE: compiled
:ORG2_PROVENANCE: file:../notes/source.org2
:ORG2_GENERATED_AT: 2000-01-01T00:00:00Z
:ORG2_GENERATOR: test-fixture
:ORG2_SOURCE_HASHES: file:../notes/source.org2=sha256:0000000000000000000000000000000000000000000000000000000000000000
:END:

Compiled output.
`);

const json = JSON.parse(execFileSync('node', [cli, 'lint', '--dir', tmpDir, '--recursive', '--format', 'json'], { encoding: 'utf8' }));
assert.equal(json.$schema, 'org2:lint:v1');
assert.equal(json.checkedFiles, 6);

const rules = new Set(json.issues.map((issue) => issue.rule));
assert.ok(rules.has('unresolved-wiki-link'));
assert.ok(rules.has('unresolved-id-link'));
assert.ok(rules.has('ambiguous-wiki-link'));
assert.ok(rules.has('ambiguous-wiki-label'));
assert.ok(rules.has('artifact-stale-source-mtime'));
assert.ok(rules.has('artifact-source-hash-mismatch'));

assert.ok(json.issues.some((issue) => issue.rule === 'unresolved-wiki-link' && issue.file.endsWith('alpha.org2') && issue.line === 8 && /Missing Topic/.test(issue.message)));
assert.ok(json.issues.some((issue) => issue.rule === 'unresolved-id-link' && issue.file.endsWith('alpha.org2') && issue.line === 8));
assert.ok(json.issues.some((issue) => issue.rule === 'ambiguous-wiki-link' && issue.file.endsWith('alpha.org2') && issue.line === 8 && /\[\[Shared\]\]/.test(issue.message)));
assert.ok(json.issues.some((issue) => issue.rule === 'ambiguous-wiki-label' && /shared/i.test(issue.message)));
assert.ok(json.issues.some((issue) => issue.rule === 'artifact-stale-source-mtime' && issue.file.endsWith(path.join('compiled', 'report.org2')) && issue.line === 3));
assert.ok(json.issues.some((issue) => issue.rule === 'artifact-source-hash-mismatch' && issue.file.endsWith(path.join('compiled', 'report.org2')) && issue.line === 3));

const text = execFileSync('node', [cli, 'lint', '--dir', tmpDir, '--recursive'], { encoding: 'utf8' });
assert.match(text, /WARNING unresolved-wiki-link/);
assert.match(text, /WARNING ambiguous-wiki-label/);
assert.match(text, /WARNING artifact-source-hash-mismatch/);

console.log('✓ lint-graph-health');
