import assert from "node:assert/strict";
import { renderOrgCharts } from "../dist/chartRender.js";
import { renderOrgDocumentToAppHtml, renderOrgDocumentToHtml } from "../dist/export.js";
import { parseOrgToCanonicalAst } from "../dist/parser.js";

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
assert.match(rendered.html, /\.org2-headline-summary::before/);
assert.match(rendered.html, /font-size: 0\.82rem/);
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
\`\`\`
`;
const chartDocument = parseOrgToCanonicalAst(chartSource, { sourceRanges: true, sourceLineOffset: 30 });
const charts = renderOrgCharts(chartSource, { sourceLineOffset: 30 })
  .filter((chart) => chart.ok && chart.svg && chart.source)
  .map((chart) => ({ svg: chart.svg, source: chart.source }));
const chartRendered = renderOrgDocumentToAppHtml(chartDocument, { charts });
assert.match(chartRendered.html, /<figure class="org2-chart" data-org2-start-line="40"/);
assert.match(chartRendered.html, /<svg [^>]*role="img"/);
assert.match(chartRendered.html, /<polyline /);
assert.doesNotMatch(chartRendered.html, /<code class="language-chart">/);
assert.match(chartRendered.html, /\.org2-chart svg \{ display: block; width: 100%;/);
const chartPublished = renderOrgDocumentToHtml(chartDocument, { charts });
assert.match(chartPublished.html, /<figure class="org2-chart">/);
assert.match(chartPublished.html, /<polyline /);
assert.doesNotMatch(chartPublished.html, /language-chart/);

console.log("app HTML renderer tests: ok");
