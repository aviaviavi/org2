#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";

function run(args) {
  return spawnSync("node", ["dist/cli.js", ...args], {
    encoding: "utf8",
  });
}

const valid = run(["ai", "validate-job", "--job", "examples/jobs/weekly-summary.org2-ai.json", "--format", "json"]);
assert.equal(valid.status, 0, valid.stderr || valid.stdout);
const validJson = JSON.parse(valid.stdout);
assert.equal(validJson.$schema, "org2:ai-job-validation:v1");
assert.equal(validJson.valid, true);
assert.deepEqual(validJson.issues, []);

const invalid = run(["ai", "validate-job", "--job", "spec/v0/fixtures/ai-job-manifest.invalid-secret.json", "--format", "json"]);
assert.equal(invalid.status, 1, invalid.stderr || invalid.stdout);
const invalidJson = JSON.parse(invalid.stdout);
assert.equal(invalidJson.valid, false);
assert.ok(
  invalidJson.issues.some((issue) => issue.path === "$.adapter.apiKey" && /provider secrets/.test(issue.message)),
  `expected secret-key validation issue, got ${JSON.stringify(invalidJson.issues, null, 2)}`,
);
assert.ok(
  invalidJson.issues.some((issue) => issue.path === "$.adapter.apiKey" && /inline provider secrets/.test(issue.message)),
  `expected secret-value validation issue, got ${JSON.stringify(invalidJson.issues, null, 2)}`,
);

const missingJob = run(["ai", "validate-job"]);
assert.equal(missingJob.status, 1);
assert.match(missingJob.stderr, /requires --job FILE/);

const missingRunJob = run(["ai", "run"]);
assert.equal(missingRunJob.status, 1);
assert.match(missingRunJob.stderr, /requires --job FILE/);

console.log("AI job manifest validation tests passed");
