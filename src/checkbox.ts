import type { Node } from "./ast.js";
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
