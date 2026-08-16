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
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageVersion = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).version;
const packageDir = join(repoRoot, "apps", "macos", "Org2Workspace");
const appPath = resolve(
  process.env.ORG2_WORKSPACE_APP_PATH ?? join(homedir(), "Applications", "Org2Workspace.app")
);
const bundleIdentifier = process.env.ORG2_WORKSPACE_BUNDLE_ID ?? "org.org2.workspace";
const appName = process.env.ORG2_WORKSPACE_APP_NAME ?? "Org2Workspace";
const requestedSigningIdentity = process.env.ORG2_WORKSPACE_CODE_SIGN_IDENTITY?.trim();
const executableName = "Org2Workspace";
const swiftBuildArch = process.env.ORG2_WORKSPACE_SWIFT_ARCH ?? defaultSwiftBuildArch();
const swiftBuildConfiguration = process.env.ORG2_WORKSPACE_SWIFT_CONFIGURATION?.trim();
const bundledNodePath = process.env.ORG2_WORKSPACE_NODE_PATH?.trim();

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
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Org2Workspace records microphone audio for meeting notes.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Org2Workspace uses ScreenCaptureKit to capture system and call audio for meeting notes.</string>
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

  if (bundledNodePath) {
    if (!existsSync(bundledNodePath)) {
      throw new Error(`Bundled Node.js runtime not found at ${bundledNodePath}`);
    }
    const binDir = join(runtimeDir, "bin");
    mkdirSync(binDir, { recursive: true });
    const destination = join(binDir, "node");
    copyFileSync(bundledNodePath, destination);
    chmodSync(destination, 0o755);
    return destination;
  }
  return "";
}

function main() {
  console.log(`Building ${executableName}...`);
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
  const runtimeNodePath = copyOrg2Runtime(resourcesDir);

  const signingIdentity = codeSigningIdentity();
  const signingLabel = signingIdentity === "-" ? "ad-hoc" : signingIdentity;
  console.log(`Signing ${appPath} as ${bundleIdentifier} with ${signingLabel}...`);
  if (runtimeNodePath) {
    run("codesign", ["--force", "--sign", signingIdentity, runtimeNodePath]);
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
