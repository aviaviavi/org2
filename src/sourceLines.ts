export type SubtreeRange = {
  start: number;
  endExclusive: number;
  level: number;
};

export function isHeadlineLine(line: string): boolean {
  return /^\*+\s+/.test(line);
}

export function getHeadlineLevel(line: string): number {
  const match = /^(\*+)\s+/.exec(line);
  return match ? match[1].length : 0;
}

export function findHeadingAtOrAbove(lines: string[], lineNumber: number): number {
  const cursorIndex = Math.max(0, Math.min(lines.length - 1, lineNumber - 1));
  for (let i = cursorIndex; i >= 0; i -= 1) {
    if (isHeadlineLine(lines[i] ?? "")) return i;
  }
  throw new Error(`No headline found at or above line ${lineNumber}`);
}

export function computeSubtreeRange(lines: string[], headingIndex: number): SubtreeRange {
  const headingLine = lines[headingIndex] ?? "";
  if (headingIndex < 0 || headingIndex >= lines.length || !isHeadlineLine(headingLine)) {
    throw new Error(`Expected headline at line index ${headingIndex}`);
  }

  const level = getHeadlineLevel(headingLine);
  for (let i = headingIndex + 1; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    if (isHeadlineLine(line) && getHeadlineLevel(line) <= level) {
      return { start: headingIndex, endExclusive: i, level };
    }
  }
  return { start: headingIndex, endExclusive: lines.length, level };
}
