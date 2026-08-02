#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const { buildUnifiedDiff } = await import(path.join(repo, "dist", "unifiedDiff.js"));

const targetPath = "/workspace/notes.org2";
const temporaryDirectoryPrefix = `org2-unified-diff-test-${process.pid}-`;
const options = {
  targetPath,
  temporaryDirectoryPrefix,
};

assert.equal(buildUnifiedDiff("same\n", "same\n", options), "");

const diff = buildUnifiedDiff("* Before\n", "* After\n", options);
assert.match(diff, /^--- \/workspace\/notes\.org2(?:\t|\n)/);
assert.match(diff, /^\+\+\+ \/workspace\/notes\.org2(?:\t|\n)/m);
assert.match(diff, /^-\* Before$/m);
assert.match(diff, /^\+\* After$/m);
assert.doesNotMatch(diff, new RegExp(temporaryDirectoryPrefix));

const labeledDiff = buildUnifiedDiff("* Before\n", "* After\n", {
  ...options,
  useLabels: true,
});
assert.match(labeledDiff, /^--- \/workspace\/notes\.org2$/m);
assert.match(labeledDiff, /^\+\+\+ \/workspace\/notes\.org2$/m);
assert.equal(
  fs.readdirSync(os.tmpdir()).some((entry) => entry.startsWith(temporaryDirectoryPrefix)),
  false,
);

console.log("✓ unified diff");
