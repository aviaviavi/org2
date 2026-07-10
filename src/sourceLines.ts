export type SubtreeRange = {
  start: number;
  endExclusive: number;
  level: number;
};

export type DrawerRange = {
  start: number;
  end: number;
  terminated: boolean;
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

export function findDrawerInLines(lines: string[], start: number, endExclusive: number, name: string): DrawerRange | null {
  const begin = `:${name.trim().toUpperCase()}:`;
  for (let i = start; i < endExclusive; i += 1) {
    if ((lines[i] ?? "").trim().toUpperCase() !== begin) continue;

    for (let j = i + 1; j < endExclusive; j += 1) {
      if ((lines[j] ?? "").trim().toUpperCase() === ":END:") {
        return { start: i, end: j, terminated: true };
      }
    }
    return { start: i, end: endExclusive - 1, terminated: false };
  }
  return null;
}

export function getDrawerPropertyValue(lines: string[], drawer: DrawerRange, key: string): string | undefined {
  if (!drawer.terminated) return undefined;

  const keyPrefix = `:${key.trim().toUpperCase()}:`;
  for (let i = drawer.start + 1; i < drawer.end; i += 1) {
    const line = lines[i] ?? "";
    if (!line.toUpperCase().startsWith(keyPrefix)) continue;
    return line.slice(keyPrefix.length).trim();
  }
  return undefined;
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

  const nextHeading = computeSubtreeRange(lines, headingIndex).endExclusive;
  const drawer = findDrawerInLines(lines, insertAt, nextHeading, "PROPERTIES");

  if (!drawer || !drawer.terminated || drawer.start !== insertAt) {
    lines.splice(insertAt, 0, ":PROPERTIES:", `:${propertyKey}: ${value}`, ":END:");
    return;
  }

  const keyPrefix = `:${propertyKey}:`;
  for (let i = drawer.start + 1; i < drawer.end; i += 1) {
    if ((lines[i] ?? "").toUpperCase().startsWith(keyPrefix)) {
      lines[i] = `${keyPrefix} ${value}`;
      return;
    }
  }
  lines.splice(drawer.end, 0, `${keyPrefix} ${value}`);
}
