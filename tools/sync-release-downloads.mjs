#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

export const repository = "aviaviavi/org2";
export const scarfGatewayBase = "https://org2.gateway.scarf.sh/downloads";
export const managedBlockStart = "<!-- org2-scarf-downloads:start -->";
export const managedBlockEnd = "<!-- org2-scarf-downloads:end -->";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const downloadsSourcePath = path.join(repoRoot, "docs/site/downloads.org");

function run(command, args, { input } = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    input,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(
      `${command} ${args.join(" ")} failed: ${(result.stderr || result.stdout || "unknown error").trim()}`,
    );
  }
  return result.stdout;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function encodePathSegment(value) {
  return encodeURIComponent(String(value)).replaceAll("%2F", "/");
}

export function scarfDownloadUrl(version, artifact) {
  return `${scarfGatewayBase}/${encodePathSegment(version)}/${encodePathSegment(artifact)}`;
}

export function artifactKind(name) {
  const lower = name.toLowerCase();
  if (lower.endsWith(".dmg")) return "macos";
  if (lower.endsWith(".vsix")) return "vscode";
  if (lower.endsWith(".tgz")) return "npm";
  return "other";
}

export function artifactLabel(asset) {
  switch (artifactKind(asset.name)) {
    case "macos":
      return "Org2 Workspace for macOS (Apple Silicon DMG)";
    case "vscode":
      return "Org2 for VS Code (VSIX)";
    case "npm":
      return "Org2 npm package (TGZ)";
    default:
      return asset.name;
  }
}

function artifactRank(asset) {
  return { macos: 0, vscode: 1, npm: 2, other: 3 }[artifactKind(asset.name)];
}

export function sortedAssets(release) {
  return [...(release.assets || [])].sort(
    (left, right) => artifactRank(left) - artifactRank(right) || left.name.localeCompare(right.name),
  );
}

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${bytes} B`;
}

export function releaseDownloadBlock(release) {
  const assets = sortedAssets(release);
  const lines = [
    managedBlockStart,
    "## Direct downloads",
    "",
    "These links are measured by Scarf Gateway and redirect to the original files hosted on GitHub Releases.",
    "",
    ...assets.map(
      (asset) => `- [${artifactLabel(asset)}](${scarfDownloadUrl(release.tag_name, asset.name)})`,
    ),
    managedBlockEnd,
  ];
  return lines.join("\n");
}

export function mergeReleaseDownloadBlock(body, release) {
  const block = releaseDownloadBlock(release);
  const managedPattern = new RegExp(
    `${managedBlockStart.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}[\\s\\S]*?${managedBlockEnd.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\n*`,
    "m",
  );
  const remainder = String(body || "").replace(managedPattern, "").trim();
  return remainder ? `${block}\n\n${remainder}\n` : `${block}\n`;
}

function currentReleaseCard(asset, version) {
  const kind = artifactKind(asset.name);
  const descriptions = {
    macos: "Native Apple Silicon workspace app. Developer-signed and currently not notarized.",
    vscode: "Editor integration with syntax, agenda, navigation, formatting, and Org2 commands.",
    npm: "CLI, compiler, language server, publishing runtime, and agent-facing tools.",
    other: "Additional release artifact.",
  };
  return [
    `    <article class="org2-download-card org2-download-card-${escapeHtml(kind)}">`,
    `      <p class="org2-download-kicker">${escapeHtml(kind === "macos" ? "macOS" : kind === "vscode" ? "VS Code" : kind === "npm" ? "npm / CLI" : "Artifact")}</p>`,
    `      <h3>${escapeHtml(artifactLabel(asset))}</h3>`,
    `      <p>${escapeHtml(descriptions[kind])}</p>`,
    `      <p class="org2-download-meta">${escapeHtml(version)} · ${escapeHtml(formatBytes(asset.size))}</p>`,
    `      <a class="org2-download-button" href="${escapeHtml(scarfDownloadUrl(version, asset.name))}">Download <span aria-hidden="true">↓</span></a>`,
    "    </article>",
  ].join("\n");
}

function orgLink(version, asset) {
  if (!asset) return "—";
  return `[[${scarfDownloadUrl(version, asset.name)}][Download]]`;
}

export function renderDownloadsPage(releases) {
  const published = releases
    .filter((release) => !release.draft && !release.prerelease && (release.assets || []).length > 0)
    .sort((left, right) => String(right.published_at).localeCompare(String(left.published_at)));
  if (!published.length) throw new Error("No published releases with assets were found");

  const current = published[0];
  const cards = sortedAssets(current).map((asset) => currentReleaseCard(asset, current.tag_name)).join("\n");
  const rows = published.map((release) => {
    const byKind = new Map(sortedAssets(release).map((asset) => [artifactKind(asset.name), asset]));
    return `| ${release.tag_name} | ${orgLink(release.tag_name, byKind.get("macos"))} | ${orgLink(release.tag_name, byKind.get("vscode"))} | ${orgLink(release.tag_name, byKind.get("npm"))} |`;
  });

  return `#+TITLE: Downloads
#+SUBTITLE: Install Org2 apps and tools from versioned GitHub release artifacts

#+BEGIN_EXPORT html
<section class="org2-page-intro org2-downloads-intro">
  <p>Choose the Org2 surface you need. Every direct-download link passes through Scarf Gateway for aggregate download measurement, then redirects to the original artifact hosted on GitHub Releases.</p>
  <div class="org2-page-summary" aria-label="Org2 download overview">
    <div><strong>One stable route.</strong><span>Version and artifact names map directly to immutable GitHub release files.</span></div>
    <div><strong>No mirror.</strong><span>GitHub Releases remains the underlying host for every binary and package archive.</span></div>
    <div><strong>Inspectable releases.</strong><span>Checksums, notes, source tags, and attached artifacts stay together on GitHub.</span></div>
  </div>
</section>
#+END_EXPORT

* Current release ${current.tag_name}

#+BEGIN_EXPORT html
<section class="org2-download-grid" aria-label="Org2 ${escapeHtml(current.tag_name)} downloads">
${cards}
</section>
#+END_EXPORT

The macOS disk image is built for Apple Silicon and is developer-signed but not notarized. If macOS blocks its first launch, right-click the app and choose *Open*, or allow it under *System Settings → Privacy & Security*.

For registry-managed installation, use =npm install -g @aviaviavi/org2= or install [[https://marketplace.visualstudio.com/items?itemName=AviPress.org2-vscode][Org2 from the VS Code Marketplace]]. The paired iOS app is distributed separately through TestFlight.

* iOS mobile app

Org2 Mobile brings capture, agenda, approvals, and Mac-hosted AI chat to iPhone. The beta is currently invitation-only, or you can build the open-source app directly with Xcode.

#+BEGIN_EXPORT html
<section class="org2-download-grid org2-download-grid-mobile" aria-label="Org2 Mobile installation options">
  <article class="org2-download-card org2-download-card-ios">
    <p class="org2-download-kicker">TestFlight</p>
    <h3>Join the private beta</h3>
    <p>Get the current iPhone build and future beta updates through TestFlight. Email Avi to request an invitation; include the email address you use with TestFlight.</p>
    <p class="org2-download-meta">Private beta · iPhone</p>
    <a class="org2-download-button" href="mailto:mail@avi.press?subject=Org2%20Mobile%20TestFlight">Request TestFlight access <span aria-hidden="true">→</span></a>
  </article>
  <article class="org2-download-card org2-download-card-source">
    <p class="org2-download-kicker">Open source</p>
    <h3>Build it with Xcode</h3>
    <p>Open the included Xcode project, select your Apple development team, configure the shared App Group, and install directly on your own iPhone.</p>
    <p class="org2-download-meta">Source · Xcode</p>
    <a class="org2-download-button" href="https://github.com/aviaviavi/org2/tree/main/apps/ios/Org2Mobile">View iOS source <span aria-hidden="true">↗</span></a>
  </article>
</section>
#+END_EXPORT

The [[file:getting-started.org::*iOS app][iOS setup guide]] covers source signing, the share extension, corpus sync, and pairing Mobile Remote with the Mac app over Tailscale.

* All release artifacts

These are the same files attached to each [[https://github.com/aviaviavi/org2/releases][GitHub Release]]. Scarf Gateway records the version and artifact variables before redirecting to GitHub.

| Version | macOS DMG | VS Code VSIX | npm TGZ |
|---------+-----------+----------------+---------|
${rows.join("\n")}

* Stable download URL

Release automation uses one permanent template:

#+begin_src text
https://org2.gateway.scarf.sh/downloads/{version}/{artifact}
#+end_src

For example, the current macOS build is:

#+begin_src text
${scarfDownloadUrl(current.tag_name, "Org2Workspace.dmg")}
#+end_src

Scarf redirects that request to the matching =github.com/aviaviavi/org2/releases/download/{version}/{artifact}= URL. No release files are hosted separately by Scarf.
`;
}

function fetchReleases() {
  const output = run("gh", ["api", "--paginate", "--slurp", `repos/${repository}/releases?per_page=100`]);
  const parsed = JSON.parse(output);
  return Array.isArray(parsed[0]) ? parsed.flat() : parsed;
}

function updateRelease(release, body) {
  run("gh", [
    "api",
    "--method",
    "PATCH",
    `repos/${repository}/releases/${release.id}`,
    "--field",
    `body=${body}`,
  ]);
}

export function parseArgs(argv) {
  const options = {
    applyPage: false,
    applyReleaseNotes: false,
    check: false,
    release: "",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--apply-page") options.applyPage = true;
    else if (arg === "--apply-release-notes") options.applyReleaseNotes = true;
    else if (arg === "--check") options.check = true;
    else if (arg === "--release") options.release = argv[++index] || "";
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (options.check && (options.applyPage || options.applyReleaseNotes)) {
    throw new Error("--check cannot be combined with apply flags");
  }
  return options;
}

export function planReleaseDownloadSync(releases, { release = "", currentPage = "" } = {}) {
  const selected = release ? releases.filter((item) => item.tag_name === release) : releases;
  if (release && selected.length !== 1) throw new Error(`Release not found: ${release}`);
  const page = renderDownloadsPage(releases);
  const releaseUpdates = selected
    .filter((item) => !item.draft && (item.assets || []).length > 0)
    .map((item) => ({
      release: item,
      body: mergeReleaseDownloadBlock(item.body, item),
      changed: mergeReleaseDownloadBlock(item.body, item) !== String(item.body || ""),
    }));
  return {
    page,
    pageChanged: page !== currentPage,
    releaseUpdates,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const releases = fetchReleases();
  const currentPage = fs.existsSync(downloadsSourcePath)
    ? fs.readFileSync(downloadsSourcePath, "utf8")
    : "";
  const plan = planReleaseDownloadSync(releases, { release: options.release, currentPage });

  console.log(`Downloads page: ${plan.pageChanged ? "update required" : "current"}`);
  const changedTags = plan.releaseUpdates.filter((item) => item.changed).map((item) => item.release.tag_name);
  console.log(`Release notes: ${changedTags.length ? `update required for ${changedTags.join(", ")}` : "current"}`);

  if (options.check) {
    if (plan.pageChanged || changedTags.length) process.exitCode = 1;
    return;
  }
  if (options.applyPage && plan.pageChanged) {
    fs.writeFileSync(downloadsSourcePath, plan.page);
    console.log(`Updated ${path.relative(repoRoot, downloadsSourcePath)}`);
  }
  if (options.applyReleaseNotes) {
    for (const update of plan.releaseUpdates.filter((item) => item.changed)) {
      updateRelease(update.release, update.body);
      console.log(`Updated GitHub release ${update.release.tag_name}`);
    }
  }
  if (!options.applyPage && !options.applyReleaseNotes && !options.check) {
    console.log("Preview only; pass --apply-page and/or --apply-release-notes to write changes.");
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
