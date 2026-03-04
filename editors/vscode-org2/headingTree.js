const headingRe = /^(\*+)\s+/;

function findHeadlineLineAtOrAbove(document, line0) {
  if (!document || typeof document.lineCount !== 'number' || document.lineCount <= 0) return -1;

  const clamped = Math.max(0, Math.min(Number(line0) || 0, document.lineCount - 1));
  for (let i = clamped; i >= 0; i -= 1) {
    if (headingRe.test(document.lineAt(i).text)) return i;
  }
  return -1;
}

function findSubtreeRangeAtOrAbove(document, line0) {
  if (!document || typeof document.lineCount !== 'number' || document.lineCount <= 0) return null;

  const headlineLine = findHeadlineLineAtOrAbove(document, line0);
  if (headlineLine < 0) return null;

  const headlineMatch = headingRe.exec(document.lineAt(headlineLine).text || '');
  if (!headlineMatch) return null;

  const level = headlineMatch[1].length;
  let endLine = document.lineCount - 1;
  for (let i = headlineLine + 1; i < document.lineCount; i += 1) {
    const m = headingRe.exec(document.lineAt(i).text || '');
    if (!m) continue;
    if (m[1].length <= level) {
      endLine = i - 1;
      break;
    }
  }

  return { startLine: headlineLine, endLine, level };
}

function findHeadingLevelEditTargets(document, range) {
  if (!document || !range) return [];

  const targets = [];
  const startLine = Math.max(0, Math.min(Number(range.startLine) || 0, document.lineCount - 1));
  const endLine = Math.max(startLine, Math.min(Number(range.endLine) || startLine, document.lineCount - 1));

  for (let i = startLine; i <= endLine; i += 1) {
    const text = document.lineAt(i).text || '';
    const m = headingRe.exec(text);
    if (!m) continue;
    targets.push({ line: i, level: m[1].length, text });
  }

  return targets;
}

function findPreviousSiblingSubtreeRange(document, range) {
  if (!document || !range) return null;

  const level = Number(range.level) || 0;
  if (level <= 0) return null;

  for (let i = Math.max(0, Number(range.startLine) - 1); i >= 0; i -= 1) {
    const text = document.lineAt(i).text || '';
    const m = headingRe.exec(text);
    if (!m) continue;

    const candidateLevel = m[1].length;
    if (candidateLevel < level) break;
    if (candidateLevel === level) return findSubtreeRangeAtOrAbove(document, i);
  }

  return null;
}

function findNextSiblingSubtreeRange(document, range) {
  if (!document || !range) return null;

  const level = Number(range.level) || 0;
  if (level <= 0) return null;

  for (let i = Math.max(0, Number(range.endLine) + 1); i < document.lineCount; i += 1) {
    const text = document.lineAt(i).text || '';
    const m = headingRe.exec(text);
    if (!m) continue;

    const candidateLevel = m[1].length;
    if (candidateLevel < level) break;
    if (candidateLevel === level) return findSubtreeRangeAtOrAbove(document, i);
  }

  return null;
}

function findHeadingLinesAtLevel(document, level) {
  if (!document || typeof level !== 'number' || level <= 0) return [];

  const starts = [];
  for (let i = 0; i < document.lineCount; i += 1) {
    const text = document.lineAt(i).text;
    const m = headingRe.exec(text);
    if (m && m[1].length === level) starts.push(i);
  }
  return starts;
}

module.exports = {
  findHeadlineLineAtOrAbove,
  findSubtreeRangeAtOrAbove,
  findHeadingLevelEditTargets,
  findPreviousSiblingSubtreeRange,
  findNextSiblingSubtreeRange,
  findHeadingLinesAtLevel,
};
