import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { readRoamConnections, linkRoamMention, localRoamNeighborhood } from '../dist/roamConnections.js';
import { guardedContentRevision } from '../dist/guardedFile.js';
import { applyRoamLinkifyToFile, buildRoamGraph, buildRoamLinkifyIndex, collectRoamNodesForIndex } from '../dist/roam.js';
import { parseOrgToCanonicalAst } from '../dist/parser.js';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-connections-'));
const cli = fileURLToPath(new URL('../dist/cli.js', import.meta.url));
const note = (file, id, title, body = '', aliases = '') => {
  fs.writeFileSync(path.join(root, file), `#+TITLE: ${title}\n#+ROAM_ALIASES: ${aliases}\n:PROPERTIES:\n:ID: ${id}\n:END:\n\n${body}`);
};
try {
  note('alpha.org', 'alpha-stable', 'Alpha Topic', '[[id:beta-stable][Beta Topic]]\n', 'Shared Alias');
  note('beta.org', 'beta-stable', 'Beta Topic', '[[Gamma Topic]]\n');
  note('gamma.org', 'gamma-stable', 'Gamma Topic', '', 'Shared Alias');
  note('source.org2', 'source-stable', 'Source', '[[id:alpha-stable][Alpha Topic]]\n');
  const source = path.join(root, 'mentions.org2');
  const original = '#+TITLE: Mentions\r\n\r\n😀 Alpha Topic and Alpha Topic. Shared Alias.\r\n'
    + '[[Alpha Topic]] =Alpha Topic= ~Alpha Topic~ "Alpha Topic" \'Alpha Topic\' https://example.test/Alpha Topic\r\n'
    + ': Alpha Topic\r\n#+begin_src text\r\nAlpha Topic\r\n#+end_src\r\n'
    + ':PROPERTIES:\r\n:NOTE: Alpha Topic\r\n:END:\r\n'
    + '* Backlinks\r\nAlpha Topic\r\n* Ordinary section\r\nAlpha Topic\r\n';
  fs.writeFileSync(source, original);
  note('headings.org2', 'headings-file', 'Headings', '* Nested target\n:PROPERTIES:\n:ID: nested-stable\n:END:\n[[id:alpha-stable][Alpha Topic]]\n* Next heading\nbody\n');
  fs.mkdirSync(path.join(root, 'raw'));
  note('raw/source.org', 'raw-stable', 'Raw capture', 'Alpha Topic\n');
  assert.throws(() => linkRoamMention(root, { file: path.join(root, 'raw/source.org'), mention: 'any', target: 'alpha-stable', revision: 'any', apply: true }), /immutable/);
  fs.mkdirSync(path.join(root, 'archive'));
  note('archive/old.org', 'old-stable', 'Old', 'Alpha Topic\n');
  fs.mkdirSync(path.join(root, 'private'));
  note('private/hidden.org', 'hidden-stable', 'Hidden', 'Alpha Topic\n');
  fs.writeFileSync(path.join(root, 'org2.json'), JSON.stringify({ ignorePatterns: ['private/**'] }));
  const data = readRoamConnections(root, { id: 'alpha-stable' });
  assert.equal(data.$schema, 'org2:connections:v1');
  assert.deepEqual(new Set(data.neighborhood.nodes.map(n => n.id)), new Set(['alpha-stable', 'beta-stable', 'source-stable', 'nested-stable']));
  assert.ok(data.neighborhood.edges.some(e => e.source === 'source-stable' && e.target === 'alpha-stable'));
  assert.ok(!data.neighborhood.nodes.some(n => n.id === 'gamma-stable'));
  const depthTwo = readRoamConnections(root, { id: 'alpha-stable', depth: 2 });
  assert.ok(depthTwo.neighborhood.nodes.some(n => n.id === 'gamma-stable'));
  const heading = readRoamConnections(root, { file: path.join(root, 'headings.org2'), line: 11 });
  assert.equal(heading.neighborhood.focus.id, 'nested-stable');
  assert.equal(heading.neighborhood.focus.line, 7);
  const afterHeading = readRoamConnections(root, { file: path.join(root, 'headings.org2'), line: 13 });
  assert.equal(afterHeading.neighborhood.focus.id, 'headings-file');
  assert.equal(readRoamConnections(root, { id: 'missing' }).neighborhood, null);
  assert.equal(data.mentions.filter(m => m.text === 'Alpha Topic').length, 3);
  assert.ok(data.mentions.every(m => m.file === source));
  const first = data.mentions.find(m => m.text === 'Alpha Topic');
  assert.equal(first.line, 3);
  assert.equal(first.start, 3); // UTF-16 offset preserves emoji.
  assert.equal(first.revision, guardedContentRevision(original));
  const ambiguous = data.mentions.find(m => m.ambiguous);
  assert.equal(ambiguous.text, 'Shared Alias');
  assert.deepEqual(ambiguous.candidates.map(c => c.label).sort(), ['Alpha Topic', 'Gamma Topic']);
  assert.throws(() => linkRoamMention(root, { file: source, mention: first.id, target: 'beta-stable', revision: first.revision, apply: true }), /Mention or target changed/);
  const preview = linkRoamMention(root, { file: source, mention: first.id, target: 'alpha-stable', revision: first.revision });
  assert.equal(preview.applied, false);
  assert.equal(fs.readFileSync(source, 'utf8'), original);
  const applied = JSON.parse(execFileSync('node', [cli, 'roam', 'mention-link', '--dir', root, '--file', source, '--mention', first.id, '--target', 'alpha-stable', '--if-revision', first.revision, '--apply', '--json'], { encoding: 'utf8' }));
  assert.equal(applied.applied, true);
  const expected = original.replace('😀 Alpha Topic', '😀 [[id:alpha-stable][Alpha Topic]]');
  assert.equal(fs.readFileSync(source, 'utf8'), expected);
  assert.throws(() => linkRoamMention(root, { file: source, mention: ambiguous.id, target: 'gamma-stable', revision: ambiguous.revision, apply: true }), /source changed/);
  const refreshed = readRoamConnections(root, { id: 'alpha-stable' });
  const shared = refreshed.mentions.find(m => m.ambiguous);
  linkRoamMention(root, { file: source, mention: shared.id, target: 'gamma-stable', revision: shared.revision, apply: true });
  assert.match(fs.readFileSync(source, 'utf8'), /\[\[id:gamma-stable\]\[Shared Alias\]\]/);
  const staleTarget = readRoamConnections(root, { id: 'alpha-stable' }).mentions.find(m => m.text === 'Alpha Topic');
  note('alpha.org', 'renamed-stable', 'Renamed');
  assert.throws(() => linkRoamMention(root, { file: source, mention: staleTarget.id, target: 'alpha-stable', revision: staleTarget.revision, apply: true }), /Mention or target changed/);
  note('alpha.org', 'alpha-stable', 'Alpha Topic');
  note('duplicate.org', 'alpha-stable', 'Duplicate Alpha');
  const dup = readRoamConnections(root, { id: 'alpha-stable' }).mentions.find(m => m.text === 'Alpha Topic');
  assert.throws(() => linkRoamMention(root, { file: source, mention: dup.id, target: 'alpha-stable', revision: dup.revision, apply: true }), /duplicated/);
  fs.unlinkSync(path.join(root, 'duplicate.org'));
  fs.writeFileSync(source, 'Alpha Topic\n');
  const beforeLock = readRoamConnections(root, { id: 'alpha-stable' }).mentions[0];
  fs.writeFileSync(source + '.lock', '{}');
  assert.throws(() => linkRoamMention(root, { file: source, mention: beforeLock.id, target: 'alpha-stable', revision: beforeLock.revision, apply: true }), /already being updated/);
  assert.equal(fs.readFileSync(source, 'utf8'), 'Alpha Topic\n');
  fs.unlinkSync(source + '.lock');
  const outside = path.join(os.tmpdir(), `org2-outside-${process.pid}.org`);
  fs.writeFileSync(outside, 'Alpha Topic\n');
  try {
    fs.symlinkSync(outside, path.join(root, 'symlink.org'));
    assert.ok(!readRoamConnections(root, { id: 'alpha-stable' }).mentions.some(m => m.file.endsWith('symlink.org')));
    assert.throws(() => linkRoamMention(root, { file: outside, mention: beforeLock.id, target: 'alpha-stable', revision: beforeLock.revision, apply: true }), /inside the active corpus/);
  } finally { fs.unlinkSync(outside); }
  const nodes = Array.from({ length: 100 }, (_, i) => ({ id: `${i}`, label: `${i}`, file: source, line: 1, lineEnd: 1, degree: 1, degreeIn: 0, degreeOut: 1 }));
  const edges = nodes.slice(1).map(n => ({ source: '0', target: n.id, count: 1 }));
  const bounded = localRoamNeighborhood({ nodes, edges }, '0', 2);
  assert.equal(bounded.nodes.length, 60);
  assert.equal(bounded.truncated, true);
  assert.throws(() => localRoamNeighborhood({ nodes, edges }, '0', 3), /depth/);
  fs.writeFileSync(source, Array(205).fill('Alpha Topic').join('\n'));
  const limited = readRoamConnections(root, { id: 'alpha-stable' });
  assert.equal(limited.mentions.length, 200);
  assert.equal(limited.mentionsTruncated, true);
  const cliRead = JSON.parse(execFileSync('node', [cli, 'roam', 'connections', '--dir', root, '--id', 'alpha-stable', '--depth', '2', '--format', 'json'], { encoding: 'utf8' }));
  assert.equal(cliRead.neighborhood.focus.id, 'alpha-stable');
  // Canonical syntax is the authority for targets, source ownership, and safe edit spans.
  const canonicalRoot = path.join(root, 'canonical-structure');
  fs.mkdirSync(canonicalRoot);
  const canonicalTarget = path.join(canonicalRoot, 'target.org');
  fs.writeFileSync(canonicalTarget, '#+TITLE: Alpha\n#+ID: alpha-canonical\n');
  const canonicalFile = path.join(canonicalRoot, 'source.org');
  const canonicalOriginal = [
    '#+TITLE: Protected source', '#+ID: protected-source',
    '#+begin_src org', '#+begin_example', '#+end_example', 'Alpha',
    '[[id:alpha-canonical][Alpha]]', '* Fake Topic', ':PROPERTIES:', ':ID: fake-heading-id', ':END:', '#+end_src',
    '#+begin_example', '#+ID: fake-file-id', ':PROPERTIES:', ':ID: alpha-canonical', ':END:', '#+end_example',
    '  : Alpha [[id:alpha-canonical][Alpha]]',
    '* TODO [#A] Alpha :Alpha:', 'SCHEDULED: <2026-09-13 Sun>', ':PROPERTIES:', ':ID: planned-id',
    ':ROAM_ALIASES: Planned Alias', ':END:', 'Alpha', '[[id:alpha-canonical][Alpha]]', '* Next heading', 'body', '',
  ].join('\n');
  fs.writeFileSync(canonicalFile, canonicalOriginal);
  const canonicalNodes = collectRoamNodesForIndex(canonicalOriginal, canonicalFile, true);
  assert.deepEqual(canonicalNodes.map(node => node.id), ['protected-source', 'planned-id']);
  const plannedLine = canonicalOriginal.split('\n').indexOf('* TODO [#A] Alpha :Alpha:') + 1;
  assert.equal(readRoamConnections(canonicalRoot, { file: canonicalFile, line: plannedLine + 6 }).neighborhood.focus.id, 'planned-id');
  assert.equal(readRoamConnections(canonicalRoot, { id: 'fake-heading-id' }).neighborhood, null);
  assert.equal(readRoamConnections(canonicalRoot, { id: 'fake-file-id' }).neighborhood, null);
  const graph = buildRoamGraph([canonicalTarget, canonicalFile]);
  assert.deepEqual(graph.edges, [{ source: 'planned-id', target: 'alpha-canonical', count: 1 }]);
  const canonicalIndex = buildRoamLinkifyIndex([canonicalTarget, canonicalFile]);
  assert.equal(canonicalIndex.get('planned alias')[0].id, 'planned-id');
  // The target label must differ from this file's heading title, which suppresses self-mentions.
  const protectedSource = canonicalOriginal.replace('* TODO [#A] Alpha :Alpha:', '* TODO [#A] Review Alpha :Alpha:');
  fs.writeFileSync(canonicalFile, protectedSource);
  const canonicalData = readRoamConnections(canonicalRoot, { id: 'alpha-canonical' });
  const canonicalMentions = canonicalData.mentions.filter(mention => mention.file === canonicalFile);
  assert.deepEqual(canonicalMentions.map(mention => mention.line), [plannedLine, plannedLine + 6]);
  const titleMention = canonicalMentions[0];
  assert.equal(titleMention.start, '* TODO [#A] Review '.length);
  assert.equal(titleMention.text, 'Alpha');
  // Reconstructing an old/forged occurrence cannot bypass the canonical source protection.
  for (const [line, start] of [[6, 0], [19, 4], [plannedLine, '* TODO [#A] Review Alpha :'.length]]) {
    const mentionID = guardedContentRevision(`${canonicalFile}\n${line}:${start}:${start + 5}:alpha`).slice(7);
    assert.throws(() => linkRoamMention(canonicalRoot, {
      file: canonicalFile, mention: mentionID, target: 'alpha-canonical', revision: titleMention.revision, apply: true,
    }), /Mention or target changed/);
    assert.equal(fs.readFileSync(canonicalFile, 'utf8'), protectedSource);
  }
  const changedTitle = linkRoamMention(canonicalRoot, {
    file: canonicalFile, mention: titleMention.id, target: 'alpha-canonical', revision: titleMention.revision, apply: true,
  });
  const expectedTitle = protectedSource.replace('Review Alpha :Alpha:', 'Review [[id:alpha-canonical][Alpha]] :Alpha:');
  assert.equal(changedTitle.preview, expectedTitle);
  assert.equal(fs.readFileSync(canonicalFile, 'utf8'), expectedTitle);
  const changedHeading = parseOrgToCanonicalAst(expectedTitle).children.find(node => node.type === 'Headline');
  assert.deepEqual(changedHeading.tags, ['Alpha']);
  assert.equal(changedHeading.todo, 'TODO');
  assert.equal(changedHeading.priority, 'A');
  const bulk = applyRoamLinkifyToFile(protectedSource, canonicalFile, canonicalIndex);
  assert.equal(bulk.replacements, 2);
  assert.equal(bulk.outText, expectedTitle.replace(':END:\nAlpha\n[[id:alpha-canonical]', ':END:\n[[id:alpha-canonical][Alpha]]\n[[id:alpha-canonical]'));
  console.log('✓ local graph, exact mentions, explicit ambiguity, guarded links, CRLF/UTF-16, corpus boundaries and bounds');
  console.log('✓ canonical targets, planned heading ownership, nested block markers, indented fixed width and heading metadata');
} finally { fs.rmSync(root, { recursive: true, force: true }); }
