import { execFile } from "node:child_process";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export function conciseGoal(prompt, fallback = "OpenClaw agent execution") {
  const clean = String(prompt || "").replace(/\s+/g, " ").trim();
  return (clean || fallback).slice(0, 240);
}

export function shouldTrackMainTurn(prompt, ctx = {}) {
  if (ctx.trigger === "heartbeat") return false;
  if (ctx.jobId || String(ctx.sessionKey || "").includes(":cron:")) return false;
  if (workflowMarker(prompt)) return true;
  const text = String(prompt || "").trim();
  if (!text) return false;
  if (/^(thanks|thank you|cool|ok(?:ay)?|got it|sounds good)[.!\s]*$/i.test(text)) return false;
  return /\b(build|implement|fix|update|change|create|ship|deploy|migrate|refactor|review|investigate|diagnos|audit|research|prepare|draft|submit|send|execute|run|reconcile|install|configure|set up|make sure)\b/i.test(text);
}

export function workflowMarker(prompt) {
  const text = String(prompt || "");
  const workflowId = text.match(/^ORG2_WORKFLOW_ID:\s*([^\s]+)\s*$/mi)?.[1];
  const workflowRunId = text.match(/^ORG2_WORKFLOW_RUN_ID:\s*([^\s]+)\s*$/mi)?.[1];
  const triggerId = text.match(/^ORG2_WORKFLOW_TRIGGER_ID:\s*([^\s]+)\s*$/mi)?.[1];
  const inputsRaw = text.match(/^ORG2_WORKFLOW_INPUTS:\s*(\{.*\})\s*$/mi)?.[1];
  let inputs = {};
  if (inputsRaw) {
    try { inputs = JSON.parse(inputsRaw); } catch {}
  }
  return workflowId ? { workflowId, workflowRunId, ...(triggerId ? { triggerId } : {}), inputs } : null;
}

export function workflowExecutionPrompt(workflow, inputs = {}, runId, triggerId) {
  return [
    `ORG2_WORKFLOW_ID: ${workflow.id}`,
    `ORG2_WORKFLOW_VERSION: ${workflow.version}`,
    ...(runId ? [`ORG2_WORKFLOW_RUN_ID: ${runId}`] : []),
    ...(triggerId ? [`ORG2_WORKFLOW_TRIGGER_ID: ${triggerId}`] : []),
    `ORG2_WORKFLOW_INPUTS: ${JSON.stringify(inputs)}`,
    "",
    `Execute the Org2 workflow \"${workflow.title}\" from its canonical plain-text workflow file.`,
    ...(triggerId ? ["This is a scheduled attempt. The Org2 lifecycle adapter checks its declared event/fresh-work gate before creating the durable attempt; if no run was created, stop without executing workflow steps."] : []),
    "Read the workflow and durable run with the Org2 CLI. Update run steps as they progress, record produced artifacts and validation results, and keep generated work in the declared reviewable locations.",
    "At an approval boundary, request the approval on this run and end the turn without performing the protected action. Org2 will explicitly continue the same run after approval.",
    "Before requesting an external-action or high-impact approval, record the exact recipient, content, command, and attachments in an inspectable run artifact or approval note. An opaque ID or content fingerprint is not review material.",
    "Do not bypass an approval, complete a run with a pending review boundary, or silently promote generated work into canonical notes. After a human review decision, record it with `org2 run artifact-review RUN_ID ARTIFACT_ID --status reviewed|rejected` before completing the run.",
  ].join("\n");
}

export function workflowContinuationPrompt(workflow, runId) {
  return [
    `ORG2_WORKFLOW_ID: ${workflow.id}`,
    `ORG2_WORKFLOW_VERSION: ${workflow.version}`,
    `ORG2_WORKFLOW_RUN_ID: ${runId}`,
    "ORG2_WORKFLOW_RESUME: approval-decided",
    "",
    `Continue the Org2 workflow \"${workflow.title}\" using its existing durable run.`,
    "Re-read the workflow and run with the Org2 CLI. Continue from the first incomplete step, perform only actions covered by recorded approvals, and preserve the run's artifacts, validation, and event history.",
    "Treat an approval as valid only for the exact review material recorded with it; do not substitute a new recipient, payload, command, or attachment after approval.",
    "When an approval resolves an artifact review boundary, record the artifact decision with `org2 run artifact-review RUN_ID ARTIFACT_ID --status reviewed|rejected` before completing the run.",
  ].join("\n");
}

function messageText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map((part) => messageText(part)).filter(Boolean).join("\n");
  if (content && typeof content === "object") {
    if (typeof content.text === "string") return content.text;
    if (typeof content.content === "string" || Array.isArray(content.content)) return messageText(content.content);
  }
  return "";
}

export function executionSummary(messages, fallback = "OpenClaw execution completed successfully.") {
  const entries = Array.isArray(messages) ? [...messages].reverse() : [];
  const assistant = entries.find((message) => message?.role === "assistant" && messageText(message.content).trim());
  const text = messageText(assistant?.content).replace(/\s+/g, " ").trim();
  return (text || fallback).slice(0, 1200);
}

export function outcomeCommand(outcome, success = true) {
  if (outcome === "killed" || outcome === "reset" || outcome === "deleted") return "cancel";
  if (outcome === "error" || outcome === "timeout" || success === false) return "fail";
  return "complete";
}

export function cronKey(event) {
  // runId/sessionId may appear only on `finished`; runAtMs is shared by both.
  return `cron:${event.jobId}:${String(event.runAtMs || event.runId || event.sessionId || "unknown")}`;
}

export class Org2Lifecycle {
  constructor(options = {}) {
    this.corpusDir = options.corpusDir;
    this.stateFile = options.stateFile || join(homedir(), ".openclaw", "org2-lifecycle", "state.json");
    this.log = options.log || console;
    this.owner = options.owner || "user";
    this.exec = options.exec || this.#exec.bind(this);
    this.state = { version: 4, mappings: {}, workflowJobs: {} };
    this.cron = options.cron;
    this.queue = Promise.resolve();
  }

  async init() {
    try { this.state = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
    this.state.version = 4;
    this.state.mappings ||= {};
    this.state.workflowJobs ||= {};
  }

  setCron(cron) { this.cron = cron; }

  serialize(fn) {
    const next = this.queue.then(fn, fn);
    this.queue = next.catch((error) => this.log.error?.(`[org2-lifecycle] ${error.message}`));
    return next;
  }

  async #exec(args) {
    if (!this.corpusDir) throw new Error("org2-lifecycle requires plugin config corpusDir");
    const { stdout } = await execFileAsync("org2", [...args, "--dir", this.corpusDir], { maxBuffer: 2_000_000 });
    return stdout;
  }

  async #save() {
    let disk = { mappings: {} };
    try { disk = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
    this.state.mappings = { ...(disk.mappings || {}), ...(this.state.mappings || {}) };
    this.state.workflowJobs = { ...(disk.workflowJobs || {}), ...(this.state.workflowJobs || {}) };
    await mkdir(dirname(this.stateFile), { recursive: true });
    const tmp = `${this.stateFile}.${process.pid}.tmp`;
    await writeFile(tmp, `${JSON.stringify(this.state, null, 2)}\n`);
    await rename(tmp, this.stateFile);
  }

  async corpus() {
    return JSON.parse(await this.exec(["corpus", "show", "--json"]));
  }

  async assertCorpus(expectedCorpusId) {
    const status = await this.corpus();
    if (expectedCorpusId && status.identity?.id !== expectedCorpusId) {
      throw new Error(`Org2 corpus mismatch: Mac app selected ${expectedCorpusId}, but OpenClaw is configured for ${status.identity?.id || "an unidentified corpus"}`);
    }
    return status;
  }

  async #updateRuntime(runId, details = {}) {
    const args = ["run", "runtime", runId, "--actor", "org2-lifecycle"];
    if (details.provider) args.push("--provider", String(details.provider));
    if (details.model) args.push("--model", String(details.model));
    if (Number.isFinite(details.tokensUsed)) args.push("--tokens-used", String(details.tokensUsed));
    if (Number.isFinite(details.elapsedSeconds)) args.push("--elapsed-seconds", String(details.elapsedSeconds));
    if (args.length > 5) await this.exec(args);
  }

  async ensure(key, details) {
    const existing = this.state.mappings[key];
    if (existing?.org2RunId) return existing.org2RunId;
    const created = JSON.parse(await this.exec([
      "run", "create",
      "--goal", conciseGoal(details.goal),
      "--accept", details.accept || "The OpenClaw execution reaches a terminal state with its outcome recorded.",
      "--risk", details.risk || "local-draft",
      "--owner", this.owner,
      "--capability", "agent-context",
      "--capability", "validation",
      ...(details.provider ? ["--provider", String(details.provider)] : []),
      ...(details.model ? ["--model", String(details.model)] : []),
      "--json",
    ]));
    const id = created.run.id;
    await this.exec(["run", "comment", id, "--author", "org2-lifecycle", "--body",
      `OPENCLAW_KEY: ${key}\nOPENCLAW_KIND: ${details.kind}\nOPENCLAW_SESSION: ${details.sessionKey || "unknown"}\nOPENCLAW_RUN: ${details.openclawRunId || "unknown"}`]);
    await this.exec(["run", "start", id]);
    this.state.mappings[key] = {
      org2RunId: id,
      kind: details.kind,
      sessionKey: details.sessionKey,
      openclawRunId: details.openclawRunId,
      provider: details.provider,
      model: details.model,
      createdAt: new Date().toISOString(),
    };
    await this.#save();
    return id;
  }

  async attach(key, runId, details = {}) {
    const existing = this.state.mappings[key];
    if (existing?.org2RunId) return existing.org2RunId;
    await this.exec(["run", "comment", runId, "--author", "org2-lifecycle", "--body",
      `OPENCLAW_KEY: ${key}\nOPENCLAW_KIND: ${details.kind || "workflow"}\nOPENCLAW_SESSION: ${details.sessionKey || "unknown"}\nOPENCLAW_RUN: ${details.openclawRunId || "unknown"}`]);
    await this.exec(["run", "start", runId]);
    await this.#updateRuntime(runId, details);
    this.state.mappings[key] = {
      org2RunId: runId,
      kind: details.kind || "workflow",
      workflowId: details.workflowId,
      sessionKey: details.sessionKey,
      openclawRunId: details.openclawRunId,
      provider: details.provider,
      model: details.model,
      createdAt: new Date().toISOString(),
    };
    await this.#save();
    return runId;
  }

  async prepareWorkflowRun(workflowId, inputs = {}, details = {}) {
    const corpus = await this.assertCorpus(details.expectedCorpusId);
    const args = ["workflow", "run", workflowId, "--owner", this.owner, "--json"];
    if (details.triggerId) args.push("--trigger", String(details.triggerId));
    if (details.attemptId) args.push("--attempt-id", String(details.attemptId));
    if (details.scheduledFor) args.push("--scheduled-for", String(details.scheduledFor));
    if (details.logicalWorkId) args.push("--logical-work-id", String(details.logicalWorkId));
    for (const [name, value] of Object.entries(inputs)) args.push("--input", `${name}=${value}`);
    const created = JSON.parse(await this.exec(args));
    const workflow = await this.workflow(workflowId);
    return {
      run: created.run,
      skipped: created.schema === "org2:workflow-run-skipped:v1",
      eligibility: created.eligibility || (created.reason ? { eligible: false, reason: created.reason } : undefined),
      workflow,
      prompt: created.run ? workflowExecutionPrompt(workflow, inputs, created.run.id, details.triggerId) : undefined,
      corpus: corpus.identity,
    };
  }

  async ensureWorkflow(key, workflowId, inputs = {}, details = {}) {
    const existing = this.state.mappings[key];
    if (existing?.org2RunId) return existing.org2RunId;
    const prepared = await this.prepareWorkflowRun(workflowId, inputs, details);
    if (!prepared.run) {
      const now = new Date().toISOString();
      this.state.mappings[key] = {
        kind: "workflow-attempt",
        workflowId,
        logicalWorkId: details.logicalWorkId || `workflow:${workflowId}`,
        attemptId: details.attemptId,
        skippedAt: now,
        skippedReason: prepared.eligibility?.reason || "workflow event gate was not eligible",
        finishedAt: now,
        outcome: "skipped",
      };
      await this.#save();
      return null;
    }
    return this.attach(key, prepared.run.id, { ...details, kind: "workflow", workflowId });
  }

  async workflow(id) {
    return JSON.parse(await this.exec(["workflow", "show", id, "--json"]));
  }

  async workflows() {
    const payload = JSON.parse(await this.exec(["workflow", "list", "--json"]));
    return payload.workflows || [];
  }

  async recordUsage(openclawRunId, usage = {}) {
    if (!openclawRunId) return;
    const mapping = Object.values(this.state.mappings).find((item) => item.openclawRunId === openclawRunId && !item.finishedAt);
    if (!mapping) return;
    const total = Number.isFinite(usage.total)
      ? usage.total
      : [usage.input, usage.output, usage.cacheRead, usage.cacheWrite]
        .reduce((sum, value) => sum + (Number.isFinite(value) ? value : 0), 0);
    if (total > 0) mapping.tokensUsed = (mapping.tokensUsed || 0) + total;
  }

  async resumeWorkflowRun(runId, details = {}) {
    const corpus = await this.assertCorpus(details.expectedCorpusId);
    const run = JSON.parse(await this.exec(["run", "show", runId, "--json"]));
    if (!run.workflowId) throw new Error(`${runId} is not a workflow run`);
    if (run.status !== "running") throw new Error(`${runId} cannot continue while ${run.status}`);
    if ((run.approvals || []).some((approval) => approval.status === "pending")) {
      throw new Error(`${runId} still has pending approvals`);
    }
    const mapping = Object.values(this.state.mappings)
      .filter((item) => item.org2RunId === runId && item.sessionKey)
      .sort((a, b) => String(b.createdAt || "").localeCompare(String(a.createdAt || "")))[0];
    if (!mapping?.sessionKey) throw new Error(`OpenClaw session correlation is missing for ${runId}`);
    const workflow = await this.workflow(run.workflowId);
    mapping.resumedAt = new Date().toISOString();
    await this.#save();
    return {
      run,
      workflow,
      sessionKey: mapping.sessionKey,
      prompt: workflowContinuationPrompt(workflow, runId),
      corpus: corpus.identity,
    };
  }

  async finish(key, outcome, details = {}) {
    // Start and finish may be observed by overlapping Gateway generations
    // during a hot restart. Refresh the durable map so terminal events do not
    // depend on one process's in-memory view.
    if (!this.state.mappings[key]) {
      try {
        const disk = JSON.parse(await readFile(this.stateFile, "utf8"));
        this.state.mappings = { ...(disk.mappings || {}), ...(this.state.mappings || {}) };
      } catch {}
    }
    const mapping = this.state.mappings[key];
    if (!mapping || mapping.finishedAt) return;
    await this.#updateRuntime(mapping.org2RunId, {
      provider: details.provider || mapping.provider,
      model: details.model || mapping.model,
      tokensUsed: mapping.tokensUsed,
      elapsedSeconds: Number.isFinite(details.durationMs) ? details.durationMs / 1000 : undefined,
    });
    if (details.error) {
      await this.exec(["run", "comment", mapping.org2RunId, "--author", "org2-lifecycle", "--body",
        `OpenClaw terminal error: ${String(details.error).slice(0, 1000)}`]);
    }
    const run = JSON.parse(await this.exec(["run", "show", mapping.org2RunId, "--json"]));
    const command = outcomeCommand(outcome);
    if (command === "complete"
      && !["completed", "failed", "canceled"].includes(run.status)
      && (run.artifacts || []).some((artifact) => artifact.reviewStatus === "review-required")) {
      mapping.pausedAt = new Date().toISOString();
      mapping.pausedStatus = "review-required";
      await this.#save();
      return { terminal: false, status: "review-required" };
    }
    if (command === "complete" && (run.status === "waiting-approval" || run.status === "blocked")) {
      mapping.pausedAt = new Date().toISOString();
      mapping.pausedStatus = run.status;
      await this.#save();
      return { terminal: false, status: run.status };
    }
    if (["completed", "failed", "canceled"].includes(run.status)) {
      mapping.finishedAt = new Date().toISOString();
      mapping.outcome = outcome;
      await this.#save();
      return { terminal: true, status: run.status };
    }
    const args = ["run", command, mapping.org2RunId, "--actor", "org2-lifecycle"];
    if (command === "complete") args.push("--summary", details.summary || "OpenClaw execution completed successfully.");
    if (command === "fail") args.push("--reason", String(details.error || "OpenClaw execution failed").slice(0, 1000));
    await this.exec(args);
    const finishedAt = new Date().toISOString();
    for (const item of Object.values(this.state.mappings)) {
      if (item.org2RunId !== mapping.org2RunId) continue;
      item.finishedAt = finishedAt;
      item.outcome = outcome;
    }
    await this.#save();
    return { terminal: true, status: command === "complete" ? "completed" : command === "fail" ? "failed" : "canceled" };
  }

  async reconcile(expectedCorpusId) {
    await this.assertCorpus(expectedCorpusId);
    if (this.cron) await this.#reconcileWorkflowJobs();
    await this.#save();
    return this.workflowStatus();
  }

  async workflowStatus(expectedCorpusId) {
    const corpus = await this.assertCorpus(expectedCorpusId);
    const workflows = await this.workflows();
    const jobs = this.cron ? await this.cron.list({ includeDisabled: true }) : [];
    const jobsById = new Map(jobs.map((job) => [job.id, job]));
    return {
      schema: "org2:openclaw-workflow-status:v1",
      corpus: corpus.identity,
      workflows: workflows.map((workflow) => {
        const binding = this.state.workflowJobs[workflow.id];
        return { ...workflow, openclaw: binding ? { ...binding, job: jobsById.get(binding.jobId) } : undefined };
      }),
    };
  }

  async #reconcileWorkflowJobs() {
    const workflows = await this.workflows();
    const jobs = await this.cron.list({ includeDisabled: true });
    const jobsById = new Map(jobs.map((job) => [job.id, job]));
    for (const workflow of workflows) {
      const trigger = (workflow.triggers || []).find((item) => item.type === "schedule" && item.id === "openclaw-schedule");
      const desiredEnabled = workflow.state === "active" && trigger?.enabled === true && Boolean(trigger.schedule);
      let binding = this.state.workflowJobs[workflow.id];
      let job = binding?.jobId ? jobsById.get(binding.jobId) : undefined;
      if (!job) {
        job = jobs.find((item) => String(item.description || "").includes(`ORG2_WORKFLOW_ID: ${workflow.id}`));
        if (job) binding = this.state.workflowJobs[workflow.id] = { jobId: job.id };
      }
      if (!desiredEnabled) {
        if (job?.enabled) await this.cron.update(job.id, { enabled: false });
        continue;
      }
      const desired = {
        name: `Org2: ${workflow.title}`,
        description: `Managed by Org2.\nORG2_WORKFLOW_ID: ${workflow.id}\nORG2_WORKFLOW_VERSION: ${workflow.version}`,
        enabled: true,
        schedule: { kind: "cron", expr: trigger.schedule, ...(trigger.timezone ? { tz: trigger.timezone } : {}) },
        sessionTarget: "isolated",
        wakeMode: "now",
        payload: { kind: "agentTurn", text: workflowExecutionPrompt(workflow, {}, undefined, trigger.id) },
      };
      const fingerprint = JSON.stringify(desired);
      if (!job) {
        const created = await this.cron.add(desired);
        const jobId = created?.id || created?.job?.id;
        if (!jobId) throw new Error(`OpenClaw did not return a job id for workflow ${workflow.id}`);
        this.state.workflowJobs[workflow.id] = { jobId, fingerprint, syncedAt: new Date().toISOString() };
      } else if (binding?.fingerprint !== fingerprint || job.enabled !== true) {
        await this.cron.update(job.id, desired);
        this.state.workflowJobs[workflow.id] = { jobId: job.id, fingerprint, syncedAt: new Date().toISOString() };
      }
    }
  }
}
