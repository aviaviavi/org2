import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const {
  TODO_KEYWORDS,
  documentTodoSequences,
  updateTodoInText,
  isActiveTodoKeyword,
  isTerminalTodoKeyword,
  isTodoKeyword,
  normalizeTodoKeyword,
  terminalTodoStatusFromKeyword,
} = await import(path.join(repo, "dist", "todo.js"));
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
assert.equal(terminalTodoStatusFromKeyword(" done "), "done");
assert.equal(terminalTodoStatusFromKeyword("CANCELED"), "canceled");
assert.equal(terminalTodoStatusFromKeyword("cancelled"), "canceled");
assert.equal(terminalTodoStatusFromKeyword("IN_PROGRESS"), undefined);
assert.equal(isTerminalTodoKeyword("done"), true);
assert.equal(isTerminalTodoKeyword("TODO"), false);
assert.equal(isActiveTodoKeyword("IN_PROGRESS"), true);
assert.equal(isActiveTodoKeyword("cancelled"), false);
assert.equal(isActiveTodoKeyword(undefined), false);

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

// File-local states retain spelling and terminal semantics in every transition.
const workflowSource = `#+TODO: TODO(t) missed(m@) | DONE(d!) SKIPPED(s)
#+SEQ_TODO: RESEARCH REVIEW PUBLISHED
* missed Follow up
SCHEDULED: <2026-09-08 Tue>
:PROPERTIES:
:ID: jacob-task
:END:
`;
const workflows = documentTodoSequences(workflowSource);
assert.deepEqual(workflows[0], { keywords: ["TODO", "missed", "DONE", "SKIPPED"], terminal: ["DONE", "SKIPPED"] });
assert.deepEqual(workflows[1].terminal, ["PUBLISHED"]);
assert.equal(isTerminalTodoKeyword("SKIPPED", workflows), true);
assert.equal(isTerminalTodoKeyword("missed", workflows), false);
assert.deepEqual(documentTodoSequences("#+begin_src org\n#+TODO: FAKE | FINISHED\n#+end_src\n"), []);
const customAst = parseOrgToCanonicalAst(workflowSource);
const heading = customAst.children.find(node => node.type === "Headline");
assert.equal(heading.todo, "missed");
assert.equal(heading.todoTerminal, false);
assert.deepEqual(customAst.todoSequences, workflows);
const update = (text, options) => updateTodoInText(text, { filePath: "tasks.org", lineNumber: 3, now: new Date("2026-09-08T12:00:00Z"), logbook: true, ...options });
const completed = update(workflowSource, { status: "done" });
assert.match(completed.text, /\* DONE Follow up/);
assert.doesNotMatch(completed.text, /DONE missed/);
assert.match(completed.text, /CLOSED:/);
assert.match(completed.text, /State "DONE" from "missed"/);
const skipped = update(completed.text, { keyword: "SKIPPED" });
assert.match(skipped.text, /State "SKIPPED" from "DONE"/);
assert.equal(skipped.newStatus, "done");
const reopened = update(skipped.text, { keyword: "missed" });
assert.doesNotMatch(reopened.text, /CLOSED:/);
assert.equal(reopened.newKeyword, "missed");
assert.throws(() => update(workflowSource, { keyword: "MISSING" }), /Unknown TODO keyword/);
assert.equal(update(workflowSource, { toggle: true }).newKeyword, "DONE");
assert.equal(update(skipped.text, { toggle: true }).newKeyword, "TODO");
// Lowercase standard keywords must be replaced, not treated as an unchanged success.
assert.match(updateTodoInText("* todo Task\n", { filePath: "x.org", lineNumber: 1, status: "done" }).text, /^\* DONE Task/);
const { execFileSync } = await import("node:child_process");
const workflowFile = path.join(tmp, "workflow.org");
fs.writeFileSync(workflowFile, workflowSource);
const cli = (...args) => execFileSync(process.execPath, [path.join(repo, "dist/cli.js"), ...args], { encoding: "utf8" });
const preview = JSON.parse(cli("todo", "set", "--file", workflowFile, "--line", "3", "--keyword", "SKIPPED", "--format", "json"));
assert.equal(preview.newKeyword, "SKIPPED");
assert.equal(preview.applied, false);
assert.equal(fs.readFileSync(workflowFile, "utf8"), workflowSource);
cli("todo", "set", "--file", workflowFile, "--line", "3", "--status", "SKIPPED", "--apply");
const agenda = cli("agenda", "--files", workflowFile, "--from", "2026-09-09", "--days", "1", "--overdue", "--format", "json");
assert.ok(!agenda.includes('"headline": "Follow up"'), "custom terminal states must not appear as overdue tasks");
console.log("✓ custom TODO workflows and CLI transitions");
const { compileCorpus } = await import(path.join(repo, "dist/corpusCompile.js"));
const { buildSearchIndex, searchIndexedCorpus } = await import(path.join(repo, "dist/searchIndex.js"));
const compiled = compileCorpus([workflowFile], { rootDir: tmp });
assert.equal(compiled.nodes.find(node => node.kind === "heading").todoTerminal, true);
fs.writeFileSync(workflowFile, workflowSource);
const indexed = buildSearchIndex({ rootDir: tmp, files: [workflowFile], recursive: false, includeArchives: false }).index;
assert.equal(indexed.files[0].headings[0].todo, "missed");
const searchOptions = { query: "Follow up", context: 0, limit: 10, todoFilters: new Set(["MISSED"]), tagFilters: new Set(), fileZoneFilters: [], headingNeedle: "", sort: "scan", dateFrom: "", dateTo: "", subtree: false, answerContext: false };
assert.equal(searchIndexedCorpus(indexed, searchOptions)[0].todo, "missed");
// Old cached heading metadata must not conceal custom states until the file is edited.
delete indexed.todoWorkflowVersion;
indexed.files[0].headings[0].todo = undefined;
assert.equal(searchIndexedCorpus(indexed, searchOptions)[0].todo, "missed");
