#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageDir = join(repoRoot, "apps", "macos", "Org2Workspace");
const corpusRoot = join(repoRoot, "examples", "macos-workspace-demo");
const renderCorpusContainer = "/tmp/org2-macos-workspace-demo";
const renderCorpusRoot = join(renderCorpusContainer, "Org2 Demo");
const screenshotDir = join(repoRoot, "docs", "site", "assets", "screenshots");

const scenarios = [
  {
    mode: "agenda",
    target: "launch readiness",
    fileName: "macos-workspace-agenda.png",
  },
  {
    mode: "approvals",
    target: "publish the beacon launch brief",
    fileName: "macos-workspace-runs-review.png",
  },
  {
    mode: "files",
    target: "notes/projects/beacon-launch",
    fileName: "macos-workspace-files.png",
  },
  {
    mode: "files",
    target: "views/launch-readiness-data",
    fileName: "macos-workspace-data.png",
  },
  {
    mode: "ai-room",
    fileName: "macos-workspace-ai-room.png",
  },
  {
    mode: "meetings",
    target: "beta review",
    fileName: "macos-workspace-meetings.png",
  },
];

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    env: options.env ?? process.env,
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

function captureScenario(scenario) {
  const outputPath = join(screenshotDir, scenario.fileName);
  run("swift", ["run", "Org2WorkspaceScreenshotRenderer", "--out", outputPath], {
    cwd: packageDir,
    env: {
      ...process.env,
      ORG2_REPO_ROOT: repoRoot,
      ORG2_WORKSPACE_SCREENSHOT_CORPUS: renderCorpusRoot,
      ORG2_WORKSPACE_SCREENSHOT_MODE: scenario.mode,
      ORG2_WORKSPACE_SCREENSHOT_TARGET: scenario.target ?? "",
      ORG2_WORKSPACE_SCREENSHOT_WIDTH: "1400",
      ORG2_WORKSPACE_SCREENSHOT_HEIGHT: "900",
      ORG2_WORKSPACE_SCREENSHOT_SCALE: "1",
    },
  });
  console.log(`Rendered ${outputPath}`);
}

function main() {
  if (process.platform !== "darwin") {
    throw new Error("macOS Workspace screenshots can only be rendered on macOS.");
  }
  if (!existsSync(corpusRoot)) {
    throw new Error(`Demo corpus not found: ${corpusRoot}`);
  }

  mkdirSync(screenshotDir, { recursive: true });
  rmSync(renderCorpusContainer, { recursive: true, force: true });
  mkdirSync(renderCorpusContainer, { recursive: true });
  cpSync(corpusRoot, renderCorpusRoot, { recursive: true });
  run("npm", ["run", "build"]);

  for (const scenario of scenarios) {
    captureScenario(scenario);
  }

  run("npm", ["run", "org2", "--", "publish", "docs-site", "--config", "org2.json"]);
  console.log("Updated macOS Workspace screenshot assets.");
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
