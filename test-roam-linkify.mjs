import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const repo = path.dirname(fileURLToPath(import.meta.url));
const cli = path.join(repo, 'dist', 'cli.js');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-roam-linkify-'));

const alphaId = '11111111-1111-1111-1111-111111111111';
const gammaId = '22222222-2222-2222-2222-222222222222';
const deltaId = '33333333-3333-3333-3333-333333333333';
const databricksId = '44444444-4444-4444-4444-444444444444';
const sonatypeId = '55555555-5555-5555-5555-555555555555';
const rdId = '66666666-6666-6666-6666-666666666666';

fs.writeFileSync(path.join(tmpDir, 'alpha.org2'), `#+TITLE: Alpha Topic\n\n:PROPERTIES:\n:ID: ${alphaId}\n:END:\n\nAlpha Topic stands alone here.\n`);
fs.writeFileSync(path.join(tmpDir, 'delta.org2'), `#+TITLE: Delta Topic\n#+ROAM_ALIASES: D Topic\n\n:PROPERTIES:\n:ID: ${deltaId}\n:END:\n\n`);
fs.writeFileSync(path.join(tmpDir, 'databricks.org2'), `#+TITLE: Databricks\n\n:PROPERTIES:\n:ID: ${databricksId}\n:END:\n\n`);
fs.writeFileSync(path.join(tmpDir, 'rd.org2'), `#+TITLE: Research & Development\n\n:PROPERTIES:\n:ID: ${rdId}\n:END:\n\n`);
fs.writeFileSync(path.join(tmpDir, 'sonatype.org2'), `#+TITLE: Sonatype\n\n:PROPERTIES:\n:ID: ${sonatypeId}\n:END:\n\n`);
fs.writeFileSync(path.join(tmpDir, 'notes.org2'), `#+TITLE: Notes\n\n* TODO Delta Topic follow-up\n\nWe discussed Alpha Topic yesterday.\nAlpha Topic came up twice.\nD Topic is shorthand.\nDatabricks and Sonatype both came up.\nDatabricks came up twice.\nResearch and Development joined too.\n[[Alpha Topic]] already linked.\n: Databricks inside fixed-width should stay plain.\nQuoted string: "Databricks" should stay plain.\nShell string: 'Sonatype' should stay plain.\nInline code =Databricks= should stay plain.\nInline verbatim ~Sonatype~ should stay plain.\nURL https://databricks.example.com/sonatype should stay plain.\n\n* Backlinks\n- Databricks should stay plain here.\n- Sonatype should stay plain here too.\n\n#+begin_quote\nDatabricks inside quote block should stay plain.\n#+end_quote\n\n#+begin_src text\nAlpha Topic inside code should stay plain.\n#+end_src\n`);
fs.writeFileSync(path.join(tmpDir, 'ambiguous.org2'), `#+TITLE: Alpha Topic\n\n:PROPERTIES:\n:ID: ${gammaId}\n:END:\n\nA duplicate node title exists here.\n`);

const preview = JSON.parse(execFileSync('node', [cli, 'roam', 'linkify', '--dir', tmpDir, '--recursive', '--format', 'json'], { encoding: 'utf8' }));
assert.equal(preview.action, 'linkify');
assert.equal(preview.changedFileCount, 1);
assert.equal(preview.replacementCount, 6);
assert.ok(preview.ambiguousSkipCount >= 1);
const notesReport = preview.files.find((entry) => entry.file.endsWith('notes.org2'));
assert.ok(notesReport.debugMatches.some((entry) => entry.reason.includes('alias') && entry.confidence === 'high' && entry.ranges.length > 0));
assert.ok(notesReport.debugAmbiguous.some((entry) => entry.confidence === 'low' && entry.ranges.length > 0));

const singleFilePreview = JSON.parse(execFileSync('node', [cli, 'roam', 'linkify', '--dir', tmpDir, '--recursive', '--file', path.join(tmpDir, 'notes.org2'), '--format', 'json'], { encoding: 'utf8' }));
assert.equal(singleFilePreview.scanned, 1);
assert.equal(singleFilePreview.indexFileCount, 7);
assert.equal(singleFilePreview.changedFileCount, 1);
assert.equal(singleFilePreview.replacementCount, 6);

execFileSync('node', [cli, 'roam', 'linkify', '--dir', tmpDir, '--recursive', '--file', path.join(tmpDir, 'notes.org2'), '--apply', '--format', 'json'], { encoding: 'utf8' });

const notes = fs.readFileSync(path.join(tmpDir, 'notes.org2'), 'utf8');
assert.match(notes, /\* TODO \[\[id:33333333-3333-3333-3333-333333333333\]\[Delta Topic\]\] follow-up/);
assert.match(notes, /We discussed Alpha Topic yesterday\./);
assert.match(notes, /Alpha Topic came up twice\./);
assert.match(notes, /\[\[id:33333333-3333-3333-3333-333333333333\]\[D Topic\]\] is shorthand\./);
assert.match(notes, /\[\[id:44444444-4444-4444-4444-444444444444\]\[Databricks\]\] and \[\[id:55555555-5555-5555-5555-555555555555\]\[Sonatype\]\] both came up\./);
assert.match(notes, /\[\[id:44444444-4444-4444-4444-444444444444\]\[Databricks\]\] came up twice\./);
assert.match(notes, /\[\[id:66666666-6666-6666-6666-666666666666\]\[Research and Development\]\] joined too\./);
assert.match(notes, /\[\[Alpha Topic\]\] already linked\./);
assert.match(notes, /: Databricks inside fixed-width should stay plain\./);
assert.match(notes, /Quoted string: "Databricks" should stay plain\./);
assert.match(notes, /Shell string: 'Sonatype' should stay plain\./);
assert.match(notes, /Inline code =Databricks= should stay plain\./);
assert.match(notes, /Inline verbatim ~Sonatype~ should stay plain\./);
assert.match(notes, /URL https:\/\/databricks\.example\.com\/sonatype should stay plain\./);
assert.match(notes, /#\+begin_quote\nDatabricks inside quote block should stay plain\.\n#\+end_quote/);
assert.match(notes, /#\+begin_src text\nAlpha Topic inside code should stay plain\./);
assert.match(notes, /\* Backlinks\n- Databricks should stay plain here\.\n- Sonatype should stay plain here too\./);

const inserted = path.join(tmpDir, 'inserted.org2');
fs.writeFileSync(inserted, 'hello world\n');
const insertResult = JSON.parse(execFileSync('node', [
  cli,
  'roam', 'link', 'insert-backlink',
  '--file', inserted,
  '--pos', '1:6',
  '--title', 'Delta Topic',
  '--style', 'id',
  '--id', deltaId,
  '--apply',
  '--format', 'json',
], { encoding: 'utf8' }));
assert.equal(insertResult.action, 'link-insert-backlink');
assert.equal(insertResult.changed, true);
assert.equal(fs.readFileSync(inserted, 'utf8'), `hello [[id:${deltaId}][Delta Topic]]world\n`);

console.log('✓ roam-linkify');
