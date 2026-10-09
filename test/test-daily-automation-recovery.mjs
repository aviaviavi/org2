import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-daily-recovery-"));
const cli = path.resolve("dist/cli.js");
const command = (...args) => {
  const result = spawnSync(process.execPath, [cli, ...args, "--dir", root, "--json"], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return JSON.parse(result.stdout);
};
const occurrence = (day) => `2026-10-${day}T06:45:00.000Z`;
const dispatch = (day) => command("workflow", "run", "daily-repair", "--trigger", "schedule", "--scheduled-for", occurrence(day));
const due = (day) => command("workflow", "due", "--now", `2026-10-${day}T06:46:00Z`);

try {
  command("workflow", "create", "daily-repair", "--title", "Daily repair", "--prompt", "Repair today's items.",
    "--destination-ref", "missing-on-host", "--schedule", "45 23 * * *", "--timezone", "America/Los_Angeles",
    "--now", "2026-10-07T23:10:00Z");
  const first = dispatch("08").run;
  command("run", "fail", first.id, "--reason", "The configured AI destination is unavailable or disabled.");

  assert.equal(due("08").due.length, 0, "a failed occurrence is consumed, not repeatedly dispatched");
  const nextDay = due("09");
  assert.equal(nextDay.due[0].scheduledFor, occurrence("09"), "failure must not suppress the next day's occurrence");
  assert.equal(nextDay.skipped.length, 0);
  assert.deepEqual(dispatch("08").run, undefined, "the original failed occurrence remains deduplicated");
  assert.deepEqual(nextDay.failures, [{
    workflowId: "daily-repair", title: "Daily repair", runId: first.id,
    destinationRef: "missing-on-host", scheduledFor: occurrence("08"),
    failure: "The configured AI destination is unavailable or disabled.",
  }], "the scheduler must retain the last failure even when no new occurrence is due");
  assert.deepEqual(due("08").failures, nextDay.failures);

  const second = dispatch("09").run;
  assert.notEqual(second.id, first.id);
  assert.equal(second.logicalWorkId, first.logicalWorkId);
  assert.equal(second.attempt.number, 2);
  assert.deepEqual(due("09").failures, [], "a newer attempt supersedes an old failure warning");
  assert.equal(due("10").skipped[0].activeRunId, second.id, "queued work still prevents overlap");
  assert.equal(dispatch("10").activeRunId, second.id);

  command("run", "fail", second.id, "--reason", "Second day's dispatch failed.");
  assert.equal(due("10").failures[0].runId, second.id);
  assert.equal(due("10").due[0].scheduledFor, occurrence("10"));
  const third = dispatch("10").run;
  assert.equal(third.attempt.number, 3);
  command("run", "cancel", third.id);
  assert.equal(due("11").due[0].scheduledFor, occurrence("11"), "canceled attempts also permit the next day");
  assert.deepEqual(due("11").failures, []);
  command("workflow", "pause", "daily-repair");
  assert.deepEqual(due("11").due, []);
  assert.deepEqual(due("11").failures, []);
  console.log("daily automation recovery and persistent failure diagnostics ok");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
