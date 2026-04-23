import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const repo = path.dirname(fileURLToPath(import.meta.url));
const cli = path.join(repo, 'dist', 'cli.js');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-roam-graph-'));

const alphaId = '11111111-1111-1111-1111-111111111111';
const betaId = '22222222-2222-2222-2222-222222222222';
const gammaId = '33333333-3333-3333-3333-333333333333';
const deltaId = '44444444-4444-4444-4444-444444444444';

fs.writeFileSync(path.join(tmpDir, 'alpha.org2'), `#+TITLE: Alpha\n\n:PROPERTIES:\n:ID: ${alphaId}\n:END:\n\nLinks to [[Beta]] and [[id:${gammaId}][Gamma]].\n`);
fs.writeFileSync(path.join(tmpDir, 'beta.org2'), `#+TITLE: Beta\n#+ROAM_ALIASES: Bee\n\n:PROPERTIES:\n:ID: ${betaId}\n:END:\n\nMentions [[Alpha]] and Bee again.\n`);
fs.writeFileSync(path.join(tmpDir, 'gamma.org2'), `#+TITLE: Gamma\n\n:PROPERTIES:\n:ID: ${gammaId}\n:END:\n\n#+begin_src bash\necho '[[Alpha]] should stay ignored here'\n#+end_src\n\n: [[Beta]] also ignored here\n`);
fs.writeFileSync(path.join(tmpDir, 'delta.org2'), `#+TITLE: Delta\n\n:PROPERTIES:\n:ID: ${deltaId}\n:END:\n\nNo links.\n`);

const json = JSON.parse(execFileSync('node', [cli, 'roam', 'graph', '--dir', tmpDir, '--recursive', '--format', 'json'], { encoding: 'utf8' }));
assert.equal(json.action, 'graph');
assert.equal(json.nodeCount, 4);
assert.equal(json.edgeCount, 3);
assert.equal(json.nodes[0].label, 'Alpha');
assert.ok(json.nodes.some((node) => node.label === 'Delta' && node.degree === 0));
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

console.log('✓ roam-graph');
