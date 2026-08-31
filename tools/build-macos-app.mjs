#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { installStagedAppBundle } from "./atomic-app-bundle.mjs";
import {
  detectNodeArchitecture,
  duckDBBindingPackagesForRuntime,
} from "./macos-runtime-node.mjs";
import {
  OPENORG_SPARKLE_CHECK_INTERVAL_SECONDS,
  OPENORG_SPARKLE_PUBLIC_KEY,
  openOrgSparkleFeedURL,
} from "./openorg-sparkle.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageVersion = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).version;
const packageDir = join(repoRoot, "apps", "macos", "Org2Workspace");
const buildOptions = parseBuildOptions(process.argv.slice(2));
const appName = process.env.ORG2_WORKSPACE_APP_NAME ?? "OpenOrg";
const appPath = resolve(
  process.env.ORG2_WORKSPACE_APP_PATH ?? join(homedir(), "Applications", `${appName}.app`)
);
const bundleIdentifier = process.env.ORG2_WORKSPACE_BUNDLE_ID ?? "org.org2.workspace";
const requestedSigningIdentity = process.env.ORG2_WORKSPACE_CODE_SIGN_IDENTITY?.trim();
const executableName = "Org2Workspace";
const iconPath = resolve(
  process.env.ORG2_WORKSPACE_ICON_PATH
    ?? join(packageDir, "Sources", "Org2Workspace", "Resources", "OpenOrgAppIcon.png")
);
const swiftBuildArch = process.env.ORG2_WORKSPACE_SWIFT_ARCH ?? defaultSwiftBuildArch();
const swiftScratchPath = process.env.ORG2_WORKSPACE_SWIFT_SCRATCH_PATH?.trim()
  ? resolve(process.env.ORG2_WORKSPACE_SWIFT_SCRATCH_PATH.trim())
  : "";
const swiftBuildConfiguration = resolveBuildConfiguration();
const bundledNodePath = process.env.ORG2_WORKSPACE_NODE_PATH?.trim()
  || (swiftBuildConfiguration === "release" ? discoverNodePath() : "");
const bundledNodeArchitecture = bundledNodePath
  ? detectNodeArchitecture(bundledNodePath)
  : null;
const bundledWhisperCppPath = process.env.ORG2_WORKSPACE_WHISPER_CPP_PATH?.trim()
  || (swiftBuildConfiguration === "release" ? discoverWhisperCppPath() : "");
const bundledWhisperModelPath = process.env.ORG2_WORKSPACE_WHISPER_MODEL_PATH?.trim()
  || (swiftBuildConfiguration === "release" ? discoverWhisperModelPath() : "");
const googleOAuthConfiguration = resolveGoogleOAuthConfiguration();
const googleOAuthClientID = googleOAuthConfiguration.clientID;
const googleOAuthClientSecret = googleOAuthConfiguration.clientSecret;
const appEntitlementsPath = resolve(
  process.env.ORG2_WORKSPACE_APP_ENTITLEMENTS
    ?? join(packageDir, "OpenOrg.entitlements")
);
const nodeEntitlementsPath = resolve(
  process.env.ORG2_WORKSPACE_NODE_ENTITLEMENTS
    ?? join(
      packageDir,
      bundledNodeArchitecture === "x64"
        ? "OpenOrgNodeIntel.entitlements"
        : "OpenOrgNode.entitlements"
    )
);
function sparkleUpdateConfiguration() {
  const architecture = swiftBuildArch || (process.arch === "x64" ? "x86_64" : "arm64");
  return {
    architecture,
    enabled: bundleIdentifier === "org.org2.workspace",
    feedURL: openOrgSparkleFeedURL(architecture),
    intervalSeconds: OPENORG_SPARKLE_CHECK_INTERVAL_SECONDS,
  };
}

function parseBuildOptions(arguments_) {
  const options = {
    allowDailyDebug: false,
    configuration: "",
    googleOAuthClientJSON: "",
    help: false,
    printConfiguration: false,
    requireGoogleOAuthClient: false,
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    switch (argument) {
      case "--allow-daily-debug":
        options.allowDailyDebug = true;
        break;
      case "--configuration":
        index += 1;
        if (index >= arguments_.length) {
          throw new Error("--configuration requires debug or release");
        }
        options.configuration = arguments_[index];
        break;
      case "--google-oauth-client-json":
        index += 1;
        if (index >= arguments_.length) {
          throw new Error("--google-oauth-client-json requires a path");
        }
        options.googleOAuthClientJSON = arguments_[index];
        break;
      case "--print-configuration":
        options.printConfiguration = true;
        break;
      case "--require-google-oauth-client":
        options.requireGoogleOAuthClient = true;
        break;
      case "--help":
      case "-h":
        options.help = true;
        break;
      default:
        throw new Error(`Unknown build option: ${argument}`);
    }
  }
  return options;
}

function resolveBuildConfiguration() {
  const configured = buildOptions.configuration
    || process.env.ORG2_WORKSPACE_SWIFT_CONFIGURATION?.trim()
    || (bundleIdentifier === "org.org2.workspace" ? "release" : "debug");
  if (configured !== "debug" && configured !== "release") {
    throw new Error(`Unsupported Swift build configuration: ${configured}. Use debug or release.`);
  }
  return configured;
}

function resolveGoogleOAuthConfiguration() {
  const jsonPath = buildOptions.googleOAuthClientJSON
    || process.env.ORG2_GOOGLE_OAUTH_CLIENT_JSON?.trim()
    || "";
  const environmentClientID = process.env.ORG2_GOOGLE_OAUTH_CLIENT_ID?.trim() || "";
  const environmentClientSecret = process.env.ORG2_GOOGLE_OAUTH_CLIENT_SECRET?.trim() || "";
  if (jsonPath && (environmentClientID || environmentClientSecret)) {
    throw new Error(
      "Configure Google OAuth with either a Desktop client JSON or the separate client environment variables, not both."
    );
  }
  if (!jsonPath) {
    if (Boolean(environmentClientID) !== Boolean(environmentClientSecret)) {
      throw new Error(
        "ORG2_GOOGLE_OAUTH_CLIENT_ID and ORG2_GOOGLE_OAUTH_CLIENT_SECRET must be configured together."
      );
    }
    return {
      clientID: environmentClientID,
      clientSecret: environmentClientSecret,
      source: environmentClientID || environmentClientSecret ? "environment" : null,
    };
  }

  const resolvedPath = resolve(jsonPath);
  let envelope;
  try {
    envelope = JSON.parse(readFileSync(resolvedPath, "utf8"));
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(`Could not read Google OAuth Desktop client JSON at ${resolvedPath}: ${detail}`);
  }
  if (!envelope?.installed || envelope.web) {
    throw new Error(
      `Google OAuth client JSON at ${resolvedPath} must contain an installed Desktop client, not a Web application client.`
    );
  }
  const clientID = typeof envelope.installed.client_id === "string"
    ? envelope.installed.client_id.trim()
    : "";
  const clientSecret = typeof envelope.installed.client_secret === "string"
    ? envelope.installed.client_secret.trim()
    : "";
  if (!clientID.endsWith(".apps.googleusercontent.com")) {
    throw new Error(`Google OAuth Desktop client JSON at ${resolvedPath} has no valid client ID.`);
  }
  if (!clientSecret) {
    throw new Error(`Google OAuth Desktop client JSON at ${resolvedPath} has no client secret.`);
  }
  return { clientID, clientSecret, source: "desktop-client-json" };
}

function firstExistingPath(candidates) {
  return candidates.find((candidate) => candidate && existsSync(candidate)) ?? "";
}

function discoverNodePath() {
  return firstExistingPath([
    "/opt/homebrew/bin/node",
    "/usr/local/bin/node",
    process.execPath,
  ]);
}

function discoverWhisperCppPath() {
  return firstExistingPath([
    "/opt/homebrew/bin/whisper-cli",
    "/usr/local/bin/whisper-cli",
  ]);
}

function discoverWhisperModelPath() {
  return firstExistingPath([
    join(homedir(), "Library", "Application Support", "org2", "whisper", "ggml-base.en.bin"),
  ]);
}

function buildUsage() {
  return `Usage: node tools/build-macos-app.mjs [options]

Options:
  --configuration MODE    Build debug or release (daily app default: release)
  --allow-daily-debug     Explicitly allow a debug build at org.org2.workspace
  --google-oauth-client-json PATH
                          Bundle a Google OAuth Desktop client without copying its JSON into source
  --print-configuration   Print the resolved mode and paths without building
  --require-google-oauth-client
                          Fail unless a complete Google OAuth Desktop client is bundled
  --help                  Show this help`;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    encoding: "utf8",
    stdio: options.capture ? ["ignore", "pipe", "pipe"] : "inherit",
  });
  if (result.status !== 0) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    throw new Error(
      detail ? `${command} ${args.join(" ")} failed:\n${detail}` : `${command} ${args.join(" ")} failed`
    );
  }
  return result.stdout?.trim() ?? "";
}

function defaultSwiftBuildArch() {
  if (process.platform !== "darwin") {
    return "";
  }
  const result = spawnSync("sysctl", ["-n", "hw.optional.arm64"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  return result.stdout?.trim() === "1" ? "arm64" : "";
}

function swiftBuildArgs(...args) {
  const scratchArgs = swiftScratchPath ? [...args, "--scratch-path", swiftScratchPath] : args;
  const architectureArgs = swiftBuildArch ? [...scratchArgs, "--arch", swiftBuildArch] : scratchArgs;
  return swiftBuildConfiguration
    ? [...architectureArgs, "--configuration", swiftBuildConfiguration]
    : architectureArgs;
}

function availableCodeSigningIdentities() {
  if (process.platform !== "darwin") {
    return [];
  }
  const result = spawnSync("security", ["find-identity", "-v", "-p", "codesigning"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0) {
    return [];
  }
  return result.stdout
    .split(/\n/)
    .map((line) => {
      const match = line.match(/^\s*\d+\)\s+[A-Fa-f0-9]+\s+"([^"]+)"/);
      return match?.[1];
    })
    .filter(Boolean);
}

function defaultCodeSigningIdentity() {
  const identities = availableCodeSigningIdentities();
  return (
    identities.find((identity) => identity.startsWith("Apple Development:"))
    ?? identities.find((identity) => identity.startsWith("Developer ID Application:"))
    ?? identities[0]
    ?? "-"
  );
}

function codeSigningIdentity() {
  if (!requestedSigningIdentity) {
    return defaultCodeSigningIdentity();
  }
  if (requestedSigningIdentity === "adhoc" || requestedSigningIdentity === "ad-hoc") {
    return "-";
  }
  return requestedSigningIdentity;
}

function usesHardenedRuntime(identity) {
  return identity.startsWith("Developer ID Application:");
}

function codesignArgs(identity, path, options = {}) {
  const args = ["--force", "--sign", identity];
  if (usesHardenedRuntime(identity)) {
    args.push("--timestamp", "--options", "runtime");
    if (options.entitlements) {
      args.push("--entitlements", options.entitlements);
    }
  }
  if (options.identifier) {
    args.push("--identifier", options.identifier);
  }
  args.push(path);
  return args;
}

function verifyNodeRuntime(executable) {
  const result = spawnSync(executable, ["-e", "process.stdout.write(process.arch)"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    throw new Error(
      `Signed bundled Node.js failed its launch check${detail ? `:\n${detail}` : "."}`
    );
  }
  if (result.stdout.trim() !== bundledNodeArchitecture) {
    throw new Error(
      `Signed bundled Node.js reported ${result.stdout.trim() || "no architecture"}; expected ${bundledNodeArchitecture}`
    );
  }
}

function nestedMachOPaths(root) {
  const paths = [];
  function visit(directory) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        visit(path);
        continue;
      }
      if (!entry.isFile()) continue;
      const result = spawnSync("file", ["-b", path], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      });
      if (result.status === 0 && result.stdout.includes("Mach-O")) {
        paths.push(path);
      }
    }
  }
  visit(root);
  return paths.sort((left, right) => right.length - left.length || left.localeCompare(right));
}

function xmlEscape(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function runningProcessesForBinary(binaryPath) {
  const result = spawnSync("pgrep", ["-f", binaryPath], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0) {
    return [];
  }
  return result.stdout
    .trim()
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function writeInfoPlist(bundlePath) {
  const contentsDir = join(bundlePath, "Contents");
  const updates = sparkleUpdateConfiguration();
  const sparkleConfiguration = updates.enabled
    ? `
  <key>SUFeedURL</key>
  <string>${updates.feedURL}</string>
  <key>SUPublicEDKey</key>
  <string>${OPENORG_SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>${OPENORG_SPARKLE_CHECK_INTERVAL_SECONDS}</integer>
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUEnableSystemProfiling</key>
  <false/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>SURequireSignedFeed</key>
  <true/>`
    : "";
  const googleOAuthConfiguration = `${googleOAuthClientID
    ? `
  <key>OpenOrgGoogleOAuthClientID</key>
  <string>${xmlEscape(googleOAuthClientID)}</string>`
    : ""}${googleOAuthClientSecret
    ? `
  <key>OpenOrgGoogleOAuthClientSecret</key>
  <string>${xmlEscape(googleOAuthClientSecret)}</string>`
    : ""}`;
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${xmlEscape(appName)}</string>
  <key>CFBundleExecutable</key>
  <string>${xmlEscape(executableName)}</string>
  <key>CFBundleIdentifier</key>
  <string>${xmlEscape(bundleIdentifier)}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>${xmlEscape(appName)}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${xmlEscape(packageVersion)}</string>
  <key>CFBundleVersion</key>
  <string>${xmlEscape(packageVersion)}</string>${sparkleConfiguration}${googleOAuthConfiguration}
  <key>Org2BuildConfiguration</key>
  <string>${xmlEscape(swiftBuildConfiguration)}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>${xmlEscape(appName)} serves document links that you explicitly publish to your local network.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>${xmlEscape(appName)} records microphone audio for meeting notes.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>${xmlEscape(appName)} uses ScreenCaptureKit to capture system and call audio for meeting notes.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>${xmlEscape(appName)} may use macOS Speech recognition as a fallback when its bundled local transcriber cannot run.</string>
</dict>
</plist>
`;
  writeFileSync(join(contentsDir, "Info.plist"), plist);
}

function copySparkleFramework(buildProductsDir, contentsDir) {
  const source = join(buildProductsDir, "Sparkle.framework");
  if (!existsSync(source)) {
    throw new Error(`Sparkle.framework was not produced in ${buildProductsDir}`);
  }
  const frameworksDir = join(contentsDir, "Frameworks");
  const destination = join(frameworksDir, "Sparkle.framework");
  mkdirSync(frameworksDir, { recursive: true });
  run("ditto", [source, destination], { capture: true });
  return destination;
}

function signSparkleFramework(frameworkPath, identity) {
  const versionRoot = join(frameworkPath, "Versions", "B");
  const nestedTargets = [
    { path: join(versionRoot, "XPCServices", "Installer.xpc") },
    { path: join(versionRoot, "XPCServices", "Downloader.xpc"), preserveEntitlements: true },
    { path: join(versionRoot, "Autoupdate") },
    { path: join(versionRoot, "Updater.app") },
  ];
  for (const target of nestedTargets) {
    if (!existsSync(target.path)) continue;
    const args = ["--force", "--sign", identity];
    if (usesHardenedRuntime(identity)) {
      args.push("--timestamp", "--options", "runtime");
    }
    if (target.preserveEntitlements) {
      args.push("--preserve-metadata=entitlements");
    }
    args.push(target.path);
    run("codesign", args);
  }
  run("codesign", codesignArgs(identity, frameworkPath));
}

function writeIconSet(sourcePngPath, resourcesDir) {
  if (!existsSync(sourcePngPath)) {
    return;
  }

  copyFileSync(sourcePngPath, join(resourcesDir, "AppIcon.png"));

  if (process.platform !== "darwin") {
    return;
  }

  const iconsetParentDir = mkdtempSync(join(tmpdir(), "org2-appicon-"));
  const iconsetDir = join(iconsetParentDir, "AppIcon.iconset");
  mkdirSync(iconsetDir, { recursive: true });
  try {
    const sizes = [
      [16, "icon_16x16.png"],
      [32, "icon_16x16@2x.png"],
      [32, "icon_32x32.png"],
      [64, "icon_32x32@2x.png"],
      [128, "icon_128x128.png"],
      [256, "icon_128x128@2x.png"],
      [256, "icon_256x256.png"],
      [512, "icon_256x256@2x.png"],
      [512, "icon_512x512.png"],
      [1024, "icon_512x512@2x.png"],
    ];
    for (const [size, name] of sizes) {
      run("sips", ["-z", String(size), String(size), sourcePngPath, "--out", join(iconsetDir, name)], {
        capture: true,
      });
    }
    run("iconutil", ["-c", "icns", iconsetDir, "-o", join(resourcesDir, "AppIcon.icns")], {
      capture: true,
    });
  } finally {
    rmSync(iconsetParentDir, { recursive: true, force: true });
  }
}

function copyOrg2Runtime(resourcesDir) {
  const distPath = join(repoRoot, "dist");
  if (!existsSync(join(distPath, "cli.js")) || !existsSync(join(distPath, "render-html.js"))) {
    throw new Error(`Org2 runtime not found in ${distPath}. Run npm run build first.`);
  }

  const runtimeDir = join(resourcesDir, "Org2Runtime");
  rmSync(runtimeDir, { recursive: true, force: true });
  mkdirSync(runtimeDir, { recursive: true });
  cpSync(distPath, join(runtimeDir, "dist"), { recursive: true });
  copyFileSync(join(repoRoot, "package.json"), join(runtimeDir, "package.json"));
  cpSync(join(repoRoot, "skills"), join(runtimeDir, "skills"), { recursive: true });

  if (bundledNodePath && !existsSync(bundledNodePath)) {
    throw new Error(`Bundled Node.js runtime not found at ${bundledNodePath}`);
  }
  if (!bundledNodePath && swiftBuildConfiguration === "release") {
    throw new Error(
      "Release builds require Node.js so the app is self-contained. Install Node.js or set ORG2_WORKSPACE_NODE_PATH."
    );
  }

  const fallbackNodePath = [
    "/opt/homebrew/bin/node",
    "/usr/local/bin/node",
    "/usr/bin/node",
  ].find((candidate) => existsSync(candidate));
  const runtimeNodeSourcePath = bundledNodePath || fallbackNodePath;
  const runtimeNodeArchitecture = runtimeNodeSourcePath
    ? detectNodeArchitecture(runtimeNodeSourcePath)
    : null;
  // Node runs as a child process, so its architecture may differ from the Swift
  // app when Rosetta is available. Bundle the DuckDB binding for Node itself.
  const duckDBBindingPackages = duckDBBindingPackagesForRuntime({
    bundledNodePath,
    nodeArchitecture: runtimeNodeArchitecture,
  });
  const runtimePackages = [
    "@duckdb/node-api",
    "@duckdb/node-bindings",
    ...duckDBBindingPackages,
    "detect-libc",
  ];
  for (const packageName of runtimePackages) {
    const source = join(repoRoot, "node_modules", ...packageName.split("/"));
    if (!existsSync(source)) {
      if (swiftBuildConfiguration === "release") {
        throw new Error(`Production runtime dependency ${packageName} is missing. Run npm ci for the target Node.js architecture.`);
      }
      continue;
    }
    const destination = join(runtimeDir, "node_modules", ...packageName.split("/"));
    mkdirSync(dirname(destination), { recursive: true });
    cpSync(source, destination, { recursive: true });
  }

  let runtimeNodePath = runtimeNodeSourcePath;
  if (bundledNodePath) {
    const binDir = join(runtimeDir, "bin");
    mkdirSync(binDir, { recursive: true });
    const destination = join(binDir, "node");
    copyFileSync(bundledNodePath, destination);
    chmodSync(destination, 0o755);
    runtimeNodePath = destination;
  }

  if (runtimeNodePath) {
    const bindingEntry = join(runtimeDir, "node_modules", "@duckdb", "node-bindings");
    const verification = spawnSync(runtimeNodePath, ["-e", `require(${JSON.stringify(bindingEntry)})`], {
      cwd: runtimeDir,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (verification.status !== 0) {
      const detail = [verification.stdout, verification.stderr].filter(Boolean).join("\n").trim();
      throw new Error(
        `Bundled DuckDB failed to load with ${runtimeNodeArchitecture || "the selected"} Node.js runtime${detail ? `:\n${detail}` : "."}`
      );
    }
  }
  return bundledNodePath ? runtimeNodePath : "";
}

function copyWhisperRuntime(resourcesDir) {
  if (!bundledWhisperCppPath || !bundledWhisperModelPath) {
    if (swiftBuildConfiguration === "release") {
      throw new Error(
        "Release builds require whisper.cpp and its base English model. Install whisper-cpp and the Org2 model, or set ORG2_WORKSPACE_WHISPER_CPP_PATH and ORG2_WORKSPACE_WHISPER_MODEL_PATH."
      );
    }
    return { executable: "", libraries: [] };
  }
  if (!existsSync(bundledWhisperCppPath)) {
    throw new Error(`Bundled whisper.cpp executable not found at ${bundledWhisperCppPath}`);
  }
  if (!existsSync(bundledWhisperModelPath)) {
    throw new Error(`Bundled whisper.cpp model not found at ${bundledWhisperModelPath}`);
  }
  if (process.platform === "darwin" && swiftBuildArch) {
    const architectures = run("lipo", ["-archs", bundledWhisperCppPath], { capture: true }).split(/\s+/);
    if (!architectures.includes(swiftBuildArch)) {
      throw new Error(
        `Bundled whisper.cpp executable must include ${swiftBuildArch}; found ${architectures.join(", ") || "no Mach-O architecture"}.`
      );
    }
  }

  const whisperDir = join(resourcesDir, "Whisper");
  const binDir = join(whisperDir, "bin");
  const libDir = join(whisperDir, "lib");
  const modelsDir = join(whisperDir, "models");
  mkdirSync(binDir, { recursive: true });
  mkdirSync(libDir, { recursive: true });
  mkdirSync(modelsDir, { recursive: true });
  const executableDestination = join(binDir, "whisper-cli");
  copyFileSync(bundledWhisperCppPath, executableDestination);
  chmodSync(executableDestination, 0o755);
  copyFileSync(bundledWhisperModelPath, join(modelsDir, "ggml-base.en.bin"));

  const libraries = process.platform === "darwin"
    ? copyMachODependencies(bundledWhisperCppPath, executableDestination, libDir)
    : [];

  const noticesDir = join(repoRoot, "third_party", "whisper");
  for (const noticeFile of ["LICENSE-whisper.cpp", "LICENSE-openai-whisper", "NOTICE.md"]) {
    const source = join(noticesDir, noticeFile);
    if (!existsSync(source)) {
      throw new Error(`Bundled whisper attribution file not found at ${source}`);
    }
    copyFileSync(source, join(whisperDir, noticeFile));
  }
  return { executable: executableDestination, libraries };
}

function machODependencies(path) {
  const installNameResult = spawnSync("otool", ["-D", path], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  const installName = installNameResult.status === 0
    ? installNameResult.stdout.split(/\n/).slice(1).map((line) => line.trim()).find(Boolean)
    : "";
  return run("otool", ["-L", path], { capture: true })
    .split(/\n/)
    .slice(1)
    .map((line) => line.trim().split(/\s+/)[0])
    .filter((dependency) => dependency && dependency !== installName);
}

function copyMachODependencies(sourceExecutable, destinationExecutable, destinationLibDir) {
  const resolvedExecutable = realpathSync(sourceExecutable);
  const sourceLibDirs = [
    resolve(dirname(resolvedExecutable), "../lib"),
    resolve(dirname(sourceExecutable), "../lib"),
  ];
  const pending = [{ source: resolvedExecutable, destination: destinationExecutable }];
  const copiedByName = new Map();

  while (pending.length > 0) {
    const owner = pending.shift();
    for (const dependency of machODependencies(owner.source)) {
      if (dependency.startsWith("/usr/lib/") || dependency.startsWith("/System/Library/")) {
        continue;
      }
      const name = dependency.split("/").at(-1);
      const source = resolveMachODependency(dependency, owner.source, sourceLibDirs);
      if (!source) {
        throw new Error(`Could not resolve Whisper dependency ${dependency} for ${owner.source}`);
      }
      let destination = copiedByName.get(name);
      if (!destination) {
        destination = join(destinationLibDir, name);
        copyFileSync(source, destination);
        chmodSync(destination, 0o755);
        copiedByName.set(name, destination);
        pending.push({ source, destination });
      }
      if (dependency !== `@rpath/${name}`) {
        run("install_name_tool", ["-change", dependency, `@rpath/${name}`, owner.destination]);
      }
    }
  }

  for (const [name, destination] of copiedByName) {
    run("install_name_tool", ["-id", `@rpath/${name}`, destination]);
  }
  return [...copiedByName.values()];
}

function resolveMachODependency(dependency, ownerPath, sourceLibDirs) {
  const candidates = [];
  if (dependency.startsWith("@rpath/")) {
    const name = dependency.slice("@rpath/".length);
    candidates.push(...sourceLibDirs.map((directory) => join(directory, name)));
    candidates.push(resolve(dirname(ownerPath), "../lib", name));
  } else if (dependency.startsWith("@loader_path/")) {
    candidates.push(resolve(dirname(ownerPath), dependency.slice("@loader_path/".length)));
  } else if (dependency.startsWith("/")) {
    candidates.push(dependency);
  }
  const existing = candidates.find((candidate) => existsSync(candidate));
  return existing ? realpathSync(existing) : "";
}

function verifyWhisperRuntime(executable) {
  if (!executable) return;
  const verification = spawnSync(executable, ["--help"], {
    cwd: dirname(executable),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (verification.status !== 0) {
    const detail = [verification.stdout, verification.stderr].filter(Boolean).join("\n").trim();
    throw new Error(
      `Bundled whisper.cpp failed its launch check${detail ? `:\n${detail}` : "."}`
    );
  }
}

function main() {
  if (buildOptions.help) {
    console.log(buildUsage());
    return;
  }
  if (
    bundleIdentifier === "org.org2.workspace"
    && swiftBuildConfiguration === "debug"
    && !buildOptions.allowDailyDebug
  ) {
    throw new Error(
      "Refusing to install an implicit debug build as the daily app. Use npm run build:macos-app:debug when that is intentional."
    );
  }
  if (
    buildOptions.requireGoogleOAuthClient
    && (!googleOAuthClientID || !googleOAuthClientSecret)
  ) {
    throw new Error(
      "This distributable build requires OpenOrg's Google OAuth Desktop client. Set ORG2_GOOGLE_OAUTH_CLIENT_JSON to its protected JSON path, or set the paired ORG2_GOOGLE_OAUTH_CLIENT_ID and ORG2_GOOGLE_OAUTH_CLIENT_SECRET values."
    );
  }
  if (buildOptions.printConfiguration) {
    console.log(JSON.stringify({
      appPath,
      appName,
      bundleIdentifier,
      configuration: swiftBuildConfiguration,
      iconPath,
      hardenedRuntime: requestedSigningIdentity?.startsWith("Developer ID Application:") ?? false,
      installStrategy: "verified staged replacement",
      nodeArchitecture: bundledNodeArchitecture,
      nodeEntitlementsPath,
      nodePath: bundledNodePath || null,
      googleOAuthClientConfigured: googleOAuthClientID.length > 0,
      googleOAuthClientSecretConfigured: googleOAuthClientSecret.length > 0,
      googleOAuthClientSource: googleOAuthConfiguration.source,
      googleOAuthRequired: buildOptions.requireGoogleOAuthClient,
      swiftScratchPath: swiftScratchPath || null,
      updates: sparkleUpdateConfiguration(),
      whisperCppPath: bundledWhisperCppPath || null,
      whisperModelPath: bundledWhisperModelPath || null,
    }, null, 2));
    return;
  }

  const installedBinaryPath = join(appPath, "Contents", "MacOS", executableName);
  const runningPids = runningProcessesForBinary(installedBinaryPath);
  if (runningPids.length > 0) {
    throw new Error(`${appName} is running from ${appPath}. Quit it and rerun this command.`);
  }

  console.log("Building the shared Org2 runtime for the app bundle...");
  run("npm", ["run", "build"], { cwd: repoRoot });
  console.log(`Building ${executableName} (${swiftBuildConfiguration})...`);
  run("swift", swiftBuildArgs("build"), { cwd: packageDir });
  const buildProductsDir = run("swift", swiftBuildArgs("build", "--show-bin-path"), {
    cwd: packageDir,
    capture: true,
  });

  const binaryPath = join(buildProductsDir, executableName);
  if (!existsSync(binaryPath)) {
    throw new Error(`Built binary not found at ${binaryPath}`);
  }

  mkdirSync(dirname(appPath), { recursive: true });
  const stagingRoot = mkdtempSync(join(dirname(appPath), `.${basename(appPath)}.staging-`));
  const stagedAppPath = join(stagingRoot, basename(appPath));
  try {
    const contentsDir = join(stagedAppPath, "Contents");
    const macOSDir = join(contentsDir, "MacOS");
    const resourcesDir = join(contentsDir, "Resources");
    mkdirSync(macOSDir, { recursive: true });
    mkdirSync(resourcesDir, { recursive: true });

    writeInfoPlist(stagedAppPath);
    const appBinaryPath = join(macOSDir, executableName);
    copyFileSync(binaryPath, appBinaryPath);
    chmodSync(appBinaryPath, 0o755);
    const sparkleFrameworkPath = copySparkleFramework(buildProductsDir, contentsDir);

    if (!existsSync(iconPath)) {
      throw new Error(`App icon not found at ${iconPath}`);
    }
    writeIconSet(iconPath, resourcesDir);
    copyFileSync(
      join(packageDir, "Sources", "Org2WorkspaceCore", "Resources", "NewMessage.mp3"),
      join(resourcesDir, "NewMessage.mp3")
    );
    const runtimeNodePath = copyOrg2Runtime(resourcesDir);
    const whisperRuntime = copyWhisperRuntime(resourcesDir);

    const signingIdentity = codeSigningIdentity();
    const signingLabel = signingIdentity === "-" ? "ad-hoc" : signingIdentity;
    console.log(`Signing staged ${appName} as ${bundleIdentifier} with ${signingLabel}...`);
    if (usesHardenedRuntime(signingIdentity)) {
      for (const entitlementsPath of [appEntitlementsPath, nodeEntitlementsPath]) {
        if (!existsSync(entitlementsPath)) {
          throw new Error(`Hardened-runtime entitlements not found at ${entitlementsPath}`);
        }
      }
    }
    if (runtimeNodePath) {
      run("codesign", codesignArgs(signingIdentity, runtimeNodePath, {
        entitlements: nodeEntitlementsPath,
      }));
      verifyNodeRuntime(runtimeNodePath);
    }
    for (const library of whisperRuntime.libraries) {
      run("codesign", codesignArgs(signingIdentity, library));
    }
    if (whisperRuntime.executable) {
      run("codesign", codesignArgs(signingIdentity, whisperRuntime.executable));
      verifyWhisperRuntime(whisperRuntime.executable);
    }
    signSparkleFramework(sparkleFrameworkPath, signingIdentity);
    for (const nestedPath of nestedMachOPaths(resourcesDir)) {
      if (nestedPath === runtimeNodePath
          || nestedPath === whisperRuntime.executable
          || whisperRuntime.libraries.includes(nestedPath)) {
        continue;
      }
      run("codesign", codesignArgs(signingIdentity, nestedPath));
    }
    run("codesign", codesignArgs(signingIdentity, stagedAppPath, {
      entitlements: appEntitlementsPath,
      identifier: bundleIdentifier,
    }));
    run("codesign", ["--verify", "--deep", "--strict", stagedAppPath]);

    installStagedAppBundle({ stagedAppPath, targetAppPath: appPath });
    if (signingIdentity === "-") {
      console.warn(
        "Warning: ad-hoc signing gives the app a cdhash-based TCC identity. macOS Screen/System Audio permission may reset after rebuilds. Set ORG2_WORKSPACE_CODE_SIGN_IDENTITY to a stable signing identity to avoid that."
      );
    }
  } finally {
    rmSync(stagingRoot, { recursive: true, force: true });
  }

  console.log(`Built ${appPath}`);
  console.log(`Open with: open ${appPath}`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
