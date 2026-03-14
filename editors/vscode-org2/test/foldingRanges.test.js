const test = require('node:test');
const assert = require('node:assert/strict');

const { findPropertyDrawerStartLines, provideFoldingRanges } = require('../foldingRanges');

function makeDoc(lines) {
  return {
    lineCount: lines.length,
    lineAt(i) {
      return { text: lines[i] || '' };
    },
  };
}

const mockVscode = {
  FoldingRangeKind: { Region: 'region' },
  FoldingRange: class FoldingRange {
    constructor(start, end, kind) {
      this.start = start;
      this.end = end;
      this.kind = kind;
    }
  },
};

function simplifyRanges(ranges) {
  return ranges.map((range) => ({
    start: range.start,
    end: range.end,
    kind: range.kind,
  }));
}

test('findPropertyDrawerStartLines returns all :PROPERTIES: starts', () => {
  const doc = makeDoc([
    '* One',
    ':PROPERTIES:',
    ':ID: abc',
    ':END:',
    '* Two',
    '  :PROPERTIES:',
    '  :X: y',
    '  :END:',
  ]);

  assert.deepEqual(findPropertyDrawerStartLines(doc), [1, 5]);
});

test('provideFoldingRanges folds headings, properties, and list blocks', () => {
  const doc = makeDoc([
    '* Alpha',
    'alpha body',
    '** Child',
    'child body',
    '* Beta',
    ':PROPERTIES:',
    ':ID: beta',
    ':END:',
    '- one',
    '  - nested',
    'paragraph',
  ]);

  const folds = provideFoldingRanges(doc, mockVscode);

  assert.deepEqual(simplifyRanges(folds), [
    { start: 2, end: 3, kind: 'region' },
    { start: 0, end: 3, kind: 'region' },
    { start: 5, end: 7, kind: 'region' },
    { start: 8, end: 9, kind: 'region' },
    { start: 4, end: 10, kind: 'region' },
  ]);
});

test('provideFoldingRanges validates vscode dependency', () => {
  const doc = makeDoc(['* One', 'body']);
  assert.throws(() => provideFoldingRanges(doc), /requires vscode\.FoldingRange/);
});
