import assert from "node:assert/strict";
import { parseOrgWithDiagnostics } from "../dist/parser.js";

const validOrg = `* Headline 1
Some content

** Nested headline
- List item
- Another item
`;
const result1 = parseOrgWithDiagnostics(validOrg);
assert.equal(result1.diagnostics.length, 0, "valid org should have no diagnostics");
assert.equal(result1.ast.type, "Document");

const crlfOrg = "* Headline\r\nContent\r\n";
const result2 = parseOrgWithDiagnostics(crlfOrg);
assert.equal(result2.diagnostics.length, 1, "CRLF should produce a diagnostic");
assert.deepEqual(result2.diagnostics[0], {
  line: 1,
  column: 1,
  message: "Unsupported line endings: CRLF",
});

const plainParagraph = parseOrgWithDiagnostics(`Normal paragraph
*Invalid plain text, not a headline
More content`);
assert.equal(plainParagraph.diagnostics.length, 0, "star-prefixed prose without whitespace is plain paragraph text");

const invalidHeadline = parseOrgWithDiagnostics(`Normal paragraph
*  Invalid double-space headline
More content`);
assert.equal(invalidHeadline.diagnostics.length, 1, "malformed headline spacing should produce a diagnostic");
assert.deepEqual(invalidHeadline.diagnostics[0], {
  line: 2,
  column: 2,
  message: "Invalid headline; only a single space is allowed after '*'",
});

const tabOrg = `#+TITLE:\tMyTitle
Content`;
const result4 = parseOrgWithDiagnostics(tabOrg);
assert.equal(result4.diagnostics.length, 1, "tab character in keyword line should produce a diagnostic");
assert.deepEqual(result4.diagnostics[0], {
  line: 1,
  column: 9,
  message: "Unsupported construct: tab character",
});

assert.equal(result2.ast.type, "Document", "diagnostic results should still return a document node");
assert.deepEqual(result2.ast.children, [], "fatal parse diagnostics should return an empty document");

assert.ok(Array.isArray(result1.diagnostics));
assert.ok(result2.diagnostics.every((diagnostic) =>
  typeof diagnostic.line === "number" &&
  typeof diagnostic.column === "number" &&
  typeof diagnostic.message === "string",
));

console.log("✓ parser diagnostics");
