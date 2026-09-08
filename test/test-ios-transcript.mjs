import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

// Compile the actual Foundation-only iOS policy, without rebuilding the Mac app.
if (process.platform === "darwin") {
  const directory = mkdtempSync(join(tmpdir(), "org2-ios-transcript-test-"));
  try {
    const executable = join(directory, "transcript-regression");
    for (const [command, args] of [
      ["xcrun", ["swiftc", "-swift-version", "6", "-O",
        resolve("apps/ios/Org2Mobile/Org2Mobile/MobileRemoteTranscriptPage.swift"),
        resolve("test/ios-transcript-regression.swift"), "-o", executable]],
      [executable, []],
    ]) {
      const result = spawnSync(command, args, { encoding: "utf8", timeout: 60_000 });
      assert.equal(result.status, 0, result.error?.message ?? `${result.stdout}\n${result.stderr}`);
      if (result.stdout) process.stdout.write(result.stdout);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
} else {
  console.log("iOS transcript runtime regressions require the macOS Swift toolchain");
}
