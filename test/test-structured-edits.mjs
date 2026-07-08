#!/usr/bin/env node
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const { updatePlanningInText } = await import(path.join(repo, "dist", "planning.js"));
const { assignTodoInText, updateTodoInText } = await import(path.join(repo, "dist", "todo.js"));

const source = `Intro line before headings

* TODO Parent
Body under parent.
** TODO Child
Child body line.
*** TODO Grandchild
Grandchild body line.
** TODO Sibling
Sibling body line.
`;

const assigned = assignTodoInText(source, {
  filePath: "tasks.org2",
  lineNumber: 6,
  assignee: "OpenClaw",
});
assert.equal(assigned.headingLineNumber, 5);
assert.match(assigned.text, /^\*\* TODO Child\n:PROPERTIES:\n:ASSIGNEE: OpenClaw\n:END:\nChild body line\./m);
assert.doesNotMatch(assigned.text, /^\*\*\* TODO Grandchild\n:PROPERTIES:/m);
assert.doesNotMatch(assigned.text, /^\*\* TODO Sibling\n:PROPERTIES:/m);

const planned = updatePlanningInText(source, {
  filePath: "tasks.org2",
  lineNumber: 8,
  kind: "DEADLINE",
  date: "2026-07-08",
});
assert.equal(planned.headingLineNumber, 7);
assert.match(planned.text, /^\*\*\* TODO Grandchild\nDEADLINE: <2026-07-08 Wed>\nGrandchild body line\./m);
assert.doesNotMatch(planned.text, /^\*\* TODO Sibling\nDEADLINE:/m);

const completed = updateTodoInText(source, {
  filePath: "tasks.org2",
  lineNumber: 10,
  status: "done",
  now: new Date(2026, 6, 8, 12, 34),
});
assert.equal(completed.headingLineNumber, 9);
assert.match(completed.text, /^\*\* DONE Sibling\nCLOSED: <2026-07-08 Wed 12:34>\nSibling body line\./m);
assert.doesNotMatch(completed.text, /^\*\* TODO Child\nCLOSED:/m);

assert.throws(
  () => updatePlanningInText(source, {
    filePath: "tasks.org2",
    lineNumber: 1,
    kind: "SCHEDULED",
    date: "2026-07-08",
  }),
  /No headline found at or above line 1/,
);

console.log("✓ structured edits");
