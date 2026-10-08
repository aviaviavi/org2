import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { includesMarker, markerValue, methodNames, schemaMatches } from "../lib/brand.js";
import { durableRunMarker, workflowExecutionPrompt, workflowMarker } from "../lib/lifecycle.js";

test("reads CELORGA_ prompt markers before ORG2_ markers", () => {
  assert.equal(markerValue("ORG2_SELECTED_AGENT_REF: legacy", "SELECTED_AGENT_REF"), "legacy");
  assert.equal(markerValue("CELORGA_SELECTED_AGENT_REF: modern", "SELECTED_AGENT_REF"), "modern");
  assert.equal(markerValue("ORG2_SELECTED_AGENT_REF: legacy\nCELORGA_SELECTED_AGENT_REF: modern", "ORG2_SELECTED_AGENT_REF"), "modern");
  assert.equal(markerValue("NOT_ORG2_SELECTED_AGENT_REF: x", "SELECTED_AGENT_REF"), undefined);
  assert.equal(includesMarker("Managed.\nCELORGA_WORKFLOW_ID: weekly", "WORKFLOW_ID", "weekly"), true);
  assert.equal(includesMarker("Managed.\nORG2_WORKFLOW_ID: weekly", "WORKFLOW_ID", "weekly"), true);
  assert.equal(includesMarker("Managed.", "WORKFLOW_ID", "weekly"), false);
});

test("lifecycle markers accept Celorga spellings and keep writing legacy ones", () => {
  assert.equal(durableRunMarker("Do the work.\nCELORGA_RUN_ID: run-7\n"), "run-7");
  assert.equal(durableRunMarker("CELORGA_WORKFLOW_RUN_ID: workflow-run-7"), undefined);
  assert.deepEqual(workflowMarker([
    "CELORGA_WORKFLOW_ID: weekly-review",
    "CELORGA_WORKFLOW_RUN_ID: run-42",
    "CELORGA_WORKFLOW_RUN_STARTED: true",
    "CELORGA_WORKFLOW_TRIGGER_ID: schedule",
    'CELORGA_WORKFLOW_INPUTS: {"week":"2026-W41"}',
  ].join("\n")), {
    workflowId: "weekly-review",
    workflowRunId: "run-42",
    workflowRunStarted: true,
    triggerId: "schedule",
    inputs: { week: "2026-W41" },
  });

  const prompt = workflowExecutionPrompt({ id: "weekly-review", version: "1", title: "Weekly review" }, {}, "run-42");
  assert.match(prompt, /^ORG2_WORKFLOW_ID: weekly-review$/m);
  assert.doesNotMatch(prompt, /^CELORGA_/m);
  assert.match(prompt, /Celorga workflow/);
});

test("gateway methods and node commands have celorga and org2 names", () => {
  assert.deepEqual(methodNames("org2.workflow.sync"), ["celorga.workflow.sync", "org2.workflow.sync"]);
  assert.deepEqual(methodNames("celorga.workflow.sync"), ["celorga.workflow.sync", "org2.workflow.sync"]);
  assert.equal(schemaMatches("celorga:workflow-run-skipped:v1", "org2:workflow-run-skipped:v1"), true);
  assert.equal(schemaMatches("org2:workflow-run-skipped:v1", "org2:workflow-run-skipped:v1"), true);
  assert.equal(schemaMatches("org2:workflow-run:v1", "org2:workflow-run-skipped:v1"), false);
});

test("plugin entry registers every gateway method under both names", async () => {
  const source = await readFile(new URL("../index.js", import.meta.url), "utf8");
  assert.equal(/api\.registerGatewayMethod\("org2\./.test(source), false);
  const names = [...source.matchAll(/registerGatewayMethod\("([^"]+)"/g)].map((match) => match[1]);
  assert.ok(names.length >= 8);
  for (const name of names) assert.match(name, /^celorga\./);
  assert.match(source, /for \(const alias of methodNames\(name\)\) api\.registerGatewayMethod\(alias, handler, options\)/);
});
