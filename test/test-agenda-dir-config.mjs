import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agenda-dir-config-"));
const cli = path.resolve("dist/cli.js");

try {
  fs.mkdirSync(path.join(tmp, "agents"), { recursive: true });
  fs.writeFileSync(
    path.join(tmp, "org2.json"),
    JSON.stringify({ agendaFiles: ["agents/scout.org2"] }, null, 2) + "\n",
  );
  fs.writeFileSync(
    path.join(tmp, "ignored.org"),
    "* TODO Ignored root task\nSCHEDULED: <2026-06-09 Tue>\n",
  );
  fs.writeFileSync(
    path.join(tmp, "agents", "scout.org2"),
    "* TODO Configured agent task\nSCHEDULED: <2026-06-09 Tue>\n",
  );

  const raw = execFileSync("node", [
    cli,
    "agenda",
    "--dir",
    tmp,
    "--today",
    "2026-06-09",
    "--days",
    "1",
    "--format",
    "json",
  ], { encoding: "utf8" });

  const agenda = JSON.parse(raw);
  const headlines = agenda.days.flatMap((day) => day.items.map((item) => item.headline));

  assert.deepEqual(headlines, ["Configured agent task"]);
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
