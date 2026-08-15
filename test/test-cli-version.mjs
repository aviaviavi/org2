#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const repo = process.cwd();
const expectedVersion = JSON.parse(fs.readFileSync(path.join(repo, "package.json"), "utf8")).version;

for (const args of [["version"], ["--version"], ["-v"]]) {
  const result = spawnSync(process.execPath, ["dist/cli.js", ...args], {
    cwd: repo,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, `org2 ${args.join(" ")} should exit successfully: ${result.stderr}`);
  assert.equal(result.stdout, `${expectedVersion}\n`, `org2 ${args.join(" ")} should print the package version`);
  assert.equal(result.stderr, "", `org2 ${args.join(" ")} should not print an error`);
}

console.log("✓ cli version");
