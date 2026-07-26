import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { Org2Lifecycle } from "../integrations/openclaw/lib/lifecycle.js";
import { loadAgentRun } from "../dist/agentRun.js";

const execFileAsync = promisify(execFile);
const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-openclaw-cli-"));
const stateFile = path.join(root, "plugin-state.json");
const cli = path.resolve("dist/cli.js");
const exec = async (args) => {
  const { stdout } = await execFileAsync(process.execPath, [cli, ...args, "--dir", root], { maxBuffer: 2_000_000 });
  return stdout;
};

const lifecycle = new Org2Lifecycle({ stateFile, owner: "integration-test", exec });
await lifecycle.init();

const completedId = await lifecycle.ensure("turn:completed", {
  kind: "agent-turn",
  goal: "Exercise real OpenClaw lifecycle completion",
  sessionKey: "agent:main:org2:test-completed",
  openclawRunId: "openclaw-completed",
  provider: "openai",
  model: "gpt-5",
});
await lifecycle.recordUsage("openclaw-completed", { input: 100, output: 50, total: 150 });
await lifecycle.finish("turn:completed", "ok", {
  summary: "Completed through the real Org2 CLI.",
  durationMs: 2500,
});
const completed = loadAgentRun(root, completedId);
assert.equal(completed.status, "completed");
assert.equal(completed.outcome.summary, "Completed through the real Org2 CLI.");
assert.equal(completed.provider, "openai");
assert.equal(completed.model, "gpt-5");
assert.equal(completed.budget.tokensUsed, 150);
assert.equal(completed.budget.elapsedSeconds, 2.5);

const approvalId = await lifecycle.ensure("turn:approval", {
  kind: "agent-turn",
  goal: "Stop at a real approval boundary",
  sessionKey: "agent:main:org2:test-approval",
  openclawRunId: "openclaw-approval",
});
await exec([
  "run", "approval-request", approvalId,
  "--title", "Approve external action",
  "--action", "send the result",
  "--risk", "external-action",
  "--material-json", JSON.stringify({
    kind: "message",
    target: "reviewed-recipient@example.com",
    content: "Exact reviewed result.",
  }),
]);
const paused = await lifecycle.finish("turn:approval", "ok", { summary: "Requested approval." });
assert.deepEqual(paused, { terminal: false, status: "waiting-approval" });
assert.equal(loadAgentRun(root, approvalId).status, "waiting-approval");

console.log("openclaw lifecycle CLI integration tests passed");
