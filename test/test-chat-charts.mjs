#!/usr/bin/env node
// AI chat messages render through the same app HTML renderer as documents, so
// chart blocks in a reply become the same interactive, themed SVG figures.
import assert from "node:assert/strict";
import { renderAppHTML } from "../dist/appHtmlRenderer.js";
import { renderOrgCharts } from "../dist/chartRender.js";

const render = (text) => renderAppHTML(text, { sourcePath: "/tmp/chat-message.org" });
const figures = (html) => (html.match(/<figure class="org2-chart /g) || []).length;

// A table followed by a Markdown chart fence, as agents usually write it.
const tableThenFence = `Revenue by month:

| Month | Revenue | Cost |
|-------+---------+------|
| Jan   | 10      | 4    |
| Feb   | 14      | 6    |

\`\`\`chart
type: line
x: Month
y: Revenue, Cost
\`\`\`
`;
let html = render(tableThenFence);
assert.equal(figures(html), 1);
assert.doesNotMatch(html, /language-chart/);
assert.match(html, /<script id="org2-chart-interaction">/);
assert.match(html, /class="org2-chart-legend-item" data-series="Cost"/);
assert.match(html, /fill="var\(--org2-chart-series-2, /, "series colors come from theme variables");

// A self-contained chart: the data table lives inside the chart block.
for (const opener of ["```chart bar", "#+begin_src chart bar"]) {
  const closer = opener.startsWith("```") ? "```" : "#+end_src";
  const selfContained = `Top packages:

${opener}
x: package
y: downloads
title: Downloads
| package | downloads |
|---------+-----------|
| alpha   | 1,200     |
| beta    | 800       |
${closer}

Done.`;
  const [chart] = renderOrgCharts(selfContained);
  assert.ok(chart?.ok, `${opener}: ${JSON.stringify(chart?.diagnostics)}`);
  assert.equal(chart.source.chartLine, 3);
  assert.equal(chart.source.line, 7, "the inline table starts inside the block");
  assert.match(chart.svg, /data-label="alpha" data-series="downloads" data-value="1200"/);
  html = render(selfContained);
  assert.equal(figures(html), 1, opener);
  assert.doesNotMatch(html, /language-chart|org2-src-language-chart/);
  assert.match(html, /Done\./);
}

// An inline table wins over an earlier unrelated table; an explicit source still applies.
const twoTables = `#+name: other
| k | v |
|---+---|
| a | 1 |

\`\`\`chart
x: day
y: n
| day | n |
| Mon | 3 |
\`\`\`

\`\`\`chart
x: k
y: v
source: other
\`\`\`
`;
const twoCharts = renderOrgCharts(twoTables);
assert.equal(twoCharts.length, 2);
assert.ok(twoCharts.every((chart) => chart.ok), JSON.stringify(twoCharts.map((chart) => chart.diagnostics)));
assert.match(twoCharts[0].svg, /data-label="Mon"/);
assert.match(twoCharts[1].svg, /data-label="a"/);

// A chart without data stays a readable code block rather than failing the message.
html = render("```chart\nx: a\ny: b\n```\n");
assert.equal(figures(html), 0);
assert.match(html, /x: a/);
assert.doesNotMatch(html, /org2-chart-interaction"/);

console.log("✓ chat charts");
