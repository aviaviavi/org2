#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
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
    target: "notes/projects/beacon-launch",
    contextTab: "brief",
    fileName: "macos-workspace-context.png",
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
  // Homepage crops: rendered at 2x and cropped (in points) to the part of the
  // window each homepage section describes.
  {
    mode: "ai-room",
    target: "atlas pilot handoff",
    width: 1400,
    height: 1000,
    scale: 2,
    crop: { x: 352, y: 92, width: 1048, height: 572 },
    fileName: "home-agents-room.png",
  },
  {
    mode: "approvals",
    target: "publish the beacon launch brief",
    width: 1400,
    height: 700,
    scale: 2,
    crop: { x: 350, y: 36, width: 1050, height: 384 },
    fileName: "home-agent-work.png",
  },
  {
    mode: "approvals",
    target: "publish the beacon launch brief",
    width: 1400,
    height: 700,
    scale: 2,
    crop: { x: 800, y: 200, width: 590, height: 210 },
    fileName: "home-approval-desktop.png",
  },
  {
    mode: "files",
    target: "views/launch-readiness-data",
    width: 1400,
    height: 1150,
    scale: 2,
    settleMs: 6000,
    crop: { x: 790, y: 190, width: 610, height: 750 },
    fileName: "home-data-notebook.png",
  },
  {
    mode: "meetings",
    target: "beta review",
    contextTab: "references",
    width: 1900,
    height: 1500,
    scale: 2,
    settleMs: 6000,
    crop: { x: 1070, y: 590, width: 830, height: 840 },
    fileName: "home-meeting-notes.png",
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
  const scale = scenario.scale ?? 1;
  // Cropped homepage shots render the full window first, then keep only the
  // region named in points so the published image stays readable at page size.
  const renderPath = scenario.crop
    ? join(tmpdir(), `org2-screenshot-${process.pid}-${scenario.fileName}`)
    : outputPath;
  run("swift", ["run", "Org2WorkspaceScreenshotRenderer", "--out", renderPath], {
    cwd: packageDir,
    env: {
      ...process.env,
      ORG2_REPO_ROOT: repoRoot,
      ORG2_WORKSPACE_SCREENSHOT_CORPUS: renderCorpusRoot,
      ORG2_WORKSPACE_SCREENSHOT_MODE: scenario.mode,
      ORG2_WORKSPACE_SCREENSHOT_TARGET: scenario.target ?? "",
      ORG2_WORKSPACE_SCREENSHOT_CONTEXT_TAB: scenario.contextTab ?? "",
      ORG2_WORKSPACE_SCREENSHOT_WIDTH: String(scenario.width ?? 1400),
      ORG2_WORKSPACE_SCREENSHOT_HEIGHT: String(scenario.height ?? 900),
      ORG2_WORKSPACE_SCREENSHOT_SCALE: String(scale),
      ...(scenario.settleMs ? { ORG2_WORKSPACE_SCREENSHOT_SETTLE_MS: String(scenario.settleMs) } : {}),
    },
  });
  if (scenario.crop) {
    const { x, y, width, height } = scenario.crop;
    run("sips", [
      "--cropOffset", String(Math.round(y * scale)), String(Math.round(x * scale)),
      "-c", String(Math.round(height * scale)), String(Math.round(width * scale)),
      renderPath, "--out", outputPath,
    ], { capture: true });
    rmSync(renderPath, { force: true });
  }
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

  // --only=PREFIX limits the run to screenshots whose file name starts with
  // PREFIX, for example --only=home- for the homepage crops.
  const only = process.argv.find((arg) => arg.startsWith("--only="))?.slice("--only=".length);
  const selected = only ? scenarios.filter((scenario) => scenario.fileName.startsWith(only)) : scenarios;
  if (selected.length === 0) {
    throw new Error(`No screenshot scenarios match --only=${only}`);
  }
  for (const scenario of selected) {
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
