#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cli = path.join(repoRoot, "dist", "cli.js");
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agenda-cache-"));
const corpus = path.join(fixtureRoot, "corpus");
const indexHome = path.join(fixtureRoot, "index");
const firstFile = path.join(corpus, "first.org2");
const secondFile = path.join(corpus, "second.org2");
const agendaArgs = [
  cli,
  "agenda",
  "--dir",
  corpus,
  "--from",
  "2026-08-27",
  "--to",
  "2026-08-27",
  "--format",
  "json",
];
const env = { ...process.env, ORG2_INDEX_HOME: indexHome };

function agendaSync() {
  const result = spawnSync(process.execPath, agendaArgs, {
    cwd: repoRoot,
    encoding: "utf8",
    env,
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

function agendaAsync() {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, agendaArgs, {
      cwd: repoRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`agenda exited ${code}: ${stderr}`));
        return;
      }
      resolve(stdout);
    });
  });
}

function findFilesNamed(root, name) {
  if (!fs.existsSync(root)) return [];
  const found = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const absolutePath = path.join(root, entry.name);
    if (entry.isDirectory()) found.push(...findFilesNamed(absolutePath, name));
    else if (entry.isFile() && entry.name === name) found.push(absolutePath);
  }
  return found;
}

function agendaHeadlines(raw) {
  const payload = JSON.parse(raw);
  return payload.days.flatMap((day) => day.items.map((item) => item.headline));
}

try {
  fs.mkdirSync(corpus, { recursive: true });
  fs.writeFileSync(
    path.join(corpus, "org2.json"),
    JSON.stringify({ agendaFiles: ["*.org2"], recursive: true }, null, 2) + "\n",
    "utf8",
  );
  fs.writeFileSync(firstFile, "* TODO First cached task\nSCHEDULED: <2026-08-27 Thu>\n", "utf8");
  fs.writeFileSync(secondFile, "* TODO Second cached task\nSCHEDULED: <2026-08-27 Thu>\n", "utf8");

  const coldOutput = agendaSync();
  assert.deepEqual(agendaHeadlines(coldOutput), ["First cached task", "Second cached task"]);

  const cacheFiles = findFilesNamed(indexHome, "agenda-v1.json");
  assert.equal(cacheFiles.length, 1, "agenda should write one machine-local cache for the corpus");
  const cacheFile = cacheFiles[0];
  const coldCache = JSON.parse(fs.readFileSync(cacheFile, "utf8"));
  assert.equal(coldCache.schemaVersion, "org2-agenda-cache/v2");
  assert.equal(coldCache.rootDir, corpus, "--dir should scope the cache to the scanned corpus");
  assert.equal(findFilesNamed(corpus, "agenda-v1.json").length, 0, "derived agenda state must stay outside the corpus");

  const coldCacheMtime = fs.statSync(cacheFile).mtimeMs;
  const warmOutput = agendaSync();
  assert.equal(warmOutput, coldOutput, "a warm agenda must preserve byte-for-byte CLI output");
  assert.equal(fs.statSync(cacheFile).mtimeMs, coldCacheMtime, "a fully warm agenda must not rewrite its cache");

  fs.writeFileSync(secondFile, "* TODO Updated cached task\nSCHEDULED: <2026-08-27 Thu>\n", "utf8");
  const changedOutput = agendaSync();
  assert.deepEqual(agendaHeadlines(changedOutput), ["First cached task", "Updated cached task"]);
  const changedCache = JSON.parse(fs.readFileSync(cacheFile, "utf8"));
  const coldQuery = Object.values(coldCache.queries)[0];
  const changedQuery = Object.values(changedCache.queries)[0];
  assert.deepEqual(changedQuery.files[firstFile], coldQuery.files[firstFile], "unchanged file fragments should be reused");
  assert.notDeepEqual(changedQuery.files[secondFile], coldQuery.files[secondFile], "changed file fragments should be replaced");

  fs.writeFileSync(cacheFile, "{corrupt cache\n", "utf8");
  const concurrentOutputs = await Promise.all(Array.from({ length: 4 }, () => agendaAsync()));
  for (const output of concurrentOutputs) assert.equal(output, changedOutput);
  const recoveredCache = JSON.parse(fs.readFileSync(cacheFile, "utf8"));
  assert.equal(recoveredCache.schemaVersion, "org2-agenda-cache/v2");
  assert.equal(recoveredCache.rootDir, corpus);

  process.stdout.write("agenda incremental cache tests passed\n");
} finally {
  assert.ok(
    fixtureRoot.startsWith(`${os.tmpdir()}${path.sep}org2-agenda-cache-`),
    `refusing to remove unexpected fixture path: ${fixtureRoot}`,
  );
  fs.rmSync(fixtureRoot, { recursive: true, force: true });
}
