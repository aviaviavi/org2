#!/usr/bin/env node
// Context-aware plugin actions and lifecycle hooks return reviewable
// proposals. They run sandboxed on macOS and cannot write the corpus.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createAgentRun, saveAgentRun, transitionAgentRun, loadAgentRunSnapshot } from "../dist/agentRun.js";
import { validatePluginManifest } from "../dist/pluginRuntime.js";
import { pluginSandboxAvailable } from "../dist/pluginActions.js";

const repo = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-plugin-actions-"));
const pluginRepository = path.join(root, "plugin-repository");
const corpus = path.join(root, "corpus");
const pluginHome = path.join(root, "plugin-home");
fs.mkdirSync(pluginRepository, { recursive: true });
fs.mkdirSync(corpus, { recursive: true });

function run(command, args, options = {}) {
  const child = spawnSync(command, args, {
    cwd: options.cwd || repo,
    env: { ...process.env, ORG2_PLUGIN_HOME: pluginHome },
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
  });
  if (options.allowFailure !== true && child.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed (${child.status}):\n${child.stdout}\n${child.stderr}`);
  }
  return child;
}
const cli = (args, options) => run("node", ["dist/cli.js", ...args, "--dir", corpus], options);
const git = (args) => run("git", args, { cwd: pluginRepository }).stdout.trim();

try {
  // Manifest validation: actions and hooks are typed; writes are not a capability.
  const base = { $schema: "org2:plugin-manifest:v1", id: "x", name: "X", version: "1.0.0" };
  assert.throws(() => validatePluginManifest({ ...base, contributes: { actions: [{ id: "a", title: "A", contexts: ["heading"], entry: "a.mjs", capabilities: ["write-corpus"] }] } }), /never a capability/);
  assert.throws(() => validatePluginManifest({ ...base, contributes: { actions: [{ id: "a", title: "A", contexts: ["desktop"], entry: "a.mjs" }] } }), /unsupported context/);
  assert.throws(() => validatePluginManifest({ ...base, contributes: { hooks: [{ id: "h", events: ["file.deleted"], entry: "h.mjs" }] } }), /unsupported event/);

  fs.writeFileSync(path.join(pluginRepository, "org2-plugin.json"), `${JSON.stringify({
    $schema: "org2:plugin-manifest:v1",
    id: "example.helper",
    name: "Example helper",
    version: "0.1.0",
    engines: { org2: ">=0.5.0 <1.0.0" },
    contributes: {
      actions: [
        { id: "mark-reviewed", title: "Mark reviewed", contexts: ["heading"], entry: "mark.mjs" },
        { id: "sneaky-write", title: "Sneaky write", contexts: ["note"], entry: "sneaky.mjs" },
        { id: "summarize-run", title: "Summarize run", contexts: ["run", "approval"], entry: "summarize.mjs" },
      ],
      hooks: [{ id: "on-blocked", description: "Comment when a run blocks", events: ["run.blocked"], entry: "hook.mjs" }],
    },
  }, null, 2)}\n`);
  const reader = `let input = ""; for await (const chunk of process.stdin) input += chunk; const invocation = JSON.parse(input);`;
  fs.writeFileSync(path.join(pluginRepository, "mark.mjs"), `${reader}
const c = invocation.context;
const firstLine = c.text.split("\\n")[0];
process.stdout.write(JSON.stringify({ $schema: "org2:plugin-action-result:v1", ok: true, text: "Reviewing " + c.title,
  proposals: [
    { kind: "edit", path: c.file, find: firstLine, replace: firstLine + " :reviewed:", summary: "Tag heading" },
    { kind: "create", path: "views/helper/" + c.title.toLowerCase().replace(/\\W+/g, "-") + ".org", content: "* Review of " + c.title + "\\n" },
  ] }));
`);
  fs.writeFileSync(path.join(pluginRepository, "sneaky.mjs"), `${reader}
import fs from "node:fs";
let wrote = false;
try { fs.writeFileSync(process.env.TARGET || ${JSON.stringify(path.join(corpus, "pwned.txt"))}, "x"); wrote = true; } catch {}
let read = false;
try { fs.readFileSync(${JSON.stringify(path.join(corpus, "notes.org"))}, "utf8"); read = true; } catch {}
process.stdout.write(JSON.stringify({ $schema: "org2:plugin-action-result:v1", ok: true, text: JSON.stringify({ wrote, read, sawCorpusRoot: "corpusRoot" in invocation }) }));
`);
  fs.writeFileSync(path.join(pluginRepository, "summarize.mjs"), `${reader}
const run = invocation.context.run;
process.stdout.write(JSON.stringify({ $schema: "org2:plugin-action-result:v1", ok: true, text: run.title + " is " + run.status + " (" + invocation.context.explanation.reason.code + ")" }));
`);
  fs.writeFileSync(path.join(pluginRepository, "hook.mjs"), `${reader}
process.stdout.write(JSON.stringify({ $schema: "org2:plugin-action-result:v1", ok: true,
  proposals: [{ kind: "run-comment", runId: invocation.event.subject.id, body: "Hook saw " + invocation.event.type + ": " + (invocation.event.data.reason || "") }] }));
`);
  git(["init", "-q", "-b", "main"]);
  git(["add", "."]);
  git(["-c", "user.name=Org2 Test", "-c", "user.email=org2@example.invalid", "commit", "-q", "-m", "Initial plugin"]);

  fs.writeFileSync(path.join(corpus, "org2.json"), `${JSON.stringify({ agendaFiles: ["*.org"], recursive: true }, null, 2)}\n`);
  const notes = "#+TITLE: Notes\n\n* TODO Ship feature :work:\n:PROPERTIES:\n:ID: abc\n:END:\nBody text.\n* Other\n";
  fs.writeFileSync(path.join(corpus, "notes.org"), notes);
  cli(["plugin", "add", pluginRepository, "--apply"]);

  // Untrusted plugins are listed but cannot run.
  const listed = JSON.parse(cli(["plugin", "actions", "--context", "heading", "--json"]).stdout);
  assert.deepEqual(listed.actions.map((item) => item.id), ["example.helper:mark-reviewed"]);
  assert.equal(listed.actions[0].trusted, false);
  assert.equal(listed.hooks[0].id, "example.helper:on-blocked");
  const refused = cli(["plugin", "action", "run", "example.helper:mark-reviewed", "--context", "heading", "--file", "notes.org", "--line", "5"], { allowFailure: true });
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /not trusted/);
  cli(["plugin", "trust", "example.helper", "--apply"]);

  // A heading action returns proposals; the corpus is unchanged until applied.
  const ran = JSON.parse(cli(["plugin", "action", "run", "example.helper:mark-reviewed", "--context", "heading", "--file", "notes.org", "--line", "5", "--json"]).stdout);
  assert.equal(ran.text, "Reviewing Ship feature");
  assert.equal(ran.proposal.status, "pending");
  assert.equal(ran.proposal.proposals.length, 2);
  assert.equal(fs.readFileSync(path.join(corpus, "notes.org"), "utf8"), notes, "actions never write directly");
  const pending = JSON.parse(cli(["plugin", "proposals", "list", "--status", "pending", "--json"]).stdout);
  assert.equal(pending.proposals.length, 1);
  const preview = JSON.parse(cli(["plugin", "proposals", "apply", ran.proposal.id, "--json"]).stdout);
  assert.equal(preview.applied, false);
  assert.ok(preview.changes.every((change) => change.ok));
  assert.match(preview.changes[0].diff, /\+\* TODO Ship feature :work: :reviewed:/);
  assert.equal(fs.readFileSync(path.join(corpus, "notes.org"), "utf8"), notes);
  const applied = JSON.parse(cli(["plugin", "proposals", "apply", ran.proposal.id, "--actor", "Avi", "--apply", "--json"]).stdout);
  assert.equal(applied.applied, true);
  assert.equal(applied.proposal.status, "applied");
  assert.equal(applied.proposal.decidedBy, "Avi");
  assert.match(fs.readFileSync(path.join(corpus, "notes.org"), "utf8"), /\* TODO Ship feature :work: :reviewed:/);
  assert.ok(fs.existsSync(path.join(corpus, "views", "helper", "ship-feature.org")));
  const again = cli(["plugin", "proposals", "apply", ran.proposal.id, "--apply"], { allowFailure: true });
  assert.notEqual(again.status, 0, "an applied proposal cannot be applied twice");

  // Stale proposals fail closed.
  const stale = JSON.parse(cli(["plugin", "action", "run", "example.helper:mark-reviewed", "--context", "heading", "--file", "notes.org", "--line", "9", "--json"]).stdout);
  fs.writeFileSync(path.join(corpus, "notes.org"), fs.readFileSync(path.join(corpus, "notes.org"), "utf8").replace("* Other", "* Renamed"));
  const blocked = cli(["plugin", "proposals", "apply", stale.proposal.id, "--apply"], { allowFailure: true });
  assert.notEqual(blocked.status, 0);
  assert.match(blocked.stderr, /not found/);
  cli(["plugin", "proposals", "dismiss", stale.proposal.id, "--apply"]);

  // The sandbox denies corpus writes and reads on macOS, and the corpus root is not passed.
  const sneaky = JSON.parse(JSON.parse(cli(["plugin", "action", "run", "example.helper:sneaky-write", "--context", "note", "--file", "notes.org", "--json"]).stdout).text);
  assert.equal(sneaky.sawCorpusRoot, false);
  if (pluginSandboxAvailable()) {
    assert.equal(sneaky.wrote, false, "sandbox denies corpus writes");
    assert.equal(sneaky.read, false, "sandbox denies corpus reads without read-corpus");
    assert.equal(fs.existsSync(path.join(corpus, "pwned.txt")), false);
  }

  // Run context includes the shared explanation.
  let blockedRun = createAgentRun({ id: "run-1", title: "Pick checkout", goal: "Pick checkout" });
  blockedRun = transitionAgentRun(blockedRun, "running", { actor: "Agent" });
  blockedRun = transitionAgentRun(blockedRun, "blocked", { actor: "Agent", reason: "Which checkout?" });
  saveAgentRun(corpus, blockedRun, { expectedRevision: null });
  const summary = JSON.parse(cli(["plugin", "action", "run", "example.helper:summarize-run", "--context", "run", "--run", "run-1", "--json"]).stdout);
  assert.equal(summary.text, "Pick checkout is blocked (blocked-question)");
  assert.equal(summary.proposal, null);

  // Hooks: dry run, then dispatch queues proposals; dispatch is idempotent.
  const dry = JSON.parse(cli(["plugin", "hooks", "dispatch", "--since", "10m", "--json"]).stdout);
  assert.equal(dry.applied, false);
  assert.deepEqual(dry.outcomes.map((item) => [item.eventType, item.hook, item.detail]), [["run.blocked", "example.helper:on-blocked", "would invoke"]]);
  const dispatched = JSON.parse(cli(["plugin", "hooks", "dispatch", "--since", "10m", "--apply", "--json"]).stdout);
  assert.equal(dispatched.outcomes.length, 1);
  assert.ok(dispatched.outcomes[0].proposalId);
  assert.equal(loadAgentRunSnapshot(corpus, "run-1").run.comments.length, 0, "hooks never write directly");
  const repeat = JSON.parse(cli(["plugin", "hooks", "dispatch", "--since", "10m", "--apply", "--json"]).stdout);
  assert.equal(repeat.outcomes.length, 0, "already-dispatched events are skipped");
  cli(["plugin", "proposals", "apply", dispatched.outcomes[0].proposalId, "--apply"]);
  const comments = loadAgentRunSnapshot(corpus, "run-1").run.comments;
  assert.equal(comments.length, 1);
  assert.equal(comments[0].author, "Example helper (plugin)");
  assert.equal(comments[0].body, "Hook saw run.blocked: Which checkout?");

  console.log("plugin actions and hooks ok");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
