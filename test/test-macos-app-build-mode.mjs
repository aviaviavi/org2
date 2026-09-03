import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { installStagedAppBundle } from "../tools/atomic-app-bundle.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const updaterSource = readFileSync(join(
  repoRoot,
  "apps", "macos", "Org2Workspace", "Sources", "Org2Workspace", "SoftwareUpdateController.swift"
), "utf8");
const macAppBuildSource = readFileSync(join(repoRoot, "tools", "build-macos-app.mjs"), "utf8");
const makefileSource = readFileSync(join(repoRoot, "Makefile"), "utf8");
const packageJSON = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8"));

assert.match(updaterSource, /checkForUpdatesInBackground\(\)/);
assert.match(updaterSource, /Automatically check for updates/);
assert.match(updaterSource, /Download updates automatically and install on quit/);
assert.match(updaterSource, /skip a version/);
const sharedRuntimeBuildIndex = macAppBuildSource.indexOf('run("npm", ["run", "build"]');
const swiftAppBuildIndex = macAppBuildSource.indexOf('run("swift", swiftBuildArgs("build")');
const runtimeCopyIndex = macAppBuildSource.indexOf("const runtimeNodePath = copyOrg2Runtime(resourcesDir)");
assert.ok(sharedRuntimeBuildIndex >= 0, "macOS app builds must compile the shared runtime");
assert.ok(sharedRuntimeBuildIndex < swiftAppBuildIndex, "shared runtime must build before the Swift app");
assert.ok(sharedRuntimeBuildIndex < runtimeCopyIndex, "shared runtime must build before it is bundled");
const stagedVerificationIndex = macAppBuildSource.indexOf(
  'run("codesign", ["--verify", "--deep", "--strict", stagedAppPath]);'
);
const gracefulQuitIndex = macAppBuildSource.indexOf(
  "quitRunningInstalledApp(installedBinaryPath);"
);
const stagedInstallIndex = macAppBuildSource.indexOf(
  "installStagedAppBundle({ stagedAppPath, targetAppPath: appPath });"
);
assert.ok(stagedVerificationIndex >= 0, "the staged app must be verified before installation");
assert.ok(
  stagedVerificationIndex < gracefulQuitIndex,
  "restart builds must keep the current app running until staged verification finishes"
);
assert.ok(
  gracefulQuitIndex < stagedInstallIndex,
  "restart builds must finish a graceful quit before replacing the app"
);
assert.match(makefileSource, /^macos-app-restart:\n\tnpm run build:macos-app:restart$/m);
assert.equal(
  packageJSON.scripts["build:macos-app:restart"],
  "node tools/build-macos-app.mjs --configuration release --restart"
);

function run(script, args, expectedStatus = 0, environment = process.env) {
  const result = spawnSync(process.execPath, [join(repoRoot, script), ...args], {
    cwd: repoRoot,
    encoding: "utf8",
    env: environment,
  });
  assert.equal(result.status, expectedStatus, result.stderr || result.stdout);
  return result;
}

const noGoogleOAuthEnvironment = { ...process.env };
delete noGoogleOAuthEnvironment.ORG2_GOOGLE_OAUTH_CLIENT_JSON;
delete noGoogleOAuthEnvironment.ORG2_GOOGLE_OAUTH_CLIENT_ID;
delete noGoogleOAuthEnvironment.ORG2_GOOGLE_OAUTH_CLIENT_SECRET;

const defaultDaily = JSON.parse(
  run(
    "tools/build-macos-app.mjs",
    ["--print-configuration"],
    0,
    noGoogleOAuthEnvironment
  ).stdout
);
assert.equal(defaultDaily.bundleIdentifier, "org.org2.workspace");
assert.equal(defaultDaily.configuration, "release");
assert.equal(defaultDaily.appName, "OpenOrg");
assert.match(defaultDaily.appPath, /OpenOrg\.app$/);
assert.match(defaultDaily.iconPath, /OpenOrgAppIcon\.png$/);
assert.equal(defaultDaily.installStrategy, "verified staged replacement");
assert.equal(defaultDaily.restartAfterInstall, false);
assert.ok(defaultDaily.nodeArchitecture === "arm64" || defaultDaily.nodeArchitecture === "x64");
assert.match(
  defaultDaily.nodeEntitlementsPath,
  defaultDaily.nodeArchitecture === "x64"
    ? /OpenOrgNodeIntel\.entitlements$/
    : /OpenOrgNode\.entitlements$/
);
assert.equal(defaultDaily.swiftScratchPath, null);
assert.equal(defaultDaily.updates.enabled, true);
assert.equal(defaultDaily.updates.intervalSeconds, 7200);
assert.match(defaultDaily.updates.feedURL, /appcast-(arm64|intel)\.xml$/);
assert.equal(defaultDaily.googleOAuthClientSource, null);
assert.equal(defaultDaily.googleOAuthRequired, false);

const refusedUnconfiguredDistribution = run(
  "tools/build-macos-app.mjs",
  ["--require-google-oauth-client", "--print-configuration"],
  1,
  noGoogleOAuthEnvironment
);
assert.match(refusedUnconfiguredDistribution.stderr, /requires OpenOrg's Google OAuth Desktop client/);

const refusedIncompleteEnvironmentPair = run(
  "tools/build-macos-app.mjs",
  ["--print-configuration"],
  1,
  {
    ...noGoogleOAuthEnvironment,
    ORG2_GOOGLE_OAUTH_CLIENT_ID: "incomplete-client.apps.googleusercontent.com",
  }
);
assert.match(refusedIncompleteEnvironmentPair.stderr, /must be configured together/);

const oauthConfigurationDirectory = mkdtempSync(join(tmpdir(), "openorg-google-oauth-build-"));
try {
  const desktopClientPath = join(oauthConfigurationDirectory, "desktop-client.json");
  writeFileSync(desktopClientPath, JSON.stringify({
    installed: {
      client_id: "release-client.apps.googleusercontent.com",
      client_secret: "release-client-secret",
      redirect_uris: ["http://localhost"],
    },
  }));
  const configuredBuild = JSON.parse(
    run("tools/build-macos-app.mjs", [
      "--google-oauth-client-json", desktopClientPath,
      "--require-google-oauth-client",
      "--print-configuration",
    ]).stdout
  );
  assert.equal(configuredBuild.googleOAuthClientConfigured, true);
  assert.equal(configuredBuild.googleOAuthClientSecretConfigured, true);
  assert.equal(configuredBuild.googleOAuthClientSource, "desktop-client-json");
  assert.equal(configuredBuild.googleOAuthRequired, true);
  assert.doesNotMatch(JSON.stringify(configuredBuild), /release-client-secret/);

  const webClientPath = join(oauthConfigurationDirectory, "web-client.json");
  writeFileSync(webClientPath, JSON.stringify({
    web: {
      client_id: "web-client.apps.googleusercontent.com",
      client_secret: "web-client-secret",
    },
  }));
  const refusedWebClient = run(
    "tools/build-macos-app.mjs",
    ["--google-oauth-client-json", webClientPath, "--print-configuration"],
    1
  );
  assert.match(refusedWebClient.stderr, /installed Desktop client, not a Web application client/);
  assert.doesNotMatch(refusedWebClient.stderr, /web-client-secret/);
} finally {
  rmSync(oauthConfigurationDirectory, { recursive: true, force: true });
}

const isolatedScratch = JSON.parse(
  spawnSync(process.execPath, [join(repoRoot, "tools/build-macos-app.mjs"), "--print-configuration"], {
    cwd: repoRoot,
    encoding: "utf8",
    env: { ...process.env, ORG2_WORKSPACE_SWIFT_SCRATCH_PATH: "/tmp/openorg-release-test" },
  }).stdout
);
assert.equal(isolatedScratch.swiftScratchPath, "/tmp/openorg-release-test");

const refusedDebug = run(
  "tools/build-macos-app.mjs",
  ["--configuration", "debug", "--print-configuration"],
  1
);
assert.match(refusedDebug.stderr, /Refusing to install an implicit debug build/);

const explicitDebug = JSON.parse(
  run("tools/build-macos-app.mjs", [
    "--configuration", "debug",
    "--allow-daily-debug",
    "--print-configuration",
  ]).stdout
);
assert.equal(explicitDebug.configuration, "debug");

const restartDaily = JSON.parse(
  run("tools/build-macos-app.mjs", [
    "--configuration", "release",
    "--restart",
    "--print-configuration",
  ]).stdout
);
assert.equal(restartDaily.restartAfterInstall, true);
assert.equal(restartDaily.configuration, "release");

const codexDebug = JSON.parse(
  run("tools/build-macos-app-codex.mjs", ["--print-configuration"]).stdout
);
assert.equal(codexDebug.bundleIdentifier, "org.org2.workspace.codex");
assert.equal(codexDebug.configuration, "debug");
assert.equal(codexDebug.appName, "OpenOrg Preview");
assert.match(codexDebug.appPath, /OpenOrg Preview\.app$/);
assert.equal(codexDebug.updates.enabled, false);

const codexRelease = JSON.parse(
  run("tools/build-macos-app-codex.mjs", [
    "--configuration", "release",
    "--print-configuration",
  ]).stdout
);
assert.equal(codexRelease.configuration, "release");

const temporaryDirectory = mkdtempSync(join(tmpdir(), "org2-atomic-app-install-"));
function makeBundle(path, marker) {
  mkdirSync(path, { recursive: true });
  writeFileSync(join(path, "marker.txt"), marker);
}

try {
  const stagedApp = join(temporaryDirectory, "staged", "OpenOrg.app");
  const installedApp = join(temporaryDirectory, "installed", "OpenOrg.app");
  makeBundle(stagedApp, "new");
  makeBundle(installedApp, "old");
  installStagedAppBundle({ stagedAppPath: stagedApp, targetAppPath: installedApp });
  assert.equal(readFileSync(join(installedApp, "marker.txt"), "utf8"), "new");
  assert.equal(existsSync(stagedApp), false);
  assert.equal(
    readdirSync(dirname(installedApp)).some((entry) => entry.includes(".backup-")),
    false
  );

  const rollbackTarget = join(temporaryDirectory, "rollback", "OpenOrg.app");
  const invalidNestedStage = join(rollbackTarget, "nested-staged.app");
  makeBundle(rollbackTarget, "preserved");
  makeBundle(invalidNestedStage, "never-installed");
  assert.throws(() => installStagedAppBundle({
    stagedAppPath: invalidNestedStage,
    targetAppPath: rollbackTarget,
  }));
  assert.equal(readFileSync(join(rollbackTarget, "marker.txt"), "utf8"), "preserved");
  assert.equal(existsSync(invalidNestedStage), true);
} finally {
  rmSync(temporaryDirectory, { recursive: true, force: true });
}

console.log("macOS app build-mode tests passed");
