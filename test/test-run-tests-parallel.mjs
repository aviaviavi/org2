import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { expandScript, partitionLeaves } from "../tools/run-tests-parallel.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const scripts = {
  all: "npm run a && node test/x.mjs && npm run b",
  a: "node test/a.mjs && node test/test-cli-performance.mjs",
  b: "npm --prefix integrations/openclaw test && node test/x.mjs",
  loop: "npm run loop",
};
assert.deepEqual(expandScript(scripts, "all"), [
  "node test/a.mjs",
  "node test/test-cli-performance.mjs",
  "node test/x.mjs",
  "npm --prefix integrations/openclaw test",
], "npm run references expand recursively and duplicate leaves run once");
assert.throws(() => expandScript(scripts, "loop"), /Recursive/);
assert.throws(() => expandScript(scripts, "missing"), /Unknown npm script/);

const { parallel, serial } = partitionLeaves([
  "node test/a.mjs",
  "node test/test-workspace-agent-state.mjs --performance",
  "node test/test-cli-startup.mjs",
  "node tools/cli-test-runner.mjs",
]);
assert.deepEqual(serial, [
  "node test/test-workspace-agent-state.mjs --performance",
  "node test/test-cli-startup.mjs",
], "wall-clock budget tests run alone after the pool");
assert.deepEqual(parallel, ["node tools/cli-test-runner.mjs", "node test/a.mjs"], "known slow leaves start first");

// Every test in the canonical serial chain is still covered by the runner.
const real = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).scripts;
const leaves = expandScript(real, "test:built");
const split = partitionLeaves(leaves);
assert.equal(split.parallel.length + split.serial.length, leaves.length);
assert.ok(leaves.includes("node test/test-release-openorg.mjs"));
assert.ok(leaves.includes("node test/test-run-tests-parallel.mjs"));
assert.ok(split.serial.includes("node test/test-cli-performance.mjs"));

console.log("parallel test runner tests passed");
