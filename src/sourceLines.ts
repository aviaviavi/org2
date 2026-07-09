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

export function isPlanningLine(line: string): boolean {
  return /^(SCHEDULED|DEADLINE|CLOSED):(?:\s|$)/i.test(line.trim());
}

export function findPlanningBlockEnd(lines: string[], headingIndex: number, endExclusive: number): number {
  let i = headingIndex + 1;
  while (i < endExclusive && isPlanningLine(lines[i] ?? "")) {
    i += 1;
  }
  return i;
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

export function upsertHeadlinePropertyInLines(lines: string[], headingIndex: number, key: string, value: string): void {
  if (headingIndex < 0 || headingIndex >= lines.length || !isHeadlineLine(lines[headingIndex] ?? "")) {
    throw new Error(`Expected headline at line index ${headingIndex}`);
  }

  const propertyKey = key.trim().toUpperCase();
  let insertAt = headingIndex + 1;
  while (insertAt < lines.length && isPlanningLine(lines[insertAt] ?? "")) {
    insertAt += 1;
  }

  let drawerStart = -1;
  let drawerEnd = -1;
  if ((lines[insertAt] ?? "").trim().toUpperCase() === ":PROPERTIES:") {
    drawerStart = insertAt;
    for (let i = insertAt + 1; i < lines.length; i += 1) {
      const trimmed = (lines[i] ?? "").trim().toUpperCase();
      if (isHeadlineLine(lines[i] ?? "")) break;
      if (trimmed === ":END:") {
        drawerEnd = i;
        break;
      }
    }
  }

  if (drawerStart < 0 || drawerEnd < 0) {
    lines.splice(insertAt, 0, ":PROPERTIES:", `:${propertyKey}: ${value}`, ":END:");
    return;
  }

  const keyPrefix = `:${propertyKey}:`;
  for (let i = drawerStart + 1; i < drawerEnd; i += 1) {
    if ((lines[i] ?? "").toUpperCase().startsWith(keyPrefix.toUpperCase())) {
      lines[i] = `${keyPrefix} ${value}`;
      return;
    }
  }
  lines.splice(drawerEnd, 0, `${keyPrefix} ${value}`);
}
