import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { renderOrgCharts } from "../dist/chartRender.js";
import { renderOrgDocumentToAppHtml, renderOrgDocumentToHtml, renderOrgExportIndexToHtml } from "../dist/export.js";
import { parseOrgToCanonicalAst } from "../dist/parser.js";
import { printCanonicalAstToOrg } from "../dist/printer.js";

const source = `#+TITLE: App rendering
#+HTML_HEAD: <script>globalThis.documentHeadRan = true</script>
* TODO Review the renderer :mac:
SCHEDULED: <2026-07-09 Thu>
:PROPERTIES:
:ID: render-target
:END:
A [[id:render-target][linked note]], [[file:notes/other.org2][file]], and [[https://example.com][website]].
#+begin_quote
First line
Second line
#+end_quote
| Scarf org | Stripe email | Q2 paid | Basis |
|---+---+---+---|
| jasperreports | michelle.rudd@jaspersoft.com | $10,480.00 | Paid Stripe invoices on 2026-06-15 and 2026-06-26 |
** Child heading
Child body.
#+begin_export html
<script>globalThis.exportBlockRan = true</script>
#+end_export
`;

const document = parseOrgToCanonicalAst(source, {
  sourceRanges: true,
  sourceLineOffset: 20,
});
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
assert.match(rendered.html, /--org2-content-width: 960px;/);
assert.match(rendered.html, /--org2-page-padding: 28px;/);
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
assert.match(rendered.html, /h1 \{ font-size: 1\.16rem;/);
assert.match(rendered.html, /h2 \{ font-size: 1\.08rem;/);
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
assert.doesNotMatch(published.html, /org2-app-document-script/);
assert.match(published.html, /<section class="org2-headline level-1"/);
assert.match(published.html, /<dl class="org2-properties">/);

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
