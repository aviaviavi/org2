#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import assert from "node:assert/strict";

const repo = process.cwd();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-render-chart-"));
const note = path.join(tmp, "report.org2");
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
#+chart: bar x=state y=fetches
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
title: Fetch buckets
source: previous-table
\`\`\`
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
assert.ok(fs.existsSync(out));

const stdinJson = JSON.parse(cli(["render-chart", "--stdin", "--format", "json"], fs.readFileSync(note, "utf8")));
assert.equal(stdinJson.ok, true);
assert.equal(stdinJson.source.blockId, "quarterly_revenue");

const fencedJson = JSON.parse(cli(["render-chart", "--file", note, "--line", "25", "--format", "json"]));
assert.equal(fencedJson.ok, true);
assert.equal(fencedJson.source.blockId, "fetch_buckets");
assert.equal(fencedJson.source.line, 19);
assert.equal(fencedJson.source.endLine, 30);
assert.match(fencedJson.svg, /Fetch buckets/);
assert.match(fencedJson.svg, /Org2 histogram chart/);
assert.match(fencedJson.svg, /<rect /);

const bad = spawnSync("node", ["dist/cli.js", "render-chart", "--file", note, "--block-id", "missing", "--format", "json"], { cwd: repo, encoding: "utf8" });
assert.notEqual(bad.status, 0);
const badJson = JSON.parse(bad.stdout);
assert.equal(badJson.ok, false);
assert.match(badJson.diagnostics[0].message, /No chart found/);

console.log("✓ render-chart CLI");
