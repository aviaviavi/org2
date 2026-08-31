import assert from "node:assert/strict";
import fs from "node:fs";
import { parseOrgToCanonicalAst } from "../dist/parser.js";

const suite = JSON.parse(fs.readFileSync("spec/v0/parsing-cases.json", "utf8"));

assert.equal(suite.version, "0");
assert.ok(Array.isArray(suite.cases));

for (const entry of suite.cases) {
  assert.deepEqual(
    parseOrgToCanonicalAst(entry.source),
    entry.expectedAst,
    `language conformance case failed: ${entry.id}`,
  );
}

console.log(`language specification tests passed (${suite.cases.length} cases)`);
