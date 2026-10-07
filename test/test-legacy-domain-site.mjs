import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");
const scratch = mkdtempSync(join(tmpdir(), "legacy-domain-site-"));
const site = join(scratch, "site");
const out = join(scratch, "out");
mkdirSync(join(site, "assets"), { recursive: true });
writeFileSync(join(site, "index.html"), "<p>home</p>");
writeFileSync(join(site, "features.html"), "<p>features</p>");
writeFileSync(join(site, "architecture.html"), "<p>arch</p>");
const appcast = '<?xml version="1.0"?><rss><channel><item><enclosure url="https://example.invalid/OpenOrg.dmg" sparkle:edSignature="x"/></item></channel></rss>\n';
writeFileSync(join(site, "assets", "appcast-arm64.xml"), appcast);
writeFileSync(join(site, "assets", "appcast-intel.xml"), appcast.replace("OpenOrg.dmg", "OpenOrg-Intel.dmg"));

execFileSync(process.execPath, [join(repoRoot, "tools", "build-legacy-domain-site.mjs"), "--site", site, "--out", out], { stdio: "pipe" });

// Old installs poll these exact URLs; the bytes must be unchanged.
assert.equal(readFileSync(join(out, "assets", "appcast-arm64.xml"), "utf8"), appcast);
assert.ok(readFileSync(join(out, "assets", "appcast-intel.xml"), "utf8").includes("OpenOrg-Intel.dmg"));

assert.match(readFileSync(join(out, "index.html"), "utf8"), /url=https:\/\/celorga\.io\//);
assert.match(readFileSync(join(out, "features.html"), "utf8"), /https:\/\/celorga\.io\/features\.html/);
// Renamed pages redirect to their new names even though the old page is gone.
assert.match(readFileSync(join(out, "openorg-and-org2.html"), "utf8"), /https:\/\/celorga\.io\/architecture\.html/);
assert.match(readFileSync(join(out, "org2-vs-markdown.html"), "utf8"), /celorga-vs-markdown\.html/);
assert.match(readFileSync(join(out, "404.html"), "utf8"), /location\.replace/);
assert.equal(readFileSync(join(out, "CNAME"), "utf8"), "openorg.so\n");
assert.ok(existsSync(join(out, ".nojekyll")));

// A site without appcasts must fail rather than strand old installs.
const bare = join(scratch, "bare");
mkdirSync(bare);
writeFileSync(join(bare, "index.html"), "<p>home</p>");
assert.throws(() =>
  execFileSync(process.execPath, [join(repoRoot, "tools", "build-legacy-domain-site.mjs"), "--site", bare, "--out", join(scratch, "out2")], { stdio: "pipe" }),
);

console.log("OK: legacy domain site keeps appcasts and redirects pages to celorga.io");
