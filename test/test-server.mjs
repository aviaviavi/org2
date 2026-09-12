import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync, spawn } from "node:child_process";
import { validateServerConfiguration, serverLaunchAgent, serverControl } from "../dist/serverCli.js";
import { acquireWorkflowDispatchLock, assignAutomationHost, automationHostRef } from "../dist/automationHost.js";
import { initializeCorpusIdentity } from "../dist/corpusIdentity.js";
import { loadAgentRun, saveAgentRun, transitionAgentRun } from "../dist/agentRun.js";

const temporary = fs.mkdtempSync(path.join(process.platform === "darwin" ? "/tmp" : os.tmpdir(), "org2-server-test-"));
const corpus = path.join(temporary, "corpus");
const cli = path.resolve("dist/cli.js");
const configFile = path.join(temporary, "state/server.json");
function run(...args) {
  const result = spawnSync(process.execPath, [cli, ...args], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}
async function concurrent(...args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [cli, ...args]);
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (data) => { stdout += data; });
    child.stderr.on("data", (data) => { stderr += data; });
    child.on("exit", (code) => resolve({ code, stdout, stderr }));
  });
}

try {
  fs.mkdirSync(corpus);
  initializeCorpusIdentity(corpus, { id: "server-test", name: "Server test", kind: "project" }, { apply: true });
  assert.equal(automationHostRef(corpus), "desktop");
  assert.equal(assignAutomationHost(corpus, "press", false).applied, false);
  assert.equal(automationHostRef(corpus), "desktop", "ownership previews must not mutate the corpus");
  assignAutomationHost(corpus, "press", true);
  assert.equal(automationHostRef(corpus), "press");
  const before = fs.readFileSync(path.join(corpus, "org2.json"), "utf8");
  assert.throws(() => assignAutomationHost(corpus, "../bad", true));
  assert.equal(fs.readFileSync(path.join(corpus, "org2.json"), "utf8"), before);

  const init = run("server", "init", "--dir", corpus, "--host-ref", "press", "--bind", "100.64.1.2", "--config", configFile);
  assert.equal(init.applied, false);
  assert.equal(fs.existsSync(configFile), false);
  const config = init.config;
  assert.equal(validateServerConfiguration(config, configFile).hostRef, "press");
  assert.throws(() => validateServerConfiguration({ ...config, bindHost: "0.0.0.0" }, configFile), /Tailscale/);
  assert.throws(() => validateServerConfiguration({ ...config, port: 0 }, configFile), /port/);
  assert.throws(() => validateServerConfiguration(config, path.join(corpus, "server.json")), /machine-local/);
  fs.symlinkSync(corpus, path.join(temporary, "corpus-link"));
  assert.throws(() => validateServerConfiguration(config, path.join(temporary, "corpus-link/server.json")), /machine-local/);
  run("server", "init", "--dir", corpus, "--host-ref", "press", "--bind", "100.64.1.2", "--config", configFile, "--apply");
  assert.equal(fs.statSync(configFile).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(configFile)).mode & 0o777, 0o700);
  const plist = serverLaunchAgent(configFile, { ...config, name: "A & B", repoRoot: "/tmp/a&b" });
  assert.match(plist, /\/tmp\/a&amp;b\/dist\/cli.js/);
  assert.match(plist, /SuccessfulExit/);

  run("workflow", "create", "scheduled", "--title", "Test schedule", "--prompt", "Report ready", "--schedule", "every 1m",
    "--destination-ref", "builtin.codex", "--now", "2026-09-01T00:00:00.000Z", "--dir", corpus, "--json");
  const now = "2026-09-01T00:05:00.000Z";
  const desktopDue = run("workflow", "due", "--dir", corpus, "--now", now, "--json");
  assert.equal(desktopDue.due.length, 0, "desktop must skip a server-owned corpus");
  assert.equal(desktopDue.hostRef, "press");
  const due = run("workflow", "due", "--host-ref", "press", "--dir", corpus, "--now", now, "--json");
  assert.equal(due.due.length, 1);
  assert.equal(due.hostRef, "press");
  const occurrence = due.due[0].scheduledFor;
  const args = ["workflow", "run", "scheduled", "--trigger", "schedule", "--scheduled-for", occurrence, "--dir", corpus, "--json"];
  assert.equal(run(...args).eligible, false, "ownership must be rechecked at dispatch time");
  const results = await Promise.all([concurrent(...args, "--host-ref", "press"), concurrent(...args, "--host-ref", "press")]);
  const created = results.filter((result) => result.code === 0).map((result) => JSON.parse(result.stdout)).filter((result) => result.run);
  assert.equal(created.length, 1, JSON.stringify(results));
  const runID = created[0].run.id;
  saveAgentRun(corpus, transitionAgentRun(loadAgentRun(corpus, runID), "failed", { reason: "test finished" }));
  const duplicate = run(...args, "--host-ref", "press");
  assert.equal(duplicate.eligible, false);
  assert.match(duplicate.reason, /occurrence already/);
  const release = acquireWorkflowDispatchLock(corpus, "scheduled");
  assert.throws(() => acquireWorkflowDispatchLock(corpus, "scheduled"), /EEXIST/);
  const unrelated = acquireWorkflowDispatchLock(corpus, "independent");
  unrelated();
  release();
  acquireWorkflowDispatchLock(corpus, "scheduled")();
  if (process.platform === "darwin") {
    const worker = path.join(temporary, "fake-worker.mjs");
    fs.writeFileSync(worker, `#!/usr/bin/env node
import readline from 'node:readline';
console.log(JSON.stringify({event:'ready'}));
for await (const line of readline.createInterface({input:process.stdin})) {
 const request=JSON.parse(line);
 console.log(JSON.stringify({id:request.id,result:request.command==='stop'?{stopped:true}:{listening:true}}));
 if(request.command==='stop') process.exit(0);
}
`, { mode: 0o700 });
    fs.writeFileSync(configFile, JSON.stringify({ ...config, executable: worker }));
    // A returned stop result must mean launchd can start the service again,
    // not merely that the native child has queued its final response.
    for (let attempt = 0; attempt < 2; attempt++) {
      const supervisor = spawn(process.execPath, [cli, "server", "start", "--config", configFile]);
      const exited = new Promise((resolve) => supervisor.once("exit", resolve));
      let errors = "";
      supervisor.stderr.on("data", (data) => { errors += data; });
      try {
        await new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error(`Server did not start: ${errors}`)), 10_000);
          supervisor.stdout.on("data", (data) => {
            if (data.toString().includes('"event":"ready"')) { clearTimeout(timer); resolve(); }
          });
          supervisor.once("error", reject);
        });
        assert.equal((await serverControl(configFile, "status")).listening, true);
        const stopped = await concurrent("server", "stop", "--config", configFile);
        assert.equal(stopped.code, 0, stopped.stderr);
        assert.equal(JSON.parse(stopped.stdout).stopped, true);
        assert.equal(await exited, 0, errors);
        assert.throws(() => process.kill(supervisor.pid, 0), { code: "ESRCH" });
      } finally {
        if (supervisor.exitCode === null) supervisor.kill();
      }
    }
  }
  console.log("server configuration, ownership, and concurrent dispatch tests passed");
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
