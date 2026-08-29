import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  TESTFLIGHT,
  buildReleasePlan,
  parseReleaseOptions,
  resolveReleaseVersion,
  testFlightReviewAttributes,
} from "../tools/release-openorg.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

assert.equal(resolveReleaseVersion("patch", "0.5.2"), "0.5.3");
assert.equal(resolveReleaseVersion("minor", "0.5.2"), "0.6.0");
assert.equal(resolveReleaseVersion("major", "0.5.2"), "1.0.0");
assert.equal(resolveReleaseVersion("0.5.7", "0.5.2"), "0.5.7");
assert.throws(() => resolveReleaseVersion("banana", "0.5.2"), /exact SemVer/);

const options = parseReleaseOptions([
  "patch",
  "--ios-build", "25",
  "--notes", "/tmp/openorg-notes.md",
]);
const plan = buildReleasePlan(options, "0.5.2");
assert.equal(plan.version, "0.5.3");
assert.equal(plan.execute, false);
assert.equal(plan.ios.build, 25);
assert.deepEqual(plan.ios.groups, ["Org2 Internal", "OpenOrg Alpha"]);
assert.equal(plan.safeDefaults.dailyMacAppUntouched, true);
assert.equal(plan.safeDefaults.failClosedOnDirtyTree, true);
assert.equal(plan.safeDefaults.notarizationRequired, true);
assert.deepEqual(
  plan.phases.find((phase) => phase.name === "validate").parallel,
  ["Node/full", "VS Code", "Swift/serial"]
);
assert.deepEqual(
  plan.phases.find((phase) => phase.name === "package").parallel,
  ["OpenOrg arm64 DMG", "OpenOrg Intel DMG", "iOS archive"]
);
assert.equal(TESTFLIGHT.internalGroupId, "f7462891-5b0e-4ccf-a3bc-2c2ea2f2540d");
assert.equal(TESTFLIGHT.externalGroupId, "566e8d38-3c80-442c-8b9a-4f7916181149");
assert.deepEqual(testFlightReviewAttributes(), {
  demoAccountRequired: false,
  notes: TESTFLIGHT.reviewNotes,
});
assert.match(TESTFLIGHT.reviewNotes, /no account system and does not require sign-in/);
assert.match(TESTFLIGHT.reviewNotes, /locally installed OpenOrg macOS companion/);

const releaseSource = readFileSync(join(repoRoot, "tools", "release-openorg.mjs"), "utf8");
assert.ok(
  releaseSource.indexOf("await updateBetaReviewDetails();") < releaseSource.indexOf("await submitBetaReview(build.id);")
);

const planResult = spawnSync(process.execPath, [
  join(repoRoot, "tools", "release-openorg.mjs"),
  "patch",
  "--ios-build", "25",
  "--notes", "/tmp/openorg-notes.md",
], {
  cwd: repoRoot,
  encoding: "utf8",
});
assert.equal(planResult.status, 0, planResult.stderr);
assert.match(planResult.stdout, /"execute": false/);
assert.match(planResult.stdout, /Read-only plan/);

const throughPlan = buildReleasePlan(parseReleaseOptions([
  "patch", "--through", "validate", "--skip-ios",
]), "0.5.2");
assert.deepEqual(throughPlan.phases.map((phase) => phase.name), ["preflight", "stamp", "validate"]);
assert.equal(throughPlan.ios, null);

console.log("OpenOrg release orchestrator tests passed");
