import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { createAgentRun, saveAgentRun } from "../dist/agentRun.js";
import { workflowFromRun, saveWorkflow } from "../dist/agentWorkflow.js";
import { createGoal, saveGoal, createAgentProfile, saveAgentProfile } from "../dist/coordination.js";
import { workspaceAgentState } from "../dist/workspaceAgentState.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-workspace-agent-state-"));
const cli = path.resolve("dist/cli.js");
function query(args) {
  const start = performance.now();
  const result = spawnSync(process.execPath, [cli, ...args, "--dir", root, "--json"], { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
  assert.equal(result.status, 0, result.stderr);
  return { value: JSON.parse(result.stdout), milliseconds: performance.now() - start };
}
const median = (values) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
try {
  const run = createAgentRun({ id: "refresh-run", goal: "Refresh fixture", riskClass: "local-draft" });
  saveAgentRun(root, run, { expectedRevision: null });
  saveWorkflow(root, workflowFromRun({ ...run, status: "completed" }, { id: "refresh-workflow" }));
  saveGoal(root, createGoal({ id: "refresh-goal", title: "Refresh goal" }), { expectedRevision: null });
  saveAgentProfile(root, createAgentProfile({ id: "refresh-agent", name: "Refresh agent" }), { expectedRevision: null });
  const snapshot = query(["workspace", "agent-state"]).value;
  assert.equal(snapshot.schema, "org2:workspace-agent-state:v1");
  for (const [key, family] of [["runs", "run"], ["workflows", "workflow"], ["goals", "goal"], ["profiles", "agent-profile"], ["projects", "project"]]) {
    assert.deepEqual(snapshot[key].value, query([family, "list"]).value);
    assert.ok(snapshot[key].elapsedMilliseconds >= 0);
  }
  const badGoal = path.join(root, "goals", "broken.org2");
  fs.writeFileSync(badGoal, "This is not a goal record.\n");
  const partial = workspaceAgentState(root);
  assert.equal(typeof partial.goals.error, "string");
  assert.deepEqual(partial.runs.value, snapshot.runs.value);
  assert.deepEqual(partial.workflows.value, snapshot.workflows.value);
  assert.deepEqual(partial.profiles.value, snapshot.profiles.value);
  fs.rmSync(badGoal);
  const invalidMount = spawnSync(process.execPath, [cli, "workspace", "agent-state", "--mount", root, "--json"], { encoding: "utf8" });
  assert.notEqual(invalidMount.status, 0);
  assert.match(invalidMount.stderr, /--mount is not supported/);

  if (process.argv.includes("--performance")) {
    for (let i = 0; i < 100; i++) {
      saveAgentRun(root, createAgentRun({ id: `perf-${i}`, goal: `Synthetic refresh ${i}`, riskClass: "local-draft" }), { expectedRevision: null });
    }
    const serial = [], batched = [];
    for (let i = 0; i < 3; i++) {
      // Alternate order to avoid consistently favoring a warmer file cache.
      const runSerial = () => serial.push(["run", "workflow", "goal", "agent-profile"].reduce((total, family) => total + query([family, "list"]).milliseconds, 0));
      const runBatch = () => batched.push(query(["workspace", "agent-state"]).milliseconds);
      if (i % 2) { runBatch(); runSerial(); } else { runSerial(); runBatch(); }
    }
    const baseline = median(serial), optimized = median(batched);
    console.log(`Agent-state refresh, 101 runs: four processes ${baseline.toFixed(1)}ms; one batch ${optimized.toFixed(1)}ms (median of 3)`);
    assert.ok(optimized < baseline * 0.85, `Batch refresh must remain materially faster: ${optimized} vs ${baseline}ms`);
  }
  console.log("OK: workspace agent-state matches list APIs and isolates section failures");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
