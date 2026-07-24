import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileCorpus, compileCorpusIncremental } from '../dist/corpusCompile.js';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-incremental-'));
const cache = path.join(tmp, '.org2', 'corpus-index-cache.json');
const a = path.join(tmp, 'a.org2');
const b = path.join(tmp, 'b.org2');
fs.writeFileSync(a, '#+TITLE: Alpha\n:PROPERTIES:\n:ID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n:END:\n\n* TODO First :work:\nSCHEDULED: <2026-05-20 Wed>\n[[Beta]]\n');
fs.writeFileSync(b, '#+TITLE: Beta\n:PROPERTIES:\n:ID: bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\n:END:\n\n* Second\n[[id:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa]]\n');
const full = compileCorpus([a, b], { rootDir: tmp, generatedAt: '2026-05-20T00:00:00.000Z' });
const first = compileCorpusIncremental([a, b], { rootDir: tmp, cacheFile: cache, generatedAt: '2026-05-20T00:00:00.000Z' });
assert.equal(first.indexState.status, 'fresh');
assert.equal(first.indexState.parsedFiles, 2);
assert.equal(first.indexState.reusedFiles, 0);
assert.equal(first.stats.nodes, full.stats.nodes);
assert.deepEqual(first.nodes.map((n) => n.key), full.nodes.map((n) => n.key));
assert.ok(first.index.ids['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'].length >= 1);
assert.ok(first.index.tags.work.length >= 1);
assert.ok(first.index.dates['2026-05-20'].length >= 1);
const second = compileCorpusIncremental([a, b], { rootDir: tmp, cacheFile: cache, generatedAt: '2026-05-20T00:00:00.000Z' });
assert.equal(second.indexState.status, 'fresh');
assert.equal(second.indexState.reusedFiles, 2);
assert.equal(second.indexState.parsedFiles, 0);
assert.deepEqual(second.nodes.map((n) => n.key), first.nodes.map((n) => n.key));
assert.equal(fs.existsSync(`${cache}.v8`), true);
fs.writeFileSync(a, '#+TITLE: Alpha changed\n:PROPERTIES:\n:ID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n:END:\n\n* TODO Changed :work:\nSCHEDULED: <2026-05-21 Thu>\n[[Beta]]\n');
const changed = compileCorpusIncremental([a, b], { rootDir: tmp, cacheFile: cache });
assert.equal(changed.indexState.status, 'fresh');
assert.equal(changed.indexState.parsedFiles, 1);
assert.equal(changed.indexState.reusedFiles, 1);
assert.ok(changed.nodes.some((n) => n.title === 'Changed'));
const changedFull = compileCorpus([a, b], { rootDir: tmp });
for (const field of [
  'files',
  'nodes',
  'stats',
  'entities',
  'entityProfiles',
  'relations',
  'clocks',
  'clockIssues',
  'checkboxProgress',
  'checkboxIssues',
  'clockSummary',
  'effortSummary',
  'index',
]) {
  assert.deepEqual(changed[field], changedFull[field], `incremental ${field} differs from full compile`);
}
fs.unlinkSync(b);
const deleted = compileCorpusIncremental([a], { rootDir: tmp, cacheFile: cache });
assert.equal(deleted.indexState.deletedFiles, 1);
assert.equal(deleted.indexState.parsedFiles, 0);
assert.equal(deleted.indexState.reusedFiles, 1);
assert.equal(deleted.stats.files, 1);
assert.ok(!deleted.files.some((file) => file.file === 'b.org2'));
const deletedFull = compileCorpus([a], { rootDir: tmp });
assert.deepEqual(deleted.nodes, deletedFull.nodes);
assert.deepEqual(deleted.stats, deletedFull.stats);
console.log('✓ incremental-corpus');
