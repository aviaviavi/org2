import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pluginEngineSatisfied } from "../dist/pluginRuntime.js";

const repo = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-plugin-test-"));
const pluginRepository = path.join(root, "plugin-repository");
const corpus = path.join(root, "corpus");
const pluginHome = path.join(root, "plugin-home");
fs.mkdirSync(pluginRepository, { recursive: true });
fs.mkdirSync(corpus, { recursive: true });

assert.equal(pluginEngineSatisfied(">=0.5.0 <1.0.0", "0.5.2"), true);
assert.equal(pluginEngineSatisfied("^0.5.0", "0.6.0"), false);
assert.equal(pluginEngineSatisfied("~0.5.0", "0.5.9"), true);
for (const schema of ["manifest", "lock", "invocation", "result", "render-result"]) {
  const parsed = JSON.parse(fs.readFileSync(path.join(repo, "spec", "v0", `plugin-${schema}.schema.json`), "utf8"));
  assert.match(parsed.$id, new RegExp(`plugin-${schema}\\.schema\\.json$`));
}

function run(command, args, options = {}) {
  const child = spawnSync(command, args, {
    cwd: options.cwd || repo,
    env: { ...process.env, ORG2_PLUGIN_HOME: pluginHome, ...(options.env || {}) },
    encoding: "utf8",
    input: options.input,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (options.allowFailure !== true && child.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed (${child.status}):\n${child.stdout}\n${child.stderr}`);
  }
  return child;
}

function git(args) {
  return run("git", args, { cwd: pluginRepository }).stdout.trim();
}

function cli(args, options = {}) {
  return run("node", ["dist/cli.js", ...args], options);
}

fs.writeFileSync(path.join(pluginRepository, "org2-plugin.json"), `${JSON.stringify({
  $schema: "org2:plugin-manifest:v1",
  id: "example.cards",
  name: "Example cards",
  version: "0.1.0",
  description: "Plugin runtime integration fixture",
  engines: { org2: ">=0.5.0 <1.0.0" },
  contributes: {
    commands: [{ id: "echo", entry: "echo.mjs" }],
    renderers: [{ id: "card", languages: ["demo-card"], entry: "render.mjs" }],
    templates: [{ id: "note", path: "templates/note.org2" }],
  },
}, null, 2)}\n`);
fs.writeFileSync(path.join(pluginRepository, "echo.mjs"), `
let input = "";
for await (const chunk of process.stdin) input += chunk;
const invocation = JSON.parse(input);
process.stdout.write(JSON.stringify({
  $schema: "org2:plugin-result:v1",
  ok: true,
  text: "echo:" + invocation.arguments.join("|")
}));
`);
fs.writeFileSync(path.join(pluginRepository, "render.mjs"), `
let input = "";
for await (const chunk of process.stdin) input += chunk;
const invocation = JSON.parse(input);
process.stdout.write(JSON.stringify({
  $schema: "org2:plugin-render-result:v1",
  html: '<article class="card"><strong>Plugin card</strong><p>' + invocation.block.body.trim() + '</p></article>',
  css: '.card{padding:16px;border:1px solid #888;border-radius:10px}',
  script: 'document.body.dataset.pluginReady="true"',
  title: "Example plugin card",
  height: 180
}));
`);
fs.mkdirSync(path.join(pluginRepository, "templates"));
fs.writeFileSync(path.join(pluginRepository, "templates", "note.org2"), "#+title: Plugin note\n\n* Start here\n");
git(["init", "-q", "-b", "main"]);
git(["add", "."]);
git(["-c", "user.name=Org2 Test", "-c", "user.email=org2@example.invalid", "commit", "-q", "-m", "Initial plugin"]);
const initialRevision = git(["rev-parse", "HEAD"]);

fs.writeFileSync(path.join(corpus, "org2.json"), `${JSON.stringify({ agendaFiles: ["*.org2"], recursive: true }, null, 2)}\n`);
const documentPath = path.join(corpus, "plugin-demo.org2");
const documentSource = `#+title: Plugin demo

* Card

\`\`\`demo-card compact
Hello from a plugin.
\`\`\`
`;
fs.writeFileSync(documentPath, documentSource);

const preview = JSON.parse(cli(["plugin", "add", pluginRepository, "--dir", corpus, "--json"]).stdout);
assert.equal(preview.applied, false);
assert.equal(preview.plugin.id, "example.cards");
assert.equal(preview.plugin.revision, initialRevision);
assert.equal(JSON.parse(fs.readFileSync(path.join(corpus, "org2.json"), "utf8")).plugins, undefined);
assert.equal(fs.existsSync(path.join(corpus, "org2.plugins.lock.json")), false);

const added = JSON.parse(cli(["plugin", "add", pluginRepository, "--dir", corpus, "--apply", "--json"]).stdout);
assert.equal(added.applied, true);
assert.equal(added.trusted, false);
assert.match(added.plugin.contentHash, /^sha256:[a-f0-9]{64}$/);
const contentHash = added.plugin.contentHash;
const storePath = path.join(pluginHome, "store", contentHash.replace(":", "-"));
assert.equal(fs.existsSync(path.join(storePath, "org2-plugin.json")), true);
const lock = JSON.parse(fs.readFileSync(path.join(corpus, "org2.plugins.lock.json"), "utf8"));
assert.equal(lock.$schema, "org2:plugin-lock:v1");
assert.equal(lock.plugins[0].revision, initialRevision);
assert.equal(lock.plugins[0].contentHash, contentHash);

const untrustedHtml = run("node", ["dist/render-html.js", "--source-path", documentPath], { input: documentSource }).stdout;
assert.match(untrustedHtml, /Plugin renderer unavailable/);
assert.match(untrustedHtml, /not trusted on this machine/);
assert.doesNotMatch(untrustedHtml, /<iframe/);

const trustPreview = JSON.parse(cli(["plugin", "trust", "example.cards", "--dir", corpus, "--json"]).stdout);
assert.equal(trustPreview.applied, false);
assert.equal(fs.existsSync(path.join(pluginHome, "trust.json")), false);
cli(["plugin", "trust", "example.cards", "--dir", corpus, "--apply"]);

const listed = JSON.parse(cli(["plugin", "list", "--dir", corpus, "--json"]).stdout);
assert.equal(listed.plugins[0].installed, true);
assert.equal(listed.plugins[0].trusted, true);
assert.deepEqual(listed.plugins[0].contributions.commands, ["echo"]);
assert.deepEqual(listed.plugins[0].contributions.renderers, [{ id: "card", languages: ["demo-card"] }]);

const commandResult = JSON.parse(cli([
  "plugin", "exec", "example.cards", "echo", "--dir", corpus, "--json", "--", "one", "two",
]).stdout);
assert.equal(commandResult.$schema, "org2:plugin-result:v1");
assert.equal(commandResult.text, "echo:one|two");

const renderedHtml = run("node", ["dist/render-html.js", "--source-path", documentPath], { input: documentSource }).stdout;
assert.match(renderedHtml, /data-org2-plugin="example\.cards:card"/);
assert.match(renderedHtml, /sandbox="allow-scripts"/);
assert.match(renderedHtml, /height:180px/);
assert.match(renderedHtml, /Plugin card/);
assert.match(renderedHtml, /connect-src/);
assert.doesNotMatch(renderedHtml, /class="org2-src language-demo-card"/);

const exportedDocument = path.join(corpus, "plugin-demo.html");
cli(["export", "html", "--file", documentPath, "--out", exportedDocument, "--apply"]);
const exportedHtml = fs.readFileSync(exportedDocument, "utf8");
assert.match(exportedHtml, /data-org2-plugin="example\.cards:card"/);
assert.match(exportedHtml, /sandbox="allow-scripts"/);

const templateOutput = path.join(corpus, "notes", "plugin-note.org2");
const templatePreview = JSON.parse(cli([
  "plugin", "template", "example.cards:note", "--out", "notes/plugin-note.org2", "--dir", corpus, "--json",
]).stdout);
assert.equal(templatePreview.applied, false);
assert.equal(fs.existsSync(templateOutput), false);
cli(["plugin", "template", "example.cards:note", "--out", "notes/plugin-note.org2", "--dir", corpus, "--apply"]);
assert.match(fs.readFileSync(templateOutput, "utf8"), /\* Start here/);

fs.rmSync(storePath, { recursive: true, force: true });
const syncPreview = JSON.parse(cli(["plugin", "sync", "--dir", corpus, "--json"]).stdout);
assert.equal(syncPreview.plugins[0].changed, true);
assert.equal(fs.existsSync(storePath), false);
cli(["plugin", "sync", "--dir", corpus, "--apply"]);
assert.equal(fs.existsSync(path.join(storePath, "org2-plugin.json")), true);

const healthy = JSON.parse(cli(["plugin", "doctor", "--dir", corpus, "--json"]).stdout);
assert.equal(healthy.ok, true);
assert.deepEqual(healthy.issues, []);

fs.appendFileSync(path.join(pluginRepository, "templates", "note.org2"), "\nPlugin version two.\n");
git(["add", "."]);
git(["-c", "user.name=Org2 Test", "-c", "user.email=org2@example.invalid", "commit", "-q", "-m", "Update plugin"]);
const nextRevision = git(["rev-parse", "HEAD"]);
const updated = JSON.parse(cli(["plugin", "update", "example.cards", "--dir", corpus, "--trust", "--apply", "--json"]).stdout);
assert.equal(updated.plugins[0].revision, nextRevision);
assert.notEqual(updated.plugins[0].contentHash, contentHash);
const updatedList = JSON.parse(cli(["plugin", "list", "--dir", corpus, "--json"]).stdout);
assert.equal(updatedList.plugins[0].trusted, true);

const revokePreview = JSON.parse(cli(["plugin", "trust", "example.cards", "--revoke", "--dir", corpus, "--json"]).stdout);
assert.equal(revokePreview.applied, false);
assert.equal(revokePreview.revoked, true);
cli(["plugin", "trust", "example.cards", "--revoke", "--dir", corpus, "--apply"]);
assert.equal(JSON.parse(cli(["plugin", "list", "--dir", corpus, "--json"]).stdout).plugins[0].trusted, false);

fs.symlinkSync("org2-plugin.json", path.join(pluginRepository, "manifest-link.json"));
git(["add", "."]);
git(["-c", "user.name=Org2 Test", "-c", "user.email=org2@example.invalid", "commit", "-q", "-m", "Add forbidden symlink"]);
const unsafeUpdate = cli(["plugin", "update", "example.cards", "--dir", corpus, "--apply"], { allowFailure: true });
assert.notEqual(unsafeUpdate.status, 0);
assert.match(unsafeUpdate.stderr, /may not contain links or submodules/);

const removePreview = JSON.parse(cli(["plugin", "remove", "example.cards", "--dir", corpus, "--json"]).stdout);
assert.equal(removePreview.applied, false);
assert.equal(JSON.parse(fs.readFileSync(path.join(corpus, "org2.plugins.lock.json"), "utf8")).plugins.length, 1);
cli(["plugin", "remove", "example.cards", "--dir", corpus, "--apply"]);
assert.equal(JSON.parse(fs.readFileSync(path.join(corpus, "org2.plugins.lock.json"), "utf8")).plugins.length, 0);
assert.equal(JSON.parse(fs.readFileSync(path.join(corpus, "org2.json"), "utf8")).plugins, undefined);

const chessInvocation = {
  $schema: "org2:plugin-invocation:v1",
  kind: "render",
  block: {
    language: "pgn",
    body: `[Event "Immortal Game"]\n[White "Adolf Anderssen"]\n[Black "Lionel Kieseritzky"]\n\n1. e4 e5 2. f4 exf4 3. Bc4 Qh4+`,
  },
};
const chessResult = JSON.parse(run("node", ["examples/plugins/chess-pgn/render-pgn.mjs"], {
  input: JSON.stringify(chessInvocation),
}).stdout);
assert.equal(chessResult.$schema, "org2:plugin-render-result:v1");
assert.match(chessResult.html, /Immortal Game/);
assert.match(chessResult.script, /const positions=/);
fs.rmSync(root, { recursive: true, force: true });

console.log("✓ plugin runtime");
