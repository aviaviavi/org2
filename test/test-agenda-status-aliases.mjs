#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agenda-status-aliases-"));
const note = path.join(tmp, "agenda.org2");

fs.writeFileSync(
  note,
  `* TODO Open task
SCHEDULED: <2026-07-07 Tue>
* WAITING Paused task
SCHEDULED: <2026-07-07 Tue>
* DONE Closed task
SCHEDULED: <2026-07-07 Tue>
* CANCELED Canceled task
SCHEDULED: <2026-07-07 Tue>
* SOMEDAY Custom task
SCHEDULED: <2026-07-07 Tue>
`,
  "utf8",
);

function agenda(...args) {
  const raw = execFileSync(
    "node",
    [
      "dist/cli.js",
      "agenda",
      "--files",
      note,
      "--from",
      "2026-07-07",
      "--to",
      "2026-07-07",
      "--format",
      "json",
      ...args,
    ],
    { encoding: "utf8" },
  );
  return JSON.parse(raw).days.flatMap((day) => day.items.map((item) => item.headline));
}

assert.deepEqual(
  agenda("--status", "backlog,waiting,complete,cancel,custom"),
  ["Open task", "Paused task", "Closed task", "Canceled task", "Custom task"],
);

assert.deepEqual(
  agenda("--exclude-status", "on-hold,closed"),
  ["Open task", "Custom task"],
);

console.log("✓ agenda status aliases");
