#!/usr/bin/env node
// Builds the static site that keeps the legacy OpenOrg host (openorg.so)
// working after the Celorga rename:
//
// - every published page becomes a redirect to the same path on celorga.io;
// - pages renamed during the rebrand redirect to their new names;
// - the Sparkle appcasts are copied byte-for-byte, because every build shipped
//   before the rename polls https://openorg.so/assets/appcast-*.xml.
//
// The appcast only needs to advertise a release whose feed URL points at
// celorga.io. Once an old install takes that one update, it polls celorga.io
// from then on, so this site can stay static after the cutover release.
//
// Usage:
//   node tools/build-legacy-domain-site.mjs [--site site] [--out DIR] [--domain openorg.so]
// Deploy the output directory to a separate GitHub Pages repository (or any
// static host) with the legacy domain as its custom domain.
import { copyFileSync, existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const option = (name, fallback) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);

const siteDir = resolve(repoRoot, option("--site", "site"));
const outDir = resolve(repoRoot, option("--out", ".build/legacy-domain-site"));
const legacyDomain = option("--domain", "openorg.so");
const targetOrigin = option("--target", "https://celorga.io");

// Pages renamed by the rebrand. Keep in sync with the redirect stubs in docs/site.
export const RENAMED_PAGES = Object.freeze({
  "openorg-and-org2.html": "architecture.html",
  "org2-vs-markdown.html": "celorga-vs-markdown.html",
  "org2-vs-obsidian.html": "celorga-vs-obsidian.html",
  "org2-vs-org-mode.html": "celorga-vs-org-mode.html",
});

const APPCASTS = ["assets/appcast-arm64.xml", "assets/appcast-intel.xml"];

const escapeHTML = (value) =>
  value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

export function redirectPage(targetURL) {
  const url = escapeHTML(targetURL);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>OpenOrg is now Celorga</title>
<meta name="robots" content="noindex">
<link rel="canonical" href="${url}">
<meta http-equiv="refresh" content="0; url=${url}">
<script>location.replace(${JSON.stringify(targetURL)} + location.hash);</script>
</head>
<body>
<p>OpenOrg is now <a href="${url}">Celorga</a>.</p>
</body>
</html>
`;
}

// 404 fallback: GitHub Pages serves 404.html for unknown paths, so preserve
// the requested path and send it to the same place on the new domain.
function fallbackPage() {
  const renamed = JSON.stringify(RENAMED_PAGES);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>OpenOrg is now Celorga</title>
<meta name="robots" content="noindex">
<script>
(function () {
  var renamed = ${renamed};
  var path = location.pathname.replace(/^\\//, "");
  location.replace(${JSON.stringify(targetOrigin)} + "/" + (renamed[path] || path) + location.search + location.hash);
})();
</script>
</head>
<body>
<p>OpenOrg is now <a href="${escapeHTML(targetOrigin)}/">Celorga</a>.</p>
</body>
</html>
`;
}

function htmlPages(dir) {
  const pages = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "assets") continue;
      pages.push(...htmlPages(path));
    } else if (entry.name.endsWith(".html")) {
      pages.push(relative(siteDir, path));
    }
  }
  return pages;
}

function main() {
  if (!existsSync(join(siteDir, "index.html"))) {
    throw new Error(`No published site at ${siteDir}. Run: npm run org2 -- publish docs-site --config org2.json`);
  }
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(join(outDir, "assets"), { recursive: true });

  const pages = new Set([...htmlPages(siteDir), ...Object.keys(RENAMED_PAGES)]);
  for (const page of pages) {
    const target = RENAMED_PAGES[page] ?? page;
    const targetURL = target === "index.html" ? `${targetOrigin}/` : `${targetOrigin}/${target}`;
    mkdirSync(dirname(join(outDir, page)), { recursive: true });
    writeFileSync(join(outDir, page), redirectPage(targetURL));
  }
  writeFileSync(join(outDir, "404.html"), fallbackPage());

  for (const appcast of APPCASTS) {
    const source = join(siteDir, appcast);
    if (!existsSync(source)) throw new Error(`Missing ${appcast} in ${siteDir}; old installs would stop updating.`);
    copyFileSync(source, join(outDir, appcast));
  }

  writeFileSync(join(outDir, "CNAME"), `${legacyDomain}\n`);
  writeFileSync(join(outDir, ".nojekyll"), "");
  writeFileSync(
    join(outDir, "robots.txt"),
    `User-agent: *\nDisallow:\nSitemap: ${targetOrigin}/sitemap.xml\n`,
  );
  console.log(`Legacy site for ${legacyDomain}: ${pages.size} redirects + ${APPCASTS.length} appcasts -> ${relative(repoRoot, outDir)}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
