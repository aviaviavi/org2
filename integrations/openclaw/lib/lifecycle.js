import { execFile } from "node:child_process";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export function conciseGoal(prompt, fallback = "OpenClaw agent execution") {
  const clean = String(prompt || "").replace(/\s+/g, " ").trim();
  return (clean || fallback).slice(0, 240);
}

export function shouldTrackMainTurn(prompt, ctx = {}) {
  if (ctx.trigger === "heartbeat") return false;
  if (ctx.jobId || String(ctx.sessionKey || "").includes(":cron:")) return false;
  const text = String(prompt || "").trim();
  if (!text) return false;
  if (/^(thanks|thank you|cool|ok(?:ay)?|got it|sounds good)[.!\s]*$/i.test(text)) return false;
  return /\b(build|implement|fix|update|change|create|ship|deploy|migrate|refactor|review|investigate|diagnos|audit|research|prepare|draft|submit|send|execute|run|reconcile|install|configure|set up|make sure)\b/i.test(text);
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
    this.corpusDir = options.corpusDir || "/Users/avi/avi.org2";
    this.stateFile = options.stateFile || "/Users/avi/.openclaw/org2-lifecycle/state.json";
    this.log = options.log || console;
    this.exec = options.exec || this.#exec.bind(this);
    this.state = { version: 1, mappings: {} };
    this.queue = Promise.resolve();
  }

  async init() {
    try { this.state = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
    this.state.mappings ||= {};
  }

  serialize(fn) {
    const next = this.queue.then(fn, fn);
    this.queue = next.catch((error) => this.log.error?.(`[org2-lifecycle] ${error.message}`));
    return next;
  }

  async #exec(args) {
    const { stdout } = await execFileAsync("org2", [...args, "--dir", this.corpusDir], { maxBuffer: 2_000_000 });
    return stdout;
  }

  async #save() {
    let disk = { mappings: {} };
    try { disk = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
    this.state.mappings = { ...(disk.mappings || {}), ...(this.state.mappings || {}) };
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
      "--owner", "avi",
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
    // State is retained for idempotency across Gateway restarts. A future Org2
    // runtime API can replace this file without changing the hook contract.
    await this.#save();
  }
}
