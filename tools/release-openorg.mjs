#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { createSign } from "node:crypto";
import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const rootPackagePath = join(repoRoot, "package.json");
const vscodePackageDir = join(repoRoot, "editors", "vscode-org2");
const iosProjectPath = join(repoRoot, "apps", "ios", "Org2Mobile", "Org2Mobile.xcodeproj");
const iosProjectFile = join(iosProjectPath, "project.pbxproj");

export const RELEASE_PHASES = [
  "preflight",
  "stamp",
  "validate",
  "package",
  "publish",
  "sync",
  "verify",
];

export const TESTFLIGHT = Object.freeze({
  appId: "6797133238",
  internalGroupId: "f7462891-5b0e-4ccf-a3bc-2c2ea2f2540d",
  internalGroupName: "Org2 Internal",
  externalGroupId: "566e8d38-3c80-442c-8b9a-4f7916181149",
  externalGroupName: "OpenOrg Alpha",
  publicLink: "https://testflight.apple.com/join/Yp3hfBng",
  reviewNotes: [
    "OpenOrg has no account system and does not require sign-in, so there are no demo credentials to provide.",
    "All note browsing, reading, and editing can be reviewed without an account.",
    "AI chat is optional and relays requests to a locally installed OpenOrg macOS companion configured by the user; it is not backed by an OpenOrg-hosted account.",
    "The AI chat surface will remain unavailable when no companion is configured, but the rest of the iOS app is fully reviewable.",
  ].join(" "),
});

export function testFlightReviewAttributes() {
  return {
    demoAccountRequired: false,
    notes: TESTFLIGHT.reviewNotes,
  };
}

function currentVersion() {
  return JSON.parse(readFileSync(rootPackagePath, "utf8")).version;
}

function currentIOSBuild() {
  const contents = readFileSync(iosProjectFile, "utf8");
  const match = contents.match(/CURRENT_PROJECT_VERSION = (\d+);/);
  if (!match) throw new Error("Could not find CURRENT_PROJECT_VERSION in the iOS project");
  return Number(match[1]);
}

export function resolveReleaseVersion(requested, baseVersion = currentVersion()) {
  if (/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(requested)) return requested;
  if (!new Set(["patch", "minor", "major"]).has(requested)) {
    throw new Error("Release version must be an exact SemVer or patch, minor, or major");
  }
  const match = baseVersion.match(/^(\d+)\.(\d+)\.(\d+)/);
  if (!match) throw new Error(`Current package version is not SemVer: ${baseVersion}`);
  let [, major, minor, patch] = match.map(Number);
  if (requested === "major") {
    major += 1;
    minor = 0;
    patch = 0;
  } else if (requested === "minor") {
    minor += 1;
    patch = 0;
  } else {
    patch += 1;
  }
  return `${major}.${minor}.${patch}`;
}

export function parseReleaseOptions(args) {
  const parsed = {
    artifactsDir: "",
    execute: false,
    help: false,
    iosBuild: currentIOSBuild() + 1,
    notesFile: "",
    restart: false,
    skipIOS: false,
    skipTestFlightGroups: false,
    through: "verify",
    versionRequest: "",
    whatToTestFile: "",
  };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    switch (argument) {
      case "--execute": parsed.execute = true; break;
      case "--restart": parsed.restart = true; break;
      case "--skip-ios": parsed.skipIOS = true; break;
      case "--skip-testflight-groups": parsed.skipTestFlightGroups = true; break;
      case "--artifacts-dir": parsed.artifactsDir = args[++index] ?? ""; break;
      case "--ios-build": parsed.iosBuild = Number(args[++index]); break;
      case "--notes": parsed.notesFile = args[++index] ?? ""; break;
      case "--through": parsed.through = args[++index] ?? ""; break;
      case "--what-to-test": parsed.whatToTestFile = args[++index] ?? ""; break;
      case "--plan": break;
      case "--help":
      case "-h": parsed.help = true; break;
      default:
        if (argument.startsWith("-")) throw new Error(`Unknown release option: ${argument}`);
        if (parsed.versionRequest) throw new Error("Only one release version may be supplied");
        parsed.versionRequest = argument;
    }
  }
  if (!parsed.help && !parsed.versionRequest) {
    throw new Error("Supply an exact version or patch, minor, or major");
  }
  if (!Number.isInteger(parsed.iosBuild) || parsed.iosBuild <= 0) {
    throw new Error("--ios-build must be a positive integer");
  }
  if (!RELEASE_PHASES.includes(parsed.through)) {
    throw new Error(`--through must be one of ${RELEASE_PHASES.join(", ")}`);
  }
  return parsed;
}

export function buildReleasePlan(options, baseVersion = currentVersion()) {
  const version = resolveReleaseVersion(options.versionRequest, baseVersion);
  const artifactsDir = resolve(options.artifactsDir || join("/tmp", `openorg-release-${version}`));
  return {
    artifactsDir,
    checkpoints: join(artifactsDir, "state.json"),
    execute: options.execute,
    ios: options.skipIOS ? null : {
      appId: TESTFLIGHT.appId,
      build: options.iosBuild,
      groups: [TESTFLIGHT.internalGroupName, TESTFLIGHT.externalGroupName],
      groupAutomation: options.skipTestFlightGroups ? "manual" : "App Store Connect API",
      version,
    },
    phases: [
      { name: "preflight", parallel: ["GitHub auth", "npm auth", "Apple/signing configuration"] },
      { name: "stamp", parallel: false },
      { name: "validate", parallel: ["Node/full", "VS Code", "Swift/serial"] },
      { name: "package", parallel: ["OpenOrg arm64 DMG", "OpenOrg Intel DMG", ...(options.skipIOS ? [] : ["iOS archive"]) ] },
      { name: "publish", parallel: ["Git tag workflow + DMGs", ...(options.skipIOS ? [] : ["TestFlight upload + groups"]) ] },
      { name: "sync", parallel: false },
      { name: "verify", parallel: ["npm", "VS Code Marketplace", "GitHub assets", "Scarf redirects", ...(options.skipIOS ? [] : ["TestFlight groups"]) ] },
    ].slice(0, RELEASE_PHASES.indexOf(options.through) + 1),
    safeDefaults: {
      dailyMacAppUntouched: true,
      executeMustBeExplicit: true,
      failClosedOnDirtyTree: true,
      notarizationRequired: true,
      resumable: true,
    },
    version,
  };
}

function usage() {
  return `Usage: node tools/release-openorg.mjs VERSION [options]

VERSION may be an exact SemVer or patch, minor, or major. The default is a read-only plan.

Examples:
  node tools/release-openorg.mjs patch --ios-build 25 --notes /tmp/0.5.3.md
  node tools/release-openorg.mjs patch --ios-build 25 --notes /tmp/0.5.3.md --execute

Options:
  --execute                    Mutate, publish, and resume from checkpoints
  --restart                    Remove the existing checkpoint before executing
  --through PHASE              Stop after preflight|stamp|validate|package|publish|sync|verify
  --artifacts-dir PATH         Artifact, checkpoint, and per-job log directory
  --ios-build NUMBER           TestFlight build number (defaults to current + 1)
  --notes FILE                 Markdown release notes (required with --execute)
  --what-to-test FILE          TestFlight notes (defaults to release notes)
  --skip-ios                   Release desktop/tooling channels only
  --skip-testflight-groups     Upload iOS but leave group assignment/review manual
  --plan                       Explicit alias for the read-only default
  --help                       Show this help`;
}

function atomicWriteJSON(path, value) {
  const temporary = `${path}.tmp`;
  writeFileSync(temporary, JSON.stringify(value, null, 2) + "\n");
  renameSync(temporary, path);
}

function readState(plan, options) {
  mkdirSync(plan.artifactsDir, { recursive: true });
  const statePath = plan.checkpoints;
  if (options.restart) rmSync(statePath, { force: true });
  if (!existsSync(statePath)) {
    const initial = {
      completed: {},
      createdAt: new Date().toISOString(),
      iosBuild: plan.ios?.build ?? null,
      version: plan.version,
    };
    atomicWriteJSON(statePath, initial);
    return initial;
  }
  const state = JSON.parse(readFileSync(statePath, "utf8"));
  if (state.version !== plan.version || state.iosBuild !== (plan.ios?.build ?? null)) {
    throw new Error(`Checkpoint ${statePath} belongs to a different release; use --restart`);
  }
  return state;
}

function markPhaseComplete(plan, state, phase) {
  state.completed[phase] = new Date().toISOString();
  atomicWriteJSON(plan.checkpoints, state);
}

function capture(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    encoding: "utf8",
    env: options.env ?? process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0 && !options.allowFailure) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    throw new Error(detail || `${command} ${args.join(" ")} failed`);
  }
  return {
    ok: result.status === 0,
    stderr: result.stderr?.trim() ?? "",
    stdout: result.stdout?.trim() ?? "",
  };
}

function safeJobName(name) {
  return name.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-").replaceAll(/^-|-$/g, "");
}

function runJob(plan, name, command, args, options = {}) {
  const logPath = join(plan.artifactsDir, `${safeJobName(name)}.log`);
  console.log(`→ ${name}`);
  const descriptor = openSync(logPath, "a");
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      cwd: options.cwd ?? repoRoot,
      env: options.env ?? process.env,
      stdio: ["ignore", descriptor, descriptor],
    });
    child.once("error", (error) => {
      closeSync(descriptor);
      rejectPromise(error);
    });
    child.once("exit", (code, signal) => {
      closeSync(descriptor);
      if (code === 0) {
        console.log(`✓ ${name}`);
        resolvePromise({ logPath, name });
      } else {
        rejectPromise(new Error(`${name} failed (${signal ?? `exit ${code}`}); see ${logPath}`));
      }
    });
  });
}

async function runParallel(jobs) {
  const results = await Promise.allSettled(jobs.map((job) => job()));
  const failures = results.filter((result) => result.status === "rejected");
  if (failures.length > 0) {
    throw new Error(failures.map((failure) => failure.reason?.message ?? String(failure.reason)).join("\n"));
  }
}

function requireFile(path, label) {
  if (!path || !existsSync(resolve(path))) throw new Error(`${label} file is required and must exist`);
}

function requireCleanMain() {
  const branch = capture("git", ["branch", "--show-current"]).stdout;
  if (branch !== "main") throw new Error(`Release execution requires main; current branch is ${branch}`);
  const status = capture("git", ["status", "--porcelain"]).stdout;
  if (status) throw new Error(`Release execution requires a clean tree:\n${status}`);
  capture("git", ["fetch", "origin", "main", "--tags", "--quiet"]);
  const local = capture("git", ["rev-parse", "HEAD"]).stdout;
  const remote = capture("git", ["rev-parse", "origin/main"]).stdout;
  if (local !== remote) throw new Error("main must be synchronized with origin/main before release execution");
}

async function preflight(plan, options) {
  requireFile(options.notesFile, "Release notes");
  requireCleanMain();
  if (!process.env.OPENORG_NOTARY_KEYCHAIN_PROFILE?.trim()) {
    throw new Error("OPENORG_NOTARY_KEYCHAIN_PROFILE is required");
  }
  if (!options.skipIOS && !options.skipTestFlightGroups) {
    for (const name of ["OPENORG_ASC_ISSUER_ID", "OPENORG_ASC_KEY_ID", "OPENORG_ASC_PRIVATE_KEY_PATH"]) {
      if (!process.env[name]?.trim()) throw new Error(`${name} is required for reliable TestFlight group assignment`);
    }
    requireFile(process.env.OPENORG_ASC_PRIVATE_KEY_PATH, "App Store Connect private key");
  }
  const tagExists = capture("git", ["rev-parse", "--verify", `refs/tags/${plan.version}`], { allowFailure: true }).ok;
  if (tagExists) throw new Error(`Tag ${plan.version} already exists`);
  const npmExists = capture("npm", ["view", `@aviaviavi/org2@${plan.version}`, "version"], { allowFailure: true }).ok;
  if (npmExists) throw new Error(`@aviaviavi/org2@${plan.version} is already published`);
  await runParallel([
    () => runJob(plan, "GitHub authentication", "gh", ["auth", "status"]),
    () => runJob(plan, "npm authentication", "npm", ["whoami"]),
    () => runJob(plan, "Apple signing identities", "security", ["find-identity", "-v", "-p", "codesigning"]),
  ]);
}

function updateIOSVersions(version, build) {
  const source = readFileSync(iosProjectFile, "utf8");
  const updated = source
    .replaceAll(/CURRENT_PROJECT_VERSION = \d+;/g, `CURRENT_PROJECT_VERSION = ${build};`)
    .replaceAll(/MARKETING_VERSION = [^;]+;/g, `MARKETING_VERSION = ${version};`);
  if (!updated.includes(`CURRENT_PROJECT_VERSION = ${build};`)
      || !updated.includes(`MARKETING_VERSION = ${version};`)) {
    throw new Error("iOS project versions could not be stamped");
  }
  writeFileSync(iosProjectFile, updated);
}

function updateVSCodeChangelog(version, notesFile) {
  const path = join(vscodePackageDir, "CHANGELOG.md");
  const source = readFileSync(path, "utf8");
  if (source.includes(`## ${version} -`)) return;
  const marker = "## Unreleased\n";
  if (!source.includes(marker)) throw new Error("VS Code changelog is missing the Unreleased marker");
  const notes = readFileSync(resolve(notesFile), "utf8").trim();
  const date = new Date().toISOString().slice(0, 10);
  writeFileSync(path, source.replace(marker, `${marker}\n## ${version} - ${date}\n\n${notes}\n`));
}

async function stamp(plan, options) {
  await runJob(plan, "Stamp root package", "npm", ["version", plan.version, "--no-git-tag-version", "--allow-same-version"]);
  await runJob(plan, "Stamp VS Code package", "npm", ["--prefix", "editors/vscode-org2", "version", plan.version, "--no-git-tag-version", "--allow-same-version"]);
  if (!options.skipIOS) updateIOSVersions(plan.version, plan.ios.build);
  updateVSCodeChangelog(plan.version, options.notesFile);
}

async function validate(plan) {
  await runJob(plan, "Build shared runtime", "npm", ["run", "build"]);
  await runJob(plan, "Documentation contract", "npm", ["run", "docs:check"]);
  await runParallel([
    () => runJob(plan, "Node full suite", "npm", ["test"]),
    () => runJob(plan, "VS Code suite", "npm", ["test"], { cwd: vscodePackageDir }),
    () => runJob(plan, "Swift suite serial", "swift", ["test", "--package-path", "apps/macos/Org2Workspace", "--no-parallel"]),
  ]);
  await runJob(plan, "Generated artifact check", "npm", ["run", "check:generated"]);
  await runJob(plan, "npm pack preview", "npm", ["pack", "--dry-run", "--json"]);
}

function writeExportOptions(plan) {
  const path = join(plan.artifactsDir, "ExportOptions.plist");
  writeFileSync(path, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>destination</key><string>upload</string>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>method</key><string>app-store-connect</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>9MW3N969TR</string>
</dict></plist>\n`);
  return path;
}

async function packageArtifacts(plan, options) {
  const armDMG = join(plan.artifactsDir, "OpenOrg.dmg");
  const intelDMG = join(plan.artifactsDir, "OpenOrg-Intel.dmg");
  const jobs = [
    () => runJob(plan, "OpenOrg arm64 DMG", process.execPath, [
      "tools/package-openorg-macos.mjs", "--architecture", "arm64", "--output", armDMG,
      "--require-notarization", "--force",
    ]),
    () => runJob(plan, "OpenOrg Intel DMG", process.execPath, [
      "tools/package-openorg-macos.mjs", "--architecture", "x86_64", "--output", intelDMG,
      "--require-notarization", "--force",
    ]),
  ];
  if (!options.skipIOS) {
    const archivePath = join(plan.artifactsDir, "OpenOrg.xcarchive");
    jobs.push(() => runJob(plan, "iOS release archive", "xcodebuild", [
      "-project", iosProjectPath,
      "-scheme", "Org2Mobile",
      "-configuration", "Release",
      "-destination", "generic/platform=iOS",
      "-archivePath", archivePath,
      "clean", "archive",
      `MARKETING_VERSION=${plan.version}`,
      `CURRENT_PROJECT_VERSION=${plan.ios.build}`,
      "-allowProvisioningUpdates",
    ]));
    writeExportOptions(plan);
  }
  await runParallel(jobs);
}

function releaseFiles(options) {
  const files = [
    "package.json",
    "package-lock.json",
    "editors/vscode-org2/package.json",
    "editors/vscode-org2/package-lock.json",
    "editors/vscode-org2/CHANGELOG.md",
  ];
  if (!options.skipIOS) files.push("apps/ios/Org2Mobile/Org2Mobile.xcodeproj/project.pbxproj");
  return files;
}

function ensureReleaseCommitAndTag(plan, options) {
  const tag = capture("git", ["rev-parse", "--verify", `refs/tags/${plan.version}`], { allowFailure: true });
  if (!tag.ok) {
    capture("git", ["add", "--", ...releaseFiles(options)]);
    const staged = capture("git", ["diff", "--cached", "--quiet"], { allowFailure: true });
    if (!staged.ok) capture("git", ["commit", "-m", `Release OpenOrg ${plan.version}`]);
    capture("git", ["push", "origin", "main"]);
    capture("git", ["tag", "-a", plan.version, "-m", `OpenOrg ${plan.version}`]);
    capture("git", ["push", "origin", plan.version]);
  } else {
    capture("git", ["push", "origin", "main"]);
    capture("git", ["push", "origin", plan.version]);
  }
}

async function waitForGitHubWorkflow(plan) {
  const deadline = Date.now() + 45 * 60_000;
  while (Date.now() < deadline) {
    const result = capture("gh", ["run", "list", "--workflow", "release-packages.yml", "--limit", "30", "--json", "databaseId,headBranch,event,status,conclusion"]);
    const run = JSON.parse(result.stdout).find((candidate) => candidate.headBranch === plan.version && candidate.event === "push");
    if (run) {
      await runJob(plan, "GitHub release workflow", "gh", ["run", "watch", String(run.databaseId), "--exit-status"]);
      return;
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10_000));
  }
  throw new Error(`Timed out waiting for the ${plan.version} GitHub release workflow`);
}

function releaseBody(plan, options) {
  const notes = readFileSync(resolve(options.notesFile), "utf8").trim();
  const manifests = ["OpenOrg.json", "OpenOrg-Intel.json"].map((name) => {
    const manifest = JSON.parse(readFileSync(join(plan.artifactsDir, name), "utf8"));
    return `- \`${manifest.sha256}  ${name.replace(".json", ".dmg")}\``;
  });
  const path = join(plan.artifactsDir, "release-body.md");
  writeFileSync(path, `${notes}\n\n## macOS checksums\n\n${manifests.join("\n")}\n`);
  return path;
}

async function publishGitHub(plan, options) {
  await waitForGitHubWorkflow(plan);
  await runJob(plan, "Upload notarized DMGs", "gh", [
    "release", "upload", plan.version,
    join(plan.artifactsDir, "OpenOrg.dmg"),
    join(plan.artifactsDir, "OpenOrg-Intel.dmg"),
    "--clobber",
  ]);
  await runJob(plan, "Apply release notes", "gh", ["release", "edit", plan.version, "--notes-file", releaseBody(plan, options)]);
}

function base64URL(value) {
  return Buffer.from(value).toString("base64url");
}

function appStoreConnectToken() {
  const issuer = process.env.OPENORG_ASC_ISSUER_ID.trim();
  const keyId = process.env.OPENORG_ASC_KEY_ID.trim();
  const privateKey = readFileSync(resolve(process.env.OPENORG_ASC_PRIVATE_KEY_PATH.trim()), "utf8");
  const now = Math.floor(Date.now() / 1000);
  const header = base64URL(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const payload = base64URL(JSON.stringify({ aud: "appstoreconnect-v1", exp: now + 1_200, iss: issuer, iat: now }));
  const input = `${header}.${payload}`;
  const signer = createSign("SHA256");
  signer.update(input);
  signer.end();
  const signature = signer.sign({ dsaEncoding: "ieee-p1363", key: privateKey }).toString("base64url");
  return `${input}.${signature}`;
}

async function ascRequest(path, options = {}) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method: options.method ?? "GET",
    headers: {
      Authorization: `Bearer ${appStoreConnectToken()}`,
      ...(options.body ? { "Content-Type": "application/json" } : {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const text = await response.text();
  const body = text ? JSON.parse(text) : null;
  if (!response.ok && !(options.acceptConflict && response.status === 409)) {
    throw new Error(`App Store Connect ${response.status} ${path}: ${text}`);
  }
  return body;
}

async function findTestFlightBuild(plan) {
  const query = new URLSearchParams({
    "filter[app]": TESTFLIGHT.appId,
    "filter[version]": String(plan.ios.build),
    include: "preReleaseVersion",
    limit: "10",
  });
  const response = await ascRequest(`/v1/builds?${query}`);
  return response.data?.find((build) => String(build.attributes?.version) === String(plan.ios.build)) ?? null;
}

async function waitForTestFlightBuild(plan) {
  const deadline = Date.now() + 50 * 60_000;
  while (Date.now() < deadline) {
    const build = await findTestFlightBuild(plan);
    if (build?.attributes?.processingState === "VALID") return build;
    if (build?.attributes?.processingState === "FAILED") throw new Error("TestFlight processing failed");
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 20_000));
  }
  throw new Error(`Timed out waiting for TestFlight build ${plan.ios.build}`);
}

async function addBuildToGroup(buildId, groupId) {
  await ascRequest(`/v1/betaGroups/${groupId}/relationships/builds`, {
    acceptConflict: true,
    body: { data: [{ id: buildId, type: "builds" }] },
    method: "POST",
  });
}

async function upsertWhatToTest(buildId, value) {
  const response = await ascRequest(`/v1/builds/${buildId}/betaBuildLocalizations`);
  const localization = response.data?.find((candidate) => candidate.attributes?.locale === "en-US");
  if (localization) {
    await ascRequest(`/v1/betaBuildLocalizations/${localization.id}`, {
      body: { data: { attributes: { whatsNew: value }, id: localization.id, type: "betaBuildLocalizations" } },
      method: "PATCH",
    });
    return;
  }
  await ascRequest("/v1/betaBuildLocalizations", {
    body: { data: {
      attributes: { locale: "en-US", whatsNew: value },
      relationships: { build: { data: { id: buildId, type: "builds" } } },
      type: "betaBuildLocalizations",
    } },
    method: "POST",
  });
}

async function updateBetaReviewDetails() {
  const response = await ascRequest(`/v1/apps/${TESTFLIGHT.appId}/betaAppReviewDetail`);
  const detail = response.data;
  if (!detail?.id) throw new Error("App Store Connect did not return beta app review details");
  await ascRequest(`/v1/betaAppReviewDetails/${detail.id}`, {
    body: { data: {
      attributes: testFlightReviewAttributes(),
      id: detail.id,
      type: "betaAppReviewDetails",
    } },
    method: "PATCH",
  });
  return detail.id;
}

async function submitBetaReview(buildId) {
  await ascRequest("/v1/betaAppReviewSubmissions", {
    acceptConflict: true,
    body: { data: {
      relationships: { build: { data: { id: buildId, type: "builds" } } },
      type: "betaAppReviewSubmissions",
    } },
    method: "POST",
  });
}

async function publishTestFlight(plan, options) {
  let build = options.skipTestFlightGroups ? null : await findTestFlightBuild(plan);
  if (!build) {
    await runJob(plan, "Upload iOS build", "xcodebuild", [
      "-exportArchive",
      "-archivePath", join(plan.artifactsDir, "OpenOrg.xcarchive"),
      "-exportPath", join(plan.artifactsDir, "ios-export"),
      "-exportOptionsPlist", join(plan.artifactsDir, "ExportOptions.plist"),
      "-allowProvisioningUpdates",
    ]);
  }
  if (options.skipTestFlightGroups) {
    console.warn("TestFlight upload complete; group assignment was explicitly left manual.");
    return;
  }
  build = await waitForTestFlightBuild(plan);
  const whatToTest = readFileSync(resolve(options.whatToTestFile || options.notesFile), "utf8").trim().slice(0, 4_000);
  await upsertWhatToTest(build.id, whatToTest);
  await updateBetaReviewDetails();
  await addBuildToGroup(build.id, TESTFLIGHT.internalGroupId);
  await addBuildToGroup(build.id, TESTFLIGHT.externalGroupId);
  await submitBetaReview(build.id);
  writeFileSync(join(plan.artifactsDir, "testflight-build.json"), JSON.stringify({
    buildId: build.id,
    externalGroupId: TESTFLIGHT.externalGroupId,
    internalGroupId: TESTFLIGHT.internalGroupId,
    version: plan.version,
  }, null, 2) + "\n");
  console.log(`✓ TestFlight build ${plan.ios.build} assigned to internal and external groups`);
}

async function publish(plan, options) {
  ensureReleaseCommitAndTag(plan, options);
  await runParallel([
    () => publishGitHub(plan, options),
    ...(!options.skipIOS ? [() => publishTestFlight(plan, options)] : []),
  ]);
}

async function synchronize(plan) {
  await runJob(plan, "Synchronize release downloads", process.execPath, [
    "tools/sync-release-downloads.mjs", "--release", plan.version, "--apply-page", "--apply-release-notes",
  ]);
  await runJob(plan, "Publish documentation site", "npm", ["run", "org2", "--", "publish", "docs-site", "--config", "org2.json"]);
  capture("git", ["add", "--", "docs/site/downloads.org", "site"]);
  const staged = capture("git", ["diff", "--cached", "--quiet"], { allowFailure: true });
  if (!staged.ok) capture("git", ["commit", "-m", `Publish OpenOrg ${plan.version} download surfaces`]);
  capture("git", ["push", "origin", "main"]);
}

async function verifyScarf(plan) {
  for (const artifact of ["OpenOrg.dmg", "OpenOrg-Intel.dmg"]) {
    const expected = `https://github.com/aviaviavi/org2/releases/download/${plan.version}/${artifact}`;
    const response = await fetch(`https://org2.gateway.scarf.sh/downloads/${plan.version}/${artifact}`, { redirect: "manual" });
    if (response.status < 300 || response.status >= 400 || response.headers.get("location") !== expected) {
      throw new Error(`Scarf redirect mismatch for ${artifact}: ${response.status} ${response.headers.get("location")}`);
    }
  }
}

async function pollUntil(label, timeoutMs, check) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      if (await check()) {
        console.log(`✓ ${label}`);
        return;
      }
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 15_000));
  }
  throw new Error(`${label} did not converge before timeout${lastError ? `: ${lastError.message}` : ""}`);
}

async function verify(plan, options) {
  await runParallel([
    () => pollUntil("npm public version", 10 * 60_000, async () => (
      capture("npm", ["view", "@aviaviavi/org2@latest", "version"], { allowFailure: true }).stdout === plan.version
    )),
    () => pollUntil("VS Code Marketplace public version", 15 * 60_000, async () => {
      const result = capture("npx", ["@vscode/vsce", "show", "AviPress.org2-vscode", "--json"], {
        allowFailure: true,
        cwd: vscodePackageDir,
      });
      if (!result.ok || !result.stdout) return false;
      const extension = JSON.parse(result.stdout);
      return extension.versions?.[0]?.version === plan.version;
    }),
    async () => {
      const release = JSON.parse(capture("gh", ["release", "view", plan.version, "--json", "assets,tagName,url"]).stdout);
      const names = new Set(release.assets.map((asset) => asset.name));
      for (const expected of ["OpenOrg.dmg", "OpenOrg-Intel.dmg", `aviaviavi-org2-${plan.version}.tgz`, `org2-vscode-${plan.version}.vsix`]) {
        if (!names.has(expected)) throw new Error(`GitHub Release is missing ${expected}`);
      }
      console.log(`✓ GitHub Release ${release.url}`);
    },
    () => verifyScarf(plan),
    ...(!options.skipIOS && !options.skipTestFlightGroups ? [async () => {
      const build = await findTestFlightBuild(plan);
      if (!build || build.attributes?.processingState !== "VALID") throw new Error("TestFlight build is not valid");
      console.log(`✓ TestFlight build ${plan.ios.build}`);
    }] : []),
  ]);
  await runJob(plan, "Release download drift check", process.execPath, ["tools/sync-release-downloads.mjs", "--check"]);
  const status = capture("git", ["status", "--porcelain"]).stdout;
  if (status) throw new Error(`Release finished with repository changes:\n${status}`);
  const local = capture("git", ["rev-parse", "HEAD"]).stdout;
  const remote = capture("git", ["rev-parse", "origin/main"]).stdout;
  if (local !== remote) throw new Error("Release finished with main out of sync with origin/main");
}

async function executePlan(plan, options) {
  const state = readState(plan, options);
  const implementations = { preflight, stamp, validate, package: packageArtifacts, publish, sync: synchronize, verify };
  for (const phase of RELEASE_PHASES.slice(0, RELEASE_PHASES.indexOf(options.through) + 1)) {
    if (state.completed[phase]) {
      console.log(`↷ ${phase} already completed at ${state.completed[phase]}`);
      continue;
    }
    console.log(`\n=== ${phase} ===`);
    await implementations[phase](plan, options);
    markPhaseComplete(plan, state, phase);
  }
  console.log(`\nRelease ${plan.version} completed through ${options.through}.`);
  console.log(`State and logs: ${plan.artifactsDir}`);
}

async function main() {
  const options = parseReleaseOptions(process.argv.slice(2));
  if (options.help) {
    console.log(usage());
    return;
  }
  const plan = buildReleasePlan(options);
  if (!options.execute) {
    console.log(JSON.stringify(plan, null, 2));
    console.log("\nRead-only plan. Add --execute to mutate or publish anything.");
    return;
  }
  requireFile(options.notesFile, "Release notes");
  await executePlan(plan, options);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
