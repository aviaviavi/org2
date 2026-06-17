import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cli = path.join(repo, 'dist', 'cli.js');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-roam-graph-'));

const alphaId = '11111111-1111-1111-1111-111111111111';
const betaId = '22222222-2222-2222-2222-222222222222';
const gammaId = '33333333-3333-3333-3333-333333333333';
const deltaId = '44444444-4444-4444-4444-444444444444';
const dupeOneId = '55555555-5555-5555-5555-555555555555';
const dupeTwoId = '66666666-6666-6666-6666-666666666666';

fs.writeFileSync(path.join(tmpDir, 'alpha.org2'), `#+TITLE: Alpha

:PROPERTIES:
:ID: ${alphaId}
:END:

Links to [[Beta]] and [[id:${gammaId}][Gamma]].
Mentions Delta for linkify preview.
Broken refs: [[Missing Node]], [[Shared]], and [[id:99999999-9999-9999-9999-999999999999][Missing ID]].
`);
fs.writeFileSync(path.join(tmpDir, 'beta.org2'), `#+TITLE: Beta
#+ROAM_ALIASES: Bee

:PROPERTIES:
:ID: ${betaId}
:END:

Mentions [[Alpha]] and Bee again.
`);
fs.writeFileSync(path.join(tmpDir, 'gamma.org2'), `#+TITLE: Gamma

:PROPERTIES:
:ID: ${gammaId}
:END:

#+begin_src bash
echo '[[Alpha]] should stay ignored here'
#+end_src

: [[Beta]] also ignored here
`);
fs.writeFileSync(path.join(tmpDir, 'delta.org2'), `#+TITLE: Delta

:PROPERTIES:
:ID: ${deltaId}
:END:

No links.
`);
fs.writeFileSync(path.join(tmpDir, 'dupe-one.org2'), `#+TITLE: Dupe One
#+ROAM_ALIASES: Shared

:PROPERTIES:
:ID: ${dupeOneId}
:END:

No links.
`);
fs.writeFileSync(path.join(tmpDir, 'dupe-two.org2'), `#+TITLE: Dupe Two
#+ROAM_ALIASES: Shared

:PROPERTIES:
:ID: ${dupeTwoId}
:END:

No links.
`);

const json = JSON.parse(execFileSync('node', [cli, 'roam', 'graph', '--dir', tmpDir, '--recursive', '--format', 'json'], { encoding: 'utf8' }));
assert.equal(json.action, 'graph');
assert.equal(json.nodeCount, 6);
assert.equal(json.edgeCount, 3);
assert.equal(json.nodes[0].label, 'Alpha');
assert.ok(json.nodes.some((node) => node.label === 'Delta' && node.degree === 0));
assert.equal(json.maintenance.summary.scannedFiles, 6);
assert.equal(json.maintenance.summary.nodeCount, 6);
assert.equal(json.maintenance.summary.aliasCollisionCount, 1);
assert.equal(json.maintenance.summary.unresolvedLinkCount, 2);
assert.equal(json.maintenance.summary.ambiguousLinkCount, 1);
assert.ok(json.maintenance.aliasCollisions.some((collision) => collision.label === 'shared' && collision.nodes.length === 2));
assert.ok(json.maintenance.linkFindings.some((finding) => finding.rule === 'unresolved-wiki-link' && finding.target === 'Missing Node'));
assert.ok(json.maintenance.linkFindings.some((finding) => finding.rule === 'unresolved-id-link' && finding.target === '99999999-9999-9999-9999-999999999999'));
assert.ok(json.maintenance.linkFindings.some((finding) => finding.rule === 'ambiguous-wiki-link' && finding.target === 'Shared'));
assert.ok(json.maintenance.linkifySuggestions.some((suggestion) => suggestion.kind === 'exact' && suggestion.label === 'delta'));
assert.ok(json.edges.some((edge) => edge.source === alphaId && edge.target === betaId));
assert.ok(json.edges.some((edge) => edge.source === alphaId && edge.target === gammaId));
assert.ok(json.edges.some((edge) => edge.source === betaId && edge.target === alphaId));

const out = path.join(tmpDir, 'graph.html');
const stdout = execFileSync('node', [cli, 'roam', 'graph', '--dir', tmpDir, '--recursive', '--out', out], { encoding: 'utf8' });
assert.equal(stdout.trim(), out);
const html = fs.readFileSync(out, 'utf8');
assert.match(html, /Org2 Roam Graph/);
assert.match(html, /Hover a node/);
assert.match(html, /const payload = /);
assert.match(html, /"label":"Alpha"/);
assert.match(html, /"label":"Delta"/);

const report = execFileSync('node', [cli, 'roam', 'graph', '--dir', tmpDir, '--recursive', '--format', 'report'], { encoding: 'utf8' });
assert.match(report, /Org2 roam maintenance report/);
assert.match(report, /Alias\/title collisions/);
assert.match(report, /unresolved-wiki-link/);
assert.match(report, /ambiguous-wiki-link/);
assert.match(report, /Linkify suggestions/);
assert.match(report, /delta -> Delta @/);

const reportOut = path.join(tmpDir, 'graph-report.txt');
const reportStdout = execFileSync('node', [cli, 'roam', 'graph', '--dir', tmpDir, '--recursive', '--format', 'report', '--out', reportOut], { encoding: 'utf8' });
assert.equal(reportStdout.trim(), reportOut);
assert.match(fs.readFileSync(reportOut, 'utf8'), /Org2 roam maintenance report/);

console.log('✓ roam-graph');
