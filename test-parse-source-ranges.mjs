import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-parse-ranges-"));
try {
  const file = path.join(tmp, "range.org2");
  fs.writeFileSync(file, `#+TITLE: Range Test

* TODO Parent
SCHEDULED: <2026-06-12 Fri>
Body line

** Child
Child body
`, "utf8");

  const defaultAst = JSON.parse(execFileSync("node", ["dist/parse.js", file], { encoding: "utf8" }));
  assert.equal(defaultAst.children[0].sourceRange, undefined);
  assert.equal(defaultAst.children[1].sourceRange, undefined);

  const rangedAst = JSON.parse(execFileSync("node", ["dist/parse.js", "--source-ranges", file], { encoding: "utf8" }));
  assert.deepEqual(rangedAst.children[0].sourceRange, { startLine: 1, endLine: 1 });
  assert.deepEqual(rangedAst.children[1].sourceRange, { startLine: 3, endLine: 8 });

  const parent = rangedAst.children[1];
  assert.equal(parent.type, "Headline");
  assert.deepEqual(parent.children[0].sourceRange, { startLine: 4, endLine: 4 });
  assert.deepEqual(parent.children[1].sourceRange, { startLine: 5, endLine: 5 });
  assert.deepEqual(parent.children[2].sourceRange, { startLine: 7, endLine: 8 });

  const stdinAst = JSON.parse(execFileSync("node", [
    "dist/parse.js",
    "--source-ranges",
    "--source-line-offset",
    "40",
    "-",
  ], {
    encoding: "utf8",
    input: "* TODO From stdin\nBody\n",
  }));
  assert.deepEqual(stdinAst.children[0].sourceRange, { startLine: 41, endLine: 42 });
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
