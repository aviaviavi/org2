#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const bundleIdentifier = process.env.ORG2_WORKSPACE_CODEX_BUNDLE_ID ?? "org.org2.workspace.codex";
const corpusRoot = resolve(
  process.env.ORG2_WORKSPACE_CODEX_CORPUS ?? join(repoRoot, ".codex", "org2-workspace-corpus")
);

function writeIfMissing(path, contents) {
  if (existsSync(path)) {
    return;
  }
  writeFileSync(path, contents);
}

function run(command, args) {
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed`);
  }
}

function runAllowFailure(command, args) {
  spawnSync(command, args, { stdio: "ignore" });
}

mkdirSync(corpusRoot, { recursive: true });
mkdirSync(join(corpusRoot, ".org2"), { recursive: true });
mkdirSync(join(corpusRoot, "daily"), { recursive: true });
mkdirSync(join(corpusRoot, "notes"), { recursive: true });

writeIfMissing(
  join(corpusRoot, "daily", "2026-07-05.org2"),
  `#+TITLE: Codex sandbox daily note
:PROPERTIES:
:ID: codex-sandbox-daily-2026-07-05
:END:

* Live editor smoke test
Paragraph text with [[id:codex-sandbox-project][a pretty org link]].

- first list item
- second list item

| Name | Status |
| Codex app | separate |
`
);

writeIfMissing(
  join(corpusRoot, "notes", "project.org2"),
  `#+TITLE: Codex sandbox project
:PROPERTIES:
:ID: codex-sandbox-project
:END:

* TODO Exercise app changes
Use this corpus for Codex UI smoke tests instead of the real workspace.
`
);

if (process.platform === "darwin") {
  for (const key of [
    "Org2Workspace.legacyDefaultsMigrated.v1",
    "Org2Workspace.openClawAgent",
    "Org2Workspace.openClawEndpoint",
    "Org2Workspace.openClawRemoteCorpusPath",
    "Org2Workspace.agentHandoffAssignee",
    "Org2Workspace.personalAssigneeNames",
    "Org2Workspace.orgCrypt.encryptOnSave",
    "Org2Workspace.orgCrypt.gpgProgram",
    "Org2Workspace.orgCrypt.recipientFiles",
    "Org2Workspace.orgCrypt.recipients",
    "Org2Workspace.orgCrypt.useDefaultGpgKey",
    "Org2Workspace.orgCrypt.useDefaultGpgKeyDefaulted.v2"
  ]) {
    runAllowFailure("defaults", ["delete", bundleIdentifier, key]);
  }
  run("defaults", ["write", bundleIdentifier, "Org2Workspace.corpusRoot", corpusRoot]);
}

console.log(`Codex macOS app defaults point ${bundleIdentifier} at ${corpusRoot}`);
