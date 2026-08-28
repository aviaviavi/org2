#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cli = path.join(repoRoot, "dist", "cli.js");
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-cli-performance-"));
const corpus = path.join(fixtureRoot, "corpus");
const agendaCorpus = path.join(fixtureRoot, "agenda-corpus");
const indexHome = path.join(fixtureRoot, "index");
const fileCount = 500;
const headingsPerFile = 10;
const agendaFileCount = Number.parseInt(process.env.ORG2_PERF_AGENDA_FILES || "2000", 10);
const scale = Number.parseFloat(process.env.ORG2_PERF_BUDGET_SCALE || "1");

assert.ok(Number.isFinite(scale) && scale >= 0.5 && scale <= 10, "ORG2_PERF_BUDGET_SCALE must be from 0.5 to 10");
assert.ok(
  Number.isFinite(agendaFileCount) && agendaFileCount >= 500 && agendaFileCount <= 20_000,
  "ORG2_PERF_AGENDA_FILES must be from 500 to 20000",
);

const budgets = {
  startup: 2_000 * scale,
  compile: 8_000 * scale,
  lint: 8_000 * scale,
  graphAudit: 8_000 * scale,
  context: 10_000 * scale,
  contextWarm: 4_000 * scale,
  incrementalChange: 5_000 * scale,
  agendaCold: 6_000 * scale,
  agendaWarm: 1_000 * scale,
  agendaIncremental: 1_500 * scale,
};

function syntheticFile(fileIndex) {
  const lines = [
    `#+TITLE: Performance File ${fileIndex}`,
    "",
    ":PROPERTIES:",
    `:ID: perf-file-${fileIndex}`,
    ":END:",
    "",
  ];

  for (let headingIndex = 0; headingIndex < headingsPerFile; headingIndex += 1) {
    const previousFile = fileIndex === 0 ? fileCount - 1 : fileIndex - 1;
    lines.push(
      `* TODO Performance Needle ${fileIndex} ${headingIndex} :perf:`,
      ":PROPERTIES:",
      `:ID: perf-node-${fileIndex}-${headingIndex}`,
      `:PROJECT: performance-${fileIndex % 20}`,
      ":END:",
      `Synthetic performance needle content for node ${fileIndex}-${headingIndex}.`,
      `This line links to [[id:perf-node-${previousFile}-${headingIndex}][the previous performance node]].`,
      `Additional deterministic prose keeps graph and lint line scanning representative.`,
      "",
    );
  }
  return `${lines.join("\n")}\n`;
}

function syntheticAgendaFile(fileIndex, headline = `Synthetic agenda item ${fileIndex}`) {
  return [
    `* TODO ${headline} :perf:`,
    `SCHEDULED: <2026-08-27 Thu ${String(8 + (fileIndex % 10)).padStart(2, "0")}:00>`,
    ":PROPERTIES:",
    `:ID: perf-agenda-${fileIndex}`,
    `:PROJECT: performance-${fileIndex % 20}`,
    ":END:",
    "Representative agenda body text.",
    "",
  ].join("\n");
}

function runCase(name, args, budgetMs) {
  const started = process.hrtime.bigint();
  const result = spawnSync(process.execPath, [cli, ...args], {
    cwd: repoRoot,
    encoding: "utf8",
    env: { ...process.env, ORG2_INDEX_HOME: indexHome },
    maxBuffer: 128 * 1024 * 1024,
    timeout: Math.ceil(budgetMs * 1.5),
  });
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;

  assert.equal(result.error?.code, undefined, `${name} failed to execute: ${result.error?.message || ""}`);
  assert.equal(result.signal, null, `${name} timed out after ${elapsedMs.toFixed(1)}ms`);
  assert.equal(result.status, 0, `${name} exited ${result.status}: ${result.stderr}`);
  assert.ok(
    elapsedMs <= budgetMs,
    `${name} took ${elapsedMs.toFixed(1)}ms, exceeding its ${budgetMs.toFixed(1)}ms budget`,
  );
  return { name, elapsedMs, payload: JSON.parse(result.stdout) };
}

try {
  fs.mkdirSync(corpus, { recursive: true });
  for (let fileIndex = 0; fileIndex < fileCount; fileIndex += 1) {
    fs.writeFileSync(
      path.join(corpus, `performance-${String(fileIndex).padStart(4, "0")}.org2`),
      syntheticFile(fileIndex),
      "utf8",
    );
  }

  const results = [];
  results.push(runCase("startup/capabilities", ["agent", "capabilities"], budgets.startup));
  results.push(runCase(
    "compile corpus",
    ["compile", "corpus", "--dir", corpus, "--recursive", "--format", "json"],
    budgets.compile,
  ));
  results.push(runCase(
    "lint",
    ["lint", "--dir", corpus, "--recursive", "--format", "json"],
    budgets.lint,
  ));
  results.push(runCase(
    "graph audit",
    ["graph", "audit", "--dir", corpus, "--recursive", "--format", "json"],
    budgets.graphAudit,
  ));
  results.push(runCase(
    "agent context/cold",
    ["context", "performance needle", "--dir", corpus, "--recursive", "--budget", "8k", "--format", "json"],
    budgets.context,
  ));
  results.push(runCase(
    "agent context/warm",
    ["context", "performance needle", "--dir", corpus, "--recursive", "--budget", "8k", "--format", "json"],
    budgets.contextWarm,
  ));
  fs.appendFileSync(
    path.join(corpus, "performance-0000.org2"),
    "\n* TODO Incremental performance change\nOne changed file should be reparsed without rebuilding the other fragments.\n",
    "utf8",
  );
  results.push(runCase(
    "compile/incremental change",
    ["compile", "corpus", "--dir", corpus, "--recursive", "--incremental", "--format", "json"],
    budgets.incrementalChange,
  ));

  fs.mkdirSync(agendaCorpus, { recursive: true });
  for (let fileIndex = 0; fileIndex < agendaFileCount; fileIndex += 1) {
    fs.writeFileSync(
      path.join(agendaCorpus, `agenda-${String(fileIndex).padStart(5, "0")}.org2`),
      syntheticAgendaFile(fileIndex),
      "utf8",
    );
  }
  const agendaArgs = [
    "agenda",
    "--dir",
    agendaCorpus,
    "--recursive",
    "--from",
    "2026-08-27",
    "--to",
    "2026-08-27",
    "--format",
    "json",
  ];
  results.push(runCase("agenda/cold", agendaArgs, budgets.agendaCold));
  results.push(runCase("agenda/warm", agendaArgs, budgets.agendaWarm));
  fs.writeFileSync(
    path.join(agendaCorpus, "agenda-00000.org2"),
    syntheticAgendaFile(0, "Updated synthetic agenda item"),
    "utf8",
  );
  results.push(runCase("agenda/one change", agendaArgs, budgets.agendaIncremental));

  const [, compiled, lint, graphAudit, contextCold, contextWarm, incremental, agendaCold, agendaWarm, agendaIncremental] = results;
  assert.equal(compiled.payload.stats.files, fileCount);
  assert.equal(compiled.payload.stats.headings, fileCount * headingsPerFile);
  assert.equal(lint.payload.checkedFiles, fileCount);
  assert.equal(graphAudit.payload.summary.scannedFiles, fileCount);
  assert.equal(contextCold.payload.corpus.stats.files, fileCount);
  assert.ok(contextCold.payload.results.length > 0);
  assert.equal(contextWarm.payload.corpus.stats.files, fileCount);
  assert.ok(contextWarm.payload.results.length > 0);
  assert.equal(incremental.payload.indexState.parsedFiles, 1);
  assert.equal(incremental.payload.indexState.reusedFiles, fileCount - 1);
  assert.equal(agendaCold.payload.days[0].items.length, agendaFileCount);
  assert.deepEqual(agendaWarm.payload, agendaCold.payload);
  assert.equal(agendaIncremental.payload.days[0].items.length, agendaFileCount);
  assert.ok(
    agendaIncremental.payload.days[0].items.some((item) => item.headline === "Updated synthetic agenda item"),
  );

  process.stdout.write(
    `CLI performance regression suite (${fileCount} general files, ${agendaFileCount} agenda files; ${fileCount * (headingsPerFile + 1)} nodes; budget scale ${scale})\n`,
  );
  for (const result of results) {
    process.stdout.write(`  ${result.name.padEnd(22)} ${(result.elapsedMs / 1000).toFixed(3)}s\n`);
  }
} finally {
  assert.ok(
    fixtureRoot.startsWith(`${os.tmpdir()}${path.sep}org2-cli-performance-`),
    `refusing to remove unexpected fixture path: ${fixtureRoot}`,
  );
  fs.rmSync(fixtureRoot, { recursive: true, force: true });
}
