import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { PassThrough } from "node:stream";
import {
  brandEnv,
  brandProperty,
  brandPropertyKey,
  celorgaToolName,
  configFileIn,
  configFilePath,
  isBrandName,
  legacyToolName,
  mirrorCelorgaEnvironment,
  nameAliases,
  schemaMatches,
  stateDir,
  withNameAliases,
} from "../dist/brandNames.js";
import { findConfigFile } from "../dist/config.js";
import { lintArtifactMetadataInText } from "../dist/artifactLint.js";
import { compileCorpus } from "../dist/corpusCompile.js";
import { buildAgentContextPayload } from "../dist/agentContext.js";
import { updateArtifactReviewStatusInText } from "../dist/artifactMetadata.js";
import { createGoal, parseGoalOrg, renderGoalOrg } from "../dist/coordination.js";
import { agentRunDirectory } from "../dist/agentRun.js";
import { serveMcp } from "../dist/mcpRuntime.js";
import { upsertHeadlinePropertyInLines } from "../dist/sourceLines.js";
import { resolveEmailPassword } from "../dist/emailSource.js";

// Helpers.
assert.deepEqual(nameAliases("ORG2_REVIEW_STATUS"), ["CELORGA_REVIEW_STATUS", "ORG2_REVIEW_STATUS"]);
assert.deepEqual(nameAliases("CELORGA_KIND"), ["CELORGA_KIND", "ORG2_KIND"]);
assert.deepEqual(nameAliases("TITLE"), ["TITLE"]);
assert.deepEqual(withNameAliases(["OWNER", "ORG2_OWNER"]), ["OWNER", "CELORGA_OWNER", "ORG2_OWNER"]);
assert.equal(brandProperty(new Map([["ORG2_X", "old"], ["CELORGA_X", "new"]]), "ORG2_X"), "new");
assert.equal(brandProperty({ ORG2_X: "old", CELORGA_X: " " }, "ORG2_X"), "old");
assert.equal(brandProperty({ ORG2_X: "old" }, "CELORGA_X"), "old");
assert.equal(brandPropertyKey({ CELORGA_X: "a" }, "ORG2_X"), "CELORGA_X");
assert.equal(brandPropertyKey({}, "ORG2_X"), undefined);
assert.equal(isBrandName("CELORGA_RELATION", "ORG2_RELATION"), true);
assert.equal(isBrandName("OTHER_RELATION", "ORG2_RELATION"), false);
assert.equal(schemaMatches("celorga:agent-run:v1", "org2:agent-run:v1"), true);
assert.equal(schemaMatches("org2:agent-run:v1", "org2:agent-run:v1"), true);
assert.equal(schemaMatches("other:agent-run:v1", "org2:agent-run:v1"), false);
assert.equal(legacyToolName("celorga_search"), "org2_search");
assert.equal(celorgaToolName("org2_search"), "celorga_search");
assert.equal(brandEnv("ORG2_X", { ORG2_X: "old", CELORGA_X: "new" }), "new");
assert.equal(brandEnv("ORG2_X", { ORG2_X: "old" }), "old");
const mirrored = { CELORGA_TODAY: "2026-01-02", CELORGA_KEEP: "new", ORG2_KEEP: "legacy" };
mirrorCelorgaEnvironment(mirrored);
assert.equal(mirrored.ORG2_TODAY, "2026-01-02");
assert.equal(mirrored.ORG2_KEEP, "legacy");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-brand-names-"));
try {
  // Config file: new corpora get celorga.json, an existing org2.json keeps being
  // edited in place, and celorga.json wins when both exist.
  const nested = path.join(root, "notes", "deep");
  fs.mkdirSync(nested, { recursive: true });
  assert.equal(configFilePath(root), path.join(root, "celorga.json"));
  fs.writeFileSync(path.join(nested, "org2.json"), JSON.stringify({}));
  assert.equal(configFilePath(nested), path.join(nested, "org2.json"));
  fs.rmSync(path.join(nested, "org2.json"));
  fs.writeFileSync(path.join(root, "celorga.json"), JSON.stringify({ include: ["**/*.org"] }));
  assert.equal(findConfigFile(nested), path.join(root, "celorga.json"));
  assert.equal(configFileIn(root), path.join(root, "celorga.json"));
  fs.writeFileSync(path.join(root, "org2.json"), JSON.stringify({}));
  assert.equal(findConfigFile(nested), path.join(root, "celorga.json"));
  assert.equal(configFilePath(root), path.join(root, "celorga.json"));

  // State directory: .org2/ until a corpus has .celorga/.
  assert.equal(agentRunDirectory(root), path.join(root, ".org2", "runs"));
  fs.mkdirSync(path.join(root, ".celorga"));
  assert.equal(stateDir(root, "runs"), path.join(root, ".celorga", "runs"));
  assert.equal(agentRunDirectory(root), path.join(root, ".celorga", "runs"));

  // Artifact lint honours CELORGA_ properties.
  const generated = [
    ":PROPERTIES:",
    ":ID: brand-artifact",
    ":CELORGA_ARTIFACT_ROLE: compiled",
    ":CELORGA_PROVENANCE: file:notes/source.org",
    ":CELORGA_GENERATED_AT: 2026-10-08",
    ":CELORGA_GENERATOR: test",
    ":CELORGA_REVIEW_STATUS: bogus-status",
    ":END:",
    "#+TITLE: Brand artifact",
    "",
  ].join("\n");
  const issues = lintArtifactMetadataInText(generated, "compiled/brand.org");
  assert.ok(issues.some((issue) => /Invalid ORG2_REVIEW_STATUS 'bogus-status'/.test(issue.message)), JSON.stringify(issues));
  assert.ok(!issues.some((issue) => /must set ORG2_PROVENANCE/.test(issue.message)));
  const reviewed = generated.replace("bogus-status", "reviewed").replace(":CELORGA_PROVENANCE:", ":CELORGA_CLAIM_STATE: source-backed\n:CELORGA_OBSERVED_AT: 2026-10-08\n:CELORGA_PROVENANCE:");
  assert.ok(!lintArtifactMetadataInText(reviewed, "compiled/brand.org").some((issue) => /REVIEW_STATUS/.test(issue.message)));

  // Updating a review status keeps the spelling that is present.
  const updated = updateArtifactReviewStatusInText(generated, "promoted");
  assert.match(updated, /^:CELORGA_REVIEW_STATUS: promoted$/m);
  assert.doesNotMatch(updated, /ORG2_REVIEW_STATUS/);
  assert.match(updateArtifactReviewStatusInText("#+TITLE: New\n", "generated"), /^#\+ORG2_REVIEW_STATUS: generated$/m);
  const lines = ["* Task", ":PROPERTIES:", ":CELORGA_AGENT_HANDOFF_AT: then", ":END:"];
  upsertHeadlinePropertyInLines(lines, 0, "ORG2_AGENT_HANDOFF_AT", "now");
  assert.deepEqual(lines, ["* Task", ":PROPERTIES:", ":CELORGA_AGENT_HANDOFF_AT: now", ":END:"]);
  const fresh = ["* Task"];
  upsertHeadlinePropertyInLines(fresh, 0, "ORG2_AGENT_HANDOFF_AT", "now");
  assert.deepEqual(fresh, ["* Task", ":PROPERTIES:", ":ORG2_AGENT_HANDOFF_AT: now", ":END:"]);

  // Agent context honours CELORGA_ review status and claim state.
  const note = path.join(root, "notes", "claims.org");
  fs.writeFileSync(note, [
    "#+TITLE: Claims",
    "",
    "* Reviewed launch claim",
    ":PROPERTIES:",
    ":ID: reviewed-launch-claim",
    ":CELORGA_REVIEW_STATUS: reviewed",
    ":CELORGA_CLAIM_STATE: source-backed",
    ":CELORGA_OBSERVED_AT: 2026-10-01",
    ":END:",
    "The launch moved to Thursday.",
    "",
    "* Legacy launch claim",
    ":PROPERTIES:",
    ":ID: legacy-launch-claim",
    ":ORG2_REVIEW_STATUS: promoted",
    ":END:",
    "The launch checklist is complete.",
    "",
  ].join("\n"));
  const corpus = compileCorpus([note], { rootDir: root });
  const payload = buildAgentContextPayload(corpus, { action: "search", query: "launch", limit: 10 });
  const byId = new Map(payload.results.map((node) => [node.id, node]));
  assert.equal(byId.get("reviewed-launch-claim")?.claimState.reviewStatus, "reviewed");
  assert.equal(byId.get("reviewed-launch-claim")?.claimState.claimState, "source-backed");
  assert.equal(byId.get("reviewed-launch-claim")?.claimState.observedAt, "2026-10-01");
  assert.equal(byId.get("legacy-launch-claim")?.claimState.reviewStatus, "promoted");

  // celorga: record types are accepted; writers keep org2:.
  const goal = createGoal({ id: "brand-goal", title: "Brand goal" });
  assert.equal(goal.schema, "org2:goal:v1");
  const rendered = renderGoalOrg(goal);
  assert.match(rendered, /"schema": "org2:goal:v1"/);
  const parsed = parseGoalOrg(rendered.replace('"schema": "org2:goal:v1"', '"schema": "celorga:goal:v1"'));
  assert.equal(parsed.id, "brand-goal");
  assert.throws(() => parseGoalOrg(rendered.replace('"schema": "org2:goal:v1"', '"schema": "other:goal:v1"')), /goal schema must be/);

  // MCP: celorga_X is advertised; celorga_X and org2_X both work.
  const input = new PassThrough();
  const output = new PassThrough();
  let response = "";
  output.setEncoding("utf8");
  output.on("data", (chunk) => { response += chunk; });
  const serving = serveMcp(root, input, output);
  input.end([
    { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "celorga_search", arguments: { query: "launch" } } },
    { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "org2_search", arguments: { query: "launch" } } },
    { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "celorga_run_list", arguments: {} } },
  ].map((message) => JSON.stringify(message)).join("\n") + "\n");
  await serving;
  const messages = response.trim().split("\n").map((line) => JSON.parse(line));
  const names = messages[0].result.tools.map((tool) => tool.name);
  assert.ok(names.includes("celorga_search") && names.includes("celorga_thread_post"));
  assert.ok(names.every((name) => name.startsWith("celorga_")), names.join(", "));
  for (const message of messages.slice(1)) assert.equal(message.error, undefined, JSON.stringify(message.error));
  assert.equal(messages[1].result.structuredContent.results.length > 0, true);
  assert.deepEqual(messages[1].result.structuredContent.results.map((item) => item.id), messages[2].result.structuredContent.results.map((item) => item.id));

  // Environment: CELORGA_X wins, both in-process and through the CLI.
  assert.equal(resolveEmailPassword({}, { CELORGA_EMAIL_PASSWORD: "new", ORG2_EMAIL_PASSWORD: "old" }).password, "new");
  assert.equal(resolveEmailPassword({}, { ORG2_EMAIL_PASSWORD: "old" }).password, "old");
  const env = { ...process.env, CELORGA_TODAY: "2031-02-03" };
  delete env.ORG2_TODAY;
  const brief = spawnSync(process.execPath, [path.resolve("dist/cli.js"), "brief", "today", "--dir", path.join(root, "notes"), "--format", "json"], { encoding: "utf8", env });
  assert.equal(brief.status, 0, brief.stderr);
  assert.match(brief.stdout, /2031-02-03/);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

// Plugin manifests, AI job manifests and chart styles accept the Celorga spellings.
{
  const { loadPluginManifest, assertPluginEngineCompatible } = await import("../dist/pluginRuntime.js");
  const { validateAiJobManifest } = await import("../dist/aiJobManifest.js");
  const pluginRoot = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-plugin-"));
  const manifest = { $schema: "celorga:plugin-manifest:v1", id: "example.celorga", name: "Example", version: "1.0.0", engines: { celorga: ">=0.0.1" } };
  fs.writeFileSync(path.join(pluginRoot, "celorga-plugin.json"), JSON.stringify(manifest));
  const loaded = loadPluginManifest(pluginRoot);
  assert.equal(loaded.engines?.org2, ">=0.0.1");
  assert.doesNotThrow(() => assertPluginEngineCompatible(loaded, "0.9.0"));
  fs.rmSync(path.join(pluginRoot, "celorga-plugin.json"));
  fs.writeFileSync(path.join(pluginRoot, "org2-plugin.json"), JSON.stringify({ ...manifest, engines: { org2: ">=0.0.1" } }));
  assert.equal(loadPluginManifest(pluginRoot).id, "example.celorga");
  fs.rmSync(pluginRoot, { recursive: true, force: true });

  for (const schemaVersion of ["celorga-ai-job/v1", "org2-ai-job/v1"]) {
    const result = validateAiJobManifest({ schemaVersion });
    assert.ok(!result.issues.some((issue) => issue.path === "$.schemaVersion"), schemaVersion);
  }
  assert.ok(validateAiJobManifest({ schemaVersion: "other/v1" }).issues.some((issue) => issue.path === "$.schemaVersion"));

  const chartSource = fs.readFileSync(new URL("../dist/chartRender.js", import.meta.url), "utf8");
  assert.match(chartSource, /var\(--celorga-chart-mark, var\(--org2-chart-mark, #2563eb\)\)/);
}

console.log("brand names: ok");
