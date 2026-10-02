#!/usr/bin/env node
// OpenOrg shows linked code files and app source blocks with native,
// script-free syntax highlighting from the shared renderer.
import assert from "node:assert/strict";
import { codeLanguageForPath, highlightCodeToHtml, normalizeCodeLanguage, tokenizeCode } from "../dist/codeHighlight.js";
import { renderAppHTML } from "../dist/appHtmlRenderer.js";
import { renderOrgDocumentToAppHtml, renderOrgDocumentToHtml } from "../dist/export.js";
import { parseOrgToCanonicalAst } from "../dist/parser.js";

const kinds = (source, language) => tokenizeCode(source, language).filter((t) => t.kind).map((t) => [t.kind, t.text]);
const roundTrips = (source, language) => assert.equal(tokenizeCode(source, language).map((t) => t.text).join(""), source, language);

// Paths: code files map to a language; documents stay Org/Markdown/CSV.
assert.equal(codeLanguageForPath("/repo/scripts/worker_lease.py"), "python");
assert.equal(codeLanguageForPath("src/App.TSX"), "typescript");
assert.equal(codeLanguageForPath("/repo/Dockerfile"), "dockerfile");
assert.equal(codeLanguageForPath("Makefile"), "makefile");
assert.equal(codeLanguageForPath("notes/a.org"), null);
assert.equal(codeLanguageForPath("notes/a.org2"), null);
assert.equal(codeLanguageForPath("README.md"), null);
assert.equal(codeLanguageForPath("data.csv"), null);
assert.equal(codeLanguageForPath("no-extension"), null);
assert.equal(normalizeCodeLanguage("emacs-lisp"), "lisp");
assert.equal(normalizeCodeLanguage("sh"), "shell");
assert.equal(normalizeCodeLanguage("unknownlang"), null);

// Lexical classes for the major languages.
const python = `import os\n# note\n@cache\ndef run(self, n=0x1F):\n    """multi\n    line"""\n    return "a\\"b" if n else None\n`;
roundTrips(python, "python");
assert.deepEqual(kinds(python, "python"), [
  ["keyword", "import"], ["comment", "# note"], ["meta", "@cache"], ["keyword", "def"], ["function", "run"],
  ["literal", "self"], ["number", "0x1F"], ["string", '"""multi\n    line"""'], ["keyword", "return"],
  ["string", '"a\\"b"'], ["keyword", "if"], ["keyword", "else"], ["literal", "None"],
]);
const ts = "const x: Map<string, number> = new Map(); // c\n/* b */ `t${x}`";
roundTrips(ts, "ts");
assert.deepEqual(kinds(ts, "ts"), [
  ["keyword", "const"], ["type", "Map"], ["type", "string"], ["type", "number"], ["keyword", "new"],
  ["type", "Map"], ["comment", "// c"], ["comment", "/* b */"], ["string", "`t${x}`"],
]);
assert.deepEqual(kinds('{"name": "org2", "n": 1.5, "ok": true}', "json"), [
  ["property", '"name"'], ["string", '"org2"'], ["property", '"n"'], ["number", "1.5"], ["property", '"ok"'], ["literal", "true"],
]);
assert.deepEqual(kinds("echo \"$HOME\" ${PATH} # hi", "bash"), [["string", '"$HOME"'], ["variable", "${PATH}"], ["comment", "# hi"]]);
assert.deepEqual(kinds("SELECT id FROM t WHERE n > 2", "sql"), [["keyword", "SELECT"], ["keyword", "FROM"], ["keyword", "WHERE"], ["number", "2"]]);
assert.deepEqual(kinds('<a href="x">&amp;</a><!-- c -->', "html"), [
  ["tag", "<a"], ["attr", "href"], ["string", '"x"'], ["tag", ">"], ["literal", "&amp;"], ["tag", "</a"], ["tag", ">"], ["comment", "<!-- c -->"],
]);
for (const [language, source] of [["swift", 'let s = """\nx\n"""\n#if DEBUG\n'], ["go", "s := `raw\\n`"], ["rust", "fn main() { let v: Vec<u8> = vec![]; }"], ["yaml", "key: value # c\nlist:\n  - 'a'"], ["css", "a { color: #fff; }"]]) {
  roundTrips(source, language);
  assert.ok(kinds(source, language).length > 0, language);
}
assert.equal(highlightCodeToHtml("<script>alert(1)</script>", "plaintext"), "&lt;script&gt;alert(1)&lt;/script&gt;");
assert.equal(highlightCodeToHtml('x = "<b>"', "python"), 'x = <span class="org2-tok-string">&quot;&lt;b&gt;&quot;</span>');

// A linked code file renders as one highlighted block with every line
// addressable, never collapsed, and never parsed as Org markup.
const lines = Array.from({ length: 260 }, (_, i) => (i === 0 ? "* not an org heading" : `x_${i} = ${i}  # line ${i + 1}`));
const html = renderAppHTML(lines.join("\n") + "\n", { sourcePath: "/repo/tool.py" });
assert.ok(html.includes('<pre class="org2-src org2-code-file language-python">'));
assert.ok(!html.includes('<details class="org2-large-source"'), "Code files stay expanded");
assert.ok(!html.includes('class="org2-headline'), "Code is not parsed as Org");
assert.ok(html.includes('<span class="org2-code-line" data-org2-start-line="27" data-org2-end-line="27">'));
assert.ok(html.includes('data-org2-start-line="260"'));
assert.ok(!html.includes('data-org2-start-line="261"'));
assert.ok(html.includes('<span class="org2-tok-comment"># line 27</span>'));
assert.ok(html.includes(".org2-tok-keyword"), "Token styles ship with the app document style");
assert.ok(!/<script(?![^>]*org2-app-document-script)/.test(html.replace(/<script id="org2-app-document-script">[\s\S]*?<\/script>/, "")), "No highlighter script is injected");

// Org documents still render as Org; app source blocks are highlighted while
// published HTML keeps plain code for its configured highlighter.
const org = parseOrgToCanonicalAst("* Heading\n#+begin_src python\ndef f():\n    return 1\n#+end_src\n", { sourceRanges: true });
const app = renderOrgDocumentToAppHtml(org).html;
assert.ok(app.includes('<span class="org2-tok-keyword">def</span>'));
assert.ok(renderAppHTML("* Heading\n", { sourcePath: "/repo/notes/a.org", referenceEmbeds: true }).includes("org2-headline"));
const published = renderOrgDocumentToHtml(org, { profile: "publish" }).html;
assert.ok(!published.includes('class="org2-tok-') && !published.includes("org2-tok-keyword"));

console.log("Code highlight tests passed: language detection, tokens, code-file view, and app source blocks.");
