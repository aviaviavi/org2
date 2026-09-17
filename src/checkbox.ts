import type { Node } from "./ast.js";
import { extractOwnedCheckboxIssues, type CheckboxProgressIssue } from "./checkboxProgress.js";
import { isLineInOpaqueElement, parseOrgToCanonicalAst } from "./parser.js";

export type CheckboxState = "unchecked" | "indeterminate" | "checked";

export const checkboxMarkers: Record<CheckboxState, string> = {
  unchecked: " ", indeterminate: "-", checked: "X",
};

/** Edit precisely one parsed list checkbox. Line numbers are one-based. */
export function updateCheckboxInText(text: string, line: number, state?: CheckboxState) {
  const lines = text.split(/\r\n|\n|\r/);
  if (!Number.isSafeInteger(line) || line < 1 || line > lines.length) {
    throw new Error(`Checkbox line must be between 1 and ${lines.length}.`);
  }
  if (state !== undefined && !Object.hasOwn(checkboxMarkers, state)) {
    throw new Error("Checkbox status must be unchecked, indeterminate, or checked.");
  }

  // Let the canonical parser distinguish lists from examples, drawers, and prose.
  // Normalize only the parse input; the edit below preserves original bytes/EOLs.
  const parseInput = lines.join("\n");
  if (isLineInOpaqueElement(parseInput, line)) {
    throw new Error(`Line ${line} is not a list checkbox: it belongs to a block or drawer.`);
  }
  const ast = parseOrgToCanonicalAst(parseInput, { sourceRanges: true });
  function find(nodes: Node[]): CheckboxState | undefined {
    for (const node of nodes) {
      const range = (node as Node & { sourceRange?: { startLine: number } }).sourceRange;
      if (node.type === "ListItem" && range?.startLine === line && node.checkbox) return node.checkbox;
      const children = node.type === "List" ? node.items : node.type === "Headline" || node.type === "ListItem" ? node.children : [];
      const match = find(children);
      if (match) return match;
    }
    return undefined;
  }
  const oldState = find(ast.children);
  const source = lines[line - 1]!;
  // Locate the already-validated marker, including an optional ordered counter.
  const marker = /^\s*(?:[-+*]|\d+[.)]) (?:\[@\d+\]\s+)?\[([ Xx-])\]\s/.exec(source);
  if (!oldState || !marker) {
    throw new Error(`Line ${line} is not a list checkbox. Choose a list item beginning with [ ], [-], or [X].`);
  }
  const newState = state ?? ({ unchecked: "indeterminate", indeterminate: "checked", checked: "unchecked" } as const)[oldState];
  const column = marker[0].lastIndexOf("[") + 1; // zero-based UTF-16 marker position, for LSP
  let offset = column;
  let currentLine = 1;
  for (const ending of text.matchAll(/\r\n|\n|\r/g)) {
    if (currentLine++ === line) break;
    offset = ending.index! + ending[0].length + column;
  }
  // An explicit set to the current state is a true no-op (including lowercase x).
  const changed = oldState !== newState;
  return {
    text: changed ? text.slice(0, offset) + checkboxMarkers[newState] + text.slice(offset + 1) : text,
    line, column, oldState, newState, changed,
  };
}

/** Recalculate stale progress cookies while preserving all unrelated source bytes. */
export function updateCheckboxProgressCookiesInText(text: string) {
  const issues = extractOwnedCheckboxIssues(text.split(/\r\n|\n|\r/));
  if (issues.length === 0) return { text, changed: false, edits: [] as CheckboxProgressIssue[] };

  const issuesByLine = new Map<number, CheckboxProgressIssue[]>();
  for (const issue of issues) issuesByLine.set(issue.line, [...(issuesByLine.get(issue.line) || []), issue]);

  const lineBounds: Array<{ start: number; end: number }> = [];
  let start = 0;
  for (const ending of text.matchAll(/\r\n|\n|\r/g)) {
    lineBounds.push({ start, end: ending.index! });
    start = ending.index! + ending[0].length;
  }
  lineBounds.push({ start, end: text.length });

  const replacements: Array<{ start: number; end: number; text: string }> = [];
  for (const [line, lineIssues] of issuesByLine) {
    const bounds = lineBounds[line - 1];
    if (!bounds) throw new Error(`Progress cookie line ${line} is outside the source document.`);
    const source = text.slice(bounds.start, bounds.end);
    let updated = source;
    for (const issue of lineIssues) updated = updated.split(issue.raw).join(issue.expectedRaw);
    if (updated !== source) replacements.push({ ...bounds, text: updated });
  }

  let updatedText = text;
  for (const replacement of replacements.sort((a, b) => b.start - a.start)) {
    updatedText = updatedText.slice(0, replacement.start) + replacement.text + updatedText.slice(replacement.end);
  }
  return { text: updatedText, changed: updatedText !== text, edits: issues };
}
