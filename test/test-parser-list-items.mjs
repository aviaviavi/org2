import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const { parseOrgToCanonicalAst } = await import(path.join(repo, "dist", "parser.js"));
const { printCanonicalAstToOrg } = await import(path.join(repo, "dist", "printer.js"));

const input = `* Tasks

- [ ] [0/1] Parent
  - [X] [100%] Child
    1. [ ] [0%] Deeper
- [x] Lowercase checked
- Block item
  #+begin_src text
  payload
  #+end_src
`;

const ast = parseOrgToCanonicalAst(input);

const headline = ast.children[0];
assert.equal(headline.type, "Headline");

const list = headline.children[0];
assert.equal(list.type, "List");
assert.equal(list.items.length, 3);

const parent = list.items[0];
assert.equal(parent.checkbox, "unchecked");
assert.deepEqual(parent.progressCookie, {
  type: "ProgressCookie",
  raw: "[0/1]",
  format: "fraction",
  done: 0,
  total: 1,
  percent: 0,
});

const nestedList = parent.children[1];
assert.equal(nestedList.type, "List");
const child = nestedList.items[0];
assert.equal(child.checkbox, "checked");
assert.equal(child.progressCookie.raw, "[100%]");
assert.equal(child.progressCookie.percent, 100);

const deeperList = child.children[1];
assert.equal(deeperList.type, "List");
assert.equal(deeperList.ordered, true);
const deeper = deeperList.items[0];
assert.equal(deeper.checkbox, "unchecked");
assert.equal(deeper.progressCookie.raw, "[0%]");

const lowercaseChecked = list.items[1];
assert.equal(lowercaseChecked.checkbox, "checked");

const blockItem = list.items[2];
const block = blockItem.children[1];
assert.equal(block.type, "SrcBlock");
assert.equal(block.begin.keywordRaw, "begin_src");
assert.equal(block.begin.afterKeywordRaw, " text");
assert.equal(block.bodyRaw, "  payload");
assert.equal(block.terminated, true);

assert.equal(printCanonicalAstToOrg(ast), input.replace("- [x] Lowercase checked", "- [X] Lowercase checked"));

console.log("✓ parser-list-items");
