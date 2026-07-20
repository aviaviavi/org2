import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { conciseGoal, cronKey, durableRunMarker, executionSummary, outcomeCommand, shouldTrackMainTurn, workflowContinuationPrompt, workflowExecutionPrompt, workflowMarker, workflowRevisionPrompt } from "../lib/lifecycle.js";
import { Org2Lifecycle } from "../lib/lifecycle.js";
import { approvalAction, approvalTitle, draftCreatedEffect, draftSendEffect } from "../lib/draft-approvals.js";

test("tracks substantial work but not acknowledgements or heartbeats", () => {
  assert.equal(shouldTrackMainTurn("Please implement the lifecycle plugin", {}), true);
  assert.equal(shouldTrackMainTurn("cool", {}), false);
  assert.equal(shouldTrackMainTurn("investigate the failed job", { trigger: "heartbeat" }), false);
});

test("maps terminal outcomes", () => {
  assert.equal(outcomeCommand("ok"), "complete");
  assert.equal(outcomeCommand("timeout"), "fail");
  assert.equal(outcomeCommand("interrupted"), "fail");
  assert.equal(outcomeCommand("killed"), "cancel");
});

test("recognizes an explicitly delegated durable run", () => {
  assert.equal(durableRunMarker("Do the work.\nORG2_RUN_ID: run-42\n"), "run-42");
  assert.equal(durableRunMarker("ORG2_WORKFLOW_RUN_ID: workflow-run-42"), undefined);
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
  assert.match(prompt, /Provider draft: PROVIDER:TOOL:DRAFT_ID/);
  assert.match(workflowContinuationPrompt({ id: "weekly-review", version: "1.2.0", title: "Weekly review" }, "run-42"), /artifact-review/);
  assert.match(workflowContinuationPrompt({ id: "weekly-review", version: "1.2.0", title: "Weekly review" }, "run-42"), /org2 run approval-resolve --decision-key/);
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
  assert.equal(workflowMarker(added[0].payload.text).triggerId, "openclaw-schedule");
});

test("records an ineligible scheduled workflow attempt as skipped without creating a run", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-gate-"));
  const lifecycle = new Org2Lifecycle({
    stateFile: join(dir, "state.json"),
    exec: async (args) => {
      if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
      if (args[0] === "workflow" && args[1] === "run") {
        return JSON.stringify({
          schema: "org2:workflow-run-skipped:v1",
          workflowId: "weekly-review",
          triggerId: "openclaw-schedule",
          eligible: false,
          reason: "no matching event or fresh-work signal arrived after the previous attempt",
        });
      }
      if (args[0] === "workflow" && args[1] === "show") {
        return JSON.stringify({ id: "weekly-review", version: "1.0.0", title: "Weekly review" });
      }
      return "";
    },
  });
  await lifecycle.init();
  const result = await lifecycle.ensureWorkflow("cron:job:1", "weekly-review", {}, {
    triggerId: "openclaw-schedule",
    attemptId: "cron-job-1",
    logicalWorkId: "workflow:weekly-review",
  });
  assert.equal(result, null);
  const state = JSON.parse(await readFile(join(dir, "state.json"), "utf8"));
  assert.equal(state.mappings["cron:job:1"].outcome, "skipped");
  assert.match(state.mappings["cron:job:1"].skippedReason, /no matching event/);
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

test("session end fails active durable runs left without a terminal agent event", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-interrupted-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  const lifecycle = new Org2Lifecycle({ stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "run" && args[1] === "show") return JSON.stringify({ id: "run-1", status: "running" });
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = {
    org2RunId: "run-1",
    sessionKey: "agent:main:subagent:child-1",
  };
  const interrupted = await lifecycle.interruptSession("agent:main:subagent:child-1", "idle");
  assert.equal(interrupted.length, 1);
  assert.deepEqual(calls.find((args) => args[1] === "fail"), [
    "run", "fail", "run-1", "--actor", "org2-lifecycle",
    "--reason", "OpenClaw session ended before its durable run reached a terminal state (reason: idle).",
  ]);
  const state = JSON.parse(await readFile(stateFile, "utf8"));
  assert.equal(state.mappings.key.outcome, "interrupted");
});

test("session end preserves deliberate approval and review pauses", async () => {
  const lifecycle = new Org2Lifecycle({ exec: async () => {
    throw new Error("paused mappings must not call Org2");
  } });
  lifecycle.state.mappings.approval = {
    org2RunId: "run-approval",
    sessionKey: "agent:main:subagent:child-1",
    pausedAt: "2026-07-27T12:00:00Z",
    pausedStatus: "waiting-approval",
  };
  assert.deepEqual(await lifecycle.interruptSession("agent:main:subagent:child-1", "idle"), []);
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

test("resumes a requested workflow revision with the reviewer's durable feedback", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-revision-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  const workflow = { id: "weekly-review", version: "1.0.0", title: "Weekly review" };
  const approval = {
    id: "review-copy",
    status: "revised",
    decisionNote: "Lead with the recommendation and remove the internal acronym.",
  };
  const run = {
    id: "run-1",
    status: "blocked",
    workflowId: workflow.id,
    approvals: [approval],
    events: [
      { type: "status-changed", data: { to: "waiting-approval" } },
      { type: "approval-requested", data: { approvalId: approval.id } },
    ],
  };
  const lifecycle = new Org2Lifecycle({ stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
    if (args[0] === "run" && args[1] === "show") return JSON.stringify(run);
    if (args[0] === "run" && args[1] === "resume") return JSON.stringify({ ...run, status: "running" });
    if (args[0] === "workflow" && args[1] === "show") return JSON.stringify(workflow);
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = {
    org2RunId: run.id,
    sessionKey: "agent:main:org2:thread-1",
    createdAt: "2026-07-18T10:00:00Z",
  };

  const resumed = await lifecycle.resumeWorkflowRevision(run.id, approval.id, { expectedCorpusId: "personal" });

  assert.equal(resumed.sessionKey, "agent:main:org2:thread-1");
  assert.equal(workflowMarker(resumed.prompt).workflowRunId, run.id);
  assert.match(resumed.prompt, /Lead with the recommendation/);
  assert.match(resumed.prompt, /request a replacement approval/);
  assert.match(resumed.prompt, /Request the replacement on ORG2_WORKFLOW_RUN_ID/);
  assert.match(resumed.prompt, /Provider draft: PROVIDER:TOOL:DRAFT_ID/);
  assert.match(resumed.prompt, /revision request is not approval/i);
  assert.deepEqual(
    calls.find((args) => args[0] === "run" && args[1] === "resume"),
    ["run", "resume", run.id, "--actor", "org2-lifecycle", "--json"],
  );
  assert.match(workflowRevisionPrompt(workflow, run.id, approval), /revision-requested/);
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

test("recognizes a ClawLink Gmail draft and its later send", () => {
  const params = {
    tool: "gmail_create_draft",
    connectionId: 7,
    arguments: { to: "person@example.com", subject: "Short update", body: "Hello" },
  };
  const result = { content: [{ type: "text", text: `ClawLink tool result: gmail_create_draft\n\n${JSON.stringify({ result: { draftId: "draft-42" } })}` }] };
  const effect = draftCreatedEffect("clawlink_call_tool", params, result);
  assert.equal(effect.draftId, "draft-42");
  assert.equal(effect.destination, "person@example.com");
  assert.equal(effect.subject, "Short update");
  assert.match(approvalTitle(effect), /Short update/);
  assert.match(approvalAction(effect), /draft-42/);
  assert.deepEqual(draftSendEffect("clawlink_call_tool", {
    tool: "gmail_send_draft",
    connectionId: 7,
    arguments: { draftId: "draft-42" },
  }), {
    kind: "outbound-draft-send",
    key: effect.key,
    provider: effect.provider,
    account: effect.account,
    draftId: "draft-42",
  });
});

test("recognizes gog Gmail draft commands", () => {
  const created = draftCreatedEffect("exec", {
    command: "gog gmail drafts create --account avi@example.com --to person@example.com --subject Update --body Hello",
  }, JSON.stringify({ draftId: "gog-1" }));
  assert.equal(created.draftId, "gog-1");
  assert.equal(draftSendEffect("exec", { command: "gog gmail drafts send gog-1" }).draftId, "gog-1");
  const wrapped = draftCreatedEffect("exec", {
    source: `const result = await tools.exec_command({cmd: "gog gmail drafts create --to person@example.com --subject Update"});`,
  }, `Script completed\nOutput:\n${JSON.stringify({ draftId: "gog-wrapped-1" })}`);
  assert.equal(wrapped.draftId, "gog-wrapped-1");
  assert.equal(draftSendEffect("exec", {
    source: `await tools.exec_command({cmd: "gog gmail drafts send gog-wrapped-1"});`,
  }).draftId, "gog-wrapped-1");
});

test("requests an Org2 approval for a draft and gates sending on its decision", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-draft-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  let approvalStatus = "pending";
  const lifecycle = new Org2Lifecycle({ owner: "avi", stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "run" && args[1] === "approval-request") {
      return JSON.stringify({ approvals: [{ id: "approval-1", status: "pending" }] });
    }
    if (args[0] === "run" && args[1] === "show") {
      return JSON.stringify({ id: "run-1", status: approvalStatus === "approved" ? "running" : "waiting-approval", approvals: [{ id: "approval-1", status: approvalStatus }] });
    }
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.turn = { org2RunId: "run-1", openclawRunId: "openclaw-1", createdAt: "2026-07-19T00:00:00Z" };
  const effect = {
    key: "gmail:default:draft-1", provider: "gmail", account: "default", draftId: "draft-1",
    destination: "person@example.com", subject: "Update", fingerprint: "abc", title: "Approve update", action: "Send update",
  };
  const record = await lifecycle.requestDraftApproval(effect, { openclawRunId: "openclaw-1" });
  assert.equal(record.approvalId, "approval-1");
  assert.equal((await lifecycle.draftSendDecision({ key: effect.key, draftId: effect.draftId })).allowed, false);
  approvalStatus = "approved";
  assert.equal((await lifecycle.draftSendDecision({ key: effect.key, draftId: effect.draftId })).allowed, true);
  assert.ok(calls.some((args) => args[1] === "approval-request" && args.includes("external-action")));
});
