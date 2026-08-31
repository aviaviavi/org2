#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { listAgentRunsWithApprovals } from "../dist/agentRun.js";

const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-approval-refresh-performance-"));
const corpus = path.join(fixtureRoot, "corpus");
const runs = path.join(corpus, ".org2", "runs");
const indexHome = path.join(fixtureRoot, "index");
const previousIndexHome = process.env.ORG2_INDEX_HOME;
const runCount = Number.parseInt(process.env.ORG2_PERF_APPROVAL_RUNS || "2500", 10);
const scale = Number.parseFloat(process.env.ORG2_PERF_BUDGET_SCALE || "1");

assert.ok(Number.isFinite(runCount) && runCount >= 500 && runCount <= 20_000);
assert.ok(Number.isFinite(scale) && scale >= 0.5 && scale <= 10);

function runRefresh(label, budgetMs) {
  const started = process.hrtime.bigint();
  const items = listAgentRunsWithApprovals(corpus);
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
  assert.ok(elapsedMs <= budgetMs, `${label} took ${elapsedMs.toFixed(1)}ms, exceeding ${budgetMs.toFixed(1)}ms`);
  return { label, elapsedMs, items };
}

try {
  process.env.ORG2_INDEX_HOME = indexHome;
  fs.mkdirSync(runs, { recursive: true });
  fs.writeFileSync(path.join(corpus, "notes.org2"), "* TODO Synthetic note without an approval\n", "utf8");
  const runFiller = "Representative durable run history. ".repeat(960);
  for (let runIndex = 0; runIndex < runCount; runIndex += 1) {
    fs.writeFileSync(
      path.join(runs, `run-${String(runIndex).padStart(5, "0")}.org2`),
      `#+TITLE: Synthetic run ${runIndex}\n** Approvals [0/0 pending]\n${runFiller}\n`,
      "utf8",
    );
  }

  const cold = runRefresh("approvals/cold", 10_000 * scale);
  const warm = runRefresh("approvals/warm", 3_000 * scale);
  fs.appendFileSync(path.join(runs, "run-00000.org2"), "One changed run.\n", "utf8");
  const incremental = runRefresh("approvals/one change", 3_500 * scale);

  assert.equal(cold.items.length, 0);
  assert.deepEqual(warm.items, cold.items);
  assert.equal(incremental.items.length, 0);
  assert.ok(
    warm.elapsedMs < cold.elapsedMs * 0.65,
    `warm refresh ${warm.elapsedMs.toFixed(1)}ms should be materially faster than cold ${cold.elapsedMs.toFixed(1)}ms`,
  );

  process.stdout.write(`Approval refresh performance (${runCount} durable runs)\n`);
  for (const result of [cold, warm, incremental]) {
    process.stdout.write(`  ${result.label.padEnd(22)} ${(result.elapsedMs / 1000).toFixed(3)}s\n`);
  }
} finally {
  if (previousIndexHome === undefined) delete process.env.ORG2_INDEX_HOME;
  else process.env.ORG2_INDEX_HOME = previousIndexHome;
  assert.ok(
    fixtureRoot.startsWith(`${os.tmpdir()}${path.sep}org2-approval-refresh-performance-`),
    `refusing to remove unexpected fixture path: ${fixtureRoot}`,
  );
  fs.rmSync(fixtureRoot, { recursive: true, force: true });
}
