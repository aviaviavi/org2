const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { resolveDocumentLinkAbbreviations, expandLinkAbbreviationTarget } = require('../linkAbbrev');

function mkDoc(filePath, text) {
  return {
    uri: { scheme: 'file', fsPath: filePath },
    getText: () => text,
  };
}

test('expands in-file #+LINK shortcode target (linear:APP-4675) to clickable URL', () => {
  const filePath = path.join(os.tmpdir(), `org2-link-abbrev-${Date.now()}-infile.org`);
  const doc = mkDoc(
    filePath,
    '#+LINK: linear https://linear.app/scarf/issue/%s\n* Test\n[[linear:APP-4675][APP-4675]]\n'
  );

  const abbreviations = resolveDocumentLinkAbbreviations(doc);
  const expanded = expandLinkAbbreviationTarget('linear:APP-4675', abbreviations);
  assert.equal(expanded, 'https://linear.app/scarf/issue/APP-4675');
});

test('expands project-config abbreviation from org2.json', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-link-abbrev-'));
  const nested = path.join(root, 'notes');
  fs.mkdirSync(nested, { recursive: true });
  const filePath = path.join(nested, 'test.org');

  fs.writeFileSync(
    path.join(root, 'org2.json'),
    JSON.stringify({ links: { abbreviations: { linear: 'https://linear.app/scarf/issue/%s' } } }),
    'utf8'
  );

  const doc = mkDoc(filePath, '* Test\n[[linear:APP-4675][APP-4675]]\n');
  const abbreviations = resolveDocumentLinkAbbreviations(doc);
  const expanded = expandLinkAbbreviationTarget('linear:APP-4675', abbreviations);
  assert.equal(expanded, 'https://linear.app/scarf/issue/APP-4675');
});
