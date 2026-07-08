#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const repo = process.cwd();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-refile-"));
const source = path.join(tmp, "notes.org2");

fs.writeFileSync(source, `* Inbox
** Task A
Task A body.
*** Nested
Nested body.
** Target
Target body.
* Later
Later body.
`, "utf8");

const previewRaw = execFileSync("node", [
  "dist/cli.js",
  "refile",
  "--file",
  source,
  "--pos",
  "3",
  "--to-file",
  source,
  "--to-pos",
  "6",
  "--format",
  "json",
], { cwd: repo, encoding: "utf8" });

const preview = JSON.parse(previewRaw);
assert.equal(preview.apply, false);
assert.equal(preview.changed, true);
assert.equal(preview.sourceHeadlineLine1, 2);
assert.equal(preview.destinationHeadingLine1, 2);
assert.equal(preview.headingLevelDelta, 1);
assert.match(preview.sourceSubtreeText, /^\*\* Task A\nTask A body\./);
assert.match(preview.newSourceText, /^\* Inbox\n\*\* Target\nTarget body\.\n\n\*\*\* Task A\nTask A body\.\n\*\*\*\* Nested\nNested body\.\n\n\* Later/m);
assert.equal(fs.readFileSync(source, "utf8").includes("*** Task A"), false, "preview must not write source file");

const noHeading = path.join(tmp, "no-heading.org2");
fs.writeFileSync(noHeading, "Intro only.\n", "utf8");

const invalid = spawnSync("node", [
  "dist/cli.js",
  "refile",
  "--file",
  noHeading,
  "--pos",
  "1",
  "--to-file",
  source,
  "--format",
  "json",
], { cwd: repo, encoding: "utf8" });

assert.notEqual(invalid.status, 0);
assert.match(invalid.stderr, /Error: no source headline found at or above --pos/);

console.log("✓ refile");
