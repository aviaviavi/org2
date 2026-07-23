#!/usr/bin/env node
import assert from "node:assert/strict";
import { isOrgTableDataLine, isOrgTableHline, parseOrgTableDataLine } from "../dist/orgTableData.js";

assert.equal(isOrgTableDataLine("not a table"), false);
assert.equal(isOrgTableDataLine("  | state | fetches |"), true);
assert.equal(parseOrgTableDataLine("not a table"), null);
assert.deepEqual(parseOrgTableDataLine("  | state | fetches |  "), ["state", "fetches"]);
assert.deepEqual(parseOrgTableDataLine("| CA | 42"), ["CA", "42"]);

assert.equal(isOrgTableHline(["-----+---------"]), true);
assert.equal(isOrgTableHline(["=====", "==="]), true);
assert.equal(isOrgTableHline(["state", "fetches"]), false);
assert.equal(isOrgTableHline([]), false);

console.log("✓ shared Org table data parsing");
