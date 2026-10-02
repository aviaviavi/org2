import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform !== "darwin") {
  console.log("OpenOrg launch-hook compilation requires macOS; skipped");
  process.exit(0);
}

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const appSource = readFileSync(join(repoRoot,
  "apps/macos/Org2Workspace/Sources/Org2Workspace/Org2WorkspaceApp.swift"), "utf8");
const start = appSource.indexOf("  func applicationDidFinishLaunching(_ notification: Notification) {");
const end = appSource.indexOf("    // AppKit defers", start);
assert.ok(start >= 0 && end > start, "locate the real app's startup telemetry hook");

// Compile the actual startup hook, with a spy at its transport boundary and
// without the later AppKit window setup. Core tests cover eligibility and payload.
// Local daily builds use DEBUG just like Preview, but have the production identity.
const directory = mkdtempSync(join(tmpdir(), "openorg-launch-hook-"));
try {
  const sourcePath = join(directory, "main.swift");
  writeFileSync(sourcePath, `
import Foundation
enum LocalAgentExecutableLocator { static func warmUp() {} }
final class TelemetrySpy {
  var count = 0
  func recordLaunch(bundleIdentifier: String?, version: String?, osVersion: String, architecture: String) {
    count += 1
  }
}
final class Delegate {
  let telemetry = TelemetrySpy()
${appSource.slice(start, end)}
  }
}
let delegate = Delegate()
delegate.applicationDidFinishLaunching(Notification(name: Notification.Name("launch")))
print(delegate.telemetry.count)
`);
  for (const configuration of ["debug", "release"]) {
    const executable = join(directory, configuration);
    const compile = spawnSync("xcrun", ["swiftc", ...(configuration === "debug" ? ["-D", "DEBUG"] : []),
      sourcePath, "-o", executable], { encoding: "utf8" });
    assert.equal(compile.status, 0, compile.stderr);
    const run = spawnSync(executable, [], { encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stdout.trim(), "1", `${configuration} daily app must reach the telemetry eligibility check`);
  }
} finally {
  rmSync(directory, { recursive: true, force: true });
}
console.log("OpenOrg debug/release launch-hook tests passed");
