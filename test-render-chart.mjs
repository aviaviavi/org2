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
assert.match(namedSourceJson.svg, /Revenue from named source/);
assert.match(namedSourceJson.svg, /<polyline /);

const futureSourceJson = JSON.parse(cli(["render-chart", "--file", note, "--block-id", "future_source_chart", "--format", "json"]));
assert.equal(futureSourceJson.ok, true);
assert.equal(futureSourceJson.source.blockId, "future_source_chart");
assert.equal(futureSourceJson.source.dataBlockId, "future_fetches_result");
assert.match(futureSourceJson.svg, /<rect /);

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
