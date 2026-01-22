#!/usr/bin/env node

import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const testDir = "spec/v0/tests/cli";
const testFiles = fs.readdirSync(testDir).filter((f) => f.endsWith(".org"));

let passed = 0;
let failed = 0;

for (const orgFile of testFiles) {
  const basename = orgFile.replace(/\.org$/, "");
  const expectedFile = path.join(testDir, `${basename}.expected.txt`);

  if (!fs.existsSync(expectedFile)) {
    console.log(`⊘ ${basename} (no expected output file)`);
    continue;
  }

  const filePath = path.join(testDir, orgFile);
  try {
    const output = execSync(`node dist/cli.js agenda --files "${filePath}" --today 2026-01-21 --days 2`, {
      encoding: "utf8",
    });

    const expected = fs.readFileSync(expectedFile, "utf8");

    if (output === expected) {
      console.log(`✓ ${basename}`);
      passed++;
    } else {
      console.log(`✗ ${basename}`);
      console.log("Expected:");
      console.log(expected);
      console.log("Got:");
      console.log(output);
      failed++;
    }
  } catch (err) {
    console.log(`✗ ${basename} (error)`);
    console.error(err instanceof Error ? err.message : err);
    failed++;
  }
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
