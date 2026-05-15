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
const excludedId = '66666666-6666-6666-6666-666666666666';
const rdId = '77777777-7777-7777-7777-777777777777';
const llmId = '88888888-8888-8888-8888-888888888888';
const archivedId = '99999999-9999-9999-9999-999999999999';

fs.writeFileSync(path.join(tmpDir, 'alpha.org2'), `#+TITLE: Alpha Topic\n\n:PROPERTIES:\n:ID: ${alphaId}\n:END:\n\nAlpha Topic stands alone here.\n`);
fs.writeFileSync(path.join(tmpDir, 'delta.org2'), `#+TITLE: Delta Topic\n#+ROAM_ALIASES: D Topic\n\n:PROPERTIES:\n:ID: ${deltaId}\n:END:\n\n`);
fs.writeFileSync(path.join(tmpDir, 'databricks.org2'), `#+TITLE: Databricks\n\n:PROPERTIES:\n:ID: ${databricksId}\n:END:\n\n`);
fs.writeFileSync(path.join(tmpDir, 'rd.org2'), `#+TITLE: Research & Development\n\n:PROPERTIES:\n:ID: ${rdId}\n:END:\n\n`);
fs.writeFileSync(path.join(tmpDir, 'sonatype.org2'), `#+TITLE: Sonatype\n\n:PROPERTIES:\n:ID: ${sonatypeId}\n:END:\n\n`);
fs.mkdirSync(path.join(tmpDir, 'agents'));
fs.mkdirSync(path.join(tmpDir, 'archive'));
fs.writeFileSync(path.join(tmpDir, 'agents', 'private.org2'), `#+TITLE: Private Agent

:PROPERTIES:
:ID: ${excludedId}
:END:

`);
fs.writeFileSync(path.join(tmpDir, 'archive', 'archived.org2'), `#+TITLE: Archived Topic

:PROPERTIES:
:ID: ${archivedId}
:END:

`);
fs.writeFileSync(path.join(tmpDir, 'llm.org2'), `#+TITLE: Large Language Models
#+ROAM_ALIASES: "Generative AI Systems"

:PROPERTIES:
:ID: ${llmId}
:END:

`);
fs.writeFileSync(path.join(tmpDir, 'notes.org2'), `#+TITLE: Notes

* TODO Delta Topic follow-up

We discussed Alpha Topic yesterday.
Alpha Topic came up twice.
D Topic is shorthand.
Databricks and Sonatype both came up.
Databricks came up twice.
Research and Development joined too.
LLMs can summarize a paragraph.
Private Agent and Archived Topic should stay plain when excluded.
[[Alpha Topic]] already linked.
: Databricks inside fixed-width should stay plain.
Quoted string: "Databricks" should stay plain.
Shell string: 'Sonatype' should stay plain.
Inline code =Databricks= should stay plain.
Inline verbatim ~Sonatype~ should stay plain.
URL https://databricks.example.com/sonatype should stay plain.

* Backlinks
- Databricks should stay plain here.
- Sonatype should stay plain here too.

#+begin_quote
Databricks inside quote block should stay plain.
#+end_quote

#+begin_src text
Alpha Topic inside code should stay plain.
#+end_src
`);
fs.writeFileSync(path.join(tmpDir, 'ambiguous.org2'), `#+TITLE: Alpha Topic\n\n:PROPERTIES:\n:ID: ${gammaId}\n:END:\n\nA duplicate node title exists here.\n`);

const preview = JSON.parse(execFileSync('node', [cli, 'roam', 'linkify', '--dir', tmpDir, '--recursive', '--exclude', 'agents/', '--format', 'json'], { encoding: 'utf8' }));
assert.equal(preview.action, 'linkify');
assert.equal(preview.changedFileCount, 1);
assert.equal(preview.replacementCount, 7);
assert.ok(preview.ambiguousSkipCount >= 1);
const notesReport = preview.files.find((entry) => entry.file.endsWith('notes.org2'));
assert.ok(notesReport.debugMatches.some((entry) => entry.reason.includes('alias') && entry.confidence === 'high' && entry.ranges.length > 0));
assert.ok(notesReport.debugAmbiguous.some((entry) => entry.confidence === 'low' && entry.ranges.length > 0));

const singleFilePreview = JSON.parse(execFileSync('node', [cli, 'roam', 'linkify', '--dir', tmpDir, '--recursive', '--exclude', 'agents/', '--file', path.join(tmpDir, 'notes.org2'), '--format', 'json'], { encoding: 'utf8' }));
assert.equal(singleFilePreview.scanned, 1);
assert.equal(singleFilePreview.indexFileCount, 7);
assert.equal(singleFilePreview.excludedFileCount, 2);
assert.equal(singleFilePreview.changedFileCount, 1);
assert.equal(singleFilePreview.replacementCount, 7);

execFileSync('node', [cli, 'roam', 'linkify', '--dir', tmpDir, '--recursive', '--exclude', 'agents/', '--file', path.join(tmpDir, 'notes.org2'), '--apply', '--format', 'json'], { encoding: 'utf8' });

const notes = fs.readFileSync(path.join(tmpDir, 'notes.org2'), 'utf8');
assert.match(notes, /\* TODO \[\[id:33333333-3333-3333-3333-333333333333\]\[Delta Topic\]\] follow-up/);
assert.match(notes, /We discussed Alpha Topic yesterday\./);
assert.match(notes, /Alpha Topic came up twice\./);
assert.match(notes, /\[\[id:33333333-3333-3333-3333-333333333333\]\[D Topic\]\] is shorthand\./);
assert.match(notes, /\[\[id:44444444-4444-4444-4444-444444444444\]\[Databricks\]\] and \[\[id:55555555-5555-5555-5555-555555555555\]\[Sonatype\]\] both came up\./);
assert.match(notes, /\[\[id:44444444-4444-4444-4444-444444444444\]\[Databricks\]\] came up twice\./);
assert.match(notes, /\[\[id:66666666-6666-6666-6666-666666666666\]\[Research and Development\]\] joined too\./);
assert.match(notes, /\[\[id:77777777-7777-7777-7777-777777777777\]\[LLMs\]\] can summarize a paragraph\./);
assert.match(notes, /Archived Topic should not link from archived directories\./);
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


const excludedPreview = JSON.parse(execFileSync('node', [
  cli,
  'roam', 'linkify',
  '--dir', tmpDir,
  '--recursive',
  '--exclude', 'agents/',
  '--format', 'json',
], { encoding: 'utf8' }));
assert.equal(excludedPreview.indexFileCount, 7);
assert.equal(excludedPreview.excludedFileCount, 2);
const notesExcludedResult = excludedPreview.files.find((file) => file.file.endsWith('notes.org2'));
assert.ok(notesExcludedResult);
assert.equal(notesExcludedResult.debugMatches.some((match) => match.label === 'private agent'), false);
assert.equal(notesExcludedResult.debugMatches.some((match) => match.label === 'archived topic'), false);

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
