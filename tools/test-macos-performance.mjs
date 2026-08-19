#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const supportsArm64 = spawnSync("sysctl", ["-n", "hw.optional.arm64"], {
  encoding: "utf8",
}).stdout?.trim() === "1";
const testArgs = [
  "test",
  "--package-path", "apps/macos/Org2Workspace",
  "--configuration", "release",
  "--filter", "WorkspacePerformanceRegressionTests",
];
const command = supportsArm64 ? "arch" : "swift";
const args = supportsArm64
  ? ["-arm64", "swift", ...testArgs, "--arch", "arm64"]
  : testArgs;
const result = spawnSync(command, args, {
  cwd: repoRoot,
  stdio: "inherit",
});

process.exit(result.status ?? 1);
