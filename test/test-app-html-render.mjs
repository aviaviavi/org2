import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { renderOrgCharts } from "../dist/chartRender.js";
import { findBacklinksInText } from "../dist/backlinks.js";
import { parseOrgColorBindingTarget } from "../dist/colorBinding.js";
import { renderOrgDocumentToAppHtml, renderOrgDocumentToHtml, renderOrgExportIndexToHtml } from "../dist/export.js";
import { parseOrgToCanonicalAst } from "../dist/parser.js";
import { printCanonicalAstToOrg } from "../dist/printer.js";

// Audit runs can carry megabytes in one source block. Keep every byte and
// source citation available, but defer its layout until the reader expands it.
for (const { body, collapsed, lines } of [
  { body: "x".repeat(32_768), collapsed: false, lines: 1 },
  { body: "x".repeat(32_769), collapsed: true, lines: 1 },
  { body: Array(200).fill("small").join("\n"), collapsed: false, lines: 200 },
  { body: Array(201).fill("small").join("\n"), collapsed: true, lines: 201 },
  { body: Array(5_500).fill('  { "evidence": "<script>&full payload</script>" }').join("\n"), collapsed: true, lines: 5_500 },
]) {
  const doc = parseOrgToCanonicalAst(`#+begin_src json :org2-agent-run\n${body}\n#+end_src\n`, {
    sourceRanges: true, sourceLineOffset: 20,
  });
  const html = renderOrgDocumentToAppHtml(doc).html;
  assert.equal(html.includes('<details class="org2-large-source"'), collapsed);
  if (collapsed) {
    assert.ok(html.includes(`<details class="org2-large-source" data-org2-start-line="21" data-org2-end-line="${lines + 22}"><summary>json source · ${lines} lines</summary><pre`));
    assert.ok(!html.includes('<details class="org2-large-source" open'));
  }
  const code = /<code class="language-json">([\s\S]*?)<\/code>/.exec(html)?.[1];
  assert.equal(code, body.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"));
  for (const profile of [undefined, "publish"]) {
    assert.ok(!renderOrgDocumentToHtml(doc, { profile }).html.includes('<details class="org2-large-source"'));
  }
}

const source = `#+TITLE: App rendering
#+HTML_HEAD: <script>globalThis.documentHeadRan = true</script>
* TODO Review the renderer :mac:
SCHEDULED: <2026-07-09 Thu>
:PROPERTIES:
:ID: render-target
:END:
A [[id:render-target][linked note]], [[file:notes/other.org2][file]], and [[https://example.com][website]].
This is [[color:red][urgent]], [[color:bg=yellow][highlighted]], and [[color:fg=white;bg=#b42318][blocked]].
#+begin_quote
First line
Second line
#+end_quote
| Scarf org | Stripe email | Q2 paid | Status | Basis |
|---+---+---+---+---|
| jasperreports | michelle.rudd@jaspersoft.com | $10,480.00 | [[color:fg=white;bg=#b42318][Blocked]] | Paid Stripe invoices on 2026-06-15 and 2026-06-26 |
| Color |
|---|
| Green |
** Child heading
Child body.
#+begin_export html
<script>globalThis.exportBlockRan = true</script>
#+end_export
`;

assert.deepEqual(parseOrgColorBindingTarget("color:red"), {
  foreground: { source: "red", css: "#ff3b30", hex: "ff3b30" },
});
assert.equal(parseOrgColorBindingTarget("color:chartreuse-ish"), null);
assert.equal(parseOrgColorBindingTarget("color:fg=red;evil=url(javascript:alert(1))"), null);
assert.deepEqual(
  findBacklinksInText("[[color:red][Urgent]]", "notes/status.org2", "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", {
    resolveWikiLinkIds: (label) =>
      label === "color:red" ? ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"] : [],
  }),
  [],
);

const document = parseOrgToCanonicalAst(source, {
  sourceRanges: true,
  sourceLineOffset: 20,
});
const colorRoundTrip = printCanonicalAstToOrg(document);
assert.match(colorRoundTrip, /\[\[color:red\]\[urgent\]\]/);
assert.match(colorRoundTrip, /\[\[color:fg=white;bg=#b42318\]\[Blocked\]\]/);
const rendered = renderOrgDocumentToAppHtml(document, {
  sourcePath: "notes/render.org2",
  customCss: ":root { --org2-accent: hotpink; } </style><script>unsafe()</script>",
});

assert.match(rendered.html, /id="org2-app-document-style"/);
assert.match(rendered.html, /<meta name="org2-document-kind" content="document" \/>/);
assert.match(rendered.html, /\.org2-headline-summary::before/);
assert.match(rendered.html, /font-size: 0\.82rem/);
assert.match(rendered.html, /--org2-font-mono:/);
assert.match(rendered.html, /\.org2-document-title::before/);
assert.match(rendered.html, /\.org2-headline-summary > h1::before/);
assert.match(rendered.html, /content: "\*\*";/);
assert.match(rendered.html, /class="org2-todo todo-todo"/);
assert.match(rendered.html, /data-org2-start-line="23"/);
assert.match(rendered.html, /<details class="org2-headline level-1" open/);
assert.match(rendered.html, /<summary class="org2-headline-summary"><h1/);
assert.match(rendered.html, /<details class="org2-headline level-2" open/);
assert.match(rendered.html, /<details class="org2-properties-drawer" open/);
assert.match(rendered.html, /<summary>Properties<\/summary>/);
assert.match(rendered.html, /<blockquote class="org2-quote"[^>]*>First line\nSecond line<\/blockquote>/);
assert.match(rendered.html, /\.org2-quote \{ white-space: pre-wrap;/);
assert.match(rendered.html, /<div class="org2-table-scroll">\s*<table/);
assert.match(rendered.html, /\.org2-table-scroll \{[^}]*overflow-x: auto;/);
assert.match(rendered.html, /\.org2-table-scroll th, \.org2-table-scroll td \{ overflow-wrap: normal;/);
assert.match(rendered.html, /class="org2-color-binding" style="color: #ff3b30;">urgent<\/span>/);
assert.match(rendered.html, /class="org2-color-binding" style="background-color: #ffcc00;[^>]+>highlighted<\/span>/);
assert.match(rendered.html, /<td class="org2-color-cell" style="color: #f2f2f7; background-color: #b42318;">Blocked<\/td>/);
assert.match(rendered.html, /<td>Green<\/td>/);
assert.doesNotMatch(rendered.html, /org2-color-token|org2-color-swatch/);
assert.match(rendered.html, /--org2-content-width: 960px;/);
assert.match(rendered.html, /--org2-page-padding: 28px;/);
assert.match(rendered.html, /padding: 22px clamp\(16px, 5vw, var\(--org2-page-padding\)\) 64px;/);
assert.match(rendered.html, /details\.org2-headline,/);
assert.match(rendered.html, /\.org2-table-scroll \{[^}]*min-width: 0;[^}]*overflow-x: auto;/);
assert.match(rendered.html, /id="org2-app-document-script"/);
assert.match(rendered.html, /className = "org2-heading-ai-action"/);
assert.match(rendered.html, /org2-workspace:\/\/ask-ai\?line=/);
assert.match(rendered.html, /opacity: 0\.46;/);
assert.match(rendered.html, /vertical-align: middle;/);
assert.match(rendered.html, /transform: translateY\(-2px\);/);
assert.match(rendered.html, /paragraph\.classList\.add\("org2-section-label"\)/);
assert.match(rendered.html, /id="org2-app-user-style"/);
assert.match(rendered.html, /--org2-accent: hotpink/);
assert.doesNotMatch(rendered.html, /<\/style><script>unsafe/);
assert.match(rendered.html, /className = "org2-column-resizer"/);
assert.match(rendered.html, /addEventListener\("mousemove"/);
assert.match(rendered.html, /className = "org2-table-filter"/);
assert.match(rendered.html, /Save view to source/);
assert.match(rendered.html, /visibleBodyRowIndices/);
assert.match(rendered.html, /Intl\.Collator/);
assert.match(rendered.html, /initialVisibleRowLimit = 100/);
assert.match(rendered.html, /body\.replaceChildren\(\.\.\.currentRows\.slice\(0, renderedCount\)\.map\(renderedRow\)\)/);
assert.match(rendered.html, /org2TableShowMore/);
assert.match(rendered.html, /\.org2-table-controls \{/);
assert.match(rendered.html, /h1 \{ font-size: 1\.16rem;/);
assert.match(rendered.html, /h2 \{ font-size: 1\.08rem;/);
assert.match(rendered.html, /overflow-wrap: normal;\n  word-break: normal;\n  text-wrap: wrap;/);
assert.doesNotMatch(rendered.html, /text-wrap: balance;/);
assert.match(rendered.html, /\.org2-headline-body > \.org2-headline\.level-2 \{ margin-left: 0\.35rem;/);
assert.match(rendered.html, /org2-workspace:\/\/open-link\?target=id%3Arender-target/);
assert.match(rendered.html, /org2-workspace:\/\/open-link\?target=file%3Anotes%2Fother\.org2/);
assert.match(rendered.html, /href="https:\/\/example\.com"/);
assert.doesNotMatch(rendered.html, /globalThis\.documentHeadRan/);
assert.doesNotMatch(rendered.html, /<script>globalThis\.exportBlockRan/);
assert.match(rendered.html, /&lt;script&gt;globalThis\.exportBlockRan/);

const published = renderOrgDocumentToHtml(document, {
  sourcePath: "notes/render.org2",
});
assert.doesNotMatch(published.html, /org2-headline-summary/);
assert.doesNotMatch(published.html, /org2-properties-drawer/);
assert.doesNotMatch(published.html, /org2-quote/);
assert.doesNotMatch(published.html, /org2-table-scroll/);
assert.doesNotMatch(published.html, /org2-table-filter/);
assert.match(published.html, /class="org2-color-binding" style="color: #ff3b30;">urgent<\/span>/);
assert.match(published.html, /<td class="org2-color-cell" style="color: #f2f2f7; background-color: #b42318;">Blocked<\/td>/);
assert.match(published.html, /<td>Green<\/td>/);
assert.doesNotMatch(published.html, /org2-color-token|org2-color-swatch/);
assert.doesNotMatch(published.html, /Save view to source/);
assert.doesNotMatch(published.html, /org2-app-document-script/);
assert.match(published.html, /<section class="org2-headline level-1"/);
assert.match(published.html, /<dl class="org2-properties">/);

const formulaDocument = parseOrgToCanonicalAst(`| Item | Qty | Price | Total |
|------+-----+-------+-------|
| A    | 2   | 3.5   |       |
#+TBLFM: $4=$2*$3;%.2f
`, { sourceRanges: true });
const formulaRendered = renderOrgDocumentToAppHtml(formulaDocument);
assert.match(formulaRendered.html, /<td>7\.00<\/td>/);
assert.match(formulaRendered.html, /data-org2-formula-count="1"/);
assert.match(formulaRendered.html, /org2TableFormula/);
assert.match(formulaRendered.html, /Recalculate/);
const formulaPublished = renderOrgDocumentToHtml(formulaDocument);
assert.match(formulaPublished.html, /<td>7\.00<\/td>/);
assert.match(formulaPublished.html, /Calculated from TBLFM/);

const imageSource = `* Chess
1. [ ] Alapin Sicilian
   - Position to study
   [[file:images/chess-opening-study-2026/01-alapin-sicilian.png]]
`;
const imageDocument = parseOrgToCanonicalAst(imageSource, { sourceRanges: true });
const imageRendered = renderOrgDocumentToAppHtml(imageDocument, {
  sourcePath: "20211211101554-chess.org",
});
assert.match(
  imageRendered.html,
  /<figure class="org2-image-figure"[^>]*><a class="org2-image-link" href="org2-workspace:\/\/open-link\?target=file%3Aimages%2Fchess-opening-study-2026%2F01-alapin-sicilian\.png"><img class="org2-image" src="images\/chess-opening-study-2026\/01-alapin-sicilian\.png" alt="01 alapin sicilian" loading="lazy" decoding="async" \/><\/a><\/figure>/,
);
assert.match(imageRendered.html, /\.org2-image \{[^}]*max-width: 100%;[^}]*height: auto;/);
assert.doesNotMatch(imageRendered.html, />file:images\/chess-opening-study-2026\/01-alapin-sicilian\.png</);

const publishedImage = renderOrgDocumentToHtml(imageDocument, {
  sourcePath: "20211211101554-chess.org",
});
assert.match(
  publishedImage.html,
  /<a class="org2-image-link" href="images\/chess-opening-study-2026\/01-alapin-sicilian\.png"><img class="org2-image" src="images\/chess-opening-study-2026\/01-alapin-sicilian\.png"/,
);

const labeledImageDocument = parseOrgToCanonicalAst('[[file:images/test image.png][Example & image]]');
for (const render of [renderOrgDocumentToAppHtml, renderOrgDocumentToHtml]) {
  const rendered = render(labeledImageDocument, { sourcePath: "message.org" });
  assert.match(rendered.html, /<img class="org2-image" src="images\/test image.png" alt="Example &amp; image"/);
  const inline = render(parseOrgToCanonicalAst('See [[file:images/test.png][image]] here.'), { sourcePath: "message.org" });
  assert.doesNotMatch(inline.html, /<img /);
}

const publishedIndex = renderOrgExportIndexToHtml({
  title: "Org2 docs sitemap",
  items: [{ title: "Features", href: "features.html" }],
  headIncludes: ['<script defer src="assets/nav.js"></script>'],
});
assert.match(publishedIndex.html, /<script defer src="assets\/nav\.js"><\/script>/);
assert.match(publishedIndex.html, /<main id="content" class="content org2-export-index-document">/);
assert.match(publishedIndex.html, /<h1 id="org2-docs-sitemap">Org2 docs sitemap<\/h1>/);

const indentedDrawerSource = `* Section
** Slide one
*** Column
    :PROPERTIES:
    :BEAMER_COL: 0.45
    :BEAMER_ENV: block
    :END:
    Column body.
** Slide two
Sibling body.
`;
const indentedDrawerDocument = parseOrgToCanonicalAst(indentedDrawerSource, { sourceRanges: true });
const section = indentedDrawerDocument.children.find((node) => node.type === "Headline");
assert.ok(section && section.type === "Headline");
const slideOne = section.children.find((node) =>
  node.type === "Headline" && node.title.some((inline) => inline.type === "Text" && inline.value === "Slide one")
);
assert.ok(slideOne && slideOne.type === "Headline");
const column = slideOne.children.find((node) =>
  node.type === "Headline" && node.title.some((inline) => inline.type === "Text" && inline.value === "Column")
);
assert.ok(column && column.type === "Headline");
assert.equal(column.children[0]?.type, "PropertyDrawer");
assert.ok(section.children.some((node) =>
  node.type === "Headline" && node.title.some((inline) => inline.type === "Text" && inline.value === "Slide two")
), "a sibling heading after an indented property drawer must remain outside the drawer");

const indentedDrawerRendered = renderOrgDocumentToAppHtml(indentedDrawerDocument);
assert.match(indentedDrawerRendered.html, /<meta name="org2-document-kind" content="slides" \/>/);
assert.match(indentedDrawerRendered.html, /<details class="org2-properties-drawer" open/);
assert.match(indentedDrawerRendered.html, /<h2[^>]*>Slide two<\/h2>/);
assert.match(indentedDrawerRendered.html, /Sibling body\./);
assert.doesNotMatch(indentedDrawerRendered.html, /<details class="org2-drawer"><summary>PROPERTIES<\/summary>/);

const canonicalizedDrawer = printCanonicalAstToOrg(indentedDrawerDocument);
assert.match(canonicalizedDrawer, /\*\*\* Column\n:PROPERTIES:\n:BEAMER_COL: 0\.45\n:BEAMER_ENV: block\n:END:/);
assert.doesNotMatch(canonicalizedDrawer, /^ +:PROPERTIES:$/m);
const reparsedCanonicalDrawer = parseOrgToCanonicalAst(canonicalizedDrawer);
assert.ok(reparsedCanonicalDrawer.children.some((node) =>
  node.type === "Headline"
  && node.children.some((child) =>
    child.type === "Headline"
    && child.title.some((inline) => inline.type === "Text" && inline.value === "Slide two")
  )
));
assert.throws(
  () => parseOrgToCanonicalAst(`* Section
** Slide one
    :PROPERTIES:
    :BEAMER_ENV: block
:END:
** Slide two
Sibling body.
`),
  /Invalid property drawer line; expected matching indentation/,
  "a mismatched indented property drawer must fail instead of consuming following headings",
);

const fileMetadataSource = `#+title: Machine report
#+id: report-id
#+updated: [2026-07-13 Mon]
#+property: ORG2_ARTIFACT_ROLE view
#+property: ORG2_PROVENANCE deterministic-query

Human introduction.
`;
const fileMetadataDocument = parseOrgToCanonicalAst(fileMetadataSource, { sourceRanges: true });
const fileMetadataRendered = renderOrgDocumentToAppHtml(fileMetadataDocument);
assert.match(fileMetadataRendered.html, /<h1 class="org2-document-title">Machine report<\/h1>/);
assert.match(fileMetadataRendered.html, /<details class="org2-file-properties">/);
assert.doesNotMatch(fileMetadataRendered.html, /<details class="org2-file-properties" open/);
assert.match(fileMetadataRendered.html, /File properties <span class="org2-file-properties-count">4<\/span>/);
assert.match(fileMetadataRendered.html, /<span class="org2-keyword-name">id<\/span>: report-id/i);
assert.ok(fileMetadataRendered.html.indexOf("org2-file-properties") < fileMetadataRendered.html.indexOf("Human introduction."));
assert.doesNotMatch(fileMetadataRendered.html, /org2-keyword-name">title/);

const tabIndentedQuoteSource = `#+begin_quote
\tBest,
\tAvi
\t#+end_quote
`;
const tabPreview = spawnSync(
  process.execPath,
  [fileURLToPath(new URL("../dist/render-html.js", import.meta.url)), "--source-path", "/tmp/tabbed-quote.org2"],
  { input: tabIndentedQuoteSource, encoding: "utf8" },
);
assert.equal(tabPreview.status, 0, tabPreview.stderr);
assert.match(tabPreview.stdout, /<blockquote class="org2-quote"[^>]*>  Best,\n  Avi<\/blockquote>/);

const configuredLinkRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-app-link-config-"));
try {
  fs.writeFileSync(path.join(configuredLinkRoot, "org2.json"), JSON.stringify({
    links: { linearTeam: "scarf" },
  }));
  const configuredLinkSource = path.join(configuredLinkRoot, "goals", "firebolt.org2");
  fs.mkdirSync(path.dirname(configuredLinkSource), { recursive: true });
  const configuredLinkPreview = spawnSync(
    process.execPath,
    [fileURLToPath(new URL("../dist/render-html.js", import.meta.url)), "--source-path", configuredLinkSource],
    { input: "* Goal\nLinked Linear issue: [[linear:APP-21287][APP-21287]].\n", encoding: "utf8" },
  );
  assert.equal(configuredLinkPreview.status, 0, configuredLinkPreview.stderr);
  assert.match(configuredLinkPreview.stdout, /href="https:\/\/linear\.app\/scarf\/issue\/APP-21287"/);
} finally {
  fs.rmSync(configuredLinkRoot, { recursive: true, force: true });
}

const nestedListQuoteSource = `1. Deepgram
   - Gmail draft: draft-id
   - Subject: SDK follow-up
   #+begin_quote
   Hi Greg,

   A short readout would be useful.

   Avi
   #+end_quote
`;
const nestedListQuoteDocument = parseOrgToCanonicalAst(nestedListQuoteSource, { sourceRanges: true });
const nestedListQuoteRendered = renderOrgDocumentToAppHtml(nestedListQuoteDocument);
assert.match(
  nestedListQuoteRendered.html,
  /<blockquote class="org2-quote"[^>]*>Hi Greg,\n\nA short readout would be useful\.\n\nAvi<\/blockquote>/
);
assert.doesNotMatch(nestedListQuoteRendered.html, /#\+begin_quote|#\+end_quote/);

const explicitOrdinalSource = `1. First study item

2. Second study item

7. Seventh study item
`;
const explicitOrdinalDocument = parseOrgToCanonicalAst(explicitOrdinalSource, { sourceRanges: true });
const explicitOrdinalRendered = renderOrgDocumentToAppHtml(explicitOrdinalDocument);
assert.match(explicitOrdinalRendered.html, /<li value="2"[^>]*><p>Second study item<\/p><\/li>/);
assert.match(explicitOrdinalRendered.html, /<li value="7"[^>]*><p>Seventh study item<\/p><\/li>/);
assert.equal(printCanonicalAstToOrg(explicitOrdinalDocument), explicitOrdinalSource);

const chartSource = `* Metrics

#+name: package_fetches
| day | fetches |
|-----+---------|
| Mon | 12      |
| Tue | 18      |

#+name: package_fetches_chart
\`\`\`chart line
x: day
y: fetches
source: package_fetches
size: compact
height: 280
interactive: true
\`\`\`
`;
const chartDocument = parseOrgToCanonicalAst(chartSource, { sourceRanges: true, sourceLineOffset: 30 });
const charts = renderOrgCharts(chartSource, { sourceLineOffset: 30 })
  .filter((chart) => chart.ok && chart.svg && chart.source)
  .map((chart) => ({ svg: chart.svg, source: chart.source, presentation: chart.presentation }));
const chartRendered = renderOrgDocumentToAppHtml(chartDocument, { charts });
assert.match(chartRendered.html, /<figure class="org2-chart org2-chart-compact" data-org2-chart-interactive="true" data-org2-start-line="40"/);
assert.match(chartRendered.html, /<svg [^>]*role="img"/);
assert.match(chartRendered.html, /<polyline /);
assert.match(chartRendered.html, /tooltip\.className = "org2-chart-tooltip"/);
assert.match(chartRendered.html, /installInteractiveCharts/);
assert.match(chartRendered.html, /data-org2-chart-mark="true"/);
assert.match(chartRendered.html, /mark\.dataset\.series \|\| yLabel/);
const appScript = chartRendered.html.match(/<script id="org2-app-document-script">\n([\s\S]*?)\n<\/script>/)?.[1];
assert.ok(appScript);
new Function(appScript);
assert.doesNotMatch(chartRendered.html, /<code class="language-chart">/);
assert.match(chartRendered.html, /\.org2-chart svg \{ display: block; width: 100%; height: auto;/);
const chartPublished = renderOrgDocumentToHtml(chartDocument, { charts });
assert.match(chartPublished.html, /<figure class="org2-chart org2-chart-compact" data-org2-chart-interactive="true">/);
assert.match(chartPublished.html, /<polyline /);
assert.doesNotMatch(chartPublished.html, /language-chart/);

console.log("app HTML renderer tests: ok");
