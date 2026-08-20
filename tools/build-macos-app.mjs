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
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  detectNodeArchitecture,
  duckDBBindingPackagesForRuntime,
} from "./macos-runtime-node.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageVersion = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).version;
const packageDir = join(repoRoot, "apps", "macos", "Org2Workspace");
const buildOptions = parseBuildOptions(process.argv.slice(2));
const appPath = resolve(
  process.env.ORG2_WORKSPACE_APP_PATH ?? join(homedir(), "Applications", "Org2Workspace.app")
);
const bundleIdentifier = process.env.ORG2_WORKSPACE_BUNDLE_ID ?? "org.org2.workspace";
const appName = process.env.ORG2_WORKSPACE_APP_NAME ?? "Org2Workspace";
const requestedSigningIdentity = process.env.ORG2_WORKSPACE_CODE_SIGN_IDENTITY?.trim();
const executableName = "Org2Workspace";
const swiftBuildArch = process.env.ORG2_WORKSPACE_SWIFT_ARCH ?? defaultSwiftBuildArch();
const swiftBuildConfiguration = resolveBuildConfiguration();
const bundledNodePath = process.env.ORG2_WORKSPACE_NODE_PATH?.trim()
  || (swiftBuildConfiguration === "release" ? discoverNodePath() : "");
const bundledWhisperCppPath = process.env.ORG2_WORKSPACE_WHISPER_CPP_PATH?.trim()
  || (swiftBuildConfiguration === "release" ? discoverWhisperCppPath() : "");
const bundledWhisperModelPath = process.env.ORG2_WORKSPACE_WHISPER_MODEL_PATH?.trim()
  || (swiftBuildConfiguration === "release" ? discoverWhisperModelPath() : "");

function parseBuildOptions(arguments_) {
  const options = {
    allowDailyDebug: false,
    configuration: "",
    help: false,
    printConfiguration: false,
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
      case "--print-configuration":
        options.printConfiguration = true;
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
  --print-configuration   Print the resolved mode and paths without building
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
  const architectureArgs = swiftBuildArch ? [...args, "--arch", swiftBuildArch] : args;
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

function writeInfoPlist() {
  const contentsDir = join(appPath, "Contents");
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
  <string>1</string>
  <key>Org2BuildConfiguration</key>
  <string>${xmlEscape(swiftBuildConfiguration)}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Org2Workspace records microphone audio for meeting notes.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Org2Workspace uses ScreenCaptureKit to capture system and call audio for meeting notes.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Org2Workspace may use macOS Speech recognition as a fallback when its bundled local transcriber cannot run.</string>
</dict>
</plist>
`;
  writeFileSync(join(contentsDir, "Info.plist"), plist);
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
  if (buildOptions.printConfiguration) {
    console.log(JSON.stringify({
      appPath,
      bundleIdentifier,
      configuration: swiftBuildConfiguration,
      nodePath: bundledNodePath || null,
      whisperCppPath: bundledWhisperCppPath || null,
      whisperModelPath: bundledWhisperModelPath || null,
    }, null, 2));
    return;
  }

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

  const contentsDir = join(appPath, "Contents");
  const macOSDir = join(contentsDir, "MacOS");
  const resourcesDir = join(contentsDir, "Resources");
  mkdirSync(macOSDir, { recursive: true });
  mkdirSync(resourcesDir, { recursive: true });
  for (const entry of readdirSync(appPath)) {
    if (entry !== "Contents") {
      rmSync(join(appPath, entry), { recursive: true, force: true });
    }
  }

  writeInfoPlist();
  const appBinaryPath = join(macOSDir, executableName);
  const runningPids = runningProcessesForBinary(appBinaryPath);
  if (runningPids.length > 0) {
    throw new Error(`Org2Workspace is running from ${appPath}. Quit it and rerun this command.`);
  }
  copyFileSync(binaryPath, appBinaryPath);
  chmodSync(appBinaryPath, 0o755);

  const iconPath = join(packageDir, "Sources", "Org2Workspace", "Resources", "AppIcon.png");
  writeIconSet(iconPath, resourcesDir);
  copyFileSync(
    join(packageDir, "Sources", "Org2WorkspaceCore", "Resources", "NewMessage.mp3"),
    join(resourcesDir, "NewMessage.mp3")
  );
  const runtimeNodePath = copyOrg2Runtime(resourcesDir);
  const whisperRuntime = copyWhisperRuntime(resourcesDir);

  const signingIdentity = codeSigningIdentity();
  const signingLabel = signingIdentity === "-" ? "ad-hoc" : signingIdentity;
  console.log(`Signing ${appPath} as ${bundleIdentifier} with ${signingLabel}...`);
  if (runtimeNodePath) {
    run("codesign", ["--force", "--sign", signingIdentity, runtimeNodePath]);
  }
  for (const library of whisperRuntime.libraries) {
    run("codesign", ["--force", "--sign", signingIdentity, library]);
  }
  if (whisperRuntime.executable) {
    run("codesign", ["--force", "--sign", signingIdentity, whisperRuntime.executable]);
    verifyWhisperRuntime(whisperRuntime.executable);
  }
  run("codesign", ["--force", "--sign", signingIdentity, "--identifier", bundleIdentifier, appPath]);
  if (signingIdentity === "-") {
    console.warn(
      "Warning: ad-hoc signing gives the app a cdhash-based TCC identity. macOS Screen/System Audio permission may reset after rebuilds. Set ORG2_WORKSPACE_CODE_SIGN_IDENTITY to a stable signing identity to avoid that."
    );
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
