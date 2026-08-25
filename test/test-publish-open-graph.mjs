import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cliPath = path.join(repoRoot, "dist", "cli.js");
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-open-graph-"));

function publish() {
  return spawnSync(process.execPath, [cliPath, "publish", "website", "--config", "org2.json", "--format", "json"], {
    cwd: fixtureRoot,
    encoding: "utf8",
  });
}

function assertPng(filePath) {
  const png = fs.readFileSync(filePath);
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  assert.equal(png.readUInt32BE(16), 1200);
  assert.equal(png.readUInt32BE(20), 630);
  return png;
}

try {
  fs.mkdirSync(path.join(fixtureRoot, "docs"), { recursive: true });
  fs.writeFileSync(
    path.join(fixtureRoot, "docs", "index.org"),
    "#+TITLE: OpenOrg Test\n\nLocal-first *knowledge* & durable work for people and agents.\n",
  );
  fs.writeFileSync(
    path.join(fixtureRoot, "docs", "guide.org"),
    "#+TITLE: A deliberately long guide title that must wrap cleanly\n#+DESCRIPTION: A dedicated description for the guide page.\n\nGuide body.\n",
  );
  fs.writeFileSync(
    path.join(fixtureRoot, "org2.json"),
    `${JSON.stringify({
      publish: {
        projects: {
          website: {
            baseDir: "docs",
            outDir: "site",
            include: ["*.org"],
            recursive: true,
            includeDefaultStyle: false,
            openGraph: {
              imageFormat: "png",
              siteName: "OpenOrg",
              locale: "en_US",
            },
            sitemapXml: {
              baseUrl: "https://openorg.example",
              includeIndexPage: true,
            },
          },
        },
      },
    }, null, 2)}\n`,
  );

  const firstRun = publish();
  assert.equal(firstRun.status, 0, firstRun.stderr || firstRun.stdout);

  const homeHtml = fs.readFileSync(path.join(fixtureRoot, "site", "index.html"), "utf8");
  assert.match(homeHtml, /<meta name="description" content="Local-first knowledge &amp; durable work for people and agents\." \/>/);
  assert.match(homeHtml, /<link rel="canonical" href="https:\/\/openorg\.example\/" \/>/);
  assert.match(homeHtml, /<meta property="og:site_name" content="OpenOrg" \/>/);
  assert.match(homeHtml, /<meta property="og:locale" content="en_US" \/>/);
  assert.match(homeHtml, /<meta property="og:image" content="https:\/\/openorg\.example\/assets\/og\/index\.png" \/>/);
  assert.match(homeHtml, /<meta property="og:image:secure_url" content="https:\/\/openorg\.example\/assets\/og\/index\.png" \/>/);
  assert.match(homeHtml, /<meta property="og:image:type" content="image\/png" \/>/);
  assert.match(homeHtml, /<meta property="og:image:width" content="1200" \/>/);
  assert.match(homeHtml, /<meta property="og:image:height" content="630" \/>/);
  assert.match(homeHtml, /<meta property="og:image:alt" content="OpenOrg Test — Local-first knowledge &amp; durable work for people and agents\." \/>/);
  assert.match(homeHtml, /<meta name="twitter:url" content="https:\/\/openorg\.example\/" \/>/);
  assert.match(homeHtml, /<meta name="twitter:image:alt" content="OpenOrg Test — Local-first knowledge &amp; durable work for people and agents\." \/>/);

  const guideHtml = fs.readFileSync(path.join(fixtureRoot, "site", "guide.html"), "utf8");
  assert.match(guideHtml, /<meta name="description" content="A dedicated description for the guide page\." \/>/);
  assert.match(guideHtml, /<link rel="canonical" href="https:\/\/openorg\.example\/guide\.html" \/>/);
  assert.match(guideHtml, /https:\/\/openorg\.example\/assets\/og\/guide\.png/);
  assert.equal((guideHtml.match(/<meta name="description"/g) || []).length, 1);

  const homePngPath = path.join(fixtureRoot, "site", "assets", "og", "index.png");
  const guidePngPath = path.join(fixtureRoot, "site", "assets", "og", "guide.png");
  const firstHomePng = assertPng(homePngPath);
  assertPng(guidePngPath);

  const secondRun = publish();
  assert.equal(secondRun.status, 0, secondRun.stderr || secondRun.stdout);
  assert.deepEqual(fs.readFileSync(homePngPath), firstHomePng, "Open Graph raster output should be deterministic");
} finally {
  fs.rmSync(fixtureRoot, { recursive: true, force: true });
}

console.log("publish Open Graph metadata and PNG image tests passed");
