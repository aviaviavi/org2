#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import process from "node:process";

function run(command, args) {
  console.log(`$ ${[command, ...args].join(" ")}`);
  execFileSync(command, args, { stdio: "inherit" });
}

function main() {
  const args = process.argv.slice(2);
  const unknown = args.filter((argument) => argument !== "--built");
  if (unknown.length > 0) {
    throw new Error(`Unknown option: ${unknown[0]}`);
  }
  if (!args.includes("--built")) run("npm", ["run", "build"]);
  run("npm", ["run", "check:mobile-document"]);
  run("npm", ["run", "fixtures", "--", "--e2e"]);
  run("npm", ["run", "org2", "--", "publish", "docs-site", "--config", "org2.json"]);
  run("git", [
    "diff",
    "--exit-code",
    "--",
    "dist",
    "site",
    "spec/v0/tests",
  ]);
  console.log("OK: generated artifacts are current");
}

try {
  main();
} catch (err) {
  if (err?.status) process.exitCode = err.status;
  else {
    console.error(err?.message ?? err);
    process.exitCode = 1;
  }
}
