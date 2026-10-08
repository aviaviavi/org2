import assert from "node:assert/strict";
import { renderAppHTML, renderCodeFileAppHTML } from "../dist/appHtmlRenderer.js";
import { parseOrgToCanonicalAst } from "../dist/parser.js";
import { renderOrgDocumentToHtml } from "../dist/export.js";

const decodeSrcdoc = (html) => {
  const encoded = /srcdoc="([^"]*)"/.exec(html)?.[1] || "";
  return encoded.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
};

const snippet = '<style>body{background:rgb(255,0,128)}</style><div id="out">Notes → preview</div><script>document.getElementById("out").textContent = String(6 * 7)</script>';
for (const [open, close] of [["#+begin_src html", "#+end_src"], ["```html", "```"]]) {
  const text = `${open}\n${snippet}\n${close}\n`;
  const html = renderAppHTML(text, { sourcePath: "/tmp/chat-message.org" });
  assert.match(html, /class="org2-html-preview"/);
  // Scripts run, but only in an opaque origin: never same-origin, never top navigation.
  const sandbox = /<iframe title="HTML preview" sandbox="([^"]*)"/.exec(html)?.[1];
  assert.equal(sandbox, "allow-scripts allow-forms allow-popups");
  assert.doesNotMatch(sandbox, /allow-same-origin|allow-top-navigation/);
  assert.match(/<iframe title="HTML preview"[^>]*>/.exec(html)?.[0] || "", /data-org2-autosize="true"/);
  assert.match(html, /srcdoc="&lt;!doctype html&gt;/);
  const frame = decodeSrcdoc(html);
  const policy = /Content-Security-Policy" content="([^"]*)"/.exec(frame)?.[1] || "";
  assert.match(policy, /script-src 'unsafe-inline' 'unsafe-eval' https: blob:/);
  assert.match(policy, /connect-src https:/);
  assert.match(policy, /form-action 'none'/);
  assert.match(policy, /frame-src 'none'/);
  assert.match(policy, /base-uri 'none'/);
  assert.ok(frame.includes(snippet), "the snippet, including its script, reaches the frame unchanged");
  assert.match(frame, /org2-frame-size/, "auto-sized frames report their content height");
  assert.match(html, /<summary>HTML source<\/summary>/);
  assert.doesNotMatch(html, /<script>document.getElementById/, "the snippet never runs in the host document");
  assert.doesNotMatch(html, /<style>body\{background/);
  const exported = renderOrgDocumentToHtml(parseOrgToCanonicalAst(text)).html;
  assert.doesNotMatch(exported, /<figure class="org2-html-preview"/, "ordinary exports retain source semantics");
}

const previewFrame = (html) => /<iframe title="HTML preview"[^>]*>/.exec(html)?.[0] || "";
const fixed = previewFrame(renderAppHTML("#+begin_src html :height 240\n<canvas></canvas>\n#+end_src\n", { sourcePath: "/tmp/chat.org" }));
assert.match(fixed, /height:240px/);
assert.doesNotMatch(fixed, /data-org2-autosize/);
assert.doesNotMatch(decodeSrcdoc(fixed), /org2-frame-size/);
assert.match(previewFrame(renderAppHTML("#+begin_src html :height 99999\n<p>x</p>\n#+end_src\n", { sourcePath: "/tmp/chat.org" })), /height:1600px/);

assert.doesNotMatch(renderCodeFileAppHTML(snippet, "html", {sourcePath:"/tmp/example.html"}), /<figure class="org2-html-preview"/);
assert.doesNotMatch(renderAppHTML("#+begin_src html\n<div>partial", {sourcePath:"/tmp/chat.org"}), /<figure class="org2-html-preview"/, "streaming blocks wait for their closing delimiter");
console.log("✓ chat HTML previews");
