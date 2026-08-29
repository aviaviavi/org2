import assert from "node:assert/strict";
import fs from "node:fs";
import { renderOrgDocumentToAppHtml, renderOrgDocumentToHtml } from "../dist/export.js";
import { parseOrgToCanonicalAst } from "../dist/parser.js";
import { renderPresentationToBeamer } from "../dist/presentation.js";
import { printCanonicalAstToOrg } from "../dist/printer.js";

const source = fs.readFileSync("spec/v0/tests/0074-org-compatible-rich-syntax.org", "utf8");
const document = parseOrgToCanonicalAst(source, { sourceRanges: true });
const headline = document.children.find((node) => node.type === "Headline");
assert(headline && headline.type === "Headline");
assert.equal(headline.todo, "WAITING");
assert.equal(headline.priority, "A");
assert.equal(headline.commented, true);

const nodeTypes = new Set(headline.children.map((node) => node.type));
for (const expected of [
  "FootnoteDefinition",
  "List",
  "HorizontalRule",
  "FixedWidth",
  "Block",
  "DynamicBlock",
  "LatexEnvironment",
  "DiarySexp",
  "Table",
]) {
  assert(nodeTypes.has(expected), `expected ${expected}`);
}

const paragraph = headline.children.find((node) => node.type === "Paragraph");
assert(paragraph && paragraph.type === "Paragraph");
const inlineTypes = new Set(paragraph.children.map((node) => node.type));
for (const expected of [
  "Citation",
  "FootnoteReference",
  "Entity",
  "LatexFragment",
  "ExportSnippet",
  "Target",
  "Link",
  "LineBreak",
]) {
  assert(inlineTypes.has(expected), `expected ${expected}`);
}

const list = headline.children.find((node) => node.type === "List");
assert(list && list.type === "List");
assert.equal(list.items[0]?.counter, 3);
assert.equal(list.items[0]?.checkbox, "indeterminate");
assert.equal(list.items[0]?.descriptionTag?.[0]?.type, "Text");

const literalSeparator = parseOrgToCanonicalAst("- Example =term :: definition= stays literal\n");
const literalItem = literalSeparator.children[0]?.type === "List" ? literalSeparator.children[0].items[0] : undefined;
assert.equal(literalItem?.descriptionTag, undefined);

const table = headline.children.find((node) => node.type === "Table");
assert(table && table.type === "Table");
const tableRows = table.rows.filter((row) => row.type === "TableRow");
assert.equal(tableRows[1]?.contents?.[0]?.[1]?.type, "Script");
assert.equal(tableRows[1]?.contents?.[1]?.[0]?.type, "Target");

assert.equal(printCanonicalAstToOrg(document), source);

const leadingComment = "* COMMENT TODO remains title text\n";
const leadingCommentHeadline = parseOrgToCanonicalAst(leadingComment).children[0];
assert(leadingCommentHeadline && leadingCommentHeadline.type === "Headline");
assert.equal(leadingCommentHeadline.commented, true);
assert.equal(leadingCommentHeadline.todo, undefined);
assert.equal(printCanonicalAstToOrg(parseOrgToCanonicalAst(leadingComment)), leadingComment);

const lowercasePriority = "* [#a] Preserve priority bytes\n";
assert.equal(printCanonicalAstToOrg(parseOrgToCanonicalAst(lowercasePriority)), lowercasePriority);

const published = renderOrgDocumentToHtml(document).html;
assert.match(published, /<cite class="org2-citation"/);
assert.match(published, /see @roe2025 p\. 4/);
assert.match(published, /<mark>yes<\/mark>/);
assert.match(published, /<aside class="org2-footnote-definition"/);
assert.match(published, /<dl class="org2-description-list"/);
assert.match(published, /<hr/);
assert.match(published, /<sub>2<\/sub>/);
assert.doesNotMatch(renderOrgDocumentToHtml(parseOrgToCanonicalAst("IN_PROGRESS\n")).html, /<sub>/);

const app = renderOrgDocumentToAppHtml(document).html;
assert.match(app, /class="org2-priority"/);
assert.match(app, /class="org2-checkbox-mixed"/);
assert.match(app, /class="org2-export-snippet">&lt;mark&gt;yes&lt;\/mark&gt;/);
assert.doesNotMatch(app, /<mark>yes<\/mark>/);

const beamer = renderPresentationToBeamer(parseOrgToCanonicalAst(`#+LATEX_CLASS: beamer
* Section
** Rich syntax
- Term :: value H_2O\\\\
: fixed width
-----
\\begin{equation}
x = y
\\end{equation}
`)).tex;
assert.match(beamer, /\\begin\{description\}/);
assert.match(beamer, /H\\textsubscript\{2\}O\\\\/);
assert.match(beamer, /\\begin\{verbatim\}\nfixed width/);
assert.match(beamer, /\\noindent\\rule\{\\linewidth\}\{0\.4pt\}/);
assert.match(beamer, /\\begin\{equation\}\nx = y\n\\end\{equation\}/);

const textMate = JSON.parse(fs.readFileSync("editors/vscode-org2/syntaxes/org2.tmLanguage.json", "utf8"));
assert(textMate.repository.advancedElements);
assert(textMate.repository.orgObjects);

console.log("org syntax coverage tests: ok");
