import assert from "node:assert/strict";
import { renderAppHTML, renderCodeFileAppHTML } from "../dist/appHtmlRenderer.js";
import { parseOrgToCanonicalAst } from "../dist/parser.js";
import { renderOrgDocumentToHtml } from "../dist/export.js";

const snippet = '<style>body{background:rgb(255,0,128)}</style><div>Notes → preview</div><script>parent.hacked=true</script>';
for (const [open, close] of [["#+begin_src html", "#+end_src"], ["```html", "```"]]) {
  const text = `${open}\n${snippet}\n${close}\n`;
  const html = renderAppHTML(text, { sourcePath: "/tmp/chat-message.org" });
  assert.match(html, /class="org2-html-preview"/);
  assert.match(html, /sandbox=""/);
  assert.match(html, /srcdoc="&lt;!doctype html&gt;/);
  assert.match(html, /script-src 'none'/);
  assert.match(html, /<summary>HTML source<\/summary>/);
  assert.doesNotMatch(html, /<script>parent.hacked/);
  assert.doesNotMatch(html, /<style>body\{background/);
  const exported = renderOrgDocumentToHtml(parseOrgToCanonicalAst(text)).html;
  assert.doesNotMatch(exported, /<figure class="org2-html-preview"/, "ordinary exports retain source semantics");
}
assert.doesNotMatch(renderCodeFileAppHTML(snippet, "html", {sourcePath:"/tmp/example.html"}), /<figure class="org2-html-preview"/);
assert.doesNotMatch(renderAppHTML("#+begin_src html\n<div>partial", {sourcePath:"/tmp/chat.org"}), /<figure class="org2-html-preview"/, "streaming blocks wait for their closing delimiter");
console.log("✓ chat HTML previews");
