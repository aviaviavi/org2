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

fs.writeFileSync(note, `* TODO Send approved follow-up
:PROPERTIES:
:STATUS: waiting-on-approval
:ASSIGNEE: OpenClaw
:END:
** TODO Approve follow-up
:PROPERTIES:
:ID: approval-1
:STATUS: draft-needs-review
:ASSIGNEE: Avi
:END:
`, "utf8");
const approved = JSON.parse(cli([
  "todo",
  "set",
  "--file",
  note,
  "--line",
  "7",
  "--status",
  "done",
  "--apply",
  "--now",
  "2026-06-22T17:00:00-07:00",
]));
assert.equal(approved.newStatus, "done");

const approvedText = fs.readFileSync(note, "utf8");
assert.match(approvedText, /^\* TODO Send approved follow-up/m);
assert.match(approvedText, /:STATUS: approved-to-send/);
assert.match(approvedText, /:ASSIGNEE: OpenClaw/);
assert.match(approvedText, /:ORG2_AGENT_HANDOFF_AT: <2026-06-22 Mon 17:00>/);
assert.match(approvedText, /:APPROVAL_ID: approval-1/);
assert.match(approvedText, /^\*\* DONE Approve follow-up/m);
assert.match(approvedText, /:STATUS: approved/);
assert.match(approvedText, /:PAIRED_SEND_TODO: Send approved follow-up/);

fs.writeFileSync(note, `* TODO Continue approved Linear issue update
:PROPERTIES:
:STATUS: waiting-on-approval
:ASSIGNEE: OpenClaw
:END:
** TODO Approve Linear issue update
:PROPERTIES:
:ID: approval-2
:STATUS: draft-needs-review
:ASSIGNEE: Avi
:PAIRED_AGENT_TODO: Continue approved Linear issue update
:END:
`, "utf8");
const agentApproved = JSON.parse(cli([
  "todo",
  "approve",
  "--file",
  note,
  "--line",
  "7",
  "--apply",
  "--now",
  "2026-06-22T17:05:00-07:00",
]));
assert.equal(agentApproved.newStatus, "done");

const agentApprovedText = fs.readFileSync(note, "utf8");
assert.match(agentApprovedText, /^\* TODO Continue approved Linear issue update/m);
assert.match(agentApprovedText, /:STATUS: ready-for-agent/);
assert.match(agentApprovedText, /:ASSIGNEE: OpenClaw/);
assert.match(agentApprovedText, /:ORG2_AGENT_HANDOFF_AT: <2026-06-22 Mon 17:05>/);
assert.match(agentApprovedText, /:APPROVAL_ID: approval-2/);
assert.match(agentApprovedText, /^\*\* DONE Approve Linear issue update/m);
assert.match(agentApprovedText, /:STATUS: approved/);

console.log("✓ todo assign");
