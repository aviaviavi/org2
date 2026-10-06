// Modern chart presentation: compact units, horizontal labels, smooth lines,
// and no legacy axis chrome. Asserts the SVG contract the renderer emits.
import assert from "node:assert/strict";
import {
  renderOrgChart,
  formatChartNumber,
  formatChartValue,
  chartValueUnit,
  parseChartValue,
  humanizeChartLabel,
} from "../dist/chartRender.js";

// Number formatting.
assert.equal(formatChartNumber(950), "950");
assert.equal(formatChartNumber(95880), "95.9k");
assert.equal(formatChartNumber(24_000_000), "24M");
assert.equal(formatChartNumber(1_250_000, { prefix: "$", suffix: "" }), "$1.3M");
assert.equal(formatChartNumber(-1200), "-1.2k");
assert.equal(formatChartNumber(-1200, { prefix: "$", suffix: "" }), "-$1.2k");
assert.equal(formatChartNumber(18, { prefix: "", suffix: "%" }), "18%");
// Ticks use the step to keep labels distinct.
assert.equal(formatChartNumber(72_500, { prefix: "", suffix: "" }, 2_500), "72.5k");
assert.equal(formatChartNumber(80_000, { prefix: "", suffix: "" }, 10_000), "80k");
assert.equal(formatChartValue(95880, { prefix: "$", suffix: "" }), "$95,880");

// Units and parsing.
assert.deepEqual(chartValueUnit(["mrr_usd"], ["100"]), { prefix: "$", suffix: "" });
assert.deepEqual(chartValueUnit(["share"], ["12%", "40%"]), { prefix: "", suffix: "%" });
assert.deepEqual(chartValueUnit(["count"], ["12", "40"]), { prefix: "", suffix: "" });
assert.equal(parseChartValue("$1,200"), 1200);
assert.equal(parseChartValue("12.5%"), 12.5);
assert.ok(Number.isNaN(parseChartValue("n/a")));
assert.equal(humanizeChartLabel("mrr_usd"), "mrr usd");

const lineDoc = `| month | mrr_usd |
|-------+---------|
| 2026-01 | 80210 |
| 2026-02 | 82990 |
| 2026-03 | 84300 |
| 2026-04 | 86110 |

#+begin_src chart line
title: Month-end MRR
x: month
y: mrr_usd
#+end_src
`;
const line = renderOrgChart(lineDoc);
assert.equal(line.ok, true);
const lineSvg = line.svg;
// Smooth path, gradient area, endpoint label, invisible hover marks.
assert.match(lineSvg, /<path class="org2-chart-line" [^>]*d="M[^"]*C/);
assert.match(lineSvg, /<path class="org2-chart-area" [^>]*fill="url\(#org2-chart-fill-/);
assert.match(lineSvg, /<linearGradient id="org2-chart-fill-/);
assert.match(lineSvg, /class="org2-chart-end-label"[^>]*>\$86\.1k</);
assert.match(lineSvg, /class="org2-chart-mark org2-chart-point"[^>]*data-display="\$86,110"[^>]*fill-opacity="0"/);
// Lines fit the data instead of flattening against zero.
assert.doesNotMatch(lineSvg, />\$0</);
assert.match(lineSvg, />\$80k</);
// No rotated tick labels and no separate axis titles.
assert.doesNotMatch(lineSvg, /rotate\(/);
assert.match(lineSvg, /class="org2-chart-subtitle"[^>]*>mrr usd by month</);

const barDoc = `| customer | arr_usd |
|----------+---------|
| Acme Corporation International | 182000 |
| Globex | 121000 |
| Initech | -9000 |

#+begin_src chart bar
title: ARR
x: customer
y: arr_usd
#+end_src
`;
const bar = renderOrgChart(barDoc);
assert.equal(bar.ok, true);
assert.doesNotMatch(bar.svg, /rotate\(/);
// Bars include zero, label values, and truncate long categories with the full text as a title.
assert.match(bar.svg, />\$0</);
assert.match(bar.svg, /class="org2-chart-value"[^>]*>\$182k</);
assert.match(bar.svg, /class="org2-chart-value"[^>]*>-\$9k</);
assert.match(bar.svg, /<title>Acme Corporation International<\/title>/);
assert.equal((bar.svg.match(/<rect class="org2-chart-mark org2-chart-bar"/g) || []).length, 3);

const multiDoc = `| day | a | b | c |
|-----+---+---+---|
| 1 | 10 | 10 | 10 |
| 2 | 12 | 11 | 10 |

#+begin_src chart line
x: day
y: a, b, c
#+end_src
`;
const multi = renderOrgChart(multiDoc);
assert.equal(multi.ok, true);
assert.equal((multi.svg.match(/class="org2-chart-legend-item"/g) || []).length, 3);
assert.equal((multi.svg.match(/class="org2-chart-end-label"/g) || []).length, 3);
// Overlapping end labels are spread apart.
const endYs = [...multi.svg.matchAll(/class="org2-chart-end-label" x="[\d.]+" y="([\d.]+)"/g)].map((m) => Number(m[1])).sort((x, y) => x - y);
for (let i = 1; i < endYs.length; i += 1) assert.ok(endYs[i] - endYs[i - 1] >= 13.9, `end labels overlap: ${endYs}`);
// Three series: no area fills, which would muddy overlapping lines.
assert.doesNotMatch(multi.svg, /org2-chart-area/);

console.log("chart style tests: ok");
