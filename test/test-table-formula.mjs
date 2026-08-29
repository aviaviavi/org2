import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { parseOrgToCanonicalAst } from "../dist/parser.js";
import { printCanonicalAstToOrg } from "../dist/printer.js";
import { evaluateTableNode, recalculateOrgTableFormulas } from "../dist/tableFormula.js";
import { buildPublishDiagnosticsParams } from "../dist/lsp-diagnostics.js";

const source = `* Invoice
| Item | Qty | Price | Total |
|------+-----+-------+-------|
| A    | 2   | 3.5   |       |
| B    | 4   | 2     |       |
|------+-----+-------+-------|
| Sum  |     |       |       |
#+TBLFM: $4=$2*$3;%.2f::@4$4=vsum(@2$4..@3$4);%.2f
`;

const ast = parseOrgToCanonicalAst(source, { sourceRanges: true });
const table = ast.children[0].children[0];
assert.equal(table.type, "Table");
assert.equal(table.formulas.length, 1);
assert.deepEqual(table.formulas[0].assignments[0], {
  raw: "$4=$2*$3;%.2f",
  targetRaw: "$4",
  expressionRaw: "$2*$3",
  modeRaw: "%.2f",
});
assert.match(printCanonicalAstToOrg(ast), /#\+TBLFM: \$4=\$2\*\$3;%.2f::@4\$4=vsum\(@2\$4\.\.@3\$4\);%.2f/, "formula lines round-trip with their tables");

const evaluated = evaluateTableNode(table);
assert.equal(evaluated.ok, true, JSON.stringify(evaluated.diagnostics));
const evaluatedRows = evaluated.table.rows.filter((row) => row.type === "TableRow");
assert.equal(evaluatedRows[1].cells[3], "7.00");
assert.equal(evaluatedRows[2].cells[3], "8.00");
assert.equal(evaluatedRows[3].cells[3], "15.00");

const reversedAssignments = source.replace(
  "$4=$2*$3;%.2f::@4$4=vsum(@2$4..@3$4);%.2f",
  "@4$4=vsum(@2$4..@3$4);%.2f::$4=$2*$3;%.2f",
);
assert.match(
  recalculateOrgTableFormulas(reversedAssignments).text,
  /\| Sum  \|     \|       \| 15\.00 \|/,
  "specific formulas evaluate after the column values they override",
);

const recalculated = recalculateOrgTableFormulas(source, { line: 4 });
assert.equal(recalculated.ok, true, JSON.stringify(recalculated.diagnostics));
assert.match(recalculated.text, /\| A    \| 2   \| 3\.5   \| 7\.00  \|/);
assert.match(recalculated.text, /#\+TBLFM: \$4=\$2\*\$3;%.2f/);
assert.equal(recalculateOrgTableFormulas(recalculated.text).changed, false, "recalculation is stable");

const relative = `| A | B | Delta |
|---+---+-------|
| 4 | 9 |       |
#+TBLFM: $3=$2-$1
`;
assert.match(recalculateOrgTableFormulas(relative).text, /\| 4 \| 9 \| 5     \|/);

const duration = `| Start | End  | Hours |
|-------+------+-------|
| 1:30  | 3:00 |       |
#+TBLFM: $3=$2-$1;U
`;
assert.match(recalculateOrgTableFormulas(duration).text, /\| 1:30  \| 3:00 \| 1:30  \|/);

const combinedMode = `| Qty | Unit | Total |
|-----+------+-------|
|     | 2.5  |       |
#+TBLFM: $3=$1*$2;N%.2f
`;
assert.match(recalculateOrgTableFormulas(combinedMode).text, /\|     \| 2\.5  \| 0\.00  \|/);

const unsupported = `| A | B |
|---+---|
| 1 |   |
#+TBLFM: $2='(identity $1)
`;
const failed = recalculateOrgTableFormulas(unsupported);
assert.equal(failed.ok, false);
assert.equal(failed.text, unsupported, "unsupported execution fails atomically");
assert.match(failed.diagnostics[0].message, /Emacs Lisp/);
const formulaDiagnostics = buildPublishDiagnosticsParams("file:///table.org2", unsupported);
assert.equal(formulaDiagnostics.diagnostics[0].code, "org2-table-formula");
assert.equal(formulaDiagnostics.diagnostics[0].range.start.line, 3);

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-table-formula-test-"));
try {
  const file = path.join(temp, "table.org2");
  fs.writeFileSync(file, source);
  const preview = spawnSync(process.execPath, ["dist/cli.js", "table", "recalculate", "--file", file, "--format", "json"], { cwd: path.resolve("."), encoding: "utf8" });
  assert.equal(preview.status, 0, preview.stderr);
  assert.equal(JSON.parse(preview.stdout).applied, false);
  assert.equal(fs.readFileSync(file, "utf8"), source, "preview does not write");
  const apply = spawnSync(process.execPath, ["dist/cli.js", "table", "recalculate", "--file", file, "--apply", "--format", "json"], { cwd: path.resolve("."), encoding: "utf8" });
  assert.equal(apply.status, 0, apply.stderr);
  assert.equal(JSON.parse(apply.stdout).applied, true);
  assert.match(fs.readFileSync(file, "utf8"), /15\.00/);
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}

console.log("table formula tests passed");
