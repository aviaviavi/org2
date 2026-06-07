#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const repo = process.cwd();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-json-alias-"));
const note = path.join(tmp, "agenda.org2");
fs.writeFileSync(note, "* TODO Demo\nSCHEDULED: <2026-01-21 Wed>\n", "utf8");

function cli(args) {
  return execFileSync("node", ["dist/cli.js", ...args], { cwd: repo, encoding: "utf8" });
}

const viaFormat = cli(["agenda", "--files", note, "--today", "2026-01-21", "--days", "1", "--format", "json"]);
const viaAlias = cli(["agenda", "--files", note, "--today", "2026-01-21", "--days", "1", "--json"]);

if (viaFormat !== viaAlias) {
  console.error("--json must be equivalent to --format json for agenda");
  console.error("--format json:", viaFormat);
  console.error("--json:", viaAlias);
  process.exit(1);
}

const helpResult = spawnSync("node", ["dist/cli.js", "--help"], { cwd: repo, encoding: "utf8" });
const help = `${helpResult.stdout || ""}${helpResult.stderr || ""}`;
if (helpResult.status !== 0 || !help.includes("--json is a shorthand alias")) {
  console.error("top-level help should document --json shorthand");
  process.exit(1);
}

console.log("✓ cli --json alias");
