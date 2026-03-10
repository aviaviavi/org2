const headingRe = /^(\*+)\s+/;

function getHeadingAtLine(document, line0) {
  if (!document || !Number.isInteger(line0) || line0 < 0 || line0 >= document.lineCount) return null;
  const text = String(document.lineAt(line0).text || '');
  const match = headingRe.exec(text);
  if (!match) return null;
  return {
    line: line0,
    text,
    level: match[1].length,
  };
}

function findHeadlineLineAtOrAbove(document, line0) {
  if (!document || typeof document.lineCount !== 'number' || document.lineCount <= 0) return -1;

  const clamped = Math.max(0, Math.min(Number(line0) || 0, document.lineCount - 1));
  for (let i = clamped; i >= 0; i -= 1) {
    if (headingRe.test(String(document.lineAt(i).text || ''))) return i;
  }
  return -1;
}

function findHeadingLinesAtLevel(document, level) {
  if (!document || typeof document.lineCount !== 'number') return [];
  if (!Number.isInteger(level) || level <= 0) return [];

  const starts = [];
  for (let i = 0; i < document.lineCount; i += 1) {
    const text = String(document.lineAt(i).text || '');
    const m = headingRe.exec(text);
    if (m && m[1].length === level) starts.push(i);
  }
  return starts;
}

function findSubtreeRangeAtOrAbove(document, line0) {
  const startLine = findHeadlineLineAtOrAbove(document, line0);
  if (startLine < 0) return null;

  const root = getHeadingAtLine(document, startLine);
  if (!root) return null;

  let endLine = document.lineCount - 1;
  for (let i = startLine + 1; i < document.lineCount; i += 1) {
    const heading = getHeadingAtLine(document, i);
    if (!heading) continue;
    if (heading.level <= root.level) {
      endLine = i - 1;
      break;
    }
  }

  return {
    startLine,
    endLine: Math.max(startLine, endLine),
    level: root.level,
  };
}

function findHeadingLevelEditTargets(document, subtreeRange) {
  if (!document || !subtreeRange) return [];

  const startLine = Math.max(0, Number(subtreeRange.startLine) || 0);
  const endLine = Math.max(startLine, Number(subtreeRange.endLine) || startLine);
  const targets = [];

  for (let i = startLine; i <= endLine && i < document.lineCount; i += 1) {
    const heading = getHeadingAtLine(document, i);
    if (!heading) continue;
    targets.push({ line: heading.line, level: heading.level, text: heading.text });
  }

  return targets;
}

function findPreviousSiblingSubtreeRange(document, subtreeRange) {
  if (!document || !subtreeRange) return null;

  const level = Number(subtreeRange.level);
  if (!Number.isInteger(level) || level <= 0) return null;

  const startLine = Math.max(0, Number(subtreeRange.startLine) || 0);
  for (let i = startLine - 1; i >= 0; i -= 1) {
    const heading = getHeadingAtLine(document, i);
    if (!heading) continue;
    if (heading.level < level) return null;
    if (heading.level === level) {
      return findSubtreeRangeAtOrAbove(document, i);
    }
  }

  return null;
}

function findNextSiblingSubtreeRange(document, subtreeRange) {
  if (!document || !subtreeRange) return null;

  const level = Number(subtreeRange.level);
  if (!Number.isInteger(level) || level <= 0) return null;

  const start = Math.max(0, Number(subtreeRange.endLine) || 0) + 1;
  for (let i = start; i < document.lineCount; i += 1) {
    const heading = getHeadingAtLine(document, i);
    if (!heading) continue;
    if (heading.level < level) return null;
    if (heading.level === level) {
      return findSubtreeRangeAtOrAbove(document, i);
    }
  }

  return null;
}

module.exports = {
  findHeadlineLineAtOrAbove,
  findSubtreeRangeAtOrAbove,
  findHeadingLevelEditTargets,
  findPreviousSiblingSubtreeRange,
  findNextSiblingSubtreeRange,
  findHeadingLinesAtLevel,
};
