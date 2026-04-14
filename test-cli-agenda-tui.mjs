#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  appendAgendaTuiTodoToDailyNote,
  formatAgendaTuiDailyNotePathLabel,
  isAgendaTuiCaptureKey,
  resolveAgendaTuiTodayDailyNotePath,
} from "./dist/cli.js";

function getTodayString() {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function formatTodayScheduledTimestamp() {
  const today = getTodayString();
  const [year, month, day] = today.split("-").map((part) => Number(part));
  const date = new Date(Date.UTC(year, month - 1, day));
  const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  return `<${today} ${weekdays[date.getUTCDay()]}>`;
}

function withTempDir(run) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agenda-tui-"));
  try {
    return run(tmpDir);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

withTempDir((tmpDir) => {
  const repoRootDailyNotePath = resolveAgendaTuiTodayDailyNotePath(null, tmpDir);
  assert.equal(
    repoRootDailyNotePath,
    path.join(tmpDir, `${getTodayString()}.org2`),
    "repo-root daily notes should resolve to ./YYYY-MM-DD.org2 when no roam dailies dir is configured",
  );

  assert.equal(
    formatAgendaTuiDailyNotePathLabel(repoRootDailyNotePath, tmpDir),
    `${getTodayString()}.org2`,
    "daily-note labels should stay relative to the repo root in the TUI",
  );

  appendAgendaTuiTodoToDailyNote(repoRootDailyNotePath, "Write release notes");
  assert.equal(
    fs.readFileSync(repoRootDailyNotePath, "utf8"),
    `* TODO Write release notes\nSCHEDULED: ${formatTodayScheduledTimestamp()}\n`,
    "appendAgendaTuiTodoToDailyNote should create the repo-root daily note when it does not exist",
  );
});

withTempDir((tmpDir) => {
  const dailyNotePath = path.join(tmpDir, `${getTodayString()}.org2`);
  fs.writeFileSync(dailyNotePath, "* TODO Existing item", "utf8");
  appendAgendaTuiTodoToDailyNote(dailyNotePath, "Review inbox");
  assert.equal(
    fs.readFileSync(dailyNotePath, "utf8"),
    `* TODO Existing item\n* TODO Review inbox\nSCHEDULED: ${formatTodayScheduledTimestamp()}\n`,
    "appendAgendaTuiTodoToDailyNote should append after an existing repo-root daily note without requiring a trailing newline",
  );
});

assert.equal(isAgendaTuiCaptureKey("c"), true, "existing c capture shortcut must keep working");
assert.equal(isAgendaTuiCaptureKey("a"), true, "new ergonomic a shortcut should open TUI capture");
assert.equal(isAgendaTuiCaptureKey("n"), false, "schedule shortcut n must remain unchanged");

console.log("agenda TUI daily-note capture tests passed");
