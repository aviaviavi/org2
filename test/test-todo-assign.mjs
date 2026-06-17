#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const repo = process.cwd();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-todo-assign-"));
const note = path.join(tmp, "tasks.org2");

function cli(args) {
  return execFileSync("node", ["dist/cli.js", ...args], { cwd: repo, encoding: "utf8" });
}

fs.writeFileSync(note, "* TODO Send approved follow-up\nSCHEDULED: <2026-06-14 Sun>\n\nBody\n", "utf8");

const preview = JSON.parse(cli(["todo", "assign", "--file", note, "--line", "1", "--assignee", "OpenClaw"]));
assert.equal(preview.applied, false);
assert.equal(preview.changed, true);
assert.equal(preview.property, "ASSIGNEE");
assert.equal(preview.newAssignee, "OpenClaw");
assert.equal(fs.readFileSync(note, "utf8").includes(":ASSIGNEE:"), false);

const applied = JSON.parse(cli(["todo", "assign", "--file", note, "--line", "1", "--assignee", "OpenClaw", "--apply"]));
assert.equal(applied.applied, true);
assert.equal(applied.changed, true);

const updated = fs.readFileSync(note, "utf8");
assert.match(updated, /^\* TODO Send approved follow-up/m);
assert.match(updated, /:PROPERTIES:\n:ASSIGNEE: OpenClaw\n:END:/);

const unchanged = JSON.parse(cli(["todo", "assign", "--file", note, "--line", "1", "--assignee", "OpenClaw", "--apply"]));
assert.equal(unchanged.changed, false);

fs.writeFileSync(note, "* TODO Existing drawer\n:PROPERTIES:\n:ASSIGNEE: Avi\n:STATUS: draft-needs-review\n:END:\n", "utf8");
const replaced = JSON.parse(cli(["todo", "assign", "--file", note, "--line", "1", "--assignee", "OpenClaw", "--apply"]));
assert.equal(replaced.oldAssignee, "Avi");
assert.equal(replaced.newAssignee, "OpenClaw");

const replacedText = fs.readFileSync(note, "utf8");
assert.match(replacedText, /^\* TODO Existing drawer/m);
assert.match(replacedText, /:ASSIGNEE: OpenClaw/);
assert.match(replacedText, /:STATUS: draft-needs-review/);

console.log("✓ todo assign");
