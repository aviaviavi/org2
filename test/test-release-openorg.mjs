import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  TESTFLIGHT,
  appStoreConnectAuthenticationArguments,
  buildReleasePlan,
  parseReleaseOptions,
  resolveReleaseVersion,
  runCheckpointedStep,
  releaseBuildCacheRoot,
  validationJobs,
  withRetry,
  SWIFT_TIMING_TESTS,
  failedSwiftTests,
  swiftTimingJob,
  reusableMacArtifact,
  reusableIOSArchive,
  testFlightReviewAttributes,
} from "../tools/release-openorg.mjs";

import { notarizationAuthentication } from "../tools/openorg-notarization.mjs";

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
  ["Docs", "Node/full", "VS Code", "Swift"]
);
assert.equal(plan.phases.find((phase) => phase.name === "validate").overlapsWith, "package");
assert.equal(plan.phases.find((phase) => phase.name === "package").after, "Build shared runtime");
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
// Swift, Node, docs, and VS Code validation run concurrently; the Node suite
// uses the parallel runner; Swift builds reuse persistent per-arch caches.
const jobs = validationJobs({ artifactsDir: "/tmp/r", buildCache: "/cache" }, "fp", 8);
assert.deepEqual(jobs.map((job) => job.key), ["docs", "node", "vscode", "swift"]);
const nodeJob = jobs.find((job) => job.key === "node");
assert.deepEqual(nodeJob.args.slice(0, 4), ["tools/run-tests-parallel.mjs", "test:built", "--jobs", "4"]);
assert.equal(validationJobs({ artifactsDir: "/tmp/r", buildCache: "/cache" }, "fp", 2)
  .find((job) => job.key === "node").args[3], "2");
const swiftJob = jobs.find((job) => job.key === "swift");
assert.deepEqual(swiftJob.args.slice(0, 3), ["-arm64", "swift", "test"]);
assert.equal(swiftJob.args[swiftJob.args.indexOf("--scratch-path") + 1], "/cache/swift-tests-arm64");
assert.equal(swiftJob.args[swiftJob.args.indexOf("--skip") + 1], SWIFT_TIMING_TESTS);
assert.deepEqual(failedSwiftTests([
  "Test Case '-[Mod.ATests testFast]' passed (0.1 seconds).",
  "Test Case '-[Mod.BTests testBudget]' failed (0.5 seconds).",
  "Test Case '-[Mod.BTests testBudget]' failed (0.5 seconds).",
  "Test Case '-[Other.CTests testX]' failed (1.0 seconds).",
].join("\n")), ["Mod.BTests/testBudget", "Other.CTests/testX"]);
const retryJob = swiftTimingJob({ buildCache: "/cache" }, ["Mod.BTests/testBudget"]);
assert.equal(retryJob.args[retryJob.args.indexOf("--filter") + 1], `${SWIFT_TIMING_TESTS}|Mod\\.BTests/testBudget$`);
const timingJob = swiftTimingJob({ buildCache: "/cache" });
assert.equal(timingJob.args[timingJob.args.indexOf("--filter") + 1], SWIFT_TIMING_TESTS);
assert.equal(timingJob.args[timingJob.args.indexOf("--scratch-path") + 1], "/cache/swift-tests-arm64",
  "the timing lane reuses the correctness lane's warm build");
assert.ok(releaseSource.indexOf("swiftTimingJob(plan, isolatedRetries)", releaseSource.indexOf("async function validate("))
  > releaseSource.indexOf("await runParallel(validationJobs", releaseSource.indexOf("async function validate(")),
  "timing tests run only after the concurrent validation lanes finish");
assert.equal(releaseBuildCacheRoot({ OPENORG_RELEASE_BUILD_CACHE: " /x/cache " }), "/x/cache");
assert.match(releaseBuildCacheRoot({}), /Library\/Caches\/OpenOrg\/release-build$/);
assert.match(releaseSource, /"--swift-scratch-path", join\(plan\.buildCache, "swift-release-arm64"\)/);
assert.match(releaseSource, /"--swift-scratch-path", join\(plan\.buildCache, "swift-release-x86_64"\)/);
// Packaging overlaps validation only after the shared runtime build.
const overlap = releaseSource.slice(releaseSource.indexOf("async function executePlan"));
assert.ok(overlap.indexOf("await buildSharedRuntime(plan, state);")
  < overlap.indexOf('runPhase(plan, options, state, "package", packageArtifacts)'));
// DMG uploads and the TestFlight upload are individually checkpointed.
assert.match(releaseSource, /`upload-\$\{artifact\}`/);
assert.match(releaseSource, /"testflight-upload"/);
{
  let calls = 0;
  const waits = [];
  const value = await withRetry("flaky upload", 4, async () => {
    calls += 1;
    if (calls < 3) throw new Error("HTTP 500");
    return "uploaded";
  }, { delayMs: 10, sleep: async (ms) => { waits.push(ms); } });
  assert.equal(value, "uploaded");
  assert.deepEqual(waits, [10, 20]);
  await assert.rejects(
    withRetry("dead upload", 2, async () => { throw new Error("HTTP 400"); }, { delayMs: 1, sleep: async () => {} }),
    /HTTP 400/,
  );
}
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
  assert.equal(notarizationAuthentication("", {}), null);
  assert.deepEqual(notarizationAuthentication(" Existing Profile ", {}).args, ["--keychain-profile", "Existing Profile"]);
  assert.throws(() => notarizationAuthentication("Existing Profile", { OPENORG_NOTARY_KEY_ID: "test-key" }), /requires/);
  assert.throws(() => notarizationAuthentication("", { OPENORG_NOTARY_KEY_ID: "test-key", OPENORG_NOTARY_PRIVATE_KEY_PATH: join(checkpointDirectory, "missing.p8") }), /existing protected key file/);
  const privateKeyReference = join(checkpointDirectory, "synthetic-key.p8");
  writeFileSync(privateKeyReference, "synthetic fixture; no provider credential", { mode: 0o600 });
  const apiEnvironment = { OPENORG_NOTARY_KEY_ID: "test-key", OPENORG_NOTARY_PRIVATE_KEY_PATH: privateKeyReference, OPENORG_NOTARY_ISSUER_ID: "test-issuer" };
  assert.deepEqual(notarizationAuthentication("Existing Profile", apiEnvironment).args,
    ["--key", privateKeyReference, "--key-id", "test-key", "--issuer", "test-issuer"]);
  delete apiEnvironment.OPENORG_NOTARY_ISSUER_ID;
  assert.deepEqual(notarizationAuthentication("", apiEnvironment).args,
    ["--key", privateKeyReference, "--key-id", "test-key"]);
  assert.deepEqual(appStoreConnectAuthenticationArguments({}), []);
  assert.throws(() => appStoreConnectAuthenticationArguments({ OPENORG_ASC_KEY_ID: "test-key" }), /PRIVATE_KEY_PATH is required/);
  assert.deepEqual(appStoreConnectAuthenticationArguments({ OPENORG_ASC_PRIVATE_KEY_PATH: privateKeyReference, OPENORG_ASC_KEY_ID: "test-key", OPENORG_ASC_ISSUER_ID: "test-issuer" }),
    ["-authenticationKeyPath", privateKeyReference, "-authenticationKeyID", "test-key", "-authenticationKeyIssuerID", "test-issuer"]);

  const archive = join(checkpointDirectory, "test.xcarchive");
  const archiveApp = join(archive, "Products", "Applications", "OpenOrg.app");
  mkdirSync(archiveApp, { recursive: true });
  writeFileSync(join(archiveApp, "Info.plist"), "synthetic app metadata");
  const archiveProperties = { CFBundleShortVersionString: "0.8.0", CFBundleVersion: "28", ApplicationPath: "Applications/OpenOrg.app" };
  let validSignature = true;
  const archiveCapture = (command, args) => {
    if (command === "codesign") {
      assert.equal(args.at(-1), archiveApp);
      return { ok: validSignature };
    }
    // An archive's CreationDate cannot be converted to JSON; read string fields directly.
    assert.equal(command, "plutil");
    assert.equal(args[0], "-extract");
    assert.equal(args[2], "raw");
    return { stdout: archiveProperties[args[1].replace("ApplicationProperties.", "")] };
  };
  assert.equal(reusableIOSArchive(archive, "0.8.0", 28, archiveCapture), true);
  assert.equal(reusableIOSArchive(archive, "0.8.1", 28, archiveCapture), false);
  assert.equal(reusableIOSArchive(archive, "0.8.0", 29, archiveCapture), false);
  validSignature = false;
  assert.equal(reusableIOSArchive(archive, "0.8.0", 28, archiveCapture), false);
  const checkpointPlan = { checkpoints: join(checkpointDirectory, "state.json") };
  const checkpointState = { completed: {}, stepCheckpoints: {} };
  const artifact = join(checkpointDirectory, "OpenOrg.dmg");
  writeFileSync(artifact, "verified candidate");
  const metadata = { version: "0.8.0", architecture: "arm64", notarized: true,
    sha256: createHash("sha256").update(readFileSync(artifact)).digest("hex") };
  writeFileSync(join(checkpointDirectory, "OpenOrg.json"), JSON.stringify(metadata));
  assert.equal(reusableMacArtifact(artifact, "0.8.0", "arm64"), true);
  assert.equal(reusableMacArtifact(artifact, "0.8.0", "x86_64"), false);
  assert.equal(reusableMacArtifact(artifact, "0.7.2", "arm64"), false);
  writeFileSync(artifact, "damaged candidate");
  assert.equal(reusableMacArtifact(artifact, "0.8.0", "arm64"), false);
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
  await runCheckpointedStep(
    checkpointPlan, checkpointState, "package", "tree-b", "arm64", "Arm DMG", execute,
  );
  await assert.rejects(runCheckpointedStep(
    checkpointPlan, checkpointState, "package", "tree-b", "intel", "Intel DMG", async () => { throw new Error("notarization unavailable"); },
  ), /notarization unavailable/);
  await runCheckpointedStep(
    checkpointPlan, checkpointState, "package", "tree-b", "arm64", "Arm DMG", execute,
  );
  assert.equal(executions, 3, "retrying a failed sibling must retain successful packaging");
  await runCheckpointedStep(
    checkpointPlan, checkpointState, "package", "tree-b", "arm64", "Arm DMG", execute, () => false,
  );
  assert.equal(executions, 4, "missing or corrupt output must invalidate its successful checkpoint");
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
