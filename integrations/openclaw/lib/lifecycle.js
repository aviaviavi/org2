import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { link, lstat, mkdir, readFile, readdir, rename, unlink, writeFile } from "node:fs/promises";
import { homedir, hostname } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import { approvalMaterialDigest, sameApprovalMaterial } from "./approval-effects.js";

const execFileAsync = promisify(execFile);
const STATE_LOCK_SCHEMA = "org2:mutation-lock-owner:v2";
const STATE_LOCK_OWNER_KEYS = new Set([
  "schema",
  "host",
  "pid",
  "token",
  "phase",
  "ticket",
  "createdAt",
]);
const UUID_TOKEN_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function stateLockOwnerRaw(owner) {
  return `${JSON.stringify(owner)}\n`;
}

function parseStateLockOwner(raw) {
  try {
    const owner = JSON.parse(raw);
    if (
      !owner
      || typeof owner !== "object"
      || Array.isArray(owner)
      || !Object.keys(owner).every((key) => STATE_LOCK_OWNER_KEYS.has(key))
      || owner.schema !== STATE_LOCK_SCHEMA
      || typeof owner.host !== "string"
      || owner.host.length === 0
      || !Number.isSafeInteger(owner.pid)
      || owner.pid <= 0
      || owner.pid > 2_147_483_647
      || typeof owner.token !== "string"
      || !UUID_TOKEN_PATTERN.test(owner.token)
      || !["choosing", "ticket"].includes(owner.phase)
      || typeof owner.createdAt !== "string"
      || owner.createdAt.length === 0
      || (owner.phase === "ticket" && (!Number.isSafeInteger(owner.ticket) || owner.ticket <= 0))
      || (owner.phase === "choosing" && owner.ticket !== undefined)
    ) {
      return null;
    }
    return owner;
  } catch {
    return null;
  }
}

function stateLockParticipantIdentity(name) {
  const choosing = /^choosing\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.json$/.exec(name);
  if (choosing) return { phase: "choosing", token: choosing[1] };
  const ticket = /^ticket\.(\d{16})\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.json$/.exec(name);
  if (!ticket) return null;
  const value = Number(ticket[1]);
  if (!Number.isSafeInteger(value) || value <= 0 || String(value).padStart(16, "0") !== ticket[1]) {
    return null;
  }
  return { phase: "ticket", ticket: value, token: ticket[2] };
}

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code !== "ESRCH";
  }
}

function compareStateLockTickets(left, right) {
  const ticketDifference = Number(left.ticket) - Number(right.ticket);
  if (ticketDifference !== 0) return ticketDifference;
  return Buffer.compare(Buffer.from(left.token, "utf8"), Buffer.from(right.token, "utf8"));
}

async function publishStateLockParticipant(lockDirectory, name, raw) {
  const file = join(lockDirectory, name);
  const candidate = join(lockDirectory, `.candidate.${process.pid}.${randomUUID()}`);
  await writeFile(candidate, raw, { mode: 0o600, flag: "wx" });
  try {
    await link(candidate, file);
  } finally {
    try { await unlink(candidate); } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  return file;
}

async function removeStateLockParticipantIfUnchanged(file, raw) {
  try {
    if (await readFile(file, "utf8") === raw) await unlink(file);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

async function activeStateLockParticipants(lockDirectory, currentHost) {
  const active = [];
  for (const name of await readdir(lockDirectory)) {
    if (name.startsWith(".candidate.")) continue;
    const identity = stateLockParticipantIdentity(name);
    if (!identity) {
      throw new Error(`unrecognized Org2 lifecycle lock participant ${join(lockDirectory, name)}`);
    }
    const file = join(lockDirectory, name);
    let raw = "";
    try { raw = await readFile(file, "utf8"); } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    const owner = parseStateLockOwner(raw);
    if (
      !owner
      || owner.phase !== identity.phase
      || owner.token !== identity.token
      || owner.ticket !== identity.ticket
    ) {
      throw new Error(`invalid Org2 lifecycle lock participant ${file}`);
    }
    if (owner.host === currentHost && !processIsAlive(owner.pid)) {
      await removeStateLockParticipantIfUnchanged(file, raw);
      continue;
    }
    active.push({ file, raw, owner });
  }
  return active;
}

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
    "Read the workflow and durable run with the Org2 CLI. Update run steps as they progress, record produced artifacts and validation results, and keep generated work in the declared reviewable locations.",
    "At a declared approval boundary, use the requirement ID from the run with `org2 run approval-request RUN_ID --requirement REQUIREMENT_ID ...`, then end the turn without performing the protected action. Org2 will explicitly continue the same run after approval.",
    "Before requesting an external-action or high-impact approval, bind the exact recipient, content, command, and attachments as typed approval material with `--material-json ...` or `--material-file ...`. A note, unrelated artifact, opaque ID, or fingerprint alone is not review material.",
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
    "Treat a declared requirement as satisfied only by its current bound approval and the exact review material recorded with it; do not substitute a new recipient, payload, command, or attachment after approval.",
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
    this.state = { version: 4, mappings: {}, workflowJobs: {}, drafts: {} };
    this.baseState = this.#snapshotState(this.state);
    this.cron = options.cron;
    this.queue = Promise.resolve();
  }

  async init() {
    try { this.state = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
    this.#normalizeState();
    this.baseState = this.#snapshotState(this.state);
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

  #normalizeState() {
    if (!this.state || typeof this.state !== "object" || Array.isArray(this.state)) this.state = {};
    this.state.version = Math.max(Number(this.state.version) || 0, 4);
    this.state.mappings ||= {};
    this.state.workflowJobs ||= {};
    this.state.drafts ||= {};
  }

  #snapshotState(state) {
    return JSON.parse(JSON.stringify(state || {}));
  }

  #changedMapKeys(name) {
    const before = this.baseState?.[name] || {};
    const after = this.state?.[name] || {};
    const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
    return [...keys].filter((key) => (
      JSON.stringify(before[key]) !== JSON.stringify(after[key])
    ));
  }

  async #acquireStateLock() {
    await mkdir(dirname(this.stateFile), { recursive: true });
    const lockDirectory = `${this.stateFile}.lock`;
    try {
      await mkdir(lockDirectory, { recursive: true, mode: 0o700 });
    } catch (error) {
      if (error?.code === "EEXIST") {
        throw new Error(
          `the legacy Org2 lifecycle lock at ${lockDirectory} is not compatible with the crash-safe lock protocol`,
        );
      }
      throw error;
    }
    if (!(await lstat(lockDirectory)).isDirectory()) {
      throw new Error(`the Org2 lifecycle lock at ${lockDirectory} is not a directory`);
    }

    const currentHost = hostname();
    const token = randomUUID();
    const createdAt = new Date().toISOString();
    const choosing = {
      schema: STATE_LOCK_SCHEMA,
      host: currentHost,
      pid: process.pid,
      token,
      phase: "choosing",
      createdAt,
    };
    const choosingRaw = stateLockOwnerRaw(choosing);
    const choosingFile = await publishStateLockParticipant(
      lockDirectory,
      `choosing.${token}.json`,
      choosingRaw,
    );
    let ticketFile;
    let ticketRaw;

    try {
      const existing = await activeStateLockParticipants(lockDirectory, currentHost);
      const nextTicket = existing.reduce(
        (maximum, item) => item.owner.phase === "ticket"
          ? Math.max(maximum, Number(item.owner.ticket))
          : maximum,
        0,
      ) + 1;
      if (!Number.isSafeInteger(nextTicket) || nextTicket <= 0) {
        throw new Error(`the Org2 lifecycle lock ticket space is exhausted for ${lockDirectory}`);
      }
      const owner = {
        ...choosing,
        phase: "ticket",
        ticket: nextTicket,
      };
      ticketRaw = stateLockOwnerRaw(owner);
      ticketFile = await publishStateLockParticipant(
        lockDirectory,
        `ticket.${String(nextTicket).padStart(16, "0")}.${token}.json`,
        ticketRaw,
      );
      await removeStateLockParticipantIfUnchanged(choosingFile, choosingRaw);

      for (let attempt = 0; attempt < 200; attempt += 1) {
        const contenders = await activeStateLockParticipants(lockDirectory, currentHost);
        const blocker = contenders.find((item) => (
          item.owner.token !== token
          && (
            item.owner.phase === "choosing"
            || compareStateLockTickets(item.owner, owner) < 0
          )
        ));
        if (!blocker) return {
          lockDirectory,
          file: ticketFile,
          raw: ticketRaw,
          owner,
        };
        await new Promise((resolve) => setTimeout(resolve, Math.min(10 + attempt * 2, 100)));
      }
      throw new Error("Org2 lifecycle state is already being updated");
    } catch (error) {
      await removeStateLockParticipantIfUnchanged(choosingFile, choosingRaw);
      if (ticketFile && ticketRaw) {
        await removeStateLockParticipantIfUnchanged(ticketFile, ticketRaw);
      }
      throw error;
    }
  }

  async #withStateLock(fn) {
    const lock = await this.#acquireStateLock();
    try {
      return await fn(lock);
    } finally {
      await removeStateLockParticipantIfUnchanged(lock.file, lock.raw);
    }
  }

  async #save(lock) {
    if (!lock) return this.#withStateLock((held) => this.#save(held));
    let disk = {};
    try { disk = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
    const next = {
      ...disk,
      version: Math.max(Number(disk.version) || 0, Number(this.state.version) || 0, 4),
    };
    for (const name of ["mappings", "workflowJobs", "drafts"]) {
      const merged = { ...(disk[name] || {}) };
      for (const key of this.#changedMapKeys(name)) {
        if (Object.hasOwn(this.state[name] || {}, key)) merged[key] = this.state[name][key];
        else delete merged[key];
      }
      next[name] = merged;
    }
    this.state = next;
    this.#normalizeState();
    await mkdir(dirname(this.stateFile), { recursive: true });
    const tmp = `${this.stateFile}.${process.pid}.${randomUUID()}.tmp`;
    await writeFile(tmp, `${JSON.stringify(this.state, null, 2)}\n`, { mode: 0o600 });
    await rename(tmp, this.stateFile);
    this.baseState = this.#snapshotState(this.state);
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

  async ensure(key, details, stateLock) {
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
      ...(details.context || []).flatMap((ref) => ["--context", String(ref)]),
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
    await this.#save(stateLock);
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
    for (const [name, value] of Object.entries(inputs)) args.push("--input", `${name}=${value}`);
    const created = JSON.parse(await this.exec(args));
    const workflow = await this.workflow(workflowId);
    return {
      run: created.run,
      workflow,
      prompt: workflowExecutionPrompt(workflow, inputs, created.run.id),
      corpus: corpus.identity,
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

  async #sharedDraftRecord(key) {
    let disk = {};
    try { disk = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
    const record = disk.drafts?.[key] || this.state.drafts?.[key];
    if (record) this.state.drafts[key] = record;
    return record;
  }

  async #reloadStateFromDisk() {
    let disk = {};
    try { disk = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
    this.state = {
      ...this.state,
      ...disk,
      version: Math.max(Number(this.state.version) || 0, Number(disk.version) || 0, 4),
      mappings: { ...(this.state.mappings || {}), ...(disk.mappings || {}) },
      workflowJobs: { ...(this.state.workflowJobs || {}), ...(disk.workflowJobs || {}) },
      drafts: { ...(this.state.drafts || {}), ...(disk.drafts || {}) },
    };
    this.#normalizeState();
    this.baseState = this.#snapshotState(this.state);
  }

  #draftApprovalMatches(effect, approval, trustedLegacyMapping = false) {
    const target = approval?.material?.runtimeTarget;
    if (target?.system !== effect.provider || target?.kind !== "draft") return false;
    if (target.id === effect.key) return true;
    if (target.id !== effect.draftId) return false;
    try {
      const content = JSON.parse(approval.material?.content || "");
      return content?.schema === "org2:gmail-draft-material:v1"
        && content.account === effect.account
        && content.draftId === effect.draftId;
    } catch {
      return trustedLegacyMapping;
    }
  }

  #draftRecord(effect, run, approval) {
    return {
      key: effect.key,
      provider: effect.provider,
      account: effect.account,
      draftId: effect.draftId,
      destination: effect.destination || approval.material?.target,
      subject: effect.subject,
      org2RunId: run.id,
      approvalId: approval.id,
      approvalFingerprint: approval.fingerprint,
      materialDigest: approval.material ? approvalMaterialDigest(approval.material) : undefined,
      status: approval.effectReceipt ? "sent" : approval.status,
      ...(approval.effectReceipt ? { sentAt: approval.effectReceipt.performedAt } : {}),
      updatedAt: run.updatedAt,
    };
  }

  #assertNoConflictingDraftEffect(run, effect, currentApprovalId) {
    const conflicting = (run.approvals || []).find((approval) => (
      approval.id !== currentApprovalId
      && this.#draftApprovalMatches(effect, approval)
      && (approval.effectReservation || approval.effectReceipt)
    ));
    if (conflicting?.effectReservation) {
      throw new Error(`Gmail draft ${effect.draftId} has an unresolved effect reservation on approval ${conflicting.id}; reconcile it before creating or performing another version`);
    }
    if (conflicting?.effectReceipt) {
      throw new Error(`Gmail draft ${effect.draftId} was already sent by approval ${conflicting.id}`);
    }
  }

  async #reconstructDraftRecord(effect, stateLock) {
    const mapping = this.state.mappings[`draft:${effect.key}`];
    const candidates = [];
    if (mapping?.org2RunId) {
      try {
        const run = JSON.parse(await this.exec(["run", "show", mapping.org2RunId, "--json"]));
        const approval = [...(run.approvals || [])].reverse()
          .find((candidate) => this.#draftApprovalMatches(effect, candidate, true));
        if (approval) candidates.push({ run, approval });
      } catch {}
    }
    if (candidates.length === 0) {
      let listed = { runs: [] };
      try { listed = JSON.parse(await this.exec(["run", "list", "--json"])); } catch {}
      for (const run of listed.runs || []) {
        const approval = [...(run.approvals || [])].reverse()
          .find((candidate) => this.#draftApprovalMatches(effect, candidate));
        if (approval) candidates.push({ run, approval });
      }
    }
    if (candidates.length > 1) {
      throw new Error(`Multiple native Org2 approvals claim Gmail draft ${effect.draftId}; reconcile them before sending`);
    }
    if (candidates.length === 0) return undefined;
    const { run, approval } = candidates[0];
    const record = this.#draftRecord(effect, run, approval);
    this.state.drafts[effect.key] = record;
    this.state.mappings[`draft:${effect.key}`] ||= {
      org2RunId: run.id,
      kind: "external-draft",
      reconstructedAt: new Date().toISOString(),
    };
    await this.#save(stateLock);
    return record;
  }

  async requestDraftApproval(effect, details = {}) {
    if (!effect.material || !effect.materialDigest) {
      throw new Error(`Exact review material is required before requesting approval for Gmail draft ${effect.draftId}`);
    }
    return this.#withStateLock(async (stateLock) => {
      await this.#reloadStateFromDisk();
      const existing = this.state.drafts[effect.key] || await this.#reconstructDraftRecord(effect, stateLock);
      if (existing?.materialDigest === effect.materialDigest && existing?.approvalId) return existing;
      const runId = existing?.org2RunId || await this.ensure(`draft:${effect.key}`, {
        kind: "external-draft",
        goal: `Review ${effect.subject} draft to ${effect.destination}`,
        risk: "external-action",
        context: [
          `entity:email:${effect.destination}`,
          `artifact:${effect.provider}:${effect.draftId}`,
        ],
        sessionKey: details.sessionKey,
        openclawRunId: details.openclawRunId,
      }, stateLock);
      let supersedesId;
      const previousRun = JSON.parse(await this.exec(["run", "show", runId, "--json"]));
      this.#assertNoConflictingDraftEffect(previousRun, effect);
      if (existing?.approvalId) {
        const previous = (previousRun.approvals || []).find((candidate) => candidate.id === existing.approvalId);
        if (previous?.status === "pending") supersedesId = previous.id;
      }
      const updated = JSON.parse(await this.exec([
        "run", "approval-request", runId,
        "--title", effect.title,
        "--action", effect.action,
        "--note", effect.note,
        "--material-json", JSON.stringify(effect.material),
        "--risk", "external-action",
        "--role", "owner",
        ...(supersedesId ? ["--supersedes", supersedesId] : []),
        "--actor", "org2-lifecycle",
        "--json",
      ]));
      const approval = [...(updated.approvals || [])].reverse().find((candidate) => (
        candidate.status === "pending"
        && this.#draftApprovalMatches(effect, candidate)
      ));
      if (!approval?.id || !approval.fingerprint) {
        throw new Error(`Org2 did not return a fingerprinted approval for Gmail draft ${effect.draftId}`);
      }
      const record = this.#draftRecord(effect, { ...updated, id: updated.id || runId }, approval);
      record.materialDigest = effect.materialDigest;
      record.status = "pending";
      record.updatedAt = new Date().toISOString();
      this.state.drafts[effect.key] = record;
      await this.#save(stateLock);
      return record;
    });
  }

  async reserveDraftSend(effect, details = {}) {
    const toolCallId = String(details.toolCallId || "").trim();
    if (!toolCallId) throw new Error("A tool call id is required to reserve an approved Gmail send");
    const record = await this.#sharedDraftRecord(effect.key) || await this.#reconstructDraftRecord(effect);
    if (!record?.approvalId) throw new Error(`No Org2 approval exists for Gmail draft ${effect.draftId}`);
    if (!effect.material || !effect.materialDigest) {
      throw new Error(`Exact current review material is unavailable for Gmail draft ${effect.draftId}`);
    }
    const run = JSON.parse(await this.exec(["run", "show", record.org2RunId, "--json"]));
    const approval = (run.approvals || []).find((candidate) => candidate.id === record.approvalId);
    this.#assertNoConflictingDraftEffect(run, effect, approval?.id);
    if (approval?.status !== "approved") {
      throw new Error(`Gmail draft ${effect.draftId} is ${approval?.status || "untracked"} in Org2`);
    }
    if (approval.effectReceipt) throw new Error(`The approved effect for Gmail draft ${effect.draftId} was already performed`);
    if (!approval.fingerprint || approval.fingerprint !== record.approvalFingerprint) {
      throw new Error(`The native Org2 approval identity for Gmail draft ${effect.draftId} changed`);
    }
    const approvedDigest = approval.material ? approvalMaterialDigest(approval.material) : "";
    if (
      approvedDigest !== effect.materialDigest
      || record.materialDigest !== effect.materialDigest
      || !sameApprovalMaterial(approval.material, effect.material)
    ) {
      throw new Error(`Gmail draft ${effect.draftId} changed after it was reviewed and needs a new approval`);
    }
    await this.exec([
      "run", "approval-effect-reserve", record.org2RunId, record.approvalId,
      "--fingerprint", approval.fingerprint,
      "--material-digest", effect.materialDigest,
      "--tool-call-id", toolCallId,
      "--actor", "org2-lifecycle",
    ]);
    return { record, approval, toolCallId };
  }

  async recordDraftSent(effect, details = {}) {
    const toolCallId = String(details.toolCallId || "").trim();
    const externalId = String(details.externalId || "").trim();
    if (!toolCallId || !externalId) {
      throw new Error("A matching tool call id and provider message id are required to record a Gmail send");
    }
    const record = await this.#sharedDraftRecord(effect.key) || await this.#reconstructDraftRecord(effect);
    if (!record) throw new Error(`Cannot reconstruct the native approval for Gmail draft ${effect.draftId}`);
    const run = JSON.parse(await this.exec(["run", "show", record.org2RunId, "--json"]));
    const approval = (run.approvals || []).find((candidate) => candidate.id === record.approvalId);
    if (
      approval?.effectReceipt?.fingerprint === record.approvalFingerprint
      && approval.effectReceipt.externalId === externalId
    ) return;
    if (approval?.status !== "approved" || approval.fingerprint !== record.approvalFingerprint) {
      throw new Error(`Cannot record Gmail draft ${effect.draftId} as sent without its matching native approval`);
    }
    await this.exec([
      "run", "approval-effect", record.org2RunId, record.approvalId,
      "--fingerprint", approval.fingerprint,
      "--tool-call-id", toolCallId,
      "--system", effect.provider,
      "--external-id", externalId,
      "--actor", "org2-lifecycle",
    ]);
    await this.exec(["run", "comment", record.org2RunId, "--author", "org2-lifecycle", "--body",
      `Approved Gmail draft sent to ${record.destination}.`]);
    const refreshed = JSON.parse(await this.exec(["run", "show", record.org2RunId, "--json"]));
    if (refreshed.status === "running") {
      await this.exec(["run", "complete", record.org2RunId, "--actor", "org2-lifecycle", "--summary",
        `Approved Gmail draft sent to ${record.destination}.`]);
    }
    record.status = "sent";
    record.sentAt = new Date().toISOString();
    record.updatedAt = record.sentAt;
    await this.#save();
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
