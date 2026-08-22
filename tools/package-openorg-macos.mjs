#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageVersion = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).version;
const options = parseOptions(process.argv.slice(2));

function defaultArchitecture() {
  if (process.platform === "darwin") {
    const result = spawnSync("sysctl", ["-n", "hw.optional.arm64"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (result.status === 0 && result.stdout.trim() === "1") return "arm64";
  }
  return process.arch === "x64" ? "x86_64" : "arm64";
}

function parseOptions(args) {
  const parsed = {
    architecture: defaultArchitecture(),
    force: false,
    help: false,
    notaryProfile: process.env.OPENORG_NOTARY_KEYCHAIN_PROFILE?.trim() ?? "",
    output: "",
    plan: false,
    requireNotarization: false,
  };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    switch (argument) {
      case "--architecture":
        parsed.architecture = args[++index] ?? "";
        break;
      case "--output":
        parsed.output = args[++index] ?? "";
        break;
      case "--notary-profile":
        parsed.notaryProfile = args[++index] ?? "";
        break;
      case "--require-notarization":
        parsed.requireNotarization = true;
        break;
      case "--force":
        parsed.force = true;
        break;
      case "--plan":
        parsed.plan = true;
        break;
      case "--help":
      case "-h":
        parsed.help = true;
        break;
      default:
        throw new Error(`Unknown option: ${argument}`);
    }
  }
  if (!["arm64", "x86_64"].includes(parsed.architecture)) {
    throw new Error("--architecture must be arm64 or x86_64");
  }
  const suffix = parsed.architecture === "arm64" ? "" : "-Intel";
  parsed.output = resolve(parsed.output || join(repoRoot, "artifacts", `OpenOrg${suffix}.dmg`));
  return parsed;
}

function usage() {
  return `Usage: node tools/package-openorg-macos.mjs [options]

Build, Developer-ID sign, package, and optionally notarize an isolated OpenOrg DMG.

Options:
  --architecture ARCH       arm64 or x86_64
  --output PATH             DMG output path
  --notary-profile NAME     notarytool Keychain profile (or OPENORG_NOTARY_KEYCHAIN_PROFILE)
  --require-notarization    fail instead of producing an unstapled local candidate
  --force                   replace an existing output artifact
  --plan                    print the resolved non-secret packaging plan
  --help                    show this help`;
}

function run(command, args, runOptions = {}) {
  const result = spawnSync(command, args, {
    cwd: runOptions.cwd ?? repoRoot,
    encoding: "utf8",
    env: runOptions.env ?? process.env,
    stdio: runOptions.capture ? ["ignore", "pipe", "pipe"] : "inherit",
  });
  if (result.status !== 0) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    throw new Error(detail || `${command} ${args.join(" ")} failed`);
  }
  return result.stdout?.trim() ?? "";
}

function developerIDApplicationIdentity() {
  const configured = process.env.ORG2_WORKSPACE_CODE_SIGN_IDENTITY?.trim();
  if (configured) {
    if (!configured.startsWith("Developer ID Application:")) {
      throw new Error("Release packaging requires a Developer ID Application signing identity");
    }
    return configured;
  }
  const output = run("security", ["find-identity", "-v", "-p", "codesigning"], { capture: true });
  const match = output.match(/"(Developer ID Application:[^"]+)"/);
  if (!match) {
    throw new Error("No Developer ID Application signing identity is installed");
  }
  return match[1];
}

function artifactManifestPath(dmgPath) {
  return dmgPath.slice(0, -extname(dmgPath).length) + ".json";
}

function printPlan() {
  console.log(JSON.stringify({
    appName: "OpenOrg",
    architecture: options.architecture,
    bundleIdentifier: "org.org2.workspace",
    dailyAppUntouched: "/Users/avi/Applications/Org2Workspace.app",
    executableName: "Org2Workspace",
    hardenedRuntime: true,
    notarization: options.notaryProfile ? "notarytool Keychain profile configured" : "not configured",
    output: options.output,
    staging: "isolated temporary directory",
    version: packageVersion,
  }, null, 2));
}

function main() {
  if (options.help) {
    console.log(usage());
    return;
  }
  if (options.plan) {
    printPlan();
    return;
  }
  if (process.platform !== "darwin") {
    throw new Error("OpenOrg DMG packaging requires macOS");
  }
  if (options.requireNotarization && !options.notaryProfile) {
    throw new Error("--require-notarization needs --notary-profile or OPENORG_NOTARY_KEYCHAIN_PROFILE");
  }
  if (existsSync(options.output) && !options.force) {
    throw new Error(`Refusing to replace existing artifact: ${options.output}`);
  }

  const signingIdentity = developerIDApplicationIdentity();
  const workingDirectory = mkdtempSync(join(tmpdir(), "openorg-release-"));
  const builtApp = join(workingDirectory, "OpenOrg.app");
  const dmgRoot = join(workingDirectory, "dmg-root");
  const unsignedDMG = join(workingDirectory, "OpenOrg.dmg");

  try {
    run(process.execPath, [join(repoRoot, "tools", "build-macos-app.mjs"), "--configuration", "release"], {
      env: {
        ...process.env,
        ORG2_WORKSPACE_APP_NAME: "OpenOrg",
        ORG2_WORKSPACE_APP_PATH: builtApp,
        ORG2_WORKSPACE_BUNDLE_ID: "org.org2.workspace",
        ORG2_WORKSPACE_CODE_SIGN_IDENTITY: signingIdentity,
        ORG2_WORKSPACE_SWIFT_ARCH: options.architecture,
      },
    });

    run("codesign", ["--verify", "--deep", "--strict", "--verbose=2", builtApp]);

    mkdirSync(dmgRoot, { recursive: true });
    run("ditto", [builtApp, join(dmgRoot, "OpenOrg.app")]);
    symlinkSync("/Applications", join(dmgRoot, "Applications"));
    run("hdiutil", [
      "create",
      "-volname", "OpenOrg",
      "-srcfolder", dmgRoot,
      "-ov",
      "-format", "UDZO",
      unsignedDMG,
    ]);
    run("codesign", ["--force", "--timestamp", "--sign", signingIdentity, unsignedDMG]);
    run("hdiutil", ["verify", unsignedDMG]);

    let notarized = false;
    if (options.notaryProfile) {
      run("xcrun", [
        "notarytool", "submit", unsignedDMG,
        "--keychain-profile", options.notaryProfile,
        "--wait",
      ]);
      run("xcrun", ["stapler", "staple", unsignedDMG]);
      run("xcrun", ["stapler", "validate", unsignedDMG]);
      run("spctl", [
        "--assess", "--type", "open",
        "--context", "context:primary-signature",
        "--verbose=2", unsignedDMG,
      ]);
      notarized = true;
    }

    mkdirSync(dirname(options.output), { recursive: true });
    if (existsSync(options.output)) rmSync(options.output, { force: true });
    run("ditto", [unsignedDMG, options.output]);
    const sha256 = run("shasum", ["-a", "256", options.output], { capture: true }).split(/\s+/)[0];
    const manifestPath = artifactManifestPath(options.output);
    writeFileSync(manifestPath, JSON.stringify({
      architecture: options.architecture,
      artifact: options.output,
      bundleIdentifier: "org.org2.workspace",
      displayName: "OpenOrg",
      notarized,
      sha256,
      version: packageVersion,
    }, null, 2) + "\n");
    console.log(`Packaged ${options.output}`);
    console.log(`SHA-256 ${sha256}`);
    console.log(notarized ? "Notarization ticket stapled" : "Local candidate only; notarization was not requested");
  } finally {
    rmSync(workingDirectory, { recursive: true, force: true });
  }
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
