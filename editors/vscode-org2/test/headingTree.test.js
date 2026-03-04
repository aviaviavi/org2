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

function mockDoc(text) {
  const lines = String(text || '').replace(/\r\n/g, '\n').split('\n');
  return {
    lineCount: lines.length,
    lineAt(index) {
      return { text: lines[index] ?? '' };
    },
  };
}

const doc = mockDoc([
  '* A',
  '** A1',
  'body-a1',
  '** A2',
  '*** A2-child',
  '* B',
  '** B1',
  'tail',
].join('\n'));

test('findHeadlineLineAtOrAbove: finds nearest heading from body lines', () => {
  assert.equal(findHeadlineLineAtOrAbove(doc, 0), 0);
  assert.equal(findHeadlineLineAtOrAbove(doc, 2), 1);
  assert.equal(findHeadlineLineAtOrAbove(doc, 7), 6);
});

test('findSubtreeRangeAtOrAbove: returns subtree bounds and level', () => {
  assert.deepEqual(findSubtreeRangeAtOrAbove(doc, 4), {
    startLine: 4,
    endLine: 4,
    level: 3,
  });

  assert.deepEqual(findSubtreeRangeAtOrAbove(doc, 3), {
    startLine: 3,
    endLine: 4,
    level: 2,
  });

  assert.deepEqual(findSubtreeRangeAtOrAbove(doc, 1), {
    startLine: 1,
    endLine: 2,
    level: 2,
  });
});

test('findHeadingLevelEditTargets: collects only headings within a subtree range', () => {
  const targets = findHeadingLevelEditTargets(doc, { startLine: 3, endLine: 4 });
  assert.deepEqual(targets, [
    { line: 3, level: 2, text: '** A2' },
    { line: 4, level: 3, text: '*** A2-child' },
  ]);
});

test('findPreviousSiblingSubtreeRange and findNextSiblingSubtreeRange: respect sibling boundaries', () => {
  const a2 = findSubtreeRangeAtOrAbove(doc, 3);
  assert.deepEqual(findPreviousSiblingSubtreeRange(doc, a2), {
    startLine: 1,
    endLine: 2,
    level: 2,
  });
  assert.equal(findNextSiblingSubtreeRange(doc, a2), null);

  const a1 = findSubtreeRangeAtOrAbove(doc, 1);
  assert.equal(findPreviousSiblingSubtreeRange(doc, a1), null);
  assert.deepEqual(findNextSiblingSubtreeRange(doc, a1), {
    startLine: 3,
    endLine: 4,
    level: 2,
  });
});

test('findHeadingLinesAtLevel: returns all heading start lines for a level', () => {
  assert.deepEqual(findHeadingLinesAtLevel(doc, 1), [0, 5]);
  assert.deepEqual(findHeadingLinesAtLevel(doc, 2), [1, 3, 6]);
  assert.deepEqual(findHeadingLinesAtLevel(doc, 3), [4]);
});
