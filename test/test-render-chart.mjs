#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import assert from "node:assert/strict";

const repo = process.cwd();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-render-chart-"));
const note = path.join(tmp, "report.org2");
const badSortNote = path.join(tmp, "bad-sort.org2");
const fourTickChartNote = path.join(tmp, "four-tick-chart.org2");
const canonicalChartNote = path.join(tmp, "canonical-chart.org");
const multiLineChartNote = path.join(tmp, "multi-line-chart.org");
const multiBarChartNote = path.join(tmp, "multi-bar-chart.org");
const invalidMultiHistogramNote = path.join(tmp, "invalid-multi-histogram.org");
const out = path.join(tmp, "chart.svg");

fs.writeFileSync(note, `* Revenue report

#+name: quarterly_revenue
#+caption: Quarterly revenue
#+chart: line x=quarter y=revenue
| quarter | revenue |
|---------+---------|
| 2026-Q1 | 1200    |
| 2026-Q2 | 1500    |

#+name: fetches_by_state
#+chart: bar x=state y=fetches sort=y-asc
| state | fetches |
|-------+---------|
| CA    | 42      |
| NY    | 24      |

#+name: fetch_buckets
| bucket | fetches |
|--------+---------|
| 0-10   | 14      |
| 11-50  | 32      |
| 51-100 | 9       |

\`\`\`chart histogram
x: bucket
y: fetches
sort: y-desc
title: Fetch buckets
source: previous-table
\`\`\`

#+name: named_revenue_chart
\`\`\`chart line
x: quarter
y: revenue
title: Revenue from named source
source: quarterly_revenue
size: compact
height: 280
interactive: false
\`\`\`

#+name: future_source_chart
\`\`\`chart bar
x: day
y: fetches
source: future_fetches_result
\`\`\`

#+name: future_fetches_result
| day        | fetches |
|------------+---------|
| 2026-06-11 | 88      |
| 2026-06-12 | 91      |
`, "utf8");

fs.writeFileSync(badSortNote, fs.readFileSync(note, "utf8").replace("sort=y-asc", "sort=random"), "utf8");

fs.writeFileSync(fourTickChartNote, `* Chart fence examples

| bucket | fetches |
|--------+---------|
| 0-10   | 14      |
| 11-50  | 32      |

\`\`\`\`chart histogram
x: bucket
y: fetches
\`\`\`\`
`, "utf8");

fs.writeFileSync(canonicalChartNote, `* Canonical chart source

#+name: canonical_chart
| bucket | fetches |
|--------+---------|
| 0-10   | 14      |
| 11-50  | 32      |

#+begin_src chart histogram
x: bucket
y: fetches
source: previous-table
#+end_src
`, "utf8");

fs.writeFileSync(multiLineChartNote, `* Multi-series line chart

#+name: quarterly_metrics
#+caption: Revenue, cost, and profit
#+chart: line x=quarter y=revenue,cost,profit
| quarter | revenue | cost | profit |
|---------+---------+------+--------|
| 2026-Q1 | 1200    | 700  | 500    |
| 2026-Q2 | 1500    | 825  | 675    |
| 2026-Q3 | 1800    | 990  | 810    |
`, "utf8");

fs.writeFileSync(multiBarChartNote, `* Multi-series grouped bar chart

#+name: regional_metrics
| region | current | previous |
|--------+---------+----------|
| East   | 42      | 35       |
| West   | 56      | 48       |

#+name: regional_metrics_chart
#+begin_src chart bar
x: region
series: current, previous
source: regional_metrics
title: Regional comparison
#+end_src
`, "utf8");

fs.writeFileSync(invalidMultiHistogramNote, `#+chart: histogram x=bucket y=current,previous
| bucket | current | previous |
|--------+---------+----------|
| 0-10   | 14      | 12       |
`, "utf8");

function cli(args, input) {
  return execFileSync("node", ["dist/cli.js", ...args], { cwd: repo, encoding: "utf8", input });
}

const svg = cli(["render-chart", "--file", note, "--block-id", "quarterly_revenue"]);
assert.match(svg, /^<svg /);
assert.match(svg, /<polyline /);
assert.match(svg, /Quarterly revenue/);

const json = JSON.parse(cli(["render-chart", "--file", note, "--line", "14", "--out", out, "--format", "json"]));
assert.equal(json.ok, true);
assert.equal(json.format, "svg");
assert.equal(json.artifact, out);
assert.equal(json.source.blockId, "fetches_by_state");
assert.equal(json.source.line, 13);
assert.equal(json.source.endLine, 16);
assert.match(json.svg, /<rect /);
assert.ok(json.svg.indexOf("<title>NY: 24</title>") < json.svg.indexOf("<title>CA: 42</title>"));
assert.ok(fs.existsSync(out));

const stdinJson = JSON.parse(cli(["render-chart", "--stdin", "--format", "json"], fs.readFileSync(note, "utf8")));
assert.equal(stdinJson.ok, true);
assert.equal(stdinJson.source.blockId, "quarterly_revenue");

const fencedJson = JSON.parse(cli(["render-chart", "--file", note, "--line", "25", "--format", "json"]));
assert.equal(fencedJson.ok, true);
assert.equal(fencedJson.source.blockId, "fetch_buckets");
assert.equal(fencedJson.source.line, 19);
assert.equal(fencedJson.source.endLine, 31);
assert.match(fencedJson.svg, /Fetch buckets/);
assert.match(fencedJson.svg, /Org2 histogram chart/);
assert.match(fencedJson.svg, /<rect /);
assert.ok(fencedJson.svg.indexOf("<title>11-50: 32</title>") < fencedJson.svg.indexOf("<title>0-10: 14</title>"));

const namedSourceJson = JSON.parse(cli(["render-chart", "--file", note, "--line", "34", "--format", "json"]));
assert.equal(namedSourceJson.ok, true);
assert.equal(namedSourceJson.source.blockId, "named_revenue_chart");
assert.equal(namedSourceJson.source.dataBlockId, "quarterly_revenue");
assert.equal(namedSourceJson.source.line, 6);
assert.equal(namedSourceJson.source.chartLine, 34);
assert.deepEqual(namedSourceJson.presentation, { size: "compact", height: 280, interactive: false });
assert.match(namedSourceJson.svg, /Revenue from named source/);
assert.match(namedSourceJson.svg, /<polyline /);
assert.match(namedSourceJson.svg, /height="280"/);
assert.match(namedSourceJson.svg, /data-org2-chart-size="compact"/);
assert.match(namedSourceJson.svg, /data-org2-chart-interactive="false"/);

const futureSourceJson = JSON.parse(cli(["render-chart", "--file", note, "--block-id", "future_source_chart", "--format", "json"]));
assert.equal(futureSourceJson.ok, true);
assert.equal(futureSourceJson.source.blockId, "future_source_chart");
assert.equal(futureSourceJson.source.dataBlockId, "future_fetches_result");
assert.match(futureSourceJson.svg, /<rect /);

const canonicalChartJson = JSON.parse(cli(["render-chart", "--file", canonicalChartNote, "--block-id", "canonical_chart", "--format", "json"]));
assert.equal(canonicalChartJson.ok, true);
assert.equal(canonicalChartJson.source.blockId, "canonical_chart");
assert.match(canonicalChartJson.svg, /Org2 histogram chart/);

const multiLineChartJson = JSON.parse(cli(["render-chart", "--file", multiLineChartNote, "--block-id", "quarterly_metrics", "--format", "json"]));
assert.equal(multiLineChartJson.ok, true);
assert.equal((multiLineChartJson.svg.match(/<polyline /g) || []).length, 3);
assert.equal((multiLineChartJson.svg.match(/class="org2-chart-legend-item"/g) || []).length, 3);
assert.match(multiLineChartJson.svg, /data-org2-chart-series="revenue,cost,profit"/);
assert.match(multiLineChartJson.svg, /data-series="cost"/);
assert.match(multiLineChartJson.svg, /<title>cost — 2026-Q2: 825<\/title>/);

const multiBarChartJson = JSON.parse(cli(["render-chart", "--file", multiBarChartNote, "--block-id", "regional_metrics_chart", "--format", "json"]));
assert.equal(multiBarChartJson.ok, true);
assert.equal(multiBarChartJson.source.dataBlockId, "regional_metrics");
assert.equal((multiBarChartJson.svg.match(/<rect class="org2-chart-mark"/g) || []).length, 4);
assert.equal((multiBarChartJson.svg.match(/class="org2-chart-legend-item"/g) || []).length, 2);
assert.match(multiBarChartJson.svg, /Regional comparison/);
assert.match(multiBarChartJson.svg, /data-series="previous"/);

const invalidMultiHistogram = spawnSync("node", ["dist/cli.js", "render-chart", "--file", invalidMultiHistogramNote, "--format", "json"], {
  cwd: repo,
  encoding: "utf8",
});
assert.notEqual(invalidMultiHistogram.status, 0);
assert.match(JSON.parse(invalidMultiHistogram.stdout).diagnostics[0].message, /Histogram charts support exactly one y column/);

const bad = spawnSync("node", ["dist/cli.js", "render-chart", "--file", note, "--block-id", "missing", "--format", "json"], { cwd: repo, encoding: "utf8" });
assert.notEqual(bad.status, 0);
const badJson = JSON.parse(bad.stdout);
assert.equal(badJson.ok, false);
assert.match(badJson.diagnostics[0].message, /No chart found/);

const badSort = spawnSync("node", ["dist/cli.js", "render-chart", "--file", badSortNote, "--block-id", "fetches_by_state", "--format", "json"], {
  cwd: repo,
  encoding: "utf8",
});
assert.notEqual(badSort.status, 0);
const badSortJson = JSON.parse(badSort.stdout);
assert.equal(badSortJson.ok, false);
assert.match(badSortJson.diagnostics[0].message, /Unsupported chart sort/);

const fourTickChart = spawnSync("node", ["dist/cli.js", "render-chart", "--file", fourTickChartNote, "--line", "8", "--format", "json"], {
  cwd: repo,
  encoding: "utf8",
});
assert.notEqual(fourTickChart.status, 0);
const fourTickChartJson = JSON.parse(fourTickChart.stdout);
assert.equal(fourTickChartJson.ok, false);
assert.match(fourTickChartJson.diagnostics[0].message, /No chart-affiliated table found/);

console.log("✓ render-chart CLI");
