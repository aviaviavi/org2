import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const renderer = path.join(root, "dist", "render-presentation-pdf.js");
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "org2-presentation-preview-test-"));

try {
  const sourcePath = path.join(temporaryDirectory, "talk.org2");
  const fakeEngine = path.join(temporaryDirectory, "fake-latex-engine.mjs");
  fs.writeFileSync(sourcePath, "", "utf8");
  fs.writeFileSync(
    fakeEngine,
    `#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
const outputArgument = process.argv.find((argument) => argument.startsWith("-output-directory="));
const outputDirectory = outputArgument.slice("-output-directory=".length);
const texPath = process.argv.find((argument) => argument.endsWith(".tex"));
const tex = fs.readFileSync(texPath, "utf8");
if (!tex.includes("org2-source-line://44")) process.exit(9);
fs.writeFileSync(path.join(outputDirectory, "deck.pdf"), Buffer.from("%PDF-1.4\\n% Org2 preview test\\n"));
`,
    "utf8",
  );
  fs.chmodSync(fakeEngine, 0o755);

  const rendered = spawnSync(
    process.execPath,
    [
      renderer,
      "--source-path", sourcePath,
      "--source-line-offset", "40",
      "--latex-engine", fakeEngine,
      "--passes", "1",
    ],
    {
      cwd: root,
      input: "#+TITLE: Draft deck\n#+OPTIONS: H:2\n* Section\n** Unsaved slide\nDraft body.\n",
    },
  );
  assert.equal(rendered.status, 0, rendered.stderr.toString("utf8"));
  assert.equal(rendered.stdout.subarray(0, 4).toString("utf8"), "%PDF");

  const invalid = spawnSync(
    process.execPath,
    [renderer, "--source-path", sourcePath, "--latex-engine", fakeEngine],
    {
      cwd: root,
      input: "#+TITLE: No slides\n* Only a section\n",
      encoding: "utf8",
    },
  );
  assert.equal(invalid.status, 1);
  assert.match(invalid.stderr, /No level-2 slide headlines were found/);
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}

console.log("presentation preview tests passed");
