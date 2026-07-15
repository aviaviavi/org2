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
for (const [label, text] of [["agent quickstart", quickstart], ["llms.txt", llms]]) {
  if (!text.includes("org2 agent capabilities")) fail(`${label} does not point agents to the installed capability manifest`);
}
if (!agents.includes("## Documentation contract")) fail("AGENTS.md is missing the documentation contract");

if (!process.exitCode) {
  console.log(`OK: ${publicFamilies.size} CLI command families are represented in the agent capability manifest`);
  console.log(`OK: ${requiredDocs.size} canonical documentation entry points exist`);
}
