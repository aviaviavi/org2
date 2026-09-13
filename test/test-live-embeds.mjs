import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { createLiveEmbedResolver, liveEmbedDirective } from "../dist/liveEmbeds.js";
import { parseOrgToCanonicalAst } from "../dist/parser.js";
import { printCanonicalAstToOrg } from "../dist/printer.js";
import { renderOrgDocumentToAppHtml, renderOrgDocumentToHtml } from "../dist/export.js";
import { preparePublishedDocument, prepareGoogleDocsUpload } from "../dist/publishDocument.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-live-embeds-"));
const outside = fs.mkdtempSync(path.join(os.tmpdir(), "org2-live-embeds-outside-"));
const host = path.join(root, "host.org");
const note = path.join(root, "notes", "source.org2");
const source = `#+TITLE: Source note
:PROPERTIES:
:ID: whole-note
:END:
Preamble outside heading.
* Embedded heading
:PROPERTIES:
:ID: selected-heading
:END:
Live source text.
[[*Child][Jump within source]]

[[file:another.org][Related source]]
[[another.org][Bare relative source]]
[[FILE:another.org::*Section/Child][Case-insensitive source with heading search]]
[[../host.org][Parent note]]
[[Another Heading][Fuzzy heading title]]
[[id:whole-note][Stable note link]]
[[https://example.com/article.org][External note]]
[[file:~/notes/another.org][Home relative note]]

[[file:image.png]]
** Child
Child text.
* Excluded sibling
Private sibling text.
`;
const decode = value => value.replace(/&quot;/g, '"').replace(/&#96;/g, "`").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
function allFrames(html) {
  return [...html.matchAll(/srcdoc="([^"]*)"/g)].flatMap(match => {
    const decoded = decode(match[1]);
    return [decoded, ...allFrames(decoded)];
  });
}
function render(text, resolver = createLiveEmbedResolver({ sourcePath: host })) {
  return renderOrgDocumentToAppHtml(parseOrgToCanonicalAst(text, { sourceRanges: true }), { sourcePath: host, embedResolver: resolver }).html;
}
function cli(args, options = {}) {
  return spawnSync(process.execPath, ["dist/cli.js", "embed", ...args], { encoding: "utf8", ...options });
}
try {
  fs.mkdirSync(path.dirname(note));
  fs.writeFileSync(path.join(root, "org2.json"), "{}");
  fs.writeFileSync(host, "#+TITLE: Host\n#+EMBED: id:selected-heading\n");
  fs.writeFileSync(note, source);
  assert.equal(liveEmbedDirective(" id:Selected-Heading "), "#+EMBED: id:selected-heading");
  for (const invalid of ["https://example.com", "file:/private/note.org", "file:~/notes.org", "file:note.org::2", "id:x\n#+EMBED: file:secret.org", "file:image.png"]) {
    assert.throws(() => liveEmbedDirective(invalid));
  }
  const resolve = createLiveEmbedResolver({ sourcePath: host });
  const heading = resolve("id:selected-heading");
  assert.equal(heading.ok, true);
  assert.equal(heading.line, 6);
  assert.equal(heading.title, "Embedded heading");
  const headingSource = printCanonicalAstToOrg(heading.document);
  assert.match(headingSource, /Child text/);
  assert.doesNotMatch(headingSource, /Private sibling|Preamble outside/);
  assert.match(printCanonicalAstToOrg(resolve("id:whole-note").document), /Private sibling/);
  assert.equal(resolve("file:notes/source.org2").ok, true);
  assert.equal(resolve("id:missing").ok, false);
  assert.match(resolve("file:missing.org").message, /missing/);
  const parsed = parseOrgToCanonicalAst("#+TITLE: Host\n#+EMBED: id:selected-heading\n");
  assert.match(printCanonicalAstToOrg(parsed), /#\+EMBED: id:selected-heading/);
  const html = render("#+TITLE: Host\n#+EMBED: id:selected-heading\n");
  assert.match(html, /data-org2-live-embed="true"/);
  assert.match(html, /org2-workspace:\/\/open-link\?target=id%3Aselected-heading/);
  assert.match(html, /sandbox="allow-same-origin allow-top-navigation-by-user-activation"/);
  const frame = allFrames(html)[0];
  assert.match(frame, /Live source text/);
  assert.match(frame, /Child text/);
  assert.ok(frame.includes(encodeURIComponent(`file:${fs.realpathSync(note)}::${source.split("\n").findIndex(line => line === "** Child") + 1}`)));
  assert.doesNotMatch(frame, /Private sibling|data-org2-start-line|<script|allow-scripts/);
  assert.match(frame, new RegExp(encodeURIComponent(`file:${path.join(fs.realpathSync(root), "notes", "another.org")}`)));
  assert.ok(frame.includes(`target=${encodeURIComponent(`file:${path.join(fs.realpathSync(root), "notes", "another.org")}`)}">Bare relative source</a>`));
  assert.ok(frame.includes(`target=${encodeURIComponent(`file:${path.join(fs.realpathSync(root), "notes", "another.org")}::*Section/Child`)}">Case-insensitive source with heading search</a>`));
  assert.ok(frame.includes(`target=${encodeURIComponent(`file:${path.join(fs.realpathSync(root), "host.org")}`)}">Parent note</a>`));
  assert.ok(frame.includes(`target=${encodeURIComponent("Another Heading")}">Fuzzy heading title</a>`));
  assert.ok(frame.includes('target=id%3Awhole-note">Stable note link</a>'));
  assert.ok(frame.includes('href="https://example.com/article.org">External note</a>'));
  assert.ok(frame.includes(`target=${encodeURIComponent("file:~/notes/another.org")}">Home relative note</a>`));
  assert.match(frame, new RegExp(`org2-resource://local\\?target=${encodeURIComponent(path.join(fs.realpathSync(root), "notes", "image.png"))}`));

  // Embedded fragments route anchors through the full canonical source AST.
  // A sibling outside the rendered fragment remains navigable, and examples
  // cannot create fake targets or make real CUSTOM_IDs falsely ambiguous.
  const anchorFile = path.join(root, "notes", "anchors.org");
  const anchorSource = `* Embedded fragment
:PROPERTIES:
:ID: embed-with-anchors
:END:
[[#sibling-anchor][Custom sibling]]
[[*Actual sibling][Title sibling]]
[[#missing-anchor][Missing anchor]]
[[#duplicate-anchor][Ambiguous anchor]]
#+begin_src org
* Example sibling
:PROPERTIES:
:CUSTOM_ID: sibling-anchor
:END:
#+end_src
* Actual sibling
:PROPERTIES:
:CUSTOM_ID: sibling-anchor
:END:
Sibling content is outside fragment.
* First duplicate
:PROPERTIES:
:CUSTOM_ID: duplicate-anchor
:END:
* Second duplicate
:PROPERTIES:
:CUSTOM_ID: duplicate-anchor
:END:
`;
  fs.writeFileSync(anchorFile, anchorSource);
  const anchorFrame = allFrames(render("#+EMBED: id:embed-with-anchors\n"))[0];
  const actualAnchorLine = anchorSource.split("\n").indexOf("* Actual sibling") + 1;
  const numericAnchorTarget = encodeURIComponent(`file:${fs.realpathSync(anchorFile)}::${actualAnchorLine}`);
  assert.ok(anchorFrame.includes(`target=${numericAnchorTarget}">Custom sibling</a>`));
  assert.ok(anchorFrame.includes(`target=${numericAnchorTarget}">Title sibling</a>`));
  const anchorSourceTarget = encodeURIComponent(`file:${fs.realpathSync(anchorFile)}`);
  assert.ok(anchorFrame.includes(`target=${anchorSourceTarget}">Missing anchor</a>`));
  assert.ok(anchorFrame.includes(`target=${anchorSourceTarget}">Ambiguous anchor</a>`));
  assert.doesNotMatch(anchorFrame, /Sibling content is outside fragment/);

  // Re-rendering reads current canonical content without copying it into the host.
  const beforeHost = fs.readFileSync(host, "utf8");
  fs.writeFileSync(note, source.replace("Live source text.", "Fresh source text."));
  assert.match(allFrames(render(beforeHost))[0], /Fresh source text/);
  assert.equal(fs.readFileSync(host, "utf8"), beforeHost);
  fs.writeFileSync(path.join(root, "duplicate.org"), "* Duplicate\n:PROPERTIES:\n:ID: selected-heading\n:END:\n");
  assert.match(render(beforeHost), /ambiguous/);
  fs.unlinkSync(path.join(root, "duplicate.org"));

  // ID projections must refer to actual full-document AST nodes, never examples.
  fs.writeFileSync(path.join(root, "heading-example.org"), "#+begin_src org\n* Example heading\n:PROPERTIES:\n:ID: example-heading-id\n:END:\nEXAMPLE CONTENT\n#+end_src\n");
  fs.writeFileSync(path.join(root, "drawer-example.org"), "#+begin_example\n:PROPERTIES:\n:ID: example-file-id\n:END:\nEXAMPLE CONTENT\n#+end_example\n");
  fs.writeFileSync(path.join(root, "keyword-example.org"), "#+begin_src org\n#+ID: example-keyword-id\nEXAMPLE CONTENT\n#+end_src\n");
  for (const id of ["example-heading-id", "example-file-id", "example-keyword-id"]) {
    const resolution = createLiveEmbedResolver({ sourcePath: host })(`id:${id}`);
    assert.equal(resolution.ok, false, id);
    assert.match(resolution.message, /canonical note or heading/);
    assert.doesNotMatch(render(`#+EMBED: id:${id}\n`), /EXAMPLE CONTENT/);
    assert.equal(cli(["resolve", "--target", `id:${id}`, "--file", host]).status, 1);
  }
  fs.writeFileSync(path.join(root, "fake-duplicate.org"), "#+begin_example\n* Example duplicate\n:PROPERTIES:\n:ID: selected-heading\n:END:\n#+end_example\n");
  assert.equal(createLiveEmbedResolver({ sourcePath: host })("id:selected-heading").ok, true, "Example IDs must not create false ambiguity");
  fs.writeFileSync(path.join(root, "bounded-source.org"), "* Actual heading\n:PROPERTIES:\n:ID: actual-with-example\n:END:\n#+begin_src org\n* Fake sibling\n#+end_src\nKeep content after example.\n* Actual sibling\nExclude this sibling.\n");
  const actual = createLiveEmbedResolver({ sourcePath: host })("id:actual-with-example");
  assert.equal(actual.ok, true);
  assert.match(printCanonicalAstToOrg(actual.document), /Keep content after example/);
  assert.doesNotMatch(printCanonicalAstToOrg(actual.document), /Exclude this sibling/);
  const staleResolver = createLiveEmbedResolver({ sourcePath: host });
  assert.equal(staleResolver("id:actual-with-example").ok, true);
  fs.writeFileSync(path.join(root, "bounded-source.org"), "* Actual heading\n:PROPERTIES:\n:ID: renamed-id\n:END:\nDifferent identity.\n");
  assert.equal(staleResolver("id:actual-with-example").ok, false, "A cached projection cannot substitute a different current ID at the same line");

  fs.writeFileSync(path.join(outside, "secret.org"), "Never disclose outside content");
  fs.symlinkSync(path.join(outside, "secret.org"), path.join(root, "escape.org"));
  assert.match(render("#+EMBED: file:escape.org\n"), /outside the active corpus/);
  assert.doesNotMatch(render(`#+EMBED: file:../${path.basename(outside)}/secret.org\n`), /Never disclose outside content/);

  fs.writeFileSync(path.join(root, "cycle.org"), "#+EMBED: file:host.org\n");
  assert.match(allFrames(render("#+EMBED: file:cycle.org\n")).join("\n"), /Embed cycle stopped/);
  for (let i = 0; i < 7; i++) fs.writeFileSync(path.join(root, `depth${i}.org`), `#+EMBED: file:depth${i + 1}.org\n`);
  assert.match(allFrames(render("#+EMBED: file:depth0.org\n")).join("\n"), /Embed limit reached/);
  assert.match(render(Array(34).fill("#+EMBED: file:notes/source.org2").join("\n")), /Embed limit reached/);
  fs.writeFileSync(path.join(root, "large.org"), "x".repeat(256 * 1024 + 1));
  assert.match(render("#+EMBED: file:large.org\n"), /256 KiB content limit/);

  // Raw HTML and mutation widgets are inert in the script-free embedded frame.
  fs.writeFileSync(path.join(root, "unsafe.org"), "#+HTML_HEAD: <script>bad()</script>\n#+begin_export html\n<script>bad()</script>\n#+end_export\n");
  assert.doesNotMatch(allFrames(render("#+EMBED: file:unsafe.org\n"))[0], /<script/);
  for (const profile of [undefined, "publish"]) {
    const published = renderOrgDocumentToHtml(parsed, { sourcePath: host, profile, embedResolver: () => { throw new Error("export must not resolve"); } }).html;
    assert.match(published, /Live embed reference: id:selected-heading/);
    assert.doesNotMatch(published, /Live source text|Fresh source text|<iframe/);
  }
  const publication = preparePublishedDocument({ sourceText: beforeHost, sourcePath: host });
  assert.match(publication.html, /Live embed omitted from export/);
  assert.doesNotMatch(publication.html, /selected-heading|Fresh source|source\.org2/);
  const docx = prepareGoogleDocsUpload(publication);
  assert.ok(docx);

  const resolvedCLI = cli(["resolve", "--target", "id:selected-heading", "--file", host, "--json"]);
  assert.equal(resolvedCLI.status, 0, resolvedCLI.stderr);
  assert.equal(JSON.parse(resolvedCLI.stdout).directive, "#+EMBED: id:selected-heading");
  assert.doesNotMatch(resolvedCLI.stdout, /Fresh source text/);
  assert.equal(cli(["resolve", "--target", "id:missing", "--file", host]).status, 1);
  const renderedCLI = spawnSync(process.execPath, ["dist/render-html.js", "--source-path", host], { input: beforeHost, encoding: "utf8" });
  assert.equal(renderedCLI.status, 0, renderedCLI.stderr);
  assert.match(allFrames(renderedCLI.stdout)[0], /Fresh source text/);
  const referenceCLI = spawnSync(process.execPath, ["dist/render-html.js", "--source-path", host, "--reference-embeds"], { input: beforeHost, encoding: "utf8" });
  assert.equal(referenceCLI.status, 0, referenceCLI.stderr);
  assert.doesNotMatch(referenceCLI.stdout, /Fresh source text/);
  fs.unlinkSync(note);
  assert.match(render(beforeHost), /missing/);
  console.log("Live embeds: resolution, renderer, refresh, bounds, navigation, CLI and disclosure-safe exports passed.");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
  fs.rmSync(outside, { recursive: true, force: true });
}
