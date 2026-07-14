import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

function analyze(source, args = []) {
  const result = spawnSync(process.execPath, ["dist/editor-analysis.js", ...args], {
    cwd: process.cwd(),
    encoding: "utf8",
    input: source,
  });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

function analyzeFailure(args) {
  const result = spawnSync(process.execPath, ["dist/editor-analysis.js", ...args], {
    cwd: process.cwd(),
    encoding: "utf8",
    input: "* Parent\n",
  });
  assert.equal(result.status, 2, `expected usage error for ${args.join(" ")}`);
  assert.match(result.stderr, /Usage:/);
}

const valid = analyze("* TODO Parent\nBody\n** Child\n", ["--source-line-offset", "20"]);
assert.equal(valid.diagnostics.length, 0);
assert.equal(valid.document.children[0].sourceRange.startLine, 21);
assert.equal(valid.document.children[0].children[1].sourceRange.startLine, 23);

analyzeFailure(["--source-line-offset", "1.5"]);
analyzeFailure(["--source-line-offset=12px"]);
analyzeFailure(["--source-line-offset="]);
analyzeFailure(["--source-line-offset=9007199254740992"]);

const invalid = analyze("* Parent\n:PROPERTIES:\n:ID: one\n");
assert.equal(invalid.document.type, "Document");
assert.equal(invalid.diagnostics.length, 1);
assert.equal(invalid.diagnostics[0].line, 4);
assert.match(invalid.diagnostics[0].message, /property drawer/i);

console.log("editor analysis tests: ok");
