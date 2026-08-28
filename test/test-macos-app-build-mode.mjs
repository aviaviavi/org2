import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function run(script, args, expectedStatus = 0) {
  const result = spawnSync(process.execPath, [join(repoRoot, script), ...args], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  assert.equal(result.status, expectedStatus, result.stderr || result.stdout);
  return result;
}

const defaultDaily = JSON.parse(
  run("tools/build-macos-app.mjs", ["--print-configuration"]).stdout
);
assert.equal(defaultDaily.bundleIdentifier, "org.org2.workspace");
assert.equal(defaultDaily.configuration, "release");
assert.equal(defaultDaily.appName, "OpenOrg");
assert.match(defaultDaily.appPath, /OpenOrg\.app$/);
assert.match(defaultDaily.iconPath, /OpenOrgAppIcon\.png$/);
assert.equal(defaultDaily.swiftScratchPath, null);

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

const codexDebug = JSON.parse(
  run("tools/build-macos-app-codex.mjs", ["--print-configuration"]).stdout
);
assert.equal(codexDebug.bundleIdentifier, "org.org2.workspace.codex");
assert.equal(codexDebug.configuration, "debug");
assert.equal(codexDebug.appName, "OpenOrg Preview");
assert.match(codexDebug.appPath, /OpenOrg Preview\.app$/);

const codexRelease = JSON.parse(
  run("tools/build-macos-app-codex.mjs", [
    "--configuration", "release",
    "--print-configuration",
  ]).stdout
);
assert.equal(codexRelease.configuration, "release");

console.log("macOS app build-mode tests passed");
