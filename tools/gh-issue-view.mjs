#!/usr/bin/env node
/**
 * Workaround for `gh issue view` failing when an issue has Projects (classic).
 * Uses the REST endpoint instead of GraphQL.
 *
 * Usage:
 *   node tools/gh-issue-view.mjs 76 --repo aviaviavi/org2
 *   node tools/gh-issue-view.mjs aviaviavi/org2#76
 */

import { execFileSync } from "node:child_process";

function die(msg) {
  console.error(msg);
  process.exit(2);
}

const args = process.argv.slice(2);
if (args.length === 0 || args.includes("-h") || args.includes("--help")) {
  console.log(
    [
      "gh-issue-view.mjs",
      "",
      "Workaround for `gh issue view` failures caused by Projects (classic) deprecation.",
      "",
      "Usage:",
      "  node tools/gh-issue-view.mjs 76 --repo aviaviavi/org2",
      "  node tools/gh-issue-view.mjs aviaviavi/org2#76",
    ].join("\n"),
  );
  process.exit(0);
}

let repo;
let number;

const first = args[0];
const m = first.match(/^([^#]+)#(\d+)$/);
if (m) {
  repo = m[1];
  number = m[2];
} else {
  number = first;
}

for (let i = 1; i < args.length; i++) {
  if (args[i] === "--repo") repo = args[++i];
}

if (!number || !String(number).match(/^\d+$/)) die(`Invalid issue number: ${number}`);
if (!repo) die("Missing --repo (or use owner/repo#number)");

const jsonText = execFileSync(
  "gh",
  ["api", `repos/${repo}/issues/${number}`],
  { encoding: "utf8" },
);

const issue = JSON.parse(jsonText);

console.log(`#${issue.number} ${issue.title}`);
console.log(issue.html_url);
console.log("\n---\n");
console.log(issue.body ?? "");
