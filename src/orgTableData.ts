/**
 * Parse the permissive Org table rows consumed by derived data features.
 *
 * Unlike the canonical document parser, data-query and chart discovery also
 * accept a missing closing pipe. Keep that compatibility localized here so
 * both features interpret table data identically.
 */
export function parseOrgTableDataLine(line: string): string[] | null {
  if (!isOrgTableDataLine(line)) return null;
  const trimmed = line.trim();
  const inner = trimmed.slice(1, trimmed.endsWith("|") ? -1 : undefined);
  return inner.split("|").map((cell) => cell.trim());
}

export function isOrgTableDataLine(line: string): boolean {
  return /^\s*\|/.test(line);
}

export function isOrgTableHline(cells: string[]): boolean {
  return cells.length > 0 && cells.every((cell) => /^[+\-= ]*$/.test(cell) && /[-=]/.test(cell));
}
