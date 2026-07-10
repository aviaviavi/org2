#!/usr/bin/env node
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const {
  computeSubtreeRange,
  findDrawerInLines,
  findPlanningBlockEnd,
  findHeadingAtOrAbove,
  getDrawerPropertyValue,
  getHeadlineLevel,
  isHeadlineLine,
  isPlanningLine,
  splitSourceLines,
  upsertHeadlinePropertyInLines,
} = await import(path.join(repo, "dist", "sourceLines.js"));

const lines = [
  "Intro",
  "* Parent",
  "Parent body",
  "** Child",
  "Child body",
  "*** Grandchild",
  "Grandchild body",
  "** Sibling",
  "Sibling body",
  "* Next",
  "Next body",
];

assert.equal(isHeadlineLine("* Heading"), true);
assert.equal(isHeadlineLine("*Heading"), false);
assert.equal(isHeadlineLine(" ** Indented"), false);

assert.equal(isPlanningLine("SCHEDULED: <2026-07-09 Thu>"), true);
assert.equal(isPlanningLine("  deadline: <2026-07-09 Thu>"), true);
assert.equal(isPlanningLine("CLOSED:"), true);
assert.equal(isPlanningLine("SCHEDULED:<2026-07-09 Thu>"), false);
assert.equal(isPlanningLine("Body SCHEDULED: <2026-07-09 Thu>"), false);

assert.deepEqual(splitSourceLines("A\r\nB\nC\rD"), ["A", "B", "C", "D"]);
assert.deepEqual(splitSourceLines("A\r\n"), ["A", ""]);

assert.equal(getHeadlineLevel("*** Deep"), 3);
assert.equal(getHeadlineLevel("Body"), 0);

assert.equal(findHeadingAtOrAbove(lines, 2), 1);
assert.equal(findHeadingAtOrAbove(lines, 5), 3);
assert.equal(findHeadingAtOrAbove(lines, 999), 9);

assert.deepEqual(computeSubtreeRange(lines, 1), { start: 1, endExclusive: 9, level: 1 });
assert.deepEqual(computeSubtreeRange(lines, 3), { start: 3, endExclusive: 7, level: 2 });
assert.deepEqual(computeSubtreeRange(lines, 9), { start: 9, endExclusive: 11, level: 1 });

const drawerLines = [
  "* Task",
  ":PROPERTIES:",
  ":Assignee: Avi",
  ":END:",
  ":LOGBOOK:",
  "- State \"DONE\" from \"TODO\" <2026-07-09 Thu 12:00>",
  ":END:",
  "Body",
];
const propsDrawer = findDrawerInLines(drawerLines, 1, drawerLines.length, "properties");
assert.deepEqual(propsDrawer, { start: 1, end: 3, terminated: true });
assert.equal(getDrawerPropertyValue(drawerLines, propsDrawer, "assignee"), "Avi");
assert.equal(getDrawerPropertyValue(drawerLines, propsDrawer, "missing"), undefined);
assert.deepEqual(findDrawerInLines(drawerLines, 1, drawerLines.length, "LOGBOOK"), { start: 4, end: 6, terminated: true });
assert.equal(findDrawerInLines(drawerLines, 7, drawerLines.length, "PROPERTIES"), null);

const unterminatedDrawer = findDrawerInLines(["* Task", ":PROPERTIES:", ":STATUS: malformed", "Body"], 1, 4, "PROPERTIES");
assert.deepEqual(unterminatedDrawer, { start: 1, end: 3, terminated: false });
assert.equal(getDrawerPropertyValue(["* Task", ":PROPERTIES:", ":STATUS: malformed", "Body"], unterminatedDrawer, "STATUS"), undefined);

assert.equal(findPlanningBlockEnd([
  "* Task",
  "SCHEDULED: <2026-07-09 Thu>",
  "deadline: <2026-07-10 Fri>",
  "Body",
], 0, 4), 3);

const propertyInsertLines = [
  "* Task",
  "SCHEDULED: <2026-07-09 Thu>",
  "Body",
];
upsertHeadlinePropertyInLines(propertyInsertLines, 0, "ASSIGNEE", "OpenClaw");
assert.deepEqual(propertyInsertLines, [
  "* Task",
  "SCHEDULED: <2026-07-09 Thu>",
  ":PROPERTIES:",
  ":ASSIGNEE: OpenClaw",
  ":END:",
  "Body",
]);

const propertyUpdateLines = [
  "* Task",
  ":PROPERTIES:",
  ":ASSIGNEE: Avi",
  ":STATUS: draft",
  ":END:",
  "Body",
];
upsertHeadlinePropertyInLines(propertyUpdateLines, 0, "assignee", "OpenClaw");
upsertHeadlinePropertyInLines(propertyUpdateLines, 0, "PRIORITY", "A");
assert.deepEqual(propertyUpdateLines, [
  "* Task",
  ":PROPERTIES:",
  ":ASSIGNEE: OpenClaw",
  ":STATUS: draft",
  ":PRIORITY: A",
  ":END:",
  "Body",
]);

assert.throws(() => findHeadingAtOrAbove(lines, 1), /No headline found at or above line 1/);
assert.throws(() => findHeadingAtOrAbove(["Intro"], 1), /No headline found at or above line 1/);
assert.throws(() => computeSubtreeRange(lines, 0), /Expected headline at line index 0/);
assert.throws(() => computeSubtreeRange(lines, lines.length), /Expected headline at line index 11/);
assert.throws(() => upsertHeadlinePropertyInLines(lines, 0, "ASSIGNEE", "OpenClaw"), /Expected headline at line index 0/);

console.log("✓ source-lines");
