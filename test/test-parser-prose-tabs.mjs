import assert from "node:assert/strict";
import { renderOrgDocumentToAppHtml } from "../dist/export.js";
import { parseOrgToCanonicalAst, parseOrgWithDiagnostics } from "../dist/parser.js";
import { printCanonicalAstToOrg } from "../dist/printer.js";

const source = `* Agent report

- Verified canonical checkout is clean with divergence \`0\t0\`.
  Copied output can contain\ttabs without changing list structure.

Ordinary prose can contain\ta copied tab too.
`;

const parsed = parseOrgWithDiagnostics(source);
assert.deepEqual(parsed.diagnostics, []);

const document = parseOrgToCanonicalAst(source, { sourceRanges: true });
assert.equal(printCanonicalAstToOrg(document), source);

const rendered = renderOrgDocumentToAppHtml(document);
assert.match(rendered.html, /divergence <code>0\t0<\/code>/);
assert.match(rendered.html, /Copied output can contain\ttabs/);
assert.match(rendered.html, /Ordinary prose can contain\ta copied tab too/);

console.log("parser prose tab tests: ok");
