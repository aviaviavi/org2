const headingRe = /^(\*+)\s+/;
const listItemRe = /^(\s*)(?:[-+*]|\d+[.)])\s+/;
const propertiesBeginRe = /^\s*:PROPERTIES:\s*$/i;
const drawerEndRe = /^\s*:END:\s*$/i;

function findPropertyDrawerStartLines(document) {
  if (!document || typeof document.lineCount !== 'number' || typeof document.lineAt !== 'function') {
    return [];
  }

  const starts = [];
  const lineCount = document.lineCount;

  let inProperties = false;
  for (let i = 0; i < lineCount; i++) {
    const text = String(document.lineAt(i)?.text || '');

    if (!inProperties && propertiesBeginRe.test(text)) {
      inProperties = true;
      starts.push(i);
      continue;
    }

    if (inProperties && drawerEndRe.test(text)) {
      inProperties = false;
    }
  }

  return starts;
}

function provideFoldingRanges(document, vscode) {
  if (!document || typeof document.lineCount !== 'number' || typeof document.lineAt !== 'function') {
    return [];
  }

  const FoldingRange = vscode?.FoldingRange;
  const FoldingRangeKind = vscode?.FoldingRangeKind;
  if (typeof FoldingRange !== 'function' || !FoldingRangeKind) {
    throw new Error('provideFoldingRanges requires vscode.FoldingRange and vscode.FoldingRangeKind');
  }

  const lineCount = document.lineCount;
  const folds = [];

  const headingStack = [];
  const listStack = [];

  // :PROPERTIES: drawers only (do not fold arbitrary drawers).
  const propertiesStack = [];

  const pushFold = (startLine, endLine, kind = FoldingRangeKind.Region) => {
    if (endLine > startLine) {
      folds.push(new FoldingRange(startLine, endLine, kind));
    }
  };

  const flushStackTo = (stack, endLine) => {
    while (stack.length > 0) {
      const top = stack.pop();
      pushFold(top.startLine, endLine, top.kind);
    }
  };

  const closeHeadingsToLevel = (level, endLine) => {
    while (headingStack.length > 0 && headingStack[headingStack.length - 1].level >= level) {
      const top = headingStack.pop();
      pushFold(top.startLine, endLine, FoldingRangeKind.Region);
    }
  };

  const closeListsToIndent = (indent, endLine) => {
    while (listStack.length > 0 && listStack[listStack.length - 1].indent >= indent) {
      const top = listStack.pop();
      pushFold(top.startLine, endLine, FoldingRangeKind.Region);
    }
  };

  const closePropertiesTo = (endLine) => {
    while (propertiesStack.length > 0) {
      const top = propertiesStack.pop();
      pushFold(top.startLine, endLine, FoldingRangeKind.Region);
    }
  };

  for (let i = 0; i < lineCount; i++) {
    const text = String(document.lineAt(i)?.text || '');

    // Property drawer folding (:PROPERTIES: ... :END:)
    if (propertiesBeginRe.test(text)) {
      propertiesStack.push({ startLine: i, kind: FoldingRangeKind.Region });
      continue;
    }
    if (drawerEndRe.test(text) && propertiesStack.length > 0) {
      const top = propertiesStack.pop();
      pushFold(top.startLine, i, FoldingRangeKind.Region);
      continue;
    }

    const headingMatch = headingRe.exec(text);
    if (headingMatch) {
      flushStackTo(listStack, i - 1);
      const level = headingMatch[1].length;
      closeHeadingsToLevel(level, i - 1);
      headingStack.push({ level, startLine: i, kind: FoldingRangeKind.Region });
      continue;
    }

    const listMatch = listItemRe.exec(text);
    if (listMatch) {
      const indent = listMatch[1].length;

      // If a list starts at or above a previous list indent, close previous list folds.
      closeListsToIndent(indent, i - 1);
      listStack.push({ indent, startLine: i, kind: FoldingRangeKind.Region });
      continue;
    }

    // Close list folds when leaving list indentation (blank lines included).
    if (text.trim().length === 0) {
      continue;
    }

    // Non-list content at indentation 0 closes any top-level lists.
    if (!/^\s+/.test(text)) {
      closeListsToIndent(0, i - 1);
    }
  }

  flushStackTo(listStack, lineCount - 1);
  closeHeadingsToLevel(1, lineCount - 1);
  closePropertiesTo(lineCount - 1);

  return folds;
}

module.exports = {
  findPropertyDrawerStartLines,
  provideFoldingRanges,
};
