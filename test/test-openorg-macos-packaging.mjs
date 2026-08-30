import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const script = join(repoRoot, "tools", "package-openorg-macos.mjs");
const nodeEntitlements = readFileSync(join(
  repoRoot,
  "apps", "macos", "Org2Workspace", "OpenOrgNode.entitlements"
), "utf8");
const intelNodeEntitlements = readFileSync(join(
  repoRoot,
  "apps", "macos", "Org2Workspace", "OpenOrgNodeIntel.entitlements"
), "utf8");
const noGoogleOAuthEnvironment = { ...process.env };
delete noGoogleOAuthEnvironment.ORG2_GOOGLE_OAUTH_CLIENT_JSON;
delete noGoogleOAuthEnvironment.ORG2_GOOGLE_OAUTH_CLIENT_ID;
delete noGoogleOAuthEnvironment.ORG2_GOOGLE_OAUTH_CLIENT_SECRET;

assert.match(nodeEntitlements, /<key>com\.apple\.security\.cs\.allow-jit<\/key>\s*<true\/>/);
assert.doesNotMatch(nodeEntitlements, /com\.apple\.security\.cs\.allow-unsigned-executable-memory/);
assert.match(intelNodeEntitlements, /<key>com\.apple\.security\.cs\.allow-jit<\/key>\s*<true\/>/);
assert.match(
  intelNodeEntitlements,
  /<key>com\.apple\.security\.cs\.allow-unsigned-executable-memory<\/key>\s*<true\/>/
);

const defaultPlanResult = spawnSync(process.execPath, [script, "--plan"], {
  cwd: repoRoot,
  encoding: "utf8",
  env: noGoogleOAuthEnvironment,
});
assert.equal(defaultPlanResult.status, 0, defaultPlanResult.stderr);
const defaultPlan = JSON.parse(defaultPlanResult.stdout);
if (process.platform === "darwin") {
  const arm64Probe = spawnSync("sysctl", ["-n", "hw.optional.arm64"], { encoding: "utf8" });
  if (arm64Probe.status === 0 && arm64Probe.stdout.trim() === "1") {
    assert.equal(defaultPlan.architecture, "arm64", "Rosetta must not default packaging to Intel");
  }
}

const planResult = spawnSync(process.execPath, [script, "--plan", "--architecture", "arm64"], {
  cwd: repoRoot,
  encoding: "utf8",
  env: noGoogleOAuthEnvironment,
});
assert.equal(planResult.status, 0, planResult.stderr);
const plan = JSON.parse(planResult.stdout);
assert.equal(plan.appName, "OpenOrg");
assert.equal(plan.architecture, "arm64");
assert.equal(plan.bundleIdentifier, "org.org2.workspace");
assert.equal(plan.dailyAppUntouched, "/Users/avi/Applications/Org2Workspace.app");
assert.equal(plan.executableName, "Org2Workspace");
assert.equal(plan.googleOAuthClientSource, null);
assert.equal(plan.hardenedRuntime, true);
assert.equal(plan.swiftBuild, "isolated per artifact");
assert.equal(plan.targetRuntimeSelection, "architecture-verified at execution");
assert.equal(plan.staging, "isolated temporary directory");
assert.match(plan.output, /OpenOrg\.dmg$/);

const configuredPlanResult = spawnSync(
  process.execPath,
  [script, "--plan", "--architecture", "arm64"],
  {
    cwd: repoRoot,
    encoding: "utf8",
    env: {
      ...noGoogleOAuthEnvironment,
      ORG2_GOOGLE_OAUTH_CLIENT_JSON: "/protected/openorg-google-oauth-client.json",
    },
  }
);
assert.equal(configuredPlanResult.status, 0, configuredPlanResult.stderr);
assert.equal(
  JSON.parse(configuredPlanResult.stdout).googleOAuthClientSource,
  "desktop-client-json"
);

const missingProfile = spawnSync(
  process.execPath,
  [script, "--require-notarization", "--output", join(repoRoot, "artifacts", "unused.dmg")],
  {
    cwd: repoRoot,
    encoding: "utf8",
    env: { ...process.env, OPENORG_NOTARY_KEYCHAIN_PROFILE: "" },
  }
);
assert.equal(missingProfile.status, 1);
assert.match(missingProfile.stderr, /needs --notary-profile/);

console.log("OpenOrg macOS packaging tests passed");
