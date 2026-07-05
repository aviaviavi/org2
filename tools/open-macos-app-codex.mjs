#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const node = process.execPath;
const appPath = resolve(
  process.env.ORG2_WORKSPACE_APP_PATH ?? join(homedir(), "Applications", "Org2Workspace Codex.app")
);

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    stdio: "inherit",
  });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed`);
  }
}

run(node, [join(repoRoot, "tools", "setup-macos-codex-workspace.mjs")]);

if (!existsSync(appPath)) {
  run(node, [join(repoRoot, "tools", "build-macos-app-codex.mjs")]);
}

run("open", ["-n", appPath, "--args", "-ApplePersistenceIgnoreState", "YES"]);
