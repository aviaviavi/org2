import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const { TODO_KEYWORDS, isTodoKeyword, normalizeTodoKeyword } = await import(path.join(repo, "dist", "todo.js"));
const { parseOrgToCanonicalAst } = await import(path.join(repo, "dist", "parser.js"));
const { extractClockReport } = await import(path.join(repo, "dist", "clock.js"));
const { parseHeadlineTitleForRoam } = await import(path.join(repo, "dist", "headlineTitle.js"));

assert.deepEqual([...TODO_KEYWORDS], ["TODO", "IN_PROGRESS", "DONE", "CANCELED", "CANCELLED"]);
assert.equal(isTodoKeyword("TODO"), true);
assert.equal(isTodoKeyword("todo"), false);
assert.equal(isTodoKeyword("NEXT"), false);
assert.equal(normalizeTodoKeyword(" todo "), "TODO");
assert.equal(normalizeTodoKeyword("cancelled"), "CANCELLED");
assert.equal(normalizeTodoKeyword("NEXT"), undefined);

assert.equal(parseHeadlineTitleForRoam("* TODO [#A] Shared task :work:"), "Shared task");
assert.equal(parseHeadlineTitleForRoam("* in_progress Shared task"), "Shared task");
assert.equal(parseHeadlineTitleForRoam("* NEXT Plain title :work:"), "NEXT Plain title");
assert.equal(parseHeadlineTitleForRoam("* WAITING Plain title"), "WAITING Plain title");

const ast = parseOrgToCanonicalAst("* IN_PROGRESS Shared parser keyword\n* NEXT Plain title\n");
assert.equal(ast.children[0].todo, "IN_PROGRESS");
assert.deepEqual(ast.children[0].title, [{ type: "Text", value: "Shared parser keyword" }]);
assert.equal(ast.children[1].todo, undefined);
assert.deepEqual(ast.children[1].title, [{ type: "Text", value: "NEXT Plain title" }]);

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-todo-keywords-"));
const note = path.join(tmp, "clock.org2");
fs.writeFileSync(note, "* cancelled Review import :ops:\nCLOCK: [2026-07-05 Sun 09:00]--[2026-07-05 Sun 09:30]\n", "utf8");

const report = extractClockReport([note], { rootDir: tmp });
assert.equal(report.intervals[0].heading, "Review import");
assert.deepEqual(report.intervals[0].tags, ["ops"]);

console.log("✓ todo-keywords");
