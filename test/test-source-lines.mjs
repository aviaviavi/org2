#!/usr/bin/env node
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const {
  computeSubtreeRange,
  findPlanningBlockEnd,
  findHeadingAtOrAbove,
  getHeadlineLevel,
  isHeadlineLine,
  isPlanningLine,
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

assert.equal(getHeadlineLevel("*** Deep"), 3);
assert.equal(getHeadlineLevel("Body"), 0);

assert.equal(findHeadingAtOrAbove(lines, 2), 1);
assert.equal(findHeadingAtOrAbove(lines, 5), 3);
assert.equal(findHeadingAtOrAbove(lines, 999), 9);

assert.deepEqual(computeSubtreeRange(lines, 1), { start: 1, endExclusive: 9, level: 1 });
assert.deepEqual(computeSubtreeRange(lines, 3), { start: 3, endExclusive: 7, level: 2 });
assert.deepEqual(computeSubtreeRange(lines, 9), { start: 9, endExclusive: 11, level: 1 });

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
