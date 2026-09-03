import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  TESTFLIGHT,
  buildReleasePlan,
  parseReleaseOptions,
  resolveReleaseVersion,
  runCheckpointedStep,
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
  ["Docs", "Node/full", "VS Code"]
);
assert.deepEqual(
  plan.phases.find((phase) => phase.name === "validate").then,
  ["Swift/serial"]
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
  releaseSource.indexOf('"swift", "Swift suite serial"')
    > releaseSource.indexOf('await runParallel([', releaseSource.indexOf("async function validate"))
);
assert.match(releaseSource, /--scratch-path[\s\S]+swift-tests/);
assert.match(releaseSource, /"-arm64", "swift"/);
assert.ok(
  releaseSource.indexOf("await updateBetaReviewDetails();") < releaseSource.indexOf("await submitBetaReview(build.id);")
);
assert.ok(
  releaseSource.indexOf("await generateSparkleAppcasts(plan, options);")
    < releaseSource.indexOf("await waitForGitHubWorkflow(plan);")
);
assert.match(releaseSource, /appcast-arm64\.xml/);
assert.match(releaseSource, /appcast-intel\.xml/);
assert.match(releaseSource, /VS Code Marketplace has not exposed.*catalog propagation is a non-blocking follow-up/);
assert.doesNotMatch(releaseSource, /pollUntil\("VS Code Marketplace public version"/);
assert.match(releaseSource, /--require-google-oauth-client/);
assert.match(releaseSource, /docs:check:built/);
assert.match(releaseSource, /test:built/);
assert.match(releaseSource, /check:generated:built/);
assert.match(releaseSource, /"npm registry reachability", "npm", \["ping"\]/);
assert.doesNotMatch(releaseSource, /"npm authentication", "npm", \["whoami"\]/);

const checkpointDirectory = mkdtempSync(join(tmpdir(), "openorg-release-checkpoint-test-"));
try {
  const checkpointPlan = { checkpoints: join(checkpointDirectory, "state.json") };
  const checkpointState = { completed: {}, stepCheckpoints: {} };
  let executions = 0;
  const execute = async () => { executions += 1; };
  const first = await runCheckpointedStep(
    checkpointPlan, checkpointState, "validate", "tree-a", "node", "Node full suite", execute,
  );
  const resumed = await runCheckpointedStep(
    checkpointPlan, checkpointState, "validate", "tree-a", "node", "Node full suite", execute,
  );
  assert.equal(first.skipped, false);
  assert.equal(resumed.skipped, true);
  assert.equal(executions, 1, "a successful validation job should not rerun for the same source tree");
  await runCheckpointedStep(
    checkpointPlan, checkpointState, "validate", "tree-b", "node", "Node full suite", execute,
  );
  assert.equal(executions, 2, "a source-tree change should invalidate validation job checkpoints");
} finally {
  rmSync(checkpointDirectory, { force: true, recursive: true });
}

const rootPackage = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8"));
assert.equal(rootPackage.scripts.pretest, "npm run build");
assert.equal(rootPackage.scripts.test, "npm run test:built");
assert.match(rootPackage.scripts["test:built"], /test:prerequisites:built/);
assert.doesNotMatch(rootPackage.scripts["docs:check:built"], /npm run build/);

const releaseWorkflow = readFileSync(join(repoRoot, ".github", "workflows", "release-packages.yml"), "utf8");
assert.match(releaseWorkflow, /name: Build \+ test once[\s\S]{0,200}run: npm test/);
assert.doesNotMatch(releaseWorkflow, /npm run build\s+\n\s*npm test/);
assert.match(releaseWorkflow, /npm publish \.\/\*\.tgz[^\n]+--ignore-scripts/);
assert.match(releaseWorkflow, /publish_only:/);
assert.match(releaseWorkflow, /Publish VS Code Marketplace extension[\s\S]{0,200}continue-on-error: true/);

const macPackageSource = readFileSync(join(repoRoot, "tools", "package-openorg-macos.mjs"), "utf8");
assert.match(macPackageSource, /run\("\/usr\/sbin\/spctl"/);

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
