#!/usr/bin/env node
// Counts remaining legacy brand mentions (OpenOrg, Org2, org2 commands, legacy
// domains) by area, ignoring compatibility identifiers that intentionally keep
// their spelling. See docs/rename/celorga.org.
//
// Usage:
//   node tools/celorga-rename-audit.mjs            # summary table
//   node tools/celorga-rename-audit.mjs --list docs # matching lines for an area
//   node tools/celorga-rename-audit.mjs --json
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const listArea = args.includes("--list") ? args[args.indexOf("--list") + 1] : undefined;
const asJSON = args.includes("--json");

// Generated output and lockfiles mirror their sources.
const skipped = [
  /^site\//,
  /^docs\/site\/assets\/search-index\.json$/,
  /package-lock\.json$/,
  /^third_party\//,
  /^docs\/rename\//,
  /^tools\/celorga-rename-audit\.mjs$/,
  /\.(png|jpg|jpeg|gif|icns|pdf|dmg|zip|woff2?)$/i,
];

const areas = [
  ["docs", /^(docs\/|README\.org|AGENTS\.md|LSP_.*\.md|skills\/|examples\/)/],
  ["macos-app", /^apps\/macos\//],
  ["ios-app", /^apps\/ios\//],
  ["editors", /^editors\//],
  ["integrations", /^integrations\//],
  ["cli-src", /^src\//],
  ["spec", /^spec\//],
  ["tools", /^(tools\/|Makefile|package\.json|\.github\/)/],
  ["tests", /^(test\/|tree-sitter-org2\/)/],
];

// Brand mentions that should eventually read "Celorga".
const patterns = [
  ["OpenOrg", /\bOpenOrg\b(?![A-Z0-9_])/g],
  ["Org2", /\bOrg2\b(?![A-Za-z0-9_])/g],
  ["org2 command", /(?<![\w./:-])org2(?=\s+(?:[a-z][a-z-]+)\b)(?!\s+(?:file|files|document|documents|corpus|syntax|format)\b)/g],
  ["legacy domain", /\b(?:openorg\.so|org2\.avi\.press)\b/g],
];

// Lines that only mention compatibility identifiers are not counted.
const compatLine = /(org\.org2\.|appcast-(?:arm64|intel)\.xml|ORG2_[A-Z_]+|\borg2:[a-z-]+:v\d|org2\.json|\.org2\b)/;

function areaFor(path) {
  for (const [name, re] of areas) if (re.test(path)) return name;
  return "other";
}

const files = execFileSync("git", ["ls-files"], { cwd: repoRoot, encoding: "utf8" })
  .split("\n")
  .filter(Boolean)
  .filter((path) => !skipped.some((re) => re.test(path)));

const totals = new Map();
const listed = [];
for (const path of files) {
  let text;
  try {
    text = readFileSync(resolve(repoRoot, path), "utf8");
  } catch {
    continue;
  }
  if (text.includes("\u0000")) continue;
  const area = areaFor(path);
  const lines = text.split("\n");
  lines.forEach((line, index) => {
    for (const [label, re] of patterns) {
      re.lastIndex = 0;
      const hits = line.match(re);
      if (!hits) continue;
      if (label !== "legacy domain" && compatLine.test(line) && !/\bOpenOrg\b|\bOrg2\b/.test(line.replace(compatLine, ""))) continue;
      const key = `${area}\u0000${label}`;
      totals.set(key, (totals.get(key) ?? 0) + hits.length);
      if (listArea === area) listed.push(`${path}:${index + 1}: [${label}] ${line.trim().slice(0, 160)}`);
    }
  });
}

if (listArea) {
  console.log(listed.join("\n"));
  process.exit(0);
}

const labels = patterns.map(([label]) => label);
const areaNames = [...areas.map(([name]) => name), "other"];
const rows = areaNames.map((area) => [area, ...labels.map((label) => totals.get(`${area}\u0000${label}`) ?? 0)]);
if (asJSON) {
  console.log(JSON.stringify({ labels, rows }, null, 2));
  process.exit(0);
}
const header = ["area", ...labels];
const widths = header.map((h, i) => Math.max(h.length, ...rows.map((r) => String(r[i]).length)));
const fmt = (r) => r.map((c, i) => String(c).padEnd(widths[i])).join("  ");
console.log(fmt(header));
console.log(widths.map((w) => "-".repeat(w)).join("  "));
for (const row of rows) console.log(fmt(row));
const sum = rows.reduce((acc, row) => acc + row.slice(1).reduce((a, b) => a + b, 0), 0);
console.log(`\n${sum} legacy brand mentions outside compatibility identifiers.`);
