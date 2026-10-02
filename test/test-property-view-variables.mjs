#!/usr/bin/env node
// Saved views keep dynamic date variables and regular expressions in their
// definitions, resolving them each time the view runs.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { expandPropertyViewVariables, parsePropertyView, queryPropertyView, savePropertyView, suggestPropertyView } from "../dist/propertyViews.js";

const now = new Date(2026, 9, 1, 9, 30); // Thu 2026-10-01, local time
assert.equal(expandPropertyViewVariables("{today}", now), "2026-10-01");
assert.equal(expandPropertyViewVariables("{Yesterday}|{tomorrow}", now), "2026-09-30|2026-10-02");
assert.equal(expandPropertyViewVariables("{today-7d} {today+2w}", now), "2026-09-24 2026-10-15");
assert.equal(expandPropertyViewVariables("{today-1m} {today+1y}", new Date(2026, 2, 31)), "2026-02-28 2027-03-31");
assert.equal(expandPropertyViewVariables("daily/{year}/{month}", now), "daily/2026/2026-10");
assert.equal(expandPropertyViewVariables("{unknown} {today", now), "{unknown} {today", "Other brace text stays literal");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-property-view-variables-"));
try {
  fs.mkdirSync(path.join(root, "daily"));
  fs.mkdirSync(path.join(root, "notes"));
  fs.mkdirSync(path.join(root, "meetings"));
  fs.writeFileSync(path.join(root, "daily/2026-10-01.org"), "#+TITLE: 2026-10-01\n");
  fs.writeFileSync(path.join(root, "daily/2026-09-30.org"), "#+TITLE: 2026-09-30\n");
  fs.writeFileSync(path.join(root, "daily/2026-09-20.org"), "#+TITLE: 2026-09-20\n");
  fs.writeFileSync(path.join(root, "meetings/2026-10-01-150102-sync.org"), "#+TITLE: Sync\n");
  fs.writeFileSync(path.join(root, "notes/scratch.org"), ":PROPERTIES:\n:ID: scratch\n:CREATED: [2026-10-01 Thu 08:15]\n:END:\n#+TITLE: Scratch\n");
  fs.writeFileSync(path.join(root, "notes/old.org"), ":PROPERTIES:\n:CREATED: [2026-08-01 Sat 08:15]\n:END:\n#+TITLE: Old\n");

  const base = { schema: "org2:property-view:v1", id: "today", title: "Files from today", layout: "table", scope: { kind: "file" }, columns: ["title", "file"], match: "any", sort: [{ field: "file", direction: "asc" }], limit: 100 };
  const today = { ...base, filters: [{ field: "file", operator: "on", value: "{today}" }, { field: "CREATED", operator: "on", value: "{today}" }] };
  const files = (definition, at = now) => queryPropertyView(root, definition, { now: at }).rows.map(row => row.file);

  // The saved definition keeps the variable; only the query resolves it.
  const saved = savePropertyView(root, today, { apply: true });
  assert.equal(saved.definition.filters[0].value, "{today}");
  assert.match(fs.readFileSync(path.join(root, saved.file), "utf8"), /"value": "\{today\}"/);
  assert.deepEqual(files(today), ["daily/2026-10-01.org", "meetings/2026-10-01-150102-sync.org", "notes/scratch.org"]);
  assert.deepEqual(files(today, new Date(2026, 8, 30, 12)), ["daily/2026-09-30.org"], "The same view follows the calendar");
  assert.deepEqual(files({ ...base, filters: [{ field: "file", operator: "contains", value: "{yesterday}" }] }), ["daily/2026-09-30.org"]);

  // before/after compare the first YYYY-MM-DD in a path, timestamp, or property.
  assert.deepEqual(files({ ...base, match: "all", filters: [{ field: "file", operator: "after", value: "{today-7d}" }, { field: "file", operator: "before", value: "{today}" }] }), ["daily/2026-09-30.org"]);
  assert.deepEqual(files({ ...base, filters: [{ field: "CREATED", operator: "before", value: "2026-09-01" }] }), ["notes/old.org"]);

  // Regular expressions are case-insensitive and may embed variables.
  assert.deepEqual(files({ ...base, filters: [{ field: "file", operator: "matches", value: "^daily/2026-09-(2\\d|30)\\.org$" }] }), ["daily/2026-09-20.org", "daily/2026-09-30.org"]);
  assert.deepEqual(files({ ...base, filters: [{ field: "title", operator: "matches", value: "^SCR" }] }), ["notes/scratch.org"]);
  assert.deepEqual(files({ ...base, filters: [{ field: "file", operator: "matches", value: "^(daily|meetings)/{today}" }] }), ["daily/2026-10-01.org", "meetings/2026-10-01-150102-sync.org"]);

  assert.throws(() => parsePropertyView({ ...base, filters: [{ field: "file", operator: "matches", value: "(unclosed" }] }), /Invalid regular expression/);
  assert.throws(() => parsePropertyView({ ...base, filters: [{ field: "file", operator: "after", value: "last tuesday" }] }), /Date comparisons/);
  assert.doesNotThrow(() => parsePropertyView({ ...base, filters: [{ field: "file", operator: "after", value: "{today-30d}" }] }));

  // Plain-language suggestions save variables, never today's literal date.
  const suggestion = suggestPropertyView("show me all files that were created today");
  assert.equal(suggestion.definition.match, "any");
  assert.deepEqual(suggestion.definition.filters, [{ field: "file", operator: "on", value: "{today}" }, { field: "CREATED", operator: "on", value: "{today}" }]);
  assert.doesNotMatch(JSON.stringify(suggestion.definition), /\d{4}-\d{2}-\d{2}/);
  assert.deepEqual(suggestPropertyView("notes from the past 14 days").definition.filters[0], { field: "file", operator: "after", value: "{today-14d}" });
  assert.deepEqual(suggestPropertyView("Show my unfinished project tasks").definition.filters, [{ field: "todo", operator: "active", value: "" }]);

  console.log("Property view variable tests passed: date variables, date comparisons, regex, and relative suggestions.");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
