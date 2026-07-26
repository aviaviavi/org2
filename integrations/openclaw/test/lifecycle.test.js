import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, readdir, rm, unlink, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import { conciseGoal, cronKey, executionSummary, outcomeCommand, shouldTrackMainTurn, workflowContinuationPrompt, workflowExecutionPrompt, workflowMarker } from "../lib/lifecycle.js";
import { Org2Lifecycle } from "../lib/lifecycle.js";
import { canonicalJson } from "../lib/approval-effects.js";

test("tracks substantial work but not acknowledgements or heartbeats", () => {
  assert.equal(shouldTrackMainTurn("Please implement the lifecycle plugin", {}), true);
  assert.equal(shouldTrackMainTurn("cool", {}), false);
  assert.equal(shouldTrackMainTurn("investigate the failed job", { trigger: "heartbeat" }), false);
});

test("maps terminal outcomes", () => {
  assert.equal(outcomeCommand("ok"), "complete");
  assert.equal(outcomeCommand("timeout"), "fail");
  assert.equal(outcomeCommand("killed"), "cancel");
});

test("bounds run goals", () => assert.ok(conciseGoal("x".repeat(400)).length <= 240));

test("extracts a concise outcome from the last assistant message", () => {
  assert.equal(executionSummary([
    { role: "assistant", content: "Older" },
    { role: "user", content: "Continue" },
    { role: "assistant", content: [{ type: "text", text: "Finished the workflow.\nArtifacts are ready." }] },
  ]), "Finished the workflow. Artifacts are ready.");
});

test("uses the same cron key when finish adds run and session ids", () => {
  const started = { jobId: "job-1", runAtMs: 123 };
  const finished = { jobId: "job-1", runAtMs: 123, runId: "run-1", sessionId: "session-1" };
  assert.equal(cronKey(started), cronKey(finished));
});

test("recognizes prepared Org2 workflow runs", () => {
  const prompt = workflowExecutionPrompt({ id: "weekly-review", version: "1.2.0", title: "Weekly review" }, { week: "2026-W29" }, "run-42");
  assert.deepEqual(workflowMarker(prompt), {
    workflowId: "weekly-review",
    workflowRunId: "run-42",
    inputs: { week: "2026-W29" },
  });
  assert.equal(shouldTrackMainTurn(prompt, {}), true);
  assert.equal(shouldTrackMainTurn(prompt, { jobId: "cron-1" }), false);
  assert.match(prompt, /--requirement REQUIREMENT_ID/);
  assert.match(prompt, /--material-json/);
  assert.match(prompt, /A note, unrelated artifact, opaque ID, or fingerprint alone is not review material/);
  assert.match(workflowContinuationPrompt({ id: "weekly-review", version: "1.2.0", title: "Weekly review" }, "run-42"), /artifact-review/);
});

test("prepares a durable run before handing a workflow to OpenClaw", async () => {
  const calls = [];
  const workflow = { id: "weekly-review", version: "1.0.0", title: "Weekly review" };
  const lifecycle = new Org2Lifecycle({
    owner: "operator",
    exec: async (args) => {
      calls.push(args);
      if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
      if (args[0] === "workflow" && args[1] === "run") return JSON.stringify({ run: { id: "run-1" } });
      if (args[0] === "workflow" && args[1] === "show") return JSON.stringify(workflow);
      return "";
    },
  });
  const prepared = await lifecycle.prepareWorkflowRun("weekly-review", { week: "29" });
  assert.equal(prepared.run.id, "run-1");
  assert.equal(workflowMarker(prepared.prompt).workflowRunId, "run-1");
  assert.deepEqual(calls.find((args) => args[0] === "workflow" && args[1] === "run"), ["workflow", "run", "weekly-review", "--owner", "operator", "--json", "--input", "week=29"]);
});

test("reconciles an active Org2 schedule into OpenClaw cron", async () => {
  const added = [];
  const cron = {
    list: async () => [],
    add: async (input) => { added.push(input); return { id: "job-1" }; },
    update: async () => {},
    remove: async () => ({ removed: true }),
  };
  const lifecycle = new Org2Lifecycle({
    cron,
    exec: async (args) => {
      if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
      if (args[0] === "workflow" && args[1] === "list") return JSON.stringify({ workflows: [{
        id: "weekly-review", version: "1.0.0", title: "Weekly review", state: "active",
        triggers: [{ id: "openclaw-schedule", type: "schedule", enabled: true, schedule: "0 9 * * 1", timezone: "America/Los_Angeles" }],
      }] });
      return "";
    },
    stateFile: join(await mkdtemp(join(tmpdir(), "org2-openclaw-cron-")), "state.json"),
  });
  await lifecycle.init();
  await lifecycle.reconcile();
  assert.equal(added.length, 1);
  assert.equal(added[0].schedule.expr, "0 9 * * 1");
  assert.equal(added[0].schedule.tz, "America/Los_Angeles");
  assert.equal(workflowMarker(added[0].payload.text).workflowId, "weekly-review");
});

test("finish reloads a mapping and records the required completion summary", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  const lifecycle = new Org2Lifecycle({ stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "run" && args[1] === "show") return JSON.stringify({ id: "run-1", status: "running" });
    return "";
  } });
  await lifecycle.init();
  await writeFile(stateFile, JSON.stringify({ version: 1, mappings: { key: { org2RunId: "run-1" } } }));
  await lifecycle.finish("key", "ok", { summary: "Finished the requested work." });
  assert.deepEqual(calls.find((args) => args[1] === "complete"), [
    "run", "complete", "run-1", "--actor", "org2-lifecycle", "--summary", "Finished the requested work.",
  ]);
  const state = JSON.parse(await readFile(stateFile, "utf8"));
  assert.equal(state.version, 4);
  assert.equal(state.mappings.key.outcome, "ok");
});

test("a successful OpenClaw turn leaves approval and clarification boundaries open", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-approval-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  const lifecycle = new Org2Lifecycle({ stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "run" && args[1] === "show") return JSON.stringify({ id: "run-1", status: "waiting-approval" });
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = { org2RunId: "run-1", sessionKey: "agent:main:org2:thread-1" };
  const result = await lifecycle.finish("key", "ok", { summary: "Approval requested." });
  assert.deepEqual(result, { terminal: false, status: "waiting-approval" });
  assert.equal(calls.some((args) => args[1] === "complete"), false);
});

test("a successful OpenClaw turn leaves review-required artifacts open", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-artifact-review-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  const lifecycle = new Org2Lifecycle({ stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "run" && args[1] === "show") {
      return JSON.stringify({
        id: "run-1",
        status: "running",
        artifacts: [{ id: "report", reviewStatus: "review-required" }],
      });
    }
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = { org2RunId: "run-1", sessionKey: "agent:main:org2:thread-1" };
  const result = await lifecycle.finish("key", "ok", { summary: "Report produced for review." });
  assert.deepEqual(result, { terminal: false, status: "review-required" });
  assert.equal(calls.some((args) => args[1] === "complete"), false);
});

test("a replayed terminal event accepts an already-completed historical run", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-completed-review-"));
  const stateFile = join(dir, "state.json");
  const lifecycle = new Org2Lifecycle({ stateFile, exec: async (args) => {
    if (args[0] === "run" && args[1] === "show") {
      return JSON.stringify({
        id: "run-1",
        status: "completed",
        artifacts: [{ id: "report", reviewStatus: "review-required" }],
      });
    }
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = { org2RunId: "run-1", sessionKey: "agent:main:org2:thread-1" };
  const result = await lifecycle.finish("key", "ok", { summary: "Already completed." });
  assert.deepEqual(result, { terminal: true, status: "completed" });
});

test("resumes an approved workflow in its correlated OpenClaw session", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-resume-"));
  const stateFile = join(dir, "state.json");
  const workflow = { id: "weekly-review", version: "1.0.0", title: "Weekly review" };
  const lifecycle = new Org2Lifecycle({ stateFile, exec: async (args) => {
    if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
    if (args[0] === "run" && args[1] === "show") return JSON.stringify({ id: "run-1", status: "running", workflowId: workflow.id, approvals: [{ status: "approved" }] });
    if (args[0] === "workflow" && args[1] === "show") return JSON.stringify(workflow);
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = { org2RunId: "run-1", sessionKey: "agent:main:org2:thread-1", createdAt: "2026-07-18T10:00:00Z" };
  const resumed = await lifecycle.resumeWorkflowRun("run-1", { expectedCorpusId: "personal" });
  assert.equal(resumed.sessionKey, "agent:main:org2:thread-1");
  assert.equal(workflowMarker(resumed.prompt).workflowRunId, "run-1");
  assert.match(workflowContinuationPrompt(workflow, "run-1"), /approval-decided/);
});

test("rejects a Mac workflow request for a different configured corpus", async () => {
  const lifecycle = new Org2Lifecycle({ exec: async (args) => {
    if (args[0] === "corpus") return JSON.stringify({ identity: { id: "team" } });
    return "";
  } });
  await assert.rejects(
    lifecycle.prepareWorkflowRun("weekly-review", {}, { expectedCorpusId: "personal" }),
    /corpus mismatch/,
  );
});

function sha256(value) {
  return `sha256:${createHash("sha256").update(value, "utf8").digest("hex")}`;
}

function draftFixture() {
  const key = "gmail:gog:owner@example.com:draft-1";
  const material = {
    kind: "message",
    target: "person@example.com",
    content: canonicalJson({
      schema: "org2:gmail-draft-material:v1",
      account: "owner@example.com",
      draftId: "draft-1",
      messageId: "draft-message-1",
    }),
    runtimeTarget: { system: "gmail:gog", kind: "draft", id: key },
  };
  return {
    key,
    provider: "gmail:gog",
    account: "owner@example.com",
    draftId: "draft-1",
    destination: "person@example.com",
    subject: "Update",
    title: "Approve Update",
    action: "Send exact draft",
    note: "Readable exact draft",
    material,
    materialDigest: sha256(canonicalJson(material)),
  };
}

function nativeDraftStore(effect, options = {}) {
  const calls = [];
  const fingerprint = `sha256:${"a".repeat(64)}`;
  const run = {
    id: "draft-run-1",
    status: "running",
    updatedAt: "2026-07-25T12:00:00Z",
    approvals: [],
  };
  let creates = 0;
  const exec = async (args) => {
    calls.push(args);
    if (args[0] !== "run") return "";
    if (args[1] === "list") return JSON.stringify({ runs: run.approvals.length ? [run] : [] });
    if (args[1] === "create") {
      creates += 1;
      return JSON.stringify({ run: { id: run.id } });
    }
    if (args[1] === "approval-request") {
      const material = JSON.parse(args[args.indexOf("--material-json") + 1]);
      run.approvals.push({ id: `approval-${run.approvals.length + 1}`, status: "pending", fingerprint, material });
      return JSON.stringify(run);
    }
    if (args[1] === "show") return JSON.stringify(run);
    if (args[1] === "approval-effect-reserve") {
      if (options.reserveDelay) await new Promise((resolve) => setTimeout(resolve, options.reserveDelay));
      const approval = run.approvals.find((item) => item.id === args[3]);
      const reservation = {
        fingerprint: args[args.indexOf("--fingerprint") + 1],
        materialDigest: args[args.indexOf("--material-digest") + 1],
        toolCallId: args[args.indexOf("--tool-call-id") + 1],
        reservedAt: new Date().toISOString(),
      };
      if (approval.effectReservation) {
        throw new Error("approval already has an unresolved effect reservation");
      }
      approval.effectReservation = reservation;
      return "";
    }
    if (args[1] === "approval-effect") {
      const approval = run.approvals.find((item) => item.id === args[3]);
      const toolCallId = args[args.indexOf("--tool-call-id") + 1];
      if (approval.effectReservation?.toolCallId !== toolCallId) throw new Error("reservation mismatch");
      approval.effectReceipt = {
        fingerprint: approval.fingerprint,
        performedAt: new Date().toISOString(),
        system: "gmail:gog",
        externalId: args[args.indexOf("--external-id") + 1],
      };
      delete approval.effectReservation;
      return "";
    }
    if (args[1] === "complete") run.status = "completed";
    return "";
  };
  return { calls, exec, fingerprint, run, get creates() { return creates; } };
}

test("uses a durable native reservation and receipt as the Gmail send authority", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-draft-"));
  const stateFile = join(dir, "state.json");
  const effect = draftFixture();
  const store = nativeDraftStore(effect);
  const lifecycle = new Org2Lifecycle({ owner: "operator", stateFile, exec: store.exec });
  await lifecycle.init();
  const record = await lifecycle.requestDraftApproval(effect, {
    openclawRunId: "openclaw-1",
    sessionKey: "agent:main:test",
  });
  assert.equal(record.org2RunId, "draft-run-1");
  assert.equal(record.approvalFingerprint, store.fingerprint);
  store.run.approvals[0].status = "approved";

  await lifecycle.reserveDraftSend(effect, { toolCallId: "tool-1" });
  assert.equal(store.run.approvals[0].effectReservation.toolCallId, "tool-1");
  await lifecycle.recordDraftSent(effect, { toolCallId: "tool-1", externalId: "message-1" });
  assert.equal(store.run.approvals[0].effectReceipt.externalId, "message-1");
  const receipt = store.calls.find((args) => args[0] === "run" && args[1] === "approval-effect");
  assert.ok(receipt.includes("--tool-call-id"));
  assert.ok(receipt.includes("tool-1"));
  await assert.rejects(
    lifecycle.reserveDraftSend(effect, { toolCallId: "tool-2" }),
    /already performed/,
  );
});

test("only one concurrent tool call can reserve an approved Gmail effect", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-reserve-"));
  const effect = draftFixture();
  const store = nativeDraftStore(effect, { reserveDelay: 10 });
  const lifecycle = new Org2Lifecycle({ stateFile: join(dir, "state.json"), exec: store.exec });
  await lifecycle.init();
  await lifecycle.requestDraftApproval(effect);
  store.run.approvals[0].status = "approved";
  const outcomes = await Promise.allSettled([
    lifecycle.reserveDraftSend(effect, { toolCallId: "tool-a" }),
    lifecycle.reserveDraftSend(effect, { toolCallId: "tool-b" }),
  ]);
  assert.equal(outcomes.filter((item) => item.status === "fulfilled").length, 1);
  assert.equal(outcomes.filter((item) => item.status === "rejected").length, 1);
});

test("an unresolved reservation blocks every later approval version for the same Gmail draft", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-version-reserve-"));
  const stateFile = join(dir, "state.json");
  const original = draftFixture();
  const store = nativeDraftStore(original);
  const lifecycle = new Org2Lifecycle({ stateFile, exec: store.exec });
  await lifecycle.init();
  await lifecycle.requestDraftApproval(original);
  store.run.approvals[0].status = "approved";
  await lifecycle.reserveDraftSend(original, { toolCallId: "tool-original" });

  const changedMaterial = {
    ...original.material,
    content: canonicalJson({
      schema: "org2:gmail-draft-material:v1",
      account: original.account,
      draftId: original.draftId,
      messageId: "draft-message-2",
    }),
  };
  const changed = {
    ...original,
    title: "Approve changed update",
    material: changedMaterial,
    materialDigest: sha256(canonicalJson(changedMaterial)),
  };
  await assert.rejects(
    lifecycle.requestDraftApproval(changed),
    /unresolved effect reservation/,
  );
  assert.equal(store.run.approvals.length, 1);

  await rm(stateFile);
  const restarted = new Org2Lifecycle({ stateFile, exec: store.exec });
  await restarted.init();
  await assert.rejects(
    restarted.requestDraftApproval(changed),
    /unresolved effect reservation/,
  );
  assert.equal(store.run.approvals.length, 1);
});

test("reconstructs Gmail approval authority from native runtime targets after state deletion", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-reconstruct-"));
  const stateFile = join(dir, "state.json");
  const effect = draftFixture();
  const store = nativeDraftStore(effect);
  const first = new Org2Lifecycle({ stateFile, exec: store.exec });
  await first.init();
  await first.requestDraftApproval(effect);
  store.run.approvals[0].status = "approved";
  await rm(stateFile);

  const restarted = new Org2Lifecycle({ stateFile, exec: store.exec });
  await restarted.init();
  await restarted.reserveDraftSend(effect, { toolCallId: "restart-tool" });
  assert.equal(store.run.approvals[0].effectReservation.toolCallId, "restart-tool");
  const recovered = JSON.parse(await readFile(stateFile, "utf8"));
  assert.equal(recovered.drafts[effect.key].org2RunId, store.run.id);
});

test("cross-process draft creation is serialized and future state fields survive writes", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-state-lock-"));
  const stateFile = join(dir, "state.json");
  const effect = draftFixture();
  const store = nativeDraftStore(effect);
  await writeFile(stateFile, JSON.stringify({
    version: 9,
    mappings: {},
    workflowJobs: {},
    drafts: {},
    workMappings: { future: { org2RunId: "work-1" } },
    futureField: { keep: true },
  }));
  const first = new Org2Lifecycle({ stateFile, exec: store.exec });
  const second = new Org2Lifecycle({ stateFile, exec: store.exec });
  await Promise.all([first.init(), second.init()]);
  const [left, right] = await Promise.all([
    first.requestDraftApproval(effect),
    second.requestDraftApproval(effect),
  ]);
  assert.equal(left.approvalId, right.approvalId);
  assert.equal(store.creates, 1);
  assert.equal(store.run.approvals.length, 1);
  const state = JSON.parse(await readFile(stateFile, "utf8"));
  assert.equal(state.version, 9);
  assert.deepEqual(state.workMappings, { future: { org2RunId: "work-1" } });
  assert.deepEqual(state.futureField, { keep: true });
});

test("a stale lifecycle save cannot roll a newer draft mapping backward", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-stale-save-"));
  const stateFile = join(dir, "state.json");
  const key = "gmail:gog:owner@example.com:draft-1";
  await writeFile(stateFile, JSON.stringify({
    version: 4,
    mappings: {},
    workflowJobs: {},
    drafts: { [key]: { approvalId: "approval-1", materialDigest: "digest-a" } },
  }));
  const exec = async () => "";
  const first = new Org2Lifecycle({ stateFile, exec });
  const second = new Org2Lifecycle({ stateFile, exec });
  await Promise.all([first.init(), second.init()]);

  second.state.drafts[key] = { approvalId: "approval-2", materialDigest: "digest-b" };
  await second.attach("second", "run-second");
  first.state.mappings.unrelated = { org2RunId: "run-unrelated" };
  await first.attach("first", "run-first");

  const state = JSON.parse(await readFile(stateFile, "utf8"));
  assert.deepEqual(state.drafts[key], { approvalId: "approval-2", materialDigest: "digest-b" });
  assert.equal(state.mappings.first.org2RunId, "run-first");
  assert.equal(state.mappings.second.org2RunId, "run-second");
});

test("a live choosing participant blocks lifecycle state mutation until it withdraws", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-incomplete-lock-"));
  const stateFile = join(dir, "state.json");
  const lockDirectory = `${stateFile}.lock`;
  await mkdir(lockDirectory);
  const token = globalThis.crypto.randomUUID();
  const choosingFile = join(lockDirectory, `choosing.${token}.json`);
  await writeFile(choosingFile, `${JSON.stringify({
    schema: "org2:mutation-lock-owner:v2",
    host: hostname(),
    pid: process.pid,
    token,
    phase: "choosing",
    createdAt: "2026-07-25T00:00:00.000Z",
  })}\n`);
  const effect = draftFixture();
  const store = nativeDraftStore(effect);
  const lifecycle = new Org2Lifecycle({ stateFile, exec: store.exec });
  await lifecycle.init();
  let settled = false;
  const request = lifecycle.requestDraftApproval(effect).finally(() => { settled = true; });
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(settled, false);
  assert.equal(store.creates, 0);
  await unlink(choosingFile);
  await request;
  assert.equal(store.creates, 1);
});

test("a verified dead state-lock owner is reclaimed", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-stale-state-lock-"));
  const stateFile = join(dir, "state.json");
  const lockDirectory = `${stateFile}.lock`;
  await mkdir(lockDirectory);
  const token = globalThis.crypto.randomUUID();
  await writeFile(join(lockDirectory, `ticket.${String(1).padStart(16, "0")}.${token}.json`), `${JSON.stringify({
    schema: "org2:mutation-lock-owner:v2",
    host: hostname(),
    pid: 2_147_483_647,
    token,
    phase: "ticket",
    ticket: 1,
    createdAt: "2020-01-01T00:00:00Z",
  })}\n`);
  const effect = draftFixture();
  const store = nativeDraftStore(effect);
  const lifecycle = new Org2Lifecycle({ stateFile, exec: store.exec });
  await lifecycle.init();
  await lifecycle.requestDraftApproval(effect);
  assert.deepEqual(await readdir(lockDirectory), []);
});
