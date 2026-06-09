import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-archive-provenance-'));
const source = path.join(tmp, 'notes.org2');
fs.writeFileSync(source, `* Project
** TODO Archive me
:PROPERTIES:
:ID: task-123
:END:
SCHEDULED: <2026-01-21 Wed>
Body.
** TODO Keep me
`);

const env = { ...process.env, ORG2_ARCHIVED_AT: '2026-01-21T12:00:00.000Z' };
const previewRaw = execFileSync('node', ['dist/cli.js', 'archive', '--file', source, '--pos', '2', '--format', 'json'], {
  encoding: 'utf8',
  env,
});
const preview = JSON.parse(previewRaw);
assert.equal(preview.archivePath, `${source}_archive`);
assert.deepEqual(preview.provenance, {
  archivedAt: '2026-01-21T12:00:00.000Z',
  sourcePath: source,
  sourceLine: '2',
  originalId: 'task-123',
  headingPath: 'Project/TODO Archive me',
});
assert.match(preview.subtreeText, /:ARCHIVE_ORIGINAL_ID: task-123/);
assert.match(preview.diff, /:ARCHIVE_SOURCE_LINE: 2/);

execFileSync('node', ['dist/cli.js', 'archive', '--file', source, '--pos', '2', '--apply'], { encoding: 'utf8', env });
const archived = fs.readFileSync(`${source}_archive`, 'utf8');
const active = fs.readFileSync(source, 'utf8');
assert.match(archived, /^\*\* TODO Archive me/, 'new archive file should start with archived subtree, not blank lines');
assert.match(archived, /:ARCHIVED_AT: 2026-01-21T12:00:00.000Z/);
assert.match(archived, /:ARCHIVE_HEADING_PATH: Project\/TODO Archive me/);
assert.doesNotMatch(active, /Archive me/);
assert.match(active, /Keep me/);

const searchDefaultRaw = execFileSync('node', ['dist/cli.js', 'search', 'Archive me', '--dir', tmp, '--recursive', '--format', 'json'], { encoding: 'utf8' });
assert.equal(JSON.parse(searchDefaultRaw).results.length, 0, 'default search should exclude archive destinations');

const searchArchivedRaw = execFileSync('node', ['dist/cli.js', 'search', 'Archive me', '--dir', tmp, '--recursive', '--include-archives', '--format', 'json'], { encoding: 'utf8' });
assert.ok(JSON.parse(searchArchivedRaw).results.length >= 1, '--include-archives should make archive destinations searchable');

const agendaDefaultRaw = execFileSync('node', ['dist/cli.js', 'agenda', '--dir', tmp, '--recursive', '--from', '2026-01-21', '--to', '2026-01-21', '--format', 'json'], { encoding: 'utf8' });
assert.equal(JSON.parse(agendaDefaultRaw).days.flatMap((day) => day.items).length, 0, 'default agenda should exclude archive destinations');

const agendaArchivedRaw = execFileSync('node', ['dist/cli.js', 'agenda', '--dir', tmp, '--recursive', '--include-archives', '--from', '2026-01-21', '--to', '2026-01-21', '--format', 'json'], { encoding: 'utf8' });
assert.equal(JSON.parse(agendaArchivedRaw).days.flatMap((day) => day.items).length, 1, '--include-archives should make archive destinations available to agenda');

console.log('✓ archive provenance');
