import fs from "node:fs";
import path from "node:path";
import {
  AGENT_RUN_APPROVAL_DECISIONS,
  AGENT_RUN_ARTIFACT_REVIEW_STATUSES,
  AGENT_RUN_ARTIFACT_ROLES,
  AGENT_RUN_RISK_CLASSES,
  AGENT_RUN_STEP_KINDS,
  AGENT_RUN_STEP_STATUSES,
  AGENT_RUN_VALIDATION_STATUSES,
  addAgentRunArtifact,
  addAgentRunComment,
  addAgentRunValidation,
  createAgentRun,
  decideAgentRunApproval,
  forkAgentRun,
  listAgentRuns,
  loadAgentRun,
  normalizeLegacyAgentRuns,
  requestAgentRunApproval,
  saveAgentRun,
  transitionAgentRun,
  updateAgentRunAssignment,
  updateAgentRunOutcome,
  updateAgentRunStep,
  validateAgentRun,
  type AgentRunStatus,
} from "./agentRun.js";
import {
  dueWorkflowTriggers,
  instantiateWorkflow,
  listWorkflows,
  loadWorkflow,
  migrateLegacyWorkflows,
  packagedWorkflowManifest,
  packagedCorpusTemplate,
  saveWorkflow,
  updateWorkflow,
  validateWorkflow,
  workflowSourcePath,
  workflowFromRun,
} from "./agentWorkflow.js";
import { artifactRebuildPlan, buildArtifactGraph, loadArtifactDeclarations, MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW, saveArtifactGraph } from "./artifactPipeline.js";
import { discoverMcpClient, installBuiltinWorkflow, loadMcpClients, saveMcpClients, serveMcp, writeMcpSnapshot } from "./mcpRuntime.js";
import { loadRuntimePolicy, runtimePolicyPath, saveRuntimePolicy, selectRuntime, validateRuntimePaths } from "./runtimePolicy.js";
import { evaluateRun, loadEvalExpectation, loadWorkflowReplayFixture, replayWorkflowFixture, sanitizeRunFixture, saveEvalResult } from "./workflowEval.js";
import { ORG2_CORPUS_KINDS, corpusIdentityStatus, initializeCorpusIdentity } from "./corpusIdentity.js";

interface ParsedArgs { positional: string[]; flags: Map<string, string[]>; }
function parseArgs(args: string[]): ParsedArgs {
  const positional: string[] = [];
  const flags = new Map<string, string[]>();
  for (let i = 0; i < args.length; i += 1) {
    const item = args[i]!;
    if (!item.startsWith("--")) { positional.push(item); continue; }
    const equal = item.indexOf("=");
    const name = equal >= 0 ? item.slice(2, equal) : item.slice(2);
    const explicit = equal >= 0 ? item.slice(equal + 1) : undefined;
    const value = explicit ?? (args[i + 1] && !args[i + 1]!.startsWith("--") ? args[++i]! : "true");
    flags.set(name, [...(flags.get(name) || []), value]);
  }
  return { positional, flags };
}
function flag(parsed: ParsedArgs, name: string, fallback?: string): string | undefined { return parsed.flags.get(name)?.at(-1) ?? fallback; }
function flags(parsed: ParsedArgs, name: string): string[] { return parsed.flags.get(name) || []; }
function enabled(parsed: ParsedArgs, name: string): boolean { return parsed.flags.has(name); }
function root(parsed: ParsedArgs): string { return path.resolve(flag(parsed, "dir", ".")!); }
function output(parsed: ParsedArgs, value: unknown, text?: string): void {
  if (enabled(parsed, "json") || flag(parsed, "format") === "json") process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  else process.stdout.write(`${text ?? (typeof value === "string" ? value : JSON.stringify(value, null, 2))}\n`);
}
function required(value: string | undefined, message: string): string { if (!value) throw new Error(message); return value; }
function choice<const Choices extends readonly string[]>(value: string | undefined, choices: Choices, label: string): Choices[number] {
  const selected = required(value, `${label} is required`);
  if (!choices.includes(selected)) throw new Error(`invalid ${label}: ${selected}; expected one of: ${choices.join(", ")}`);
  return selected as Choices[number];
}
function optionalChoice<const Choices extends readonly string[]>(value: string | undefined, choices: Choices, label: string): Choices[number] | undefined {
  return value === undefined ? undefined : choice(value, choices, label);
}

const HELP = `Agentic workspace commands:
  org2 corpus show|validate|init [--dir CORPUS] [--id ID --name NAME --kind personal|shared|project] [--apply]
  org2 run create --goal TEXT [--accept TEXT] [--risk CLASS] [--owner NAME] [--capability ID] [--dir CORPUS]
  org2 run list|show|validate|start|resume|retry|cancel|complete|fail|block|fork|normalize
  org2 run block ID --reason "Specific clarification needed"
  org2 run complete ID --summary "What happened" [--highlight TEXT] [--next-action TEXT]
  org2 run outcome ID --summary "What happened" [--highlight TEXT] [--next-action TEXT]
  org2 run assign ID [--owner NAME] [--assignee NAME]
  org2 run comment ID --author NAME --body TEXT
  org2 run step ID STEP --status STATUS
  org2 run artifact ID --path FILE [--role ROLE] [--review-status STATUS]
  org2 run validation ID --name NAME --status passed|failed|warning|skipped
  org2 run approval-request ID --title TEXT --action TEXT [--risk CLASS] [--role ROLE]
  org2 run approval-decide ID APPROVAL --decision approved|rejected|revised|canceled --actor NAME [--receipt TEXT]
  org2 review list [--status pending] | org2 review show RUN
  org2 workflow list|show|validate|save|run|triggers|activate|pause|draft|schedule|migrate|package|corpus-template|install-builtin
  org2 artifact graph --manifest FILE | org2 artifact rebuild --manifest FILE
  org2 runtime init|show|select|verify-paths
  org2 mcp serve|clients|client-add|discover|snapshot
  org2 eval run RUN --expect FILE | org2 eval replay WORKFLOW --fixture FILE | org2 eval fixture RUN --output FILE

Writes are local, inspectable files under .org2/ or reviewable corpus zones. Consequential actions remain approval-gated.`;

function corpusCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "show";
  const corpus = root(parsed);
  if (action === "show" || action === "validate") {
    const status = corpusIdentityStatus(corpus);
    output(parsed, status, status.valid
      ? `${status.identity!.name}\n${status.identity!.id}\t${status.identity!.kind}\n${status.root}`
      : status.issues.map((issue) => `${issue.path}: ${issue.message}`).join("\n"));
    if (action === "validate" && !status.valid) process.exitCode = 1;
    return;
  }
  if (action === "init") {
    const result = initializeCorpusIdentity(corpus, {
      id: required(flag(parsed, "id"), "--id is required"),
      name: required(flag(parsed, "name"), "--name is required"),
      kind: choice(flag(parsed, "kind", "personal"), ORG2_CORPUS_KINDS, "corpus kind"),
    }, { apply: enabled(parsed, "apply"), force: enabled(parsed, "force") });
    output(parsed, result, `${result.applied ? "initialized" : "would initialize"} ${result.status.identity!.id}\n${result.status.configFile}`);
    return;
  }
  throw new Error(`unknown corpus action: ${action}`);
}

async function runCommand(parsed: ParsedArgs): Promise<void> {
  const action = parsed.positional[0] || "help";
  const corpus = root(parsed);
  if (action === "help") { output(parsed, HELP); return; }
  if (action === "create") {
    const risk = choice(flag(parsed, "risk", "local-draft"), AGENT_RUN_RISK_CLASSES, "risk class");
    const tokenLimit = flag(parsed, "token-limit"); const costLimit = flag(parsed, "cost-limit-usd"); const timeLimit = flag(parsed, "time-limit-seconds");
    const plan = flags(parsed, "step").map((raw, index) => { const colon = raw.indexOf(":"); const kind = colon > 0 ? raw.slice(0, colon) : "agent"; const title = colon > 0 ? raw.slice(colon + 1) : raw; if (!title.trim()) throw new Error(`--step ${index + 1} must be [${AGENT_RUN_STEP_KINDS.join("|")}]:TITLE`); return { id: `step-${index + 1}`, kind: choice(kind, AGENT_RUN_STEP_KINDS, `--step ${index + 1} kind`), title: title.trim() }; });
    const run = createAgentRun({ id: flag(parsed, "id"), goal: required(flag(parsed, "goal"), "--goal is required"), acceptanceCriteria: flags(parsed, "accept"), riskClass: risk, owner: flag(parsed, "owner"), assignee: flag(parsed, "assignee"), providerPolicy: flag(parsed, "policy"), provider: flag(parsed, "provider"), model: flag(parsed, "model"), capabilities: flags(parsed, "capability"), context: flags(parsed, "context").map((ref) => ({ ref })), plan, ...((tokenLimit || costLimit || timeLimit) ? { budget: { ...(tokenLimit ? { tokenLimit: Number(tokenLimit) } : {}), ...(costLimit ? { costLimitUsd: Number(costLimit) } : {}), ...(timeLimit ? { timeLimitSeconds: Number(timeLimit) } : {}) } } : {}) });
    const file = saveAgentRun(corpus, run); output(parsed, { run, file }, `created ${run.id}\n${file}`); return;
  }
  if (action === "list") {
    const status = flag(parsed, "status");
    const runs = listAgentRuns(corpus).filter((run) => !status || run.status === status);
    output(parsed, { schema: "org2:run-list:v1", runs }, runs.length ? runs.map((run) => `${run.id}\t${run.status}\t${run.goal}`).join("\n") : "No runs."); return;
  }
  if (action === "normalize") { const result = normalizeLegacyAgentRuns(corpus); output(parsed, result, `created ${result.created.length}; skipped ${result.skippedExisting.length}`); return; }
  const id = required(parsed.positional[1], `run id is required for ${action}`);
  if (action === "show") { const run = loadAgentRun(corpus, id); output(parsed, run, fs.readFileSync(path.join(corpus, ".org2", "runs", `${id}.org2`), "utf8")); return; }
  if (action === "validate") { const result = validateAgentRun(loadAgentRun(corpus, id)); output(parsed, result, result.valid ? `${id}: valid` : result.issues.map((issue) => `${issue.path}: ${issue.message}`).join("\n")); if (!result.valid) process.exitCode = 1; return; }
  const existing = loadAgentRun(corpus, id);
  let run = existing;
  const transitions: Record<string, AgentRunStatus> = { start: "running", resume: "running", retry: "queued", cancel: "canceled", complete: "completed", fail: "failed", block: "blocked" };
  if (transitions[action]) run = transitionAgentRun(existing, transitions[action]!, {
    actor: flag(parsed, "actor"), reason: flag(parsed, "reason"), summary: flag(parsed, "summary"),
    highlights: flags(parsed, "highlight"), nextActions: flags(parsed, "next-action"),
  });
  else if (action === "assign") run = updateAgentRunAssignment(existing, { owner: flag(parsed, "owner"), assignee: flag(parsed, "assignee"), actor: flag(parsed, "actor") });
  else if (action === "outcome") run = updateAgentRunOutcome(existing, { summary: required(flag(parsed, "summary"), "--summary is required"), highlights: flags(parsed, "highlight"), nextActions: flags(parsed, "next-action"), actor: flag(parsed, "actor") });
  else if (action === "comment") run = addAgentRunComment(existing, required(flag(parsed, "author"), "--author is required"), required(flag(parsed, "body"), "--body is required"));
  else if (action === "step") run = updateAgentRunStep(existing, required(parsed.positional[2], "step id is required"), choice(flag(parsed, "status"), AGENT_RUN_STEP_STATUSES, "step status"), { actor: flag(parsed, "actor"), detail: flag(parsed, "detail") });
  else if (action === "artifact") run = addAgentRunArtifact(existing, { path: required(flag(parsed, "path"), "--path is required"), role: choice(flag(parsed, "role", "draft"), AGENT_RUN_ARTIFACT_ROLES, "artifact role"), title: flag(parsed, "title"), mediaType: flag(parsed, "media-type"), sha256: flag(parsed, "sha256"), reviewStatus: optionalChoice(flag(parsed, "review-status"), AGENT_RUN_ARTIFACT_REVIEW_STATUSES, "artifact review status") }, flag(parsed, "actor"));
  else if (action === "validation") run = addAgentRunValidation(existing, { name: required(flag(parsed, "name"), "--name is required"), status: choice(flag(parsed, "status"), AGENT_RUN_VALIDATION_STATUSES, "validation status"), detail: flag(parsed, "detail") }, flag(parsed, "actor"));
  else if (action === "approval-request") run = requestAgentRunApproval(existing, { title: required(flag(parsed, "title"), "--title is required"), action: required(flag(parsed, "action"), "--action is required"), riskClass: choice(flag(parsed, "risk", existing.riskClass), AGENT_RUN_RISK_CLASSES, "approval risk class"), requestedRole: flag(parsed, "role"), requestedFrom: flag(parsed, "from"), note: flag(parsed, "note") }, flag(parsed, "actor"));
  else if (action === "approval-decide") run = decideAgentRunApproval(existing, required(parsed.positional[2], "approval id is required"), choice(flag(parsed, "decision"), AGENT_RUN_APPROVAL_DECISIONS, "approval decision"), { actor: required(flag(parsed, "actor"), "--actor is required"), actorRole: flag(parsed, "role"), note: flag(parsed, "note"), receipt: flag(parsed, "receipt") });
  else if (action === "fork") { run = forkAgentRun(existing, { id: flag(parsed, "id"), actor: flag(parsed, "actor"), fromEventId: flag(parsed, "event") }); const file = saveAgentRun(corpus, run); output(parsed, { run, file }, `forked ${existing.id} -> ${run.id}`); return; }
  else throw new Error(`unknown run action: ${action}`);
  saveAgentRun(corpus, run); output(parsed, run, `${run.id}: ${run.status}`);
}

function reviewCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "list";
  const corpus = root(parsed);
  const runs = listAgentRuns(corpus);
  if (action === "list") {
    const items = runs.flatMap((run) => [
      ...run.approvals.filter((approval) => !flag(parsed, "status") || approval.status === flag(parsed, "status")).map((approval) => ({ kind: "approval", runId: run.id, runGoal: run.goal, ...approval })),
      ...run.artifacts.filter((artifact) => artifact.reviewStatus === "review-required").map((artifact) => ({ kind: "artifact", runId: run.id, runGoal: run.goal, ...artifact })),
      ...(run.status === "blocked" ? [{ kind: "clarification", runId: run.id, runGoal: run.goal, reason: run.blockedReason }] : []),
      ...run.validations.filter((validation) => validation.status === "failed" || validation.status === "warning").map((validation) => ({ kind: "validation", runId: run.id, runGoal: run.goal, ...validation })),
    ]);
    output(parsed, { schema: "org2:review-queue:v1", items }, items.length ? items.map((item: any) => `${item.kind}\t${item.runId}\t${item.title || item.name || item.path || item.reason}`).join("\n") : "Review queue is empty."); return;
  }
  if (action === "show") { const run = loadAgentRun(corpus, required(parsed.positional[1], "run id is required")); output(parsed, { run, approvals: run.approvals, artifacts: run.artifacts, validations: run.validations, comments: run.comments }); return; }
  throw new Error(`unknown review action: ${action}`);
}

function workflowCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "list"; const corpus = root(parsed);
  if (action === "list") {
    const workflows = listWorkflows(corpus).map((workflow) => ({
      ...workflow,
      file: workflowSourcePath(corpus, workflow.id),
      legacyLocation: workflowSourcePath(corpus, workflow.id).includes(`${path.sep}.org2${path.sep}workflows${path.sep}`),
    }));
    output(parsed, { schema: "org2:workflow-list:v1", workflows }, workflows.length ? workflows.map((item) => `${item.id}@${item.version}\t${item.state}\t${item.title}`).join("\n") : "No workflows.");
    return;
  }
  if (action === "migrate") {
    const migrated = migrateLegacyWorkflows(corpus);
    output(parsed, { schema: "org2:workflow-migration:v1", migrated }, migrated.length ? migrated.map((item) => `${item.skipped ? "kept" : "moved"}\t${item.id}\t${item.to}`).join("\n") : "No legacy workflows.");
    return;
  }
  if (action === "install-builtin") { const name = parsed.positional[1] || "meeting-to-controlled-execution"; if (name !== "meeting-to-controlled-execution") throw new Error(`unknown built-in workflow: ${name}`); const file = installBuiltinWorkflow(corpus, MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW); output(parsed, { id: name, file }, `installed ${name}\n${file}`); return; }
  const id = required(parsed.positional[1], `workflow id is required for ${action}`);
  if (action === "save") { const run = loadAgentRun(corpus, id); const workflow = workflowFromRun(run, { id: flag(parsed, "id"), title: flag(parsed, "title"), version: flag(parsed, "version") }); const file = saveWorkflow(corpus, workflow); output(parsed, { workflow, file }, `saved ${workflow.id}@${workflow.version}`); return; }
  const workflow = loadWorkflow(corpus, id);
  if (action === "show") { output(parsed, workflow); return; }
  if (action === "validate") { const result = validateWorkflow(workflow); output(parsed, result, result.valid ? `${id}: valid` : result.issues.map((issue) => `${issue.path}: ${issue.message}`).join("\n")); if (!result.valid) process.exitCode = 1; return; }
  if (action === "activate" || action === "pause" || action === "draft") {
    const state = action === "activate" ? "active" : action === "pause" ? "paused" : "draft";
    const updated = updateWorkflow(corpus, id, (item) => ({ ...item, state }));
    output(parsed, updated, `${id}: ${state}`);
    return;
  }
  if (action === "schedule") {
    const cron = flag(parsed, "cron")?.trim();
    const timezone = flag(parsed, "timezone")?.trim() || flag(parsed, "tz")?.trim();
    const disabled = parsed.flags.has("disable");
    if (!disabled && !cron) throw new Error("workflow schedule requires --cron EXPR or --disable");
    const updated = updateWorkflow(corpus, id, (item) => {
      const triggers = item.triggers.filter((trigger) => trigger.id !== "openclaw-schedule");
      triggers.push({
        id: "openclaw-schedule",
        type: "schedule",
        enabled: !disabled,
        ...(cron ? { schedule: cron } : {}),
        ...(timezone ? { timezone } : {}),
      });
      return { ...item, triggers };
    });
    output(parsed, updated, disabled ? `${id}: schedule disabled` : `${id}: scheduled ${cron}`);
    return;
  }
  if (action === "package") { output(parsed, packagedWorkflowManifest(workflow)); return; }
  if (action === "corpus-template") { const template = packagedCorpusTemplate(workflow); const out = flag(parsed, "out"); if (out) { const file = path.resolve(out); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, `${JSON.stringify(template, null, 2)}\n`, "utf8"); output(parsed, { template, file }, file); } else output(parsed, template); return; }
  if (action === "triggers") { const due = dueWorkflowTriggers(workflow, { now: flag(parsed, "now"), changedPaths: flags(parsed, "changed"), event: flag(parsed, "event") as any }); output(parsed, { workflow: id, due }, due.length ? due.map((trigger) => `${trigger.id}\t${trigger.type}`).join("\n") : "No triggers due."); return; }
  if (action === "run") { const inputs = Object.fromEntries(flags(parsed, "input").map((item) => { const at = item.indexOf("="); if (at < 1) throw new Error("--input must be NAME=VALUE"); return [item.slice(0, at), item.slice(at + 1)]; })); const run = instantiateWorkflow(workflow, inputs, { owner: flag(parsed, "owner"), assignee: flag(parsed, "assignee") }); const file = saveAgentRun(corpus, run); output(parsed, { run, file }, `created run ${run.id} from ${id}@${workflow.version}`); return; }
  throw new Error(`unknown workflow action: ${action}`);
}

function artifactCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "graph"; const corpus = root(parsed); const manifest = path.resolve(required(flag(parsed, "manifest"), "--manifest is required")); const graph = buildArtifactGraph(corpus, loadArtifactDeclarations(manifest));
  if (action === "graph") { const file = enabled(parsed, "apply") ? saveArtifactGraph(corpus, graph) : undefined; output(parsed, { graph, ...(file ? { file } : {}) }, graph.artifacts.map((item) => `${item.status}\t${item.path}${item.reason ? `\t${item.reason}` : ""}`).join("\n")); return; }
  if (action === "rebuild") { const plan = artifactRebuildPlan(graph); output(parsed, { schema: "org2:artifact-rebuild-plan:v1", plan }, plan.length ? plan.map((item) => `${item.path}\t${item.command || "manual"}\t${item.reason}`).join("\n") : "All artifacts are fresh."); return; }
  throw new Error(`unknown artifact action: ${action}`);
}

function runtimeCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "show"; const corpus = root(parsed);
  if (action === "init") { const config = loadRuntimePolicy(corpus); const file = saveRuntimePolicy(corpus, config); output(parsed, { config, file }, file); return; }
  const config = loadRuntimePolicy(corpus);
  if (action === "show") { output(parsed, { file: runtimePolicyPath(corpus), config }); return; }
  if (action === "select") { const policy = required(parsed.positional[1], "policy name is required"); const runtime = selectRuntime(config, policy, flags(parsed, "capability")); output(parsed, { policy, runtime }, `${runtime.id}\t${runtime.provider}/${runtime.model}\t${runtime.transport}`); return; }
  if (action === "verify-paths") { const result = validateRuntimePaths(config, flags(parsed, "capability")); output(parsed, result, result.valid ? `local: ${result.local!.id}\nhosted: ${result.hosted!.id}` : result.issues.join("\n")); if (!result.valid) process.exitCode = 1; return; }
  throw new Error(`unknown runtime action: ${action}`);
}

async function mcpCommand(parsed: ParsedArgs): Promise<void> {
  const action = parsed.positional[0] || "clients"; const corpus = root(parsed);
  if (action === "serve") { await serveMcp(corpus); return; }
  if (action === "clients") { const clients = loadMcpClients(corpus); output(parsed, { schema: "org2:mcp-clients:v1", clients }); return; }
  if (action === "client-add") { const id = required(parsed.positional[1], "client id is required"); const command = required(flag(parsed, "command"), "--command is required"); const clients = loadMcpClients(corpus).filter((item) => item.id !== id); clients.push({ id, command, args: flags(parsed, "arg"), capabilities: flags(parsed, "capability"), environmentVariables: flags(parsed, "env") }); const file = saveMcpClients(corpus, clients); output(parsed, { clients, file }, `saved ${id}`); return; }
  if (action === "discover") { const id = required(parsed.positional[1], "client id is required"); const discovery = discoverMcpClient(corpus, id, { timeoutMs: Number(flag(parsed, "timeout-ms", "10000")), snapshotId: flag(parsed, "snapshot") }); output(parsed, discovery, `${id}: ${Object.values(discovery.capabilities).flatMap((value) => Array.isArray(value) ? value : []).length} discovered item(s)${discovery.snapshot ? `\n${discovery.snapshot}` : ""}`); return; }
  if (action === "snapshot") { const id = required(parsed.positional[1], "snapshot id is required"); const source = required(flag(parsed, "source"), "--source is required"); const input = flag(parsed, "input"); const payload = input ? JSON.parse(fs.readFileSync(path.resolve(input), "utf8")) : JSON.parse(await new Promise<string>((resolve, reject) => { let raw = ""; process.stdin.setEncoding("utf8"); process.stdin.on("data", (chunk) => raw += chunk); process.stdin.on("end", () => resolve(raw)); process.stdin.on("error", reject); })); const snapshot = { schema: "org2:mcp-snapshot:v1" as const, id, source, retrievedAt: new Date().toISOString(), identity: flag(parsed, "identity"), freshUntil: flag(parsed, "fresh-until"), payload }; const file = writeMcpSnapshot(corpus, snapshot); output(parsed, { snapshot, file }, file); return; }
  throw new Error(`unknown mcp action: ${action}`);
}

function evalCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "run"; const corpus = root(parsed); const id = required(parsed.positional[1], `${action === "replay" ? "workflow" : "run"} id is required`);
  if (action === "replay") { const result = replayWorkflowFixture(loadWorkflow(corpus, id), loadWorkflowReplayFixture(path.resolve(required(flag(parsed, "fixture"), "--fixture is required")))); output(parsed, result, `${result.passed ? "PASS" : "FAIL"} replay ${id}\n${result.checks.map((item) => `${item.passed ? "PASS" : "FAIL"}\t${item.name}\t${item.detail}`).join("\n")}`); if (!result.passed) process.exitCode = 1; return; }
  const run = loadAgentRun(corpus, id);
  if (action === "run") { const result = evaluateRun(run, loadEvalExpectation(path.resolve(required(flag(parsed, "expect"), "--expect is required")))); const file = saveEvalResult(corpus, result); output(parsed, { result, file }, `${result.passed ? "PASS" : "FAIL"} ${run.id}\n${result.checks.map((item) => `${item.passed ? "PASS" : "FAIL"}\t${item.name}\t${item.detail}`).join("\n")}`); if (!result.passed) process.exitCode = 1; return; }
  if (action === "fixture") { const file = path.resolve(required(flag(parsed, "output"), "--output is required")); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, `${JSON.stringify(sanitizeRunFixture(run), null, 2)}\n`, "utf8"); output(parsed, { file }, file); return; }
  throw new Error(`unknown eval action: ${action}`);
}

export async function runAgenticWorkspaceCommand(args: string[]): Promise<boolean> {
  const family = args[0];
  if (!family || !["corpus", "run", "review", "workflow", "artifact", "runtime", "mcp", "eval"].includes(family)) return false;
  const parsed = parseArgs(args.slice(1));
  if (enabled(parsed, "help") || parsed.positional[0] === "help") { output(parsed, HELP); return true; }
  if (family === "corpus") corpusCommand(parsed);
  else if (family === "run") await runCommand(parsed);
  else if (family === "review") reviewCommand(parsed);
  else if (family === "workflow") workflowCommand(parsed);
  else if (family === "artifact") artifactCommand(parsed);
  else if (family === "runtime") runtimeCommand(parsed);
  else if (family === "mcp") await mcpCommand(parsed);
  else if (family === "eval") evalCommand(parsed);
  return true;
}
