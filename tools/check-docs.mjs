#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";

const repoRoot = path.resolve(import.meta.dirname, "..");

function fail(message) {
  console.error(`docs-check: ${message}`);
  process.exitCode = 1;
}

function runCli(args) {
  const result = spawnSync(process.execPath, [path.join(repoRoot, "dist", "cli.js"), ...args], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    fail(`org2 ${args.join(" ")} exited ${result.status}: ${(result.stderr || result.stdout).trim()}`);
  }
  return { stdout: result.stdout || "", stderr: result.stderr || "" };
}

const manifestResult = runCli(["agent", "capabilities"]);
let manifest;
try {
  manifest = JSON.parse(manifestResult.stdout);
} catch (error) {
  fail(`agent capability output is not JSON: ${error instanceof Error ? error.message : String(error)}`);
  process.exit();
}

if (manifest.$schema !== "org2:capabilities:v1") {
  fail(`expected capability schema org2:capabilities:v1, got ${String(manifest.$schema)}`);
}

const declaredCommands = new Set(
  (manifest.workflows || []).flatMap((workflow) => workflow.commands || []),
);
const help = runCli(["--help"]).stderr;
const publicFamilies = new Set();
for (const match of help.matchAll(/^\s+org2\s+([^\s<]+)(?:\s|$)/gm)) {
  publicFamilies.add(match[1]);
}

for (const family of [...publicFamilies].sort()) {
  const covered = [...declaredCommands].some((command) => command === `org2 ${family}` || command.startsWith(`org2 ${family} `));
  if (!covered) fail(`top-level command '${family}' is missing from org2 agent capabilities`);
}

const requiredDocs = new Map([
  ["agent-quickstart", "docs/site/agent-quickstart.org"],
  ["features", "docs/site/features.org"],
  ["tooling-reference", "docs/site/tooling-reference.org"],
  ["language-reference", "docs/site/language-reference.org"],
  ["corpus-flow", "docs/site/corpus-flow.org"],
  ["macos-workspace", "docs/site/editors-macos.org"],
]);
const declaredDocIds = new Set((manifest.docs || []).map((doc) => doc.id));
for (const [id, relativePath] of requiredDocs) {
  if (!declaredDocIds.has(id)) fail(`capability manifest is missing documentation entry '${id}'`);
  if (!fs.existsSync(path.join(repoRoot, relativePath))) fail(`documentation source does not exist: ${relativePath}`);
}

const quickstart = fs.readFileSync(path.join(repoRoot, "docs/site/agent-quickstart.org"), "utf8");
const llms = fs.readFileSync(path.join(repoRoot, "docs/site/llms.txt"), "utf8");
const agents = fs.readFileSync(path.join(repoRoot, "AGENTS.md"), "utf8");
const siteNavigation = fs.readFileSync(path.join(repoRoot, "docs/site/assets/nav.js"), "utf8");
const siteStyles = fs.readFileSync(path.join(repoRoot, "docs/site/assets/site.css"), "utf8");
const features = fs.readFileSync(path.join(repoRoot, "docs/site/features.org"), "utf8");
const downloads = fs.readFileSync(path.join(repoRoot, "docs/site/downloads.org"), "utf8");
for (const [label, text] of [["agent quickstart", quickstart], ["llms.txt", llms]]) {
  if (!text.includes("org2 agent capabilities")) fail(`${label} does not point agents to the installed capability manifest`);
}
if (!agents.includes("## Documentation contract")) fail("AGENTS.md is missing the documentation contract");
if (!agents.includes(".codex/skills/org2-release/SKILL.md")) fail("AGENTS.md is missing the coordinated release skill");

try {
  new Function(siteNavigation);
} catch (error) {
  fail(`site navigation JavaScript is invalid: ${error instanceof Error ? error.message : String(error)}`);
}
if (!siteNavigation.includes("setupHeadingAnchors") || !siteNavigation.includes("navigator.clipboard.writeText")) {
  fail("site navigation is missing copyable heading anchors");
}
if (!siteStyles.includes(".org2-heading-anchor") || !siteStyles.includes("scroll-margin-top")) {
  fail("site styles are missing heading-anchor layout and sticky-navigation offset");
}
if (!siteStyles.includes(".org2-features-page h2::before") || !siteStyles.includes('content: "**"')) {
  fail("features page level-two headings are missing Org2 '**' styling");
}
const mobileStylesStart = siteStyles.lastIndexOf("@media (max-width: 759px)");
const mobileStylesEnd = siteStyles.indexOf("@media (max-width: 520px)", mobileStylesStart);
const mobileStyles = siteStyles.slice(mobileStylesStart, mobileStylesEnd);
if (
  !mobileStyles.includes("#content table > tbody") ||
  !mobileStyles.includes("overflow-x: auto") ||
  !mobileStyles.includes("#content table td:first-child")
) {
  fail("mobile documentation tables must retain readable columns inside a horizontal scroller");
}
if (
  !mobileStyles.includes("#content .org2-compiler-flow article::after") ||
  !mobileStyles.includes("grid-template-columns: 2rem minmax(0, 1fr)") ||
  !mobileStyles.includes("#content .org2-compiler-flow p")
) {
  fail("mobile follow-through steps must hide desktop connectors and use the compact numbered layout");
}
if (!/<h2\s+id="[^"]+">/.test(features)) {
  fail("features page sections must use addressable level-two headings");
}
if (!downloads.includes("https://org2.gateway.scarf.sh/downloads/")) {
  fail("downloads page is missing Scarf Gateway release links");
}
if (!downloads.includes("GitHub Releases remains the underlying host")) {
  fail("downloads page must disclose that GitHub Releases hosts the artifacts");
}
if (!downloads.includes("* iOS mobile app") || !downloads.includes("Request TestFlight access")) {
  fail("downloads page is missing the iOS TestFlight and source-install surface");
}
if (!JSON.stringify(JSON.parse(fs.readFileSync(path.join(repoRoot, "org2.json"), "utf8"))).includes("downloads.html")) {
  fail("site navigation is missing the downloads page");
}
if (!siteStyles.includes(".org2-download-grid") || !siteStyles.includes(".org2-download-button")) {
  fail("site styles are missing the download card surface");
}

if (!process.exitCode) {
  console.log(`OK: ${publicFamilies.size} CLI command families are represented in the agent capability manifest`);
  console.log(`OK: ${requiredDocs.size} canonical documentation entry points exist`);
  console.log("OK: site headings expose consistent copyable anchors");
}
