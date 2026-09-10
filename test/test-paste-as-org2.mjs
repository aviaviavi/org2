import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createPastePreview, serializePasteBlocks, literalPasteOrg, PastePreviewSession } from '../dist/pasteAsOrg2.js';
import { validatePasteModel, classifyPasteLines } from '../dist/pasteStructureClassifier.js';
import { parseOrgToCanonicalAst } from '../dist/parser.js';
const model = validatePasteModel(JSON.parse(fs.readFileSync('tools/paste-as-org2/model.json', 'utf8')));
const block = (text, label, extra = {}) => ({ text, label, origin: 'html', ...extra });
const ast = text => parseOrgToCanonicalAst(text);
const types = node => [node.type, ...(node.children ?? []).flatMap(types), ...(node.items ?? []).flatMap(types)];
const source = 'Crêpes 🍐\r\n1½ cups flour\r250 ml milk\n\t1/8 tsp salt\n\nBake at 180°C for 20–25 min.\n';
for (const chosenModel of [undefined, model]) {
  const preview = createPastePreview({ text: source, model: chosenModel, sourceUrl: 'https://example.test/recipe?q=½#method' });
  assert.equal(preview.originalText, source);
  assert.equal(preview.blocks.map(block => source.slice(block.sourceStart, block.sourceEnd)).join(''), source);
  for (const item of preview.blocks) if (item.text) assert.ok(preview.org.includes(item.text), item.text);
  assert.ok(preview.org.includes('[[https://example.test/recipe?q=½#method]]'));
  assert.equal(ast(preview.org).type, 'Document');
}
// Stable source coverage over CR, LF, CRLF, blank, whitespace, Unicode and delimiters.
let seed = 123;
for (let i = 0; i < 250; i++) {
  seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
  const chunks = ['', '  ', '\r', '\n', '\r\n', '½', '2.50', '* TODO', '#+end_src', '[[file:x]]', '🍲'];
  const text = Array.from({ length: i % 13 }, (_, j) => chunks[(seed + j * 7) % chunks.length]).join('');
  const preview = createPastePreview({ text });
  assert.equal(preview.blocks.map(block => text.slice(block.sourceStart, block.sourceEnd)).join(''), text);
  assert.equal(ast(preview.org).type, 'Document');
}
const dangerous = '#+end_example\n#+begin_src shell\n* TODO do not run\n:PROPERTIES:\n:END:\n[[file:private.txt]]\n{{{macro}}}';
const literal = literalPasteOrg(dangerous);
assert.deepEqual(ast(literal).children[0].lines.map(line => line.valueRaw), dangerous.split('\n'));
assert.ok(!types(ast(literal)).includes('Headline'));
for (const label of ['paragraph', 'quote', 'code', 'heading']) {
  const org = serializePasteBlocks([block(dangerous, label)]);
  assert.ok(!types(ast(org)).some(type => ['SrcBlock', 'Headline', 'Keyword', 'Drawer'].includes(type)));
}
assert.equal(ast(serializePasteBlocks([block('Title', 'heading')])).children[0].type, 'Headline');
assert.ok(types(ast(serializePasteBlocks([block('3. 1/2 tsp salt', 'list')]))).includes('List'));
const tableOrg = serializePasteBlocks([block('Name\tAmount', 'table', { cells: ['Name', 'Amount'] }), block('Oil\t2 tbsp', 'table', { cells: ['Oil', '2 tbsp'] })]);
assert.equal(ast(tableOrg).children.length, 1);
assert.ok(types(ast(tableOrg)).some(type => /Table/.test(type)));
assert.equal(serializePasteBlocks([block('A|B\t2', 'table', { cells: ['A|B', '2'] })]), ': A|B\t2');
assert.equal(serializePasteBlocks([block('1/2 tsp salt', 'code')]), ': 1/2 tsp salt');
assert.equal(serializePasteBlocks([block('TODO buy 2 eggs', 'heading')]), ': TODO buy 2 eggs');
assert.equal(serializePasteBlocks([block('COMMENT keep this', 'heading')]), ': COMMENT keep this');
assert.equal(serializePasteBlocks([block('[ ] ingredient quantity', 'list')]), ': [ ] ingredient quantity');
assert.equal(serializePasteBlocks([block('Maybe a title', 'heading', { origin: 'fallback' })]), ': Maybe a title');
assert.match(serializePasteBlocks([], ['javascript:alert(1)']), /^: javascript:/);
const semantic = { blocks: [block('2.5 g salt', 'list')], links: ['https://example.test/source'], warnings: [] };
const htmlPreview = createPastePreview({ text: 'unrelated fallback', html: '<li>2.5 g salt</li>', semantic, model: {} });
assert.equal(htmlPreview.blocks[0].origin, 'html'); // Model is bypassed for DOM structure.
assert.equal(htmlPreview.originalHtml, '<li>2.5 g salt</li>');
assert.ok(createPastePreview({ text: 'Label', semantic: { blocks: [], links: ['https://example.test/label'], warnings: [] } }).org.includes('https://example.test/label'));
assert.throws(() => validatePasteModel({ ...model, weights: [0] }), /invalid/);
assert.throws(() => validatePasteModel({ ...model, weights: model.weights.map(() => NaN) }), /invalid/);
assert.throws(() => createPastePreview({ text: 'x'.repeat(200001) }), /limit/);
assert.deepEqual(classifyPasteLines(['Ingredients', '2 cups oats'], model), classifyPasteLines(['Ingredients', '2 cups oats'], model));
const session = new PastePreviewSession();
assert.throws(() => session.insert('x'), /Preview required/);
const preview = createPastePreview({ text: '2.5 g salt' });
session.begin(preview, 'before SELECT after', 7, 13);
assert.throws(() => session.insert('changed'), /Document changed/);
session.editedOrg = '- 2.5 g salt';
assert.equal(session.insert('before SELECT after'), 'before - 2.5 g salt after');
assert.throws(() => session.insert('again'), /Preview required/);
session.begin(preview, 'keep', 4, 4); session.cancel();
assert.throws(() => session.insert('keep'), /Preview required/);
assert.throws(() => session.begin(preview, 'keep', 0, 20), /Invalid/);
// Reviewed export interoperates with the existing preview-first capture surface.
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-paste-test-'));
try {
  const destination = path.join(temporary, 'capture.org');
  const result = JSON.parse(execFileSync(process.execPath, ['dist/cli.js', 'capture', '--stdin', '--to', destination, '--title', 'Reviewed paste', '--format', 'json'], { encoding: 'utf8', input: preview.org }));
  assert.equal(result.body, preview.org);
  assert.equal(fs.existsSync(destination), false);
} finally { fs.rmSync(temporary, { recursive: true, force: true }); }
const report = JSON.parse(fs.readFileSync('tools/paste-as-org2/evaluation.json', 'utf8'));
const sha = value => createHash('sha256').update(value).digest('hex');
assert.equal(report.modelSha256, sha(fs.readFileSync('tools/paste-as-org2/model.json')));
assert.equal(report.datasetSha256, sha(fs.readFileSync('test/fixtures/paste-as-org2/documents.json')));
console.log('PASS: source coverage (250 cases), quantities/Unicode, literal safety, Org parser, semantic priority, model validation, preview/edit/cancel/stale target, capture compatibility, measured artifact hashes.');
