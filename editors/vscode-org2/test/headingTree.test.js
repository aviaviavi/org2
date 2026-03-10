const test = require('node:test');
const assert = require('node:assert/strict');

const {
  findHeadlineLineAtOrAbove,
  findSubtreeRangeAtOrAbove,
  findHeadingLevelEditTargets,
  findPreviousSiblingSubtreeRange,
  findNextSiblingSubtreeRange,
  findHeadingLinesAtLevel,
} = require('../headingTree');

function makeDoc(lines) {
  return {
    lineCount: lines.length,
    lineAt(i) {
      return { text: lines[i] || '' };
    },
  };
}

test('findHeadlineLineAtOrAbove and findHeadingLinesAtLevel locate headings', () => {
  const doc = makeDoc([
    'intro',
    '* One',
    'text',
    '** Child',
    '* Two',
  ]);

  assert.equal(findHeadlineLineAtOrAbove(doc, 2), 1);
  assert.deepEqual(findHeadingLinesAtLevel(doc, 1), [1, 4]);
  assert.deepEqual(findHeadingLinesAtLevel(doc, 2), [3]);
});

test('findSubtreeRangeAtOrAbove returns heading range + level', () => {
  const doc = makeDoc([
    '* One',
    'one text',
    '** Child',
    'child text',
    '* Two',
  ]);

  assert.deepEqual(findSubtreeRangeAtOrAbove(doc, 2), {
    startLine: 2,
    endLine: 3,
    level: 2,
  });

  assert.deepEqual(findSubtreeRangeAtOrAbove(doc, 1), {
    startLine: 0,
    endLine: 3,
    level: 1,
  });
});

test('sibling + edit-target helpers operate within subtree boundaries', () => {
  const doc = makeDoc([
    '* A',
    '** A1',
    '* B',
    '** B1',
    '* C',
  ]);

  const bRange = findSubtreeRangeAtOrAbove(doc, 2);
  assert.deepEqual(bRange, { startLine: 2, endLine: 3, level: 1 });

  assert.deepEqual(findPreviousSiblingSubtreeRange(doc, bRange), { startLine: 0, endLine: 1, level: 1 });
  assert.deepEqual(findNextSiblingSubtreeRange(doc, bRange), { startLine: 4, endLine: 4, level: 1 });

  assert.deepEqual(findHeadingLevelEditTargets(doc, bRange), [
    { line: 2, level: 1, text: '* B' },
    { line: 3, level: 2, text: '** B1' },
  ]);
});
