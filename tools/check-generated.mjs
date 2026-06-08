#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import process from "node:process";

function run(command, args) {
  console.log(`$ ${[command, ...args].join(" ")}`);
  execFileSync(command, args, { stdio: "inherit" });
}

function main() {
  run("npm", ["run", "build"]);
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
