import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { updateCheckboxInText } from "../dist/checkbox.js";
import { parseOrgToCanonicalAst } from "../dist/parser.js";

for (const prefix of ["- ", "+ ", "  * ", "1. ", "12) ", "2. [@7] ", "    - "]) {
  let text = `* Work\r\n${prefix}[ ] Keep 🥑 and literal [X]\r\nOther text`;
  for (const [before, after] of [[" ", "-"], ["-", "X"], ["X", " "]]) {
    const result = updateCheckboxInText(text, 2);
    assert.equal(result.text, text.replace(`${prefix}[${before}]`, `${prefix}[${after}]`));
    assert.equal(result.column, prefix.length + 1);
    text = result.text;
  }
}
for (const eol of ["\n", "\r\n", "\r"]) {
  const text = `* Work${eol}- [ ] One${eol}- [-] Two${eol}- [x] Three`;
  assert.equal(updateCheckboxInText(text, 3).text, text.replace("[-]", "[X]"));
  assert.equal(updateCheckboxInText(text, 4).text, text.replace("[x]", "[ ]"));
  assert.equal(updateCheckboxInText(text, 4, "checked").text, text);
}
assert.equal(updateCheckboxInText("- [ ] Task", 1).text, "- [-] Task");
assert.equal(updateCheckboxInText("- [ ] First\r\n- [ ] Second\n- [ ] Third", 3).text, "- [ ] First\r\n- [ ] Second\n- [-] Third");
const nested = "- [ ] Parent\n  - [-] Child\n    - [X] Grandchild\n  - [ ] Sibling\n- [ ] Next\n";
assert.equal(updateCheckboxInText(nested, 3).text, nested.replace("[X]", "[ ]"));
assert.equal(updateCheckboxInText(nested, 4).text, nested.replace("[ ] Sibling", "[-] Sibling"));
const ast = parseOrgToCanonicalAst(nested, { sourceRanges: true, sourceLineOffset: 10 });
assert.deepEqual(ast.children[0].items[0].sourceRange, { startLine: 11, endLine: 14 });
assert.deepEqual(ast.children[0].items[0].children[1].items[0].sourceRange, { startLine: 12, endLine: 13 });
for (const source of [
  "#+begin_src org\n- [ ] Literal\n#+end_src",
  "#+begin_example\n- [ ] Literal\n#+end_example",
  "#+begin_comment\n- [ ] Literal\n#+end_comment",
  ":DRAWER:\n- [ ] Literal\n:END:",
  "* Heading\nProse [ ] literal\n- [ ] Actual",
  "* Heading\n* [ ] A heading\n- [ ] Actual",
]) assert.throws(() => updateCheckboxInText(source, 2), /not a list checkbox/);
for (const [source, line] of [
  ["- [ ] Parent\n  - [ ] Child\n    #+begin_src org\n    - [ ] Literal\n    #+end_src", 4],
  ["- [ ] Parent\n  :DRAWER:\n  - [ ] Literal\n  :END:", 3],
]) assert.throws(() => updateCheckboxInText(source, line), /not a list checkbox/);
assert.throws(() => updateCheckboxInText("- [ ] Task", 0), /line must be/);
assert.throws(() => updateCheckboxInText("- [ ] Task", 2), /not a list|line must be/);
assert.throws(() => updateCheckboxInText("- [ ] Task", 1, "wrong"), /status must be/);
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-checkbox-test-"));
try {
  const file = path.join(temp, "tasks with spaces.org");
  const original = "* Tasks\r\n- [ ] Keep this text\r\n- [X] Other";
  fs.writeFileSync(file, original, { mode: 0o640 });
  const run = (...args) => spawnSync(process.execPath, ["dist/cli.js", "checkbox", ...args], { encoding: "utf8" });
  const preview = run("--file", file, "--line", "2", "--json");
  assert.equal(preview.status, 0, preview.stderr);
  const result = JSON.parse(preview.stdout);
  assert.equal(result.newState, "indeterminate");
  assert.equal(result.applied, false);
  assert.equal(fs.readFileSync(file, "utf8"), original);
  const diff = run("--file", file, "--line", "2");
  assert.match(diff.stdout, /\+\- \[-\] Keep this text/);
  const applied = run("toggle", "--file", file, "--line", "2", "--if-revision", result.revision, "--apply", "--json");
  assert.equal(applied.status, 0, applied.stderr);
  assert.equal(JSON.parse(applied.stdout).applied, true);
  const changed = original.replace("[ ]", "[-]");
  assert.equal(fs.readFileSync(file, "utf8"), changed);
  assert.equal(fs.statSync(file).mode & 0o777, 0o640);
  const stale = run("--file", file, "--line", "2", "--if-revision", result.revision, "--apply");
  assert.notEqual(stale.status, 0);
  assert.match(stale.stderr, /changed since/);
  for (const args of [["--line", "1"], ["--line", "999"], ["--line", "2junk"], ["set", "--status", "bad", "--line", "2"], ["--line", "2", "--format", "bad"], ["--line", "2", "--typo"]]) {
    assert.notEqual(run(...args, "--file", file, "--apply").status, 0);
    assert.equal(fs.readFileSync(file, "utf8"), changed);
  }
  fs.writeFileSync(`${file}.lock`, "{}");
  try {
    const locked = run("--file", file, "--line", "2", "--apply");
    assert.notEqual(locked.status, 0);
    assert.match(locked.stderr, /already being updated/);
    assert.equal(fs.readFileSync(file, "utf8"), changed);
  } finally { fs.unlinkSync(`${file}.lock`); }
  const link = path.join(temp, "linked.org");
  fs.symlinkSync(file, link);
  const set = run("set", "--file", link, "--line", "2", "--status", "checked", "--apply", "--format", "text");
  assert.equal(set.status, 0, set.stderr);
  assert.equal(set.stdout, original.replace("[ ]", "[X]"));
  assert.equal(fs.readFileSync(file, "utf8"), set.stdout);
  assert.ok(fs.lstatSync(link).isSymbolicLink());
  const same = run("set", "--file", file, "--line", "2", "--status", "checked", "--apply", "--json");
  assert.equal(JSON.parse(same.stdout).changed, false);
  assert.equal(JSON.parse(same.stdout).applied, false);

  const cookieFile = path.join(temp, "progress.org");
  const cookieOriginal = "* TODO Grandparent [0/3]\r\n** TODO Parent [1/2]\r\n- [x] item a\r\n- [ ] item b\r\n** TODO Sibling [99%]\r\n- [ ] item c\r\n";
  fs.writeFileSync(cookieFile, cookieOriginal, { mode: 0o640 });
  const cookiePreview = run("fix-cookies", "--file", cookieFile, "--json");
  assert.equal(cookiePreview.status, 0, cookiePreview.stderr);
  const cookieResult = JSON.parse(cookiePreview.stdout);
  assert.equal(cookieResult.schema, "org2:checkbox-cookie-fix:v1");
  assert.equal(cookieResult.changed, true);
  assert.equal(cookieResult.applied, false);
  assert.deepEqual(cookieResult.edits.map(({ line, raw, expectedRaw, checked, total }) => ({ line, raw, expectedRaw, checked, total })), [
    { line: 1, raw: "[0/3]", expectedRaw: "[1/3]", checked: 1, total: 3 },
    { line: 5, raw: "[99%]", expectedRaw: "[0%]", checked: 0, total: 1 },
  ]);
  assert.equal(fs.readFileSync(cookieFile, "utf8"), cookieOriginal);
  const cookieDiff = run("fix-cookies", "--file", cookieFile);
  assert.equal(cookieDiff.status, 0, cookieDiff.stderr);
  assert.match(cookieDiff.stdout, /-\* TODO Grandparent \[0\/3\]/);
  assert.match(cookieDiff.stdout, /\+\* TODO Grandparent \[1\/3\]/);
  const cookieApplied = run("fix-cookies", "--file", cookieFile, "--if-revision", cookieResult.revision, "--apply", "--json");
  assert.equal(cookieApplied.status, 0, cookieApplied.stderr);
  assert.equal(JSON.parse(cookieApplied.stdout).applied, true);
  const cookieExpected = cookieOriginal.replace("[0/3]", "[1/3]").replace("[99%]", "[0%]");
  assert.equal(fs.readFileSync(cookieFile, "utf8"), cookieExpected);
  assert.equal(fs.statSync(cookieFile).mode & 0o777, 0o640);
  const cookieStaleRevision = run("fix-cookies", "--file", cookieFile, "--if-revision", cookieResult.revision, "--apply");
  assert.notEqual(cookieStaleRevision.status, 0);
  assert.match(cookieStaleRevision.stderr, /changed since/);
  const cookieNoop = run("fix-cookies", "--file", cookieFile, "--apply", "--json");
  assert.equal(cookieNoop.status, 0, cookieNoop.stderr);
  assert.equal(JSON.parse(cookieNoop.stdout).changed, false);
  assert.equal(JSON.parse(cookieNoop.stdout).applied, false);
  for (const args of [["fix-cookies", "--line", "1"], ["fix-cookies", "--status", "checked"]]) {
    const invalid = run(...args, "--file", cookieFile, "--apply");
    assert.notEqual(invalid.status, 0);
    assert.equal(fs.readFileSync(cookieFile, "utf8"), cookieExpected);
  }

  const opaqueCookieFile = path.join(temp, "opaque-progress.org");
  const opaqueCookieSource = "* Safe [1/1]\n#+begin_src org\n* Literal [0/1]\n- [ ] literal\n#+end_src\n- [X] real\n";
  fs.writeFileSync(opaqueCookieFile, opaqueCookieSource);
  const opaqueCookieFix = run("fix-cookies", "--file", opaqueCookieFile, "--apply", "--json");
  assert.equal(opaqueCookieFix.status, 0, opaqueCookieFix.stderr);
  assert.equal(JSON.parse(opaqueCookieFix.stdout).changed, false);
  assert.equal(fs.readFileSync(opaqueCookieFile, "utf8"), opaqueCookieSource);
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
console.log("✓ Checkbox cycles, targeted source edits, guarded CLI preview/apply, and invalid targets");
