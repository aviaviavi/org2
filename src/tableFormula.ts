import type { DocumentNode, Node, TableNode, TableRowNode } from "./ast.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import { printTableRows } from "./printer.js";

export type TableFormulaDiagnostic = {
  message: string;
  formulaIndex: number;
  assignmentIndex?: number;
  row?: number;
  column?: number;
};

export type TableFormulaChange = {
  row: number;
  column: number;
  before: string;
  after: string;
};

export type TableFormulaEvaluation = {
  ok: boolean;
  table: TableNode;
  changes: TableFormulaChange[];
  diagnostics: TableFormulaDiagnostic[];
  formulaIndex: number;
};

type Scalar = number | string | boolean;
type Value = Scalar | Scalar[];
type Cell = { row: number; column: number };
type FormulaJob = Cell & { expression: string; mode?: string; assignmentIndex: number; specificity: number };

function cloneTable(table: TableNode): TableNode {
  return {
    ...table,
    rows: table.rows.map((row) => row.type === "TableRow"
      ? { ...row, cells: [...row.cells], contents: row.contents?.map((items) => [...items]) }
      : { ...row }),
    formulas: table.formulas?.map((line) => ({ ...line, assignments: line.assignments.map((item) => ({ ...item })) })),
  };
}

function dataRows(table: TableNode): TableRowNode[] {
  return table.rows.filter((row): row is TableRowNode => row.type === "TableRow");
}

function dataRowIndexForPhysical(table: TableNode, physical: number): number {
  let index = 0;
  for (let i = 0; i < physical; i += 1) if (table.rows[i]?.type === "TableRow") index += 1;
  return index;
}

function firstBodyRow(table: TableNode): number {
  const hline = table.rows.findIndex((row) => row.type === "TableHline");
  return hline < 0 ? 1 : dataRowIndexForPhysical(table, hline) + 1;
}

function columnCount(table: TableNode): number {
  return dataRows(table).reduce((max, row) => Math.max(max, row.cells.length), 0);
}

function parseCellText(raw: string, emptyAsZero: boolean): Scalar {
  const text = raw.trim();
  if (text === "" && emptyAsZero) return 0;
  if (/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i.test(text)) return Number(text);
  if (/^[+-]?\d+:\d{2}(?::\d{2}(?:\.\d+)?)?$/.test(text)) {
    const sign = text.startsWith("-") ? -1 : 1;
    const fields = text.replace(/^[+-]/, "").split(":").map(Number);
    return sign * (fields.length === 3 ? fields[0]! * 3600 + fields[1]! * 60 + fields[2]! : fields[0]! * 3600 + fields[1]! * 60);
  }
  return text;
}

function scalarNumber(value: Scalar): number {
  if (typeof value === "number") return value;
  if (typeof value === "boolean") return value ? 1 : 0;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) throw new Error(`Expected a number, got ${JSON.stringify(value)}`);
  return parsed;
}

function flattened(values: Value[]): Scalar[] {
  return values.flatMap((value) => Array.isArray(value) ? value : [value]);
}

function splitMode(mode = ""): { flags: Set<string>; format?: string } {
  const flags = new Set<string>();
  let format: string | undefined;
  for (const original of mode.split(/[;,\s]+/).filter(Boolean)) {
    let token = original;
    const printf = /%[-+ #0]*\d*(?:\.\d+)?[feg]$/i.exec(token);
    const calc = /[fesn]\d+$/i.exec(token);
    const matchedFormat = printf ?? calc;
    if (matchedFormat) {
      format = matchedFormat[0];
      token = token.slice(0, matchedFormat.index);
    }
    for (const flag of token) flags.add(flag);
  }
  return { flags, format };
}

function formatValue(value: Value, mode?: string): string {
  if (Array.isArray(value)) value = value[0] ?? "";
  const { flags, format } = splitMode(mode);
  if (typeof value === "boolean") return value ? "1" : "0";
  if (typeof value === "string") return value;
  if (!Number.isFinite(value)) return "nan";
  if (flags.has("t")) return String(value / 3600);
  if (flags.has("T") || flags.has("U")) {
    const sign = value < 0 ? "-" : "";
    let seconds = Math.abs(value);
    const hours = Math.floor(seconds / 3600);
    seconds -= hours * 3600;
    const minutes = Math.floor(seconds / 60);
    const secs = Math.round(seconds - minutes * 60);
    return flags.has("U")
      ? `${sign}${hours}:${String(minutes).padStart(2, "0")}`
      : `${sign}${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
  }
  if (format?.startsWith("%")) {
    const match = /\.([0-9]+)([feg])$/i.exec(format);
    const digits = Number(match?.[1] ?? 6);
    const kind = match?.[2]?.toLowerCase();
    if (kind === "f") return value.toFixed(digits);
    if (kind === "e") return value.toExponential(digits);
    if (kind === "g") return value.toPrecision(digits);
  }
  if (format) {
    const digits = Number(format.slice(1));
    if (format[0] === "f") return value.toFixed(digits);
    if (format[0] === "e") return value.toExponential(digits);
    if (format[0] === "s") return value.toPrecision(digits);
    if (format[0] === "n") return value.toPrecision(digits);
  }
  return Number.isInteger(value) ? String(value) : String(Number(value.toPrecision(12)));
}

type Token = { kind: "number" | "string" | "name" | "reference" | "operator" | "eof"; value: string };

function tokenize(expression: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  while (i < expression.length) {
    const rest = expression.slice(i);
    const whitespace = /^\s+/.exec(rest);
    if (whitespace) { i += whitespace[0].length; continue; }
    const string = /^("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')/.exec(rest);
    if (string) { tokens.push({ kind: "string", value: string[0] }); i += string[0].length; continue; }
    const reference = /^(?:@[+\-]?(?:\d+|[<>]+|I+|#|[A-Za-z][\w-]*)\$[+\-]?(?:\d+|[<>]+|#|[A-Za-z][\w-]*)|@[+\-]?(?:\d+|[<>]+|I+|#)|\$[+\-]?(?:\d+|[<>]+|#|[A-Za-z][\w-]*)|[A-Z]+\d+)(?:\.\.(?:@[+\-]?(?:\d+|[<>]+|I+|#|[A-Za-z][\w-]*)\$[+\-]?(?:\d+|[<>]+|#|[A-Za-z][\w-]*)|@[+\-]?(?:\d+|[<>]+|I+|#)|\$[+\-]?(?:\d+|[<>]+|#|[A-Za-z][\w-]*)|[A-Z]+\d+))?/.exec(rest);
    if (reference) { tokens.push({ kind: "reference", value: reference[0] }); i += reference[0].length; continue; }
    const number = /^(?:\d+(?:\.\d*)?|\.\d+)(?:e[+\-]?\d+)?/i.exec(rest);
    if (number) { tokens.push({ kind: "number", value: number[0] }); i += number[0].length; continue; }
    const name = /^[A-Za-z_][\w-]*/.exec(rest);
    if (name) { tokens.push({ kind: "name", value: name[0] }); i += name[0].length; continue; }
    const op = /^(?:<=|>=|==|!=|&&|\|\||[-+*/%^(),<>])/.exec(rest);
    if (op) { tokens.push({ kind: "operator", value: op[0] }); i += op[0].length; continue; }
    throw new Error(`Unsupported formula syntax near ${JSON.stringify(rest.slice(0, 20))}`);
  }
  tokens.push({ kind: "eof", value: "" });
  return tokens;
}

function lettersToColumn(value: string): number {
  let result = 0;
  for (const ch of value) result = result * 26 + ch.charCodeAt(0) - 64;
  return result;
}

function referenceCoordinate(part: string, current: Cell, rows: number, columns: number): Cell {
  const a1 = /^([A-Z]+)(\d+)$/.exec(part);
  if (a1) return { row: Number(a1[2]), column: lettersToColumn(a1[1]!) };
  let row = current.row;
  let column = current.column;
  const rowMatch = /^@([^$]+)/.exec(part);
  const colMatch = /\$([^$]+)$/.exec(part);
  const resolve = (raw: string, at: number, last: number): number => {
    if (raw === "#" || raw === "0") return at;
    if (/^<+$/.test(raw)) return 1 + raw.length - 1;
    if (/^>+$/.test(raw)) return last - raw.length + 1;
    if (/^[+-]\d+$/.test(raw)) return at + Number(raw);
    if (/^\d+$/.test(raw)) return Number(raw);
    throw new Error(`Unsupported named or hline reference ${raw}`);
  };
  if (rowMatch) row = resolve(rowMatch[1]!, current.row, rows);
  if (colMatch) column = resolve(colMatch[1]!, current.column, columns);
  return { row, column };
}

function readReference(raw: string, current: Cell, table: TableNode, emptyAsZero: boolean): Value {
  const rows = dataRows(table);
  const columns = columnCount(table);
  const [startRaw, endRaw] = raw.split("..");
  const start = referenceCoordinate(startRaw!, current, rows.length, columns);
  if (!endRaw) {
    if (start.row < 1 || start.row > rows.length || start.column < 1 || start.column > columns) throw new Error(`Reference ${raw} is outside the table`);
    return parseCellText(rows[start.row - 1]?.cells[start.column - 1] ?? "", emptyAsZero);
  }
  const end = referenceCoordinate(endRaw, current, rows.length, columns);
  const result: Scalar[] = [];
  for (let row = Math.min(start.row, end.row); row <= Math.max(start.row, end.row); row += 1) {
    for (let column = Math.min(start.column, end.column); column <= Math.max(start.column, end.column); column += 1) {
      const rawCell = rows[row - 1]?.cells[column - 1] ?? "";
      if (rawCell.trim() !== "" || emptyAsZero) result.push(parseCellText(rawCell, emptyAsZero));
    }
  }
  return result;
}

class ExpressionParser {
  private index = 0;
  constructor(private readonly tokens: Token[], private readonly table: TableNode, private readonly current: Cell, private readonly emptyAsZero: boolean) {}
  parse(): Value {
    const value = this.binary(0);
    if (this.peek().kind !== "eof") throw new Error(`Unexpected token ${this.peek().value}`);
    return value;
  }
  private peek(): Token { return this.tokens[this.index]!; }
  private take(): Token { return this.tokens[this.index++]!; }
  private binary(min: number): Value {
    let left = this.unary();
    const precedence: Record<string, number> = { "||": 1, "&&": 2, "==": 3, "!=": 3, "<": 4, "<=": 4, ">": 4, ">=": 4, "+": 5, "-": 5, "/": 6, "*": 7, "%": 7, "^": 8 };
    while (this.peek().kind === "operator" && (precedence[this.peek().value] ?? -1) >= min) {
      const op = this.take().value;
      const right = this.binary((precedence[op] ?? 0) + (op === "^" ? 0 : 1));
      left = this.apply(op, left, right);
    }
    return left;
  }
  private unary(): Value {
    if (this.peek().kind === "operator" && ["+", "-"].includes(this.peek().value)) {
      const op = this.take().value;
      const value = scalarNumber(this.scalar(this.unary()));
      return op === "-" ? -value : value;
    }
    return this.primary();
  }
  private primary(): Value {
    const token = this.take();
    if (token.kind === "number") return Number(token.value);
    if (token.kind === "string") return token.value.slice(1, -1).replace(/\\([\\"'])/g, "$1");
    if (token.kind === "reference") return readReference(token.value, this.current, this.table, this.emptyAsZero);
    if (token.kind === "operator" && token.value === "(") {
      const value = this.binary(0);
      if (this.take().value !== ")") throw new Error("Expected )");
      return value;
    }
    if (token.kind === "name") {
      if (token.value === "pi") return Math.PI;
      if (token.value === "e") return Math.E;
      if (this.peek().value !== "(") throw new Error(`Unknown name ${token.value}`);
      this.take();
      const args: Value[] = [];
      if (this.peek().value !== ")") {
        do { args.push(this.binary(0)); if (this.peek().value !== ",") break; this.take(); } while (true);
      }
      if (this.take().value !== ")") throw new Error("Expected ) after function arguments");
      return this.call(token.value, args);
    }
    throw new Error(`Unexpected token ${token.value || "end of formula"}`);
  }
  private scalar(value: Value): Scalar { if (Array.isArray(value)) throw new Error("A range cannot be used as a scalar"); return value; }
  private apply(op: string, leftValue: Value, rightValue: Value): Scalar {
    const left = this.scalar(leftValue); const right = this.scalar(rightValue);
    if (op === "+" && (typeof left === "string" || typeof right === "string")) return String(left) + String(right);
    if (op === "+") return scalarNumber(left) + scalarNumber(right);
    if (op === "-") return scalarNumber(left) - scalarNumber(right);
    if (op === "*") return scalarNumber(left) * scalarNumber(right);
    if (op === "/") return scalarNumber(left) / scalarNumber(right);
    if (op === "%") return scalarNumber(left) % scalarNumber(right);
    if (op === "^") return scalarNumber(left) ** scalarNumber(right);
    if (op === "&&") return Boolean(left) && Boolean(right);
    if (op === "||") return Boolean(left) || Boolean(right);
    if (op === "==") return left === right;
    if (op === "!=") return left !== right;
    if (op === "<") return left < right;
    if (op === "<=") return left <= right;
    if (op === ">") return left > right;
    return left >= right;
  }
  private call(name: string, args: Value[]): Value {
    const values = flattened(args);
    const numbers = values.map(scalarNumber);
    const lower = name.toLowerCase();
    if (lower === "vsum") return numbers.reduce((sum, value) => sum + value, 0);
    if (lower === "vmean") return numbers.reduce((sum, value) => sum + value, 0) / numbers.length;
    if (lower === "vmin" || lower === "min") return Math.min(...numbers);
    if (lower === "vmax" || lower === "max") return Math.max(...numbers);
    if (lower === "vcount") return values.length;
    if (lower === "vmedian") { const sorted = [...numbers].sort((a, b) => a - b); const mid = Math.floor(sorted.length / 2); return sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2; }
    const unary: Record<string, (value: number) => number> = { abs: Math.abs, round: Math.round, floor: Math.floor, ceil: Math.ceil, sqrt: Math.sqrt, exp: Math.exp, log: Math.log10, ln: Math.log, sin: (v) => Math.sin(v * Math.PI / 180), cos: (v) => Math.cos(v * Math.PI / 180), tan: (v) => Math.tan(v * Math.PI / 180) };
    if (unary[lower]) return unary[lower]!(numbers[0] ?? 0);
    if (lower === "pow") return (numbers[0] ?? 0) ** (numbers[1] ?? 0);
    if (lower === "string") return String(values[0] ?? "");
    if (lower === "if") return Boolean(values[0]) ? values[1] ?? "" : values[2] ?? "";
    throw new Error(`Unsupported function ${name}`);
  }
}

function targetCells(target: string, table: TableNode): Cell[] {
  const rows = dataRows(table).length;
  const columns = columnCount(table);
  const all: Cell[] = [];
  if (/^\$\d+$/.test(target)) {
    const column = Number(target.slice(1));
    for (let row = firstBodyRow(table); row <= rows; row += 1) all.push({ row, column });
    return all;
  }
  if (/^@\d+$/.test(target)) {
    const row = Number(target.slice(1));
    for (let column = 1; column <= columns; column += 1) all.push({ row, column });
    return all;
  }
  const parts = target.split("..");
  const start = referenceCoordinate(parts[0]!, { row: 1, column: 1 }, rows, columns);
  const end = parts[1] ? referenceCoordinate(parts[1], start, rows, columns) : start;
  for (let row = Math.min(start.row, end.row); row <= Math.max(start.row, end.row); row += 1) {
    for (let column = Math.min(start.column, end.column); column <= Math.max(start.column, end.column); column += 1) all.push({ row, column });
  }
  return all;
}

export function evaluateTableNode(source: TableNode, formulaIndex = 0): TableFormulaEvaluation {
  const table = cloneTable(source);
  const diagnostics: TableFormulaDiagnostic[] = [];
  const formula = table.formulas?.[formulaIndex];
  if (!formula) return { ok: false, table, changes: [], diagnostics: [{ message: `Table has no formula line ${formulaIndex + 1}`, formulaIndex }], formulaIndex };
  const jobs = new Map<string, FormulaJob>();
  formula.assignments.forEach((assignment, assignmentIndex) => {
    try {
      if (!assignment.targetRaw) throw new Error("Formula assignment is missing a target");
      if (assignment.expressionRaw.startsWith("'")) throw new Error("Emacs Lisp table formulas are preserved but are not executed");
      const specificity = /^\$\d+$/.test(assignment.targetRaw) ? 1 : /^@\d+$/.test(assignment.targetRaw) ? 2 : 3;
      for (const cell of targetCells(assignment.targetRaw, table)) {
        const key = `${cell.row}:${cell.column}`;
        const existing = jobs.get(key);
        if (!existing || specificity >= existing.specificity) jobs.set(key, { ...cell, expression: assignment.expressionRaw, mode: assignment.modeRaw, assignmentIndex, specificity });
      }
    } catch (error) {
      diagnostics.push({ message: error instanceof Error ? error.message : String(error), formulaIndex, assignmentIndex });
    }
  });
  const beforeRows = dataRows(source);
  const rows = dataRows(table);
  if (diagnostics.length === 0) {
    const orderedJobs = [...jobs.values()].sort((left, right) =>
      left.specificity - right.specificity || left.assignmentIndex - right.assignmentIndex
    );
    for (const job of orderedJobs) {
      try {
        if (job.row < 1 || job.row > rows.length || job.column < 1) throw new Error("Formula target is outside the table");
        const { flags } = splitMode(job.mode);
        const value = new ExpressionParser(tokenize(job.expression), table, job, flags.has("N")).parse();
        while ((rows[job.row - 1]?.cells.length ?? 0) < job.column) rows[job.row - 1]!.cells.push("");
        rows[job.row - 1]!.cells[job.column - 1] = formatValue(value, job.mode);
      } catch (error) {
        diagnostics.push({ message: error instanceof Error ? error.message : String(error), formulaIndex, assignmentIndex: job.assignmentIndex, row: job.row, column: job.column });
      }
    }
  }
  if (diagnostics.length > 0) return { ok: false, table: cloneTable(source), changes: [], diagnostics, formulaIndex };
  const changes: TableFormulaChange[] = [];
  rows.forEach((row, rowIndex) => row.cells.forEach((after, columnIndex) => {
    const before = beforeRows[rowIndex]?.cells[columnIndex] ?? "";
    if (before !== after) changes.push({ row: rowIndex + 1, column: columnIndex + 1, before, after });
  }));
  return { ok: true, table, changes, diagnostics, formulaIndex };
}

type RangedTable = TableNode & { sourceRange?: { startLine: number; endLine: number } };

export function tablesInDocument(document: DocumentNode): RangedTable[] {
  const tables: RangedTable[] = [];
  const visit = (nodes: Node[]): void => {
    for (const node of nodes) {
      if (node.type === "Table") tables.push(node);
      else if (node.type === "Headline" || node.type === "ListItem") visit(node.children);
      else if (node.type === "List") for (const item of node.items) visit(item.children);
    }
  };
  visit(document.children);
  return tables;
}

export type RecalculateTableResult = {
  schema: "org2:table-recalculation:v1";
  ok: boolean;
  changed: boolean;
  text: string;
  tableStartLine?: number;
  tableEndLine?: number;
  formulaIndex: number;
  changes: TableFormulaChange[];
  diagnostics: TableFormulaDiagnostic[];
};

export function recalculateOrgTableFormulas(input: string, options: { line?: number; formulaIndex?: number } = {}): RecalculateTableResult {
  const formulaIndex = options.formulaIndex ?? 0;
  const document = parseOrgToCanonicalAst(input, { sourceRanges: true });
  const tables = tablesInDocument(document).filter((table) => table.formulas && table.formulas.length > 0);
  const selected = options.line === undefined
    ? tables[0]
    : tables.find((table) => table.sourceRange && options.line! >= table.sourceRange.startLine && options.line! <= table.sourceRange.endLine + (table.formulas?.length ?? 0));
  if (!selected?.sourceRange) return { schema: "org2:table-recalculation:v1", ok: false, changed: false, text: input, formulaIndex, changes: [], diagnostics: [{ message: options.line ? `No formula-backed table contains line ${options.line}` : "No formula-backed table found", formulaIndex }] };
  const evaluation = evaluateTableNode(selected, formulaIndex);
  if (!evaluation.ok) return { schema: "org2:table-recalculation:v1", ok: false, changed: false, text: input, tableStartLine: selected.sourceRange.startLine, tableEndLine: selected.sourceRange.endLine, formulaIndex, changes: [], diagnostics: evaluation.diagnostics };
  const lines = input.split("\n");
  const replacement = printTableRows(evaluation.table).split("\n");
  lines.splice(selected.sourceRange.startLine - 1, selected.sourceRange.endLine - selected.sourceRange.startLine + 1, ...replacement);
  const text = lines.join("\n");
  return { schema: "org2:table-recalculation:v1", ok: true, changed: text !== input, text, tableStartLine: selected.sourceRange.startLine, tableEndLine: selected.sourceRange.startLine + replacement.length - 1, formulaIndex, changes: evaluation.changes, diagnostics: [] };
}
