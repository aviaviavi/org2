#!/usr/bin/env node
// Generates the Celorga brand assets (logo option E0: a C with a teal asterisk
// in its opening) and writes every app, site, and editor icon from one source.
//
// Usage: node tools/build-celorga-brand-assets.mjs
// Requires rsvg-convert (brew install librsvg) and macOS iconutil for .icns.
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const brandDir = join(repoRoot, "docs", "brand", "celorga");

export const COLORS = Object.freeze({
  slate: "#4b5761",
  teal: "#14b8a6",
  paper: "#f4f6f7",
  night: "#1f2937",
  mist: "#e5e7eb",
});

// The mark is drawn in a coordinate space centred on (486, 300), the optical
// centre of the C plus asterisk.
function mark(stroke) {
  return [
    `<path d="M627.7 162.1 A180 180 0 1 0 627.7 437.9" fill="none" stroke="${stroke}" stroke-width="80" stroke-linecap="round"/>`,
    `<line x1="622" y1="352" x2="622" y2="248" stroke="${COLORS.teal}" stroke-width="26" stroke-linecap="round"/>`,
    `<line x1="667" y1="326" x2="577" y2="274" stroke="${COLORS.teal}" stroke-width="26" stroke-linecap="round"/>`,
    `<line x1="577" y1="326" x2="667" y2="274" stroke="${COLORS.teal}" stroke-width="26" stroke-linecap="round"/>`,
  ].join("");
}

const placed = (cx, cy, scale, stroke) =>
  `<g transform="translate(${cx} ${cy}) scale(${scale}) translate(-486 -300)">${mark(stroke)}</g>`;

// iOS masks the icon itself, so its source is a full square without corners.
export function appIconSVG(theme = "light", size = 1024, { square = false } = {}) {
  const tile = theme === "dark" ? COLORS.night : COLORS.paper;
  const stroke = theme === "dark" ? COLORS.mist : COLORS.slate;
  const s = size / 512;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}"><rect width="${size}" height="${size}" rx="${square ? 0 : 112 * s}" fill="${tile}"/>${placed(size / 2, size / 2, 0.6818 * s, stroke)}</svg>\n`;
}

export function markSVG(theme = "light") {
  const stroke = theme === "dark" ? COLORS.mist : COLORS.slate;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">${placed(256, 256, 1.0909, stroke)}</svg>\n`;
}

export function logoSVG(theme = "light") {
  const bg = theme === "dark" ? COLORS.night : COLORS.paper;
  const fg = theme === "dark" ? COLORS.mist : COLORS.slate;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="768" viewBox="0 0 1024 768"><rect width="1024" height="768" fill="${bg}"/>${placed(512, 300, 0.9545, fg)}<text x="512" y="672" text-anchor="middle" font-family="Avenir Next" font-weight="600" font-size="72" letter-spacing="4" fill="${fg}">celorga</text></svg>\n`;
}

function render(svgPath, outPath, width, height = width) {
  mkdirSync(dirname(outPath), { recursive: true });
  execFileSync("rsvg-convert", ["-w", String(width), "-h", String(height), "-o", outPath, svgPath]);
}

// App Store icons must not have an alpha channel. A best-quality JPEG round
// trip through sips flattens it without extra dependencies.
function removeAlpha(pngPath) {
  const jpeg = `${pngPath}.tmp.jpg`;
  execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "best", pngPath, "--out", jpeg], { stdio: "ignore" });
  execFileSync("sips", ["-s", "format", "png", jpeg, "--out", pngPath], { stdio: "ignore" });
  rmSync(jpeg, { force: true });
}

function main() {
  mkdirSync(brandDir, { recursive: true });
  const sources = {
    "app-icon-light.svg": appIconSVG("light"),
    "app-icon-dark.svg": appIconSVG("dark"),
    "app-icon-ios.svg": appIconSVG("light", 1024, { square: true }),
    "mark-light.svg": markSVG("light"),
    "mark-dark.svg": markSVG("dark"),
    "logo-light.svg": logoSVG("light"),
    "logo-dark.svg": logoSVG("dark"),
  };
  for (const [name, svg] of Object.entries(sources)) writeFileSync(join(brandDir, name), svg);
  const src = (name) => join(brandDir, name);

  const icon = src("app-icon-light.svg");
  const targets = [
    // macOS app (file names are compatibility identifiers used by the build scripts).
    ["apps/macos/Org2Workspace/Sources/Org2Workspace/Resources/OpenOrgAppIcon.png", 1024],
    ["apps/macos/Org2Workspace/Sources/Org2Workspace/Resources/AppIcon.png", 512],
    ["apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/Resources/OpenOrgBrand.png", 1024],
    // Website.
    ["docs/site/assets/favicon.png", 64],
    ["docs/site/assets/apple-touch-icon.png", 180],
    ["docs/site/assets/openorg-app-icon.png", 512],
    // VS Code extension.
    ["editors/vscode-org2/icon.png", 512],
  ];
  for (const [path, size] of targets) render(icon, join(repoRoot, path), size);
  writeFileSync(join(repoRoot, "docs/site/assets/openorg-app-icon.svg"), appIconSVG("light"));

  for (const size of [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]) {
    const out = join(repoRoot, `apps/ios/Org2Mobile/Org2Mobile/Assets.xcassets/AppIcon.appiconset/AppIcon-${size}.png`);
    render(src("app-icon-ios.svg"), out, size);
    removeAlpha(out);
  }

  render(src("logo-light.svg"), join(repoRoot, "logo.png"), 1024, 768);
  render(src("logo-light.svg"), join(brandDir, "logo-light.png"), 1024, 768);
  render(src("logo-dark.svg"), join(brandDir, "logo-dark.png"), 1024, 768);
  render(src("mark-light.svg"), join(brandDir, "favicon-32.png"), 32);

  // macOS .icns for packaging and press kits.
  const scratch = mkdtempSync(join(tmpdir(), "celorga-iconset-"));
  const iconset = join(scratch, "Celorga.iconset");
  mkdirSync(iconset);
  for (const base of [16, 32, 128, 256, 512]) {
    render(icon, join(iconset, `icon_${base}x${base}.png`), base);
    render(icon, join(iconset, `icon_${base}x${base}@2x.png`), base * 2);
  }
  execFileSync("iconutil", ["-c", "icns", iconset, "-o", join(brandDir, "Celorga.icns")]);
  rmSync(scratch, { recursive: true, force: true });
  console.log(`Celorga brand assets written to ${brandDir} and the app, site, and editor icon paths.`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
