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
  const inputsRaw = text.match(/^ORG2_WORKFLOW_INPUTS:\s*(\{.*\})\s*$/mi)?.[1];
  let inputs = {};
  if (inputsRaw) {
    try { inputs = JSON.parse(inputsRaw); } catch {}
  }
  return workflowId ? { workflowId, workflowRunId, inputs } : null;
}

export function workflowExecutionPrompt(workflow, inputs = {}, runId) {
  return [
    `ORG2_WORKFLOW_ID: ${workflow.id}`,
    `ORG2_WORKFLOW_VERSION: ${workflow.version}`,
    ...(runId ? [`ORG2_WORKFLOW_RUN_ID: ${runId}`] : []),
    `ORG2_WORKFLOW_INPUTS: ${JSON.stringify(inputs)}`,
    "",
    `Execute the Org2 workflow \"${workflow.title}\" from its canonical plain-text workflow file.`,
    "Read the workflow and durable run with the Org2 CLI, follow their context, steps, outputs, validations, and approval boundaries, and keep generated work in the declared reviewable locations.",
    "Do not bypass an approval or silently promote generated work into canonical notes.",
  ].join("\n");
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
    this.state = { version: 2, mappings: {}, workflowJobs: {} };
    this.cron = options.cron;
    this.queue = Promise.resolve();
  }

  async init() {
    try { this.state = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
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
    this.state.mappings[key] = {
      org2RunId: runId,
      kind: details.kind || "workflow",
      workflowId: details.workflowId,
      sessionKey: details.sessionKey,
      openclawRunId: details.openclawRunId,
      createdAt: new Date().toISOString(),
    };
    await this.#save();
    return runId;
  }

  async prepareWorkflowRun(workflowId, inputs = {}, details = {}) {
    const args = ["workflow", "run", workflowId, "--owner", this.owner, "--json"];
    for (const [name, value] of Object.entries(inputs)) args.push("--input", `${name}=${value}`);
    const created = JSON.parse(await this.exec(args));
    const workflow = await this.workflow(workflowId);
    return {
      run: created.run,
      workflow,
      prompt: workflowExecutionPrompt(workflow, inputs, created.run.id),
      ...details,
    };
  }

  async ensureWorkflow(key, workflowId, inputs = {}, details = {}) {
    const existing = this.state.mappings[key];
    if (existing?.org2RunId) return existing.org2RunId;
    const prepared = await this.prepareWorkflowRun(workflowId, inputs);
    return this.attach(key, prepared.run.id, { ...details, kind: "workflow", workflowId });
  }

  async workflow(id) {
    return JSON.parse(await this.exec(["workflow", "show", id, "--json"]));
  }

  async workflows() {
    const payload = JSON.parse(await this.exec(["workflow", "list", "--json"]));
    return payload.workflows || [];
  }

  async finish(key, outcome, error) {
    // Start and finish may be observed by overlapping Gateway generations
    // during a hot restart. Refresh the durable map so terminal events do not
    // depend on one process's in-memory view.
    try {
      const disk = JSON.parse(await readFile(this.stateFile, "utf8"));
      this.state.mappings = { ...(this.state.mappings || {}), ...(disk.mappings || {}) };
    } catch {}
    const mapping = this.state.mappings[key];
    if (!mapping || mapping.finishedAt) return;
    if (error) {
      await this.exec(["run", "comment", mapping.org2RunId, "--author", "org2-lifecycle", "--body",
        `OpenClaw terminal error: ${String(error).slice(0, 1000)}`]);
    }
    await this.exec(["run", outcomeCommand(outcome), mapping.org2RunId]);
    mapping.finishedAt = new Date().toISOString();
    mapping.outcome = outcome;
    await this.#save();
  }

  async reconcile() {
    if (this.cron) await this.#reconcileWorkflowJobs();
    await this.#save();
    return this.workflowStatus();
  }

  async workflowStatus() {
    const workflows = await this.workflows();
    const jobs = this.cron ? await this.cron.list({ includeDisabled: true }) : [];
    const jobsById = new Map(jobs.map((job) => [job.id, job]));
    return {
      schema: "org2:openclaw-workflow-status:v1",
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
        payload: { kind: "agentTurn", text: workflowExecutionPrompt(workflow) },
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
