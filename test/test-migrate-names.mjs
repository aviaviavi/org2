import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { applyMigrateNames, migratePropertyText, planMigrateNames } from "../dist/migrateNames.js";

const cli = path.resolve("dist/cli.js");

// Property rewriting: drawers and keywords, never inside blocks, no lost values.
{
  const input = [
    "#+TITLE: Note",
    "#+ORG2_KIND: meeting",
    "* Heading",
    ":PROPERTIES:",
    ":ID: abc",
    ":ORG2_RUN_ID: run-1",
    ":ORG2_REVIEW_STATUS: pending",
    ":CELORGA_REVIEW_STATUS: pending",
    ":ORG2_WAITING_ON: alice",
    ":CELORGA_WAITING_ON: bob",
    ":END:",
    "Body mentions :ORG2_RUN_ID: in prose.",
    "#+begin_example",
    ":PROPERTIES:",
    ":ORG2_RUN_ID: keep-me",
    ":END:",
    "#+ORG2_KIND: keep-me",
    "#+end_example",
  ].join("\n");
  const result = migratePropertyText(input);
  assert.equal(result.renamed, 2);
  assert.equal(result.droppedDuplicates, 1);
  assert.equal(result.conflicts.length, 1);
  assert.match(result.text, /^#\+CELORGA_KIND: meeting$/m);
  assert.match(result.text, /^:CELORGA_RUN_ID: run-1$/m);
  assert.doesNotMatch(result.text, /^:ORG2_REVIEW_STATUS:/m);
  assert.match(result.text, /^:ORG2_WAITING_ON: alice$/m, "a differing legacy value is kept for review");
  assert.match(result.text, /^:CELORGA_WAITING_ON: bob$/m);
  assert.match(result.text, /Body mentions :ORG2_RUN_ID: in prose\./);
  assert.match(result.text, /^:ORG2_RUN_ID: keep-me$/m);
  assert.match(result.text, /^#\+ORG2_KIND: keep-me$/m);
  assert.equal(migratePropertyText(result.text).renamed, 0, "idempotent");
}

function corpus() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-migrate-"));
  fs.writeFileSync(path.join(root, "org2.json"), JSON.stringify({ agendaFiles: ["notes/**/*.org"] }));
  fs.mkdirSync(path.join(root, "notes"));
  fs.writeFileSync(path.join(root, "notes", "a.org"), "* TODO Task\nSCHEDULED: <2026-10-09 Fri>\n:PROPERTIES:\n:ORG2_RUN_ID: r1\n:END:\n");
  fs.mkdirSync(path.join(root, "raw"));
  fs.writeFileSync(path.join(root, "raw", "import.org"), "* Raw\n:PROPERTIES:\n:ORG2_SOURCE_ID: s1\n:END:\n");
  fs.mkdirSync(path.join(root, ".org2", "runs"), { recursive: true });
  fs.writeFileSync(path.join(root, ".org2", "runs", "keep.txt"), "state");
  fs.writeFileSync(path.join(root, ".stignore"), ".org2/index/\n(?d).DS_Store\n");
  return root;
}

// Preview changes nothing; apply migrates everything; a second run is a no-op.
{
  const root = corpus();
  const plan = planMigrateNames(root);
  assert.equal(plan.config.action, "rename");
  assert.equal(plan.stateDir.action, "rename");
  assert.equal(plan.properties.keys, 1, "raw/ is left as captured");
  assert.deepEqual(plan.stignore.add, [".celorga/index/"]);
  assert.ok(fs.existsSync(path.join(root, "org2.json")), "preview does not write");

  const applied = applyMigrateNames(root);
  assert.equal(applied.applied, true);
  assert.ok(fs.existsSync(path.join(root, "celorga.json")) && !fs.existsSync(path.join(root, "org2.json")));
  assert.equal(fs.readFileSync(path.join(root, ".celorga", "runs", "keep.txt"), "utf8"), "state");
  assert.ok(!fs.existsSync(path.join(root, ".org2")));
  assert.match(fs.readFileSync(path.join(root, "notes", "a.org"), "utf8"), /:CELORGA_RUN_ID: r1/);
  assert.match(fs.readFileSync(path.join(root, "raw", "import.org"), "utf8"), /:ORG2_SOURCE_ID: s1/);
  assert.match(fs.readFileSync(path.join(root, ".stignore"), "utf8"), /^\.celorga\/index\/$/m);
  assert.equal(planMigrateNames(root).nothingToDo, true);

  // The CLI still reads the migrated corpus.
  const agenda = spawnSync(process.execPath, [cli, "agenda", "--dir", root, "--from", "2026-10-09", "--to", "2026-10-09", "--format", "json"], { encoding: "utf8" });
  assert.equal(agenda.status, 0, agenda.stderr);
  assert.match(agenda.stdout, /Task/);
  fs.rmSync(root, { recursive: true, force: true });
}

// A legacy .org2/ recreated by an old device is merged without overwriting.
{
  const root = corpus();
  applyMigrateNames(root);
  fs.mkdirSync(path.join(root, ".org2", "runs"), { recursive: true });
  fs.writeFileSync(path.join(root, ".org2", "runs", "new.txt"), "late");
  fs.writeFileSync(path.join(root, ".org2", "runs", "keep.txt"), "older copy");
  const plan = planMigrateNames(root);
  assert.equal(plan.stateDir.action, "merge");
  assert.deepEqual(plan.stateDir.conflicts, [path.join("runs", "keep.txt")]);
  applyMigrateNames(root);
  assert.equal(fs.readFileSync(path.join(root, ".celorga", "runs", "new.txt"), "utf8"), "late");
  assert.equal(fs.readFileSync(path.join(root, ".celorga", "runs", "keep.txt"), "utf8"), "state");
  assert.equal(fs.readFileSync(path.join(root, ".org2", "runs", "keep.txt"), "utf8"), "older copy");
  fs.rmSync(root, { recursive: true, force: true });
}

// --apply refuses while an app or server is online for the corpus.
{
  const root = corpus();
  const live = path.join(root, ".org2", "openclaw-chat.store", "live");
  fs.mkdirSync(live, { recursive: true });
  fs.writeFileSync(path.join(live, "host.json"), JSON.stringify({ hostName: "Laptop", hostKind: "desktop", isOnline: true }));
  const blocked = applyMigrateNames(root);
  assert.match(blocked.blocked, /Laptop/);
  assert.ok(fs.existsSync(path.join(root, "org2.json")), "nothing written while blocked");
  const run = spawnSync(process.execPath, [cli, "migrate-names", "--dir", root, "--apply"], { encoding: "utf8" });
  assert.equal(run.status, 2);
  // An old presence file no longer blocks.
  const old = new Date(Date.now() - 60 * 60 * 1000);
  fs.utimesSync(path.join(live, "host.json"), old, old);
  assert.equal(applyMigrateNames(root).applied, true);
  fs.rmSync(root, { recursive: true, force: true });
}

console.log("migrate-names: ok");
