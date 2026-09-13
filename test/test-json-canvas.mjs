import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { canonicalNoteTargets } from '../dist/canonicalNoteTargets.js';
import { parseJSONCanvas, applyJSONCanvasOperations, createJSONCanvas, editJSONCanvas, showJSONCanvas, exportJSONCanvas, canvasTargets } from '../dist/jsonCanvas.js';

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'org2-canvas-')));
const other = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'org2-canvas-export-')));
const file = path.join(root, 'boards', 'work.canvas');
const cli = fileURLToPath(new URL('../dist/cli.js', import.meta.url));
const id = '11111111-1111-4111-8111-111111111111';
const textNode = (id, x = 0) => ({ id, type: 'text', x, y: -20, width: 250, height: 180, text: 'Hello **Canvas**', color: '#012345', vendor: { folded: true } });
try {
  fs.mkdirSync(path.join(root, 'notes'));
  fs.mkdirSync(path.join(root, 'assets'));
  fs.writeFileSync(path.join(root, 'notes', 'project.org'), `#+TITLE: Project\n\n* Architecture\n:PROPERTIES:\n:ID: ${id}\n:END:\nShared source text.\n`);
  fs.writeFileSync(path.join(root, 'assets', 'pixel.png'), Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=', 'base64'));
  const original = {
    vendor: { viewport: [1, 2, 3], flags: { any: true } },
    nodes: [
      { id: 'group', type: 'group', x: -80, y: -50, width: 800, height: 400, label: 'Project', background: 'assets/pixel.png', backgroundStyle: 'repeat', extension: 1 },
      textNode('text'),
      { id: 'note', type: 'file', x: 320, y: 20, width: 240, height: 180, file: 'notes/project.org', subpath: `#id:${id}`, org2Ref: `id:${id}`, extra: ['retained'] },
      { id: 'image', type: 'file', x: 600, y: 50, width: 200, height: 180, file: 'assets/pixel.png' },
      { id: 'web', type: 'link', x: 20, y: 450, width: 200, height: 160, url: 'https://example.com/article', metadata: { original: true } },
      { id: 'future', type: 'future-kind', x: 300, y: 450, width: 100, height: 100, payload: { opaque: [1, 2] } },
    ],
    edges: [{ id: 'edge', fromNode: 'text', toNode: 'note', fromSide: 'right', toSide: 'left', fromEnd: 'none', toEnd: 'arrow', label: 'Source', color: '5', custom: { weight: 4 } }],
  };
  const inputText = JSON.stringify(original, null, '\t') + '\r\n';
  const preview = createJSONCanvas(root, file, false, inputText);
  assert.equal(preview.applied, false); assert.ok(!fs.existsSync(file));
  createJSONCanvas(root, file, true, inputText);
  assert.equal(fs.readFileSync(file, 'utf8'), inputText);
  assert.throws(() => createJSONCanvas(root, file, true), /already exists/);
  const first = showJSONCanvas(root, file);
  assert.deepEqual(first.document, original);
  assert.equal(first.resources.note.status, 'ready');
  assert.equal(first.resources.note.title, 'Architecture');
  assert.equal(first.resources.note.line, 3);
  assert.match(first.resources.note.text, /Shared source text/);
  assert.equal(first.resources.image.imageMime, 'image/png');
  assert.ok(first.resources.image.imageData);
  assert.equal(first.resources.web.url, 'https://example.com/article');
  assert.equal(first.resources.future.status, 'unsupported');
  assert.deepEqual(first.document.nodes.map(n => n.id), original.nodes.map(n => n.id));
  const targets = canvasTargets(root, 'architecture').targets;
  assert.equal(targets[0].org2Ref, `id:${id}`);
  assert.equal(targets[0].subpath, `#id:${id}`);
  fs.renameSync(path.join(root, 'notes', 'project.org'), path.join(root, 'notes', 'renamed.org'));
  const renamed = showJSONCanvas(root, file);
  assert.equal(renamed.resources.note.file, path.join(root, 'notes', 'renamed.org'));
  assert.equal(renamed.document.nodes.find(n => n.id === 'note').file, 'notes/project.org'); // preserve portable original field
  const operations = [
    { action: 'update-node', id: 'text', patch: { x: -450, y: 230, width: 340, height: 200, text: 'Updated text' } },
    { action: 'add-node', node: textNode('new', 900) },
    { action: 'add-edge', edge: { id: 'new-edge', fromNode: 'new', toNode: 'text', toEnd: 'none' } },
    { action: 'update-edge', id: 'edge', patch: { fromSide: 'bottom', toSide: 'top', label: 'Updated label' } },
  ];
  const editedPreview = editJSONCanvas(root, file, first.revision, operations);
  assert.equal(editedPreview.applied, false); assert.equal(fs.readFileSync(file, 'utf8'), inputText);
  const edited = JSON.parse(execFileSync('node', [cli, 'canvas', 'edit', '--dir', root, '--file', file, '--if-revision', first.revision, '--stdin', '--apply', '--json'], { input: JSON.stringify(operations), encoding: 'utf8' }));
  assert.equal(edited.applied, true);
  const changed = showJSONCanvas(root, file);
  assert.deepEqual(changed.document.vendor, original.vendor);
  assert.deepEqual(changed.document.nodes.find(n => n.id === 'text').vendor, { folded: true });
  assert.deepEqual(changed.document.edges.find(e => e.id === 'edge').custom, { weight: 4 });
  assert.deepEqual(changed.document.nodes.find(n => n.id === 'future'), original.nodes.find(n => n.id === 'future'));
  assert.equal(changed.document.nodes.find(n => n.id === 'text').x, -450);
  assert.equal(changed.document.nodes.find(n => n.id === 'text').width, 340);
  assert.throws(() => editJSONCanvas(root, file, first.revision, operations, true), /changed since/);
  assert.throws(() => editJSONCanvas(root, file, changed.revision, [{ action: 'add-node', node: textNode('text') }], true), /Duplicate/);
  assert.throws(() => editJSONCanvas(root, file, changed.revision, [{ action: 'update-node', id: 'text', patch: { id: 'oops' } }], true), /cannot be changed/);
  assert.throws(() => editJSONCanvas(root, file, changed.revision, [{ action: 'update-node', id: 'text', patch: { x: 1.5 } }], true), /integer/);
  assert.equal(showJSONCanvas(root, file).revision, changed.revision);
  fs.writeFileSync(file + '.lock', '{}');
  assert.throws(() => editJSONCanvas(root, file, changed.revision, [{ action: 'remove-edge', id: 'edge' }], true), /already being updated/);
  fs.unlinkSync(file + '.lock');
  const removed = applyJSONCanvasOperations(changed.document, [{ action: 'remove-node', id: 'text' }]);
  assert.ok(!removed.nodes.some(n => n.id === 'text'));
  assert.ok(!removed.edges.some(e => e.fromNode === 'text' || e.toNode === 'text'));
  assert.deepEqual(removed.vendor, original.vendor);
  const copy = path.join(other, 'export.canvas');
  exportJSONCanvas(root, file, copy);
  assert.ok(!fs.existsSync(copy));
  exportJSONCanvas(root, file, copy, true);
  assert.equal(fs.readFileSync(copy, 'utf8'), fs.readFileSync(file, 'utf8'));
  assert.throws(() => exportJSONCanvas(root, file, copy, true), /destination exists/);
  const imported = path.join(root, 'boards', 'import.canvas');
  execFileSync('node', [cli, 'canvas', 'import', '--dir', root, '--file', imported, '--from', copy, '--apply', '--json']);
  assert.equal(fs.readFileSync(imported, 'utf8'), fs.readFileSync(file, 'utf8'));
  createJSONCanvas(root, 'empty.canvas', true, '{"unknown":123}\n');
  assert.deepEqual(showJSONCanvas(root, 'empty.canvas').document, { unknown: 123 });
  assert.deepEqual(parseJSONCanvas('{}'), {});
  const grouped = applyJSONCanvasOperations(original, [{ action: "add-node", node: { id: "new-group", type: "group", x: 0, y: 0, width: 100, height: 100 } }]);
  assert.equal(grouped.nodes[0].id, "new-group");
  assert.deepEqual(grouped.nodes.slice(1).map(n => n.id), original.nodes.map(n => n.id));
  assert.throws(() => parseJSONCanvas('{"nodes":null}'), /nodes must be/);
  assert.throws(() => parseJSONCanvas(JSON.stringify({ nodes: [textNode('x'), textNode('x')] })), /Duplicate/);
  assert.throws(() => parseJSONCanvas(JSON.stringify({ nodes: [textNode('x')], edges: [{ id: 'e', fromNode: 'x', toNode: 'missing' }] })), /missing node/);
  assert.throws(() => parseJSONCanvas(JSON.stringify({ nodes: [{ ...textNode('x'), color: 'rgb(1,2,3)' }] })), /color/);
  assert.throws(() => parseJSONCanvas(JSON.stringify({ nodes: [{ ...textNode('x'), height: 0 }] })), /dimensions/);
  assert.throws(() => createJSONCanvas(root, path.join(other, 'escape.canvas'), true), /inside the active corpus/);
  assert.throws(() => createJSONCanvas(root, 'raw/work.canvas', true), /raw/);
  assert.throws(() => createJSONCanvas(root, '.org2/work.canvas', true), /hidden/);
  fs.symlinkSync(other, path.join(root, 'outside'));
  assert.throws(() => createJSONCanvas(root, 'outside/work.canvas', true), /symlinks/);
  fs.symlinkSync(path.join(other, "absent.canvas"), path.join(root, "dangling.canvas"));
  assert.throws(() => createJSONCanvas(root, "dangling.canvas", true), /symlinks/);
  assert.ok(fs.lstatSync(path.join(root, "dangling.canvas")).isSymbolicLink());
  fs.writeFileSync(path.join(root, "script.command"), "echo never executed\n");
  assert.throws(() => exportJSONCanvas(root, file, path.join(root, "raw", "copy.canvas"), true), /raw/);
  const foreign = { nodes: [
    { id: 'outside', type: 'file', x: 0, y: 0, width: 200, height: 200, file: '../outside.org' },
    { id: 'symlink', type: 'file', x: 220, y: 0, width: 200, height: 200, file: 'outside/export.canvas' },
    { id: 'bad-url', type: 'link', x: 450, y: 0, width: 200, height: 200, url: 'javascript:alert(1)' },
    { id: "executable", type: "file", x: 900, y: 0, width: 200, height: 200, file: "script.command" },
    { id: 'missing', type: 'file', x: 670, y: 0, width: 200, height: 200, file: 'missing.org' },
  ] };
  createJSONCanvas(root, 'foreign.canvas', true, JSON.stringify(foreign));
  const restricted = showJSONCanvas(root, 'foreign.canvas');
  assert.equal(restricted.resources.outside.status, 'missing');
  assert.equal(restricted.resources.symlink.status, 'missing');
  assert.equal(restricted.resources['bad-url'].status, 'unsupported');
  assert.equal(restricted.resources.missing.status, 'missing');
  assert.equal(restricted.resources.executable.status, 'unsupported');
  assert.equal(restricted.resources.executable.file, undefined);
  assert.deepEqual(restricted.document, foreign);
  const canonicalFile = path.join(root, 'notes', 'canonical.org');
  const canonicalText = [
    '#+TITLE: Canonical note', '#+begin_example', '#+ID: fake-file-id', ':PROPERTIES:', ':ID: fake-preamble-id', ':END:', '#+end_example',
    '* TODO Architecture plan', 'SCHEDULED: <2026-09-13 Sun>', ':PROPERTIES:', ':ID: canonical-heading', ':CUSTOM_ID: architecture-section', ':END:',
    'Before source.', '#+begin_src org', '* Forged heading', ':PROPERTIES:', `:ID: ${id}`, ':END:',
    '* Example only', ':PROPERTIES:', ':ID: fake-heading-id', ':END:', '#+begin_example', '#+end_example',
    'Opaque example content.', '#+end_src', 'After source.', '** Real child', 'Child prose.', '* Next real heading', 'Outside subtree.', '',
  ].join('\n');
  fs.writeFileSync(canonicalFile, canonicalText);
  const projected = canonicalNoteTargets(root, canonicalFile);
  const canonicalHeading = projected.find(target => target.id === 'canonical-heading');
  assert.deepEqual(projected.map(target => target.title), ['Canonical note', 'Architecture plan', 'Real child', 'Next real heading']);
  assert.equal(projected[0].id, null);
  assert.deepEqual(canonicalHeading.sourceRange, { startLine: 8, endLine: 30 });
  assert.equal(canonicalHeading.snippet, 'Before source. After source. Child prose.');
  assert.ok(!canvasTargets(root).targets.some(target => target.id?.startsWith('fake-')));
  assert.equal(canvasTargets(root, 'canonical-heading').targets[0].line, 8);
  assert.equal(showJSONCanvas(root, file).resources.note.status, 'ready'); // Example duplicate does not shadow the actual heading.
  const canonicalBoard = { nodes: [
    { id: 'stable', type: 'file', x: 0, y: 0, width: 250, height: 180, file: 'notes/canonical.org', org2Ref: 'id:canonical-heading' },
    { id: 'custom', type: 'file', x: 300, y: 0, width: 250, height: 180, file: 'notes/canonical.org', subpath: '#architecture-section' },
    { id: 'title', type: 'file', x: 600, y: 0, width: 250, height: 180, file: 'notes/canonical.org', subpath: '#Architecture plan' },
    { id: 'fake', type: 'file', x: 0, y: 220, width: 250, height: 180, file: 'notes/canonical.org', org2Ref: 'id:fake-heading-id' },
    { id: 'fake-subpath', type: 'file', x: 300, y: 220, width: 250, height: 180, file: 'notes/canonical.org', subpath: '#Forged heading' },
    { id: 'fake-file', type: 'file', x: 600, y: 220, width: 250, height: 180, file: 'notes/canonical.org', org2Ref: 'id:fake-file-id' },
  ] };
  createJSONCanvas(root, 'canonical.canvas', true, JSON.stringify(canonicalBoard));
  const canonicalPreview = showJSONCanvas(root, 'canonical.canvas');
  for (const key of ['stable', 'custom', 'title']) {
    assert.equal(canonicalPreview.resources[key].status, 'ready');
    assert.equal(canonicalPreview.resources[key].line, 8);
    assert.equal(canonicalPreview.resources[key].text, 'Before source. After source. Child prose.');
  }
  for (const key of ['fake', 'fake-subpath', 'fake-file']) assert.equal(canonicalPreview.resources[key].status, 'missing');
  // Discovery obeys the same local path boundary as resource resolution, including hidden files.
  for (const name of ['raw', '.state', 'private']) fs.mkdirSync(path.join(root, name), { recursive: true });
  for (const name of ['.hidden.org', '.state/hidden.org', 'raw/source.org', 'private/source.org']) {
    fs.copyFileSync(path.join(root, 'notes', 'renamed.org'), path.join(root, name));
  }
  fs.writeFileSync(path.join(root, 'org2.json'), JSON.stringify({ ignorePatterns: ['private/**'] }));
  const outsideNote = path.join(other, 'outside.org');
  fs.copyFileSync(path.join(root, 'notes', 'renamed.org'), outsideNote);
  fs.symlinkSync(outsideNote, path.join(root, 'notes', 'symlink.org'));
  const scopedTargets = canvasTargets(root).targets;
  assert.ok(scopedTargets.every(target => !target.file.split('/').some(part => part.startsWith('.') || ['raw', 'private', 'outside', 'symlink.org'].includes(part))));
  assert.equal(scopedTargets.filter(target => target.id === id).length, 1);
  assert.equal(showJSONCanvas(root, file).resources.note.status, 'ready');
  assert.equal(fs.readFileSync(canonicalFile, 'utf8'), canonicalText);
  fs.copyFileSync(path.join(root, 'notes', 'renamed.org'), path.join(root, 'notes', 'duplicate.org'));
  assert.equal(showJSONCanvas(root, file).resources.note.status, 'ambiguous');
  fs.unlinkSync(path.join(root, 'notes', 'duplicate.org'));
  fs.unlinkSync(path.join(root, 'notes', 'renamed.org'));
  assert.equal(showJSONCanvas(root, file).resources.note.status, 'missing');
  console.log('✓ Canvas canonical IDs, planning properties, true subtree ranges, example exclusion and scoped target discovery');
  console.log('✓ JSON Canvas validation, guarded spatial edits, stable source navigation, bounded local resources and lossless import/export');
} finally { fs.rmSync(root, { recursive: true, force: true }); fs.rmSync(other, { recursive: true, force: true }); }
