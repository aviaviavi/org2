#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import crypto from "node:crypto";
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
const homepage = fs.readFileSync(path.join(repoRoot, "docs/site/index.org"), "utf8");
const features = fs.readFileSync(path.join(repoRoot, "docs/site/features.org"), "utf8");
const gettingStarted = fs.readFileSync(path.join(repoRoot, "docs/site/getting-started.org"), "utf8");
const downloads = fs.readFileSync(path.join(repoRoot, "docs/site/downloads.org"), "utf8");
const productArchitecture = fs.readFileSync(path.join(repoRoot, "docs/site/openorg-and-org2.org"), "utf8");
const macosWorkspace = fs.readFileSync(path.join(repoRoot, "docs/site/editors-macos.org"), "utf8");
const publishConfig = fs.readFileSync(path.join(repoRoot, "org2.json"), "utf8");
const parsedPublishConfig = JSON.parse(publishConfig);
const retiredPublicPages = ["privacy-and-data.org", "known-limitations.org", "launch-demo.org"];
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
if (!siteNavigation.includes('[data-heading-anchors="off"]') || !features.includes('data-heading-anchors="off"')) {
  fail("site card headings are missing their copy-anchor opt-out");
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
if (/\b(?:Codex|OpenClaw)\b/.test(homepage) || /\b(?:Codex|OpenClaw)\b/.test(features)) {
  fail("homepage and feature positioning must remain agent- and model-neutral");
}
if (
  !homepage.includes("agent, model, or provider you choose")
  || !features.includes("models and agent harnesses you already use")
  || !features.includes("Slack and Notion")
  || !features.includes("local, remote, hosted, or self-hosted destination")
  || !gettingStarted.includes("CLI JSON and MCP")
  || !quickstart.includes("any local, remote, hosted, or self-hosted agent or model")
  || !quickstart.includes("implementations, not requirements")
) {
  fail("public onboarding must explain the provider-neutral agent boundary");
}
if (
  !homepage.includes("#+TITLE: OpenOrg")
  || !homepage.includes("Build your knowledge locally and put it to work.")
  || !productArchitecture.includes("A local-first workspace built on ordinary files and an open toolkit.")
  || !productArchitecture.includes("=@aviaviavi/org2=")
) {
  fail("product site must distinguish OpenOrg from the Org2 substrate");
}
if (
  !gettingStarted.includes("* Know what leaves your Mac")
  || !gettingStarted.includes("macOS Keychain")
  || !gettingStarted.includes("require an explicit approval")
  || !gettingStarted.includes("Back up the workspace folder")
  || !gettingStarted.includes("GitHub issues")
) {
  fail("getting-started guidance must explain data sharing, credentials, approvals, backups, and support");
}
for (const page of retiredPublicPages) {
  if (fs.existsSync(path.join(repoRoot, "docs/site", page))) {
    fail(`internal launch material must stay out of the public site: ${page}`);
  }
}
if ((macosWorkspace.match(/class="org2-section-shot"/g) || []).length < 6) {
  fail("OpenOrg for macOS must place screenshots beside the sections they illustrate");
}
if (
  !publishConfig.includes('href=\\"agent-quickstart.html\\">Agents and models')
  || !publishConfig.includes('href=\\"openorg-and-org2.html\\">Architecture')
  || publishConfig.includes('<summary>About</summary>')
  || publishConfig.includes('<summary>Safety</summary>')
  || publishConfig.includes('href=\\"privacy-and-data.html\\"')
  || publishConfig.includes('href=\\"known-limitations.html\\"')
  || publishConfig.includes('href=\\"launch-demo.html\\"')
  || !publishConfig.includes('"baseUrl": "https://openorg.so"')
  || publishConfig.includes('href=\\"openclaw-knowledge-layer.html\\">OpenClaw knowledge layer')
) {
  fail("primary site navigation must expose the OpenOrg product boundary and portable agent integration");
}
if (!downloads.includes("https://org2.gateway.scarf.sh/downloads/")) {
  fail("downloads page is missing Scarf Gateway release links");
}
if (!downloads.includes("OpenOrg disk images are hosted by GitHub Releases")) {
  fail("downloads page must disclose that GitHub Releases hosts the artifacts");
}
if (
  !downloads.includes("https://marketplace.visualstudio.com/items?itemName=AviPress.org2-vscode")
  || !downloads.includes("https://www.npmjs.com/package/@aviaviavi/org2")
) {
  fail("downloads page must link developer tools to their canonical registry pages");
}
if (/org2\.gateway\.scarf\.sh\/downloads\/[^\s\]]+\.(?:vsix|tgz)/i.test(downloads)) {
  fail("downloads page must not link VS Code or npm cards to release artifacts");
}
if (!downloads.includes("* OpenOrg for iOS") || !downloads.includes("Request TestFlight access")) {
  fail("downloads page is missing the iOS TestFlight and source-install surface");
}
if (!JSON.stringify(JSON.parse(fs.readFileSync(path.join(repoRoot, "org2.json"), "utf8"))).includes("downloads.html")) {
  fail("site navigation is missing the downloads page");
}
if (!siteStyles.includes(".org2-download-grid") || !siteStyles.includes(".org2-download-button")) {
  fail("site styles are missing the download card surface");
}

const siteProject = parsedPublishConfig.publish?.projects?.["docs-site"];
if (
  siteProject?.openGraph?.imageFormat !== "png"
  || siteProject?.openGraph?.siteName !== "OpenOrg"
  || siteProject?.openGraph?.locale !== "en_US"
) {
  fail("docs-site publishing must retain branded PNG Open Graph output");
}
if (
  !siteProject?.postambleHtml?.includes("Incubated at")
  || !siteProject?.postambleHtml?.includes('href="https://scarf.sh"')
  || !siteProject?.postambleHtml?.includes('src="assets/scarf-logo.svg"')
  || !siteStyles.includes(".org2-footer-incubator")
  || !fs.existsSync(path.join(repoRoot, "docs", "site", "assets", "scarf-logo.svg"))
) {
  fail("OpenOrg site footer must retain the styled Scarf incubation credit");
}
const scarfLogoPath = path.join(repoRoot, "docs", "site", "assets", "scarf-logo.svg");
if (fs.existsSync(scarfLogoPath)) {
  const scarfLogoDigest = crypto.createHash("sha256").update(fs.readFileSync(scarfLogoPath)).digest("hex");
  if (scarfLogoDigest !== "d31bcbd3fbd1a8c96addc55a86f4c454eff3744837e4357aa247b4ef4fe7eb00") {
    fail("OpenOrg site footer must use Scarf's official full-color wordmark");
  }
}

const publicSourcePages = fs.readdirSync(path.join(repoRoot, "docs", "site"))
  .filter((name) => /\.org2?$/i.test(name))
  .sort();
for (const sourcePage of publicSourcePages) {
  const slug = sourcePage.replace(/\.org2?$/i, "");
  const htmlPath = path.join(repoRoot, "site", `${slug}.html`);
  const pngPath = path.join(repoRoot, "site", "assets", "og", `${slug}.png`);
  if (!fs.existsSync(htmlPath)) {
    fail(`published site page is missing: site/${slug}.html`);
    continue;
  }
  const html = fs.readFileSync(htmlPath, "utf8");
  const expectedPageUrl = slug === "index" ? "https://openorg.so/" : `https://openorg.so/${slug}.html`;
  const expectedImageUrl = `https://openorg.so/assets/og/${slug}.png`;
  const requiredHeadEntries = [
    `<meta name="description"`,
    `<link rel="canonical" href="${expectedPageUrl}" />`,
    `<meta property="og:site_name" content="OpenOrg" />`,
    `<meta property="og:locale" content="en_US" />`,
    `<meta property="og:url" content="${expectedPageUrl}" />`,
    `<meta property="og:image" content="${expectedImageUrl}" />`,
    `<meta property="og:image:type" content="image/png" />`,
    `<meta property="og:image:width" content="1200" />`,
    `<meta property="og:image:height" content="630" />`,
    `<meta property="og:image:alt"`,
    `<meta name="twitter:card" content="summary_large_image" />`,
    `<meta name="twitter:image" content="${expectedImageUrl}" />`,
    `<meta name="twitter:image:alt"`,
  ];
  for (const entry of requiredHeadEntries) {
    if (!html.includes(entry)) fail(`site/${slug}.html is missing required social metadata: ${entry}`);
  }
  if (
    !html.includes('<span>Incubated at</span>')
    || !html.includes('href="https://scarf.sh"')
    || !html.includes('src="assets/scarf-logo.svg"')
  ) {
    fail(`site/${slug}.html is missing the Scarf incubation credit`);
  }
  if (!fs.existsSync(pngPath)) {
    fail(`Open Graph image is missing: site/assets/og/${slug}.png`);
    continue;
  }
  const png = fs.readFileSync(pngPath);
  const hasPngSignature = png.length >= 24
    && png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  if (!hasPngSignature || png.readUInt32BE(16) !== 1200 || png.readUInt32BE(20) !== 630) {
    fail(`Open Graph image must be a 1200x630 PNG: site/assets/og/${slug}.png`);
  }
}

if (!process.exitCode) {
  console.log(`OK: ${publicFamilies.size} CLI command families are represented in the agent capability manifest`);
  console.log(`OK: ${requiredDocs.size} canonical documentation entry points exist`);
  console.log("OK: site headings expose consistent copyable anchors");
  console.log(`OK: ${publicSourcePages.length} published pages have complete Open Graph metadata and 1200x630 PNG cards`);
}
