#!/usr/bin/env node

import { execSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const testDir = "spec/v0/tests/cli";
const entries = fs.readdirSync(testDir);

const orgFiles = entries.filter((f) => f.endsWith(".org"));
const cmdFiles = entries.filter((f) => f.endsWith(".cmd.txt"));

let passed = 0;
let failed = 0;

// Error/exit-code based tests (shell command in .cmd.txt)
for (const cmdFile of cmdFiles) {
  const basename = cmdFile.replace(/\.cmd\.txt$/, "");

  const cmd = fs.readFileSync(path.join(testDir, cmdFile), "utf8").trim();
  const expectedStderrPath = path.join(testDir, `${basename}.expected.stderr.txt`);
  const expectedStdoutPath = path.join(testDir, `${basename}.expected.stdout.txt`);
  const expectedCodePath = path.join(testDir, `${basename}.expected.code.txt`);

  if (!fs.existsSync(expectedStderrPath)) {
    console.log(`⊘ ${basename} (missing expected stderr file)`);
    continue;
  }

  const expectedStderr = fs.readFileSync(expectedStderrPath, "utf8");
  const expectedStdout = fs.existsSync(expectedStdoutPath) ? fs.readFileSync(expectedStdoutPath, "utf8") : null;
  const expectedCode = fs.existsSync(expectedCodePath)
    ? Number(fs.readFileSync(expectedCodePath, "utf8").trim())
    : 1;

  const result = spawnSync(`node dist/cli.js ${cmd}`, {
    shell: true,
    encoding: "utf8",
  });

  const actualCode = result.status ?? 0;
  const actualStdout = result.stdout ?? "";
  const actualStderr = result.stderr ?? "";

  const stdoutOk = expectedStdout === null ? true : actualStdout === expectedStdout;

  if (actualCode !== expectedCode || actualStderr !== expectedStderr || !stdoutOk) {
    console.log(`✗ ${basename}`);
    if (actualCode !== expectedCode) {
      console.log(`Expected exit code: ${expectedCode}`);
      console.log(`Got exit code:      ${actualCode}`);
    }
    if (expectedStdout !== null && actualStdout !== expectedStdout) {
      console.log("Expected stdout:");
      console.log(expectedStdout);
      console.log("Got stdout:");
      console.log(actualStdout);
    }
    console.log("Expected stderr:");
    console.log(expectedStderr);
    console.log("Got stderr:");
    console.log(actualStderr);
    failed++;
  } else {
    console.log(`✓ ${basename}`);
    passed++;
  }
}

for (const orgFile of orgFiles) {
  const basename = orgFile.replace(/\.org$/, "");
  const filePath = path.join(testDir, orgFile);

  // Archive tests
  if (basename.startsWith("archive-")) {
    const expectedArchive = fs.readFileSync(path.join(testDir, `${basename}.expected.txt`), "utf8");
    try {
      const output = execSync(`node dist/cli.js archive --file "${filePath}" --pos 4`, { encoding: "utf8" });
      if (output !== expectedArchive) {
        console.log(`✗ ${basename}`);
        console.log("Expected:");
        console.log(expectedArchive);
        console.log("Got:");
        console.log(output);
        failed++;
      } else {
        console.log(`✓ ${basename}`);
        passed++;
      }
    } catch (err) {
      console.log(`✗ ${basename} (error)`);
      console.error(err instanceof Error ? err.message : err);
      failed++;
    }
    continue;
  }

  // Agenda tests
  const expectedTextFile = path.join(testDir, `${basename}.expected.txt`);
  const expectedJsonFile = path.join(testDir, `${basename}.expected.json.txt`);

  const hasText = fs.existsSync(expectedTextFile);
  const hasJson = fs.existsSync(expectedJsonFile);

  if (!hasText && !hasJson) {
    console.log(`⊘ ${basename} (no expected output file)`);
    continue;
  }

  try {
    if (hasText) {
      const output = execSync(`node dist/cli.js agenda --files "${filePath}" --today 2026-01-21 --days 2`, {
        encoding: "utf8",
      });

      const expected = fs.readFileSync(expectedTextFile, "utf8");

      if (output !== expected) {
        console.log(`✗ ${basename} (text)`);
        console.log("Expected:");
        console.log(expected);
        console.log("Got:");
        console.log(output);
        failed++;
        continue;
      }
    }

    if (hasJson) {
      const output = execSync(
        `node dist/cli.js agenda --files "${filePath}" --today 2026-01-21 --days 2 --format json`,
        { encoding: "utf8" },
      );

      const expected = fs.readFileSync(expectedJsonFile, "utf8");

      const normalizedOut = JSON.stringify(JSON.parse(output), null, 2) + "\n";
      const normalizedExpected = JSON.stringify(JSON.parse(expected), null, 2) + "\n";

      if (normalizedOut !== normalizedExpected) {
        console.log(`✗ ${basename} (json)`);
        console.log("Expected:");
        console.log(normalizedExpected);
        console.log("Got:");
        console.log(normalizedOut);
        failed++;
        continue;
      }
    }

    console.log(`✓ ${basename}`);
    passed++;
  } catch (err) {
    console.log(`✗ ${basename} (error)`);
    console.error(err instanceof Error ? err.message : err);
    failed++;
  }
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
