import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-brief-test-"));
fs.writeFileSync(path.join(tmp, "notes.org2"), `* Copper launch
:PROPERTIES:
:ID: copper-1
:PROJECT: copper
:ORG2_REVIEW_STATUS: reviewed
:ORG2_VALID_AS_OF: 2026-06-07
:END:
Copper launch needs human-facing briefings generated from agent context.

** TODO Follow up on briefing UX :copper:
:PROPERTIES:
:ORG2_REVIEW_STATUS: review-required
:DATE: 2026-06-07
:END:
Review terminal output and views storage for Copper launch.
`, "utf8");
fs.writeFileSync(path.join(tmp, "references.org2"), `* Team notes
:PROPERTIES:
:ID: team-notes
:END:
Review [[id:copper-1][Copper launch]] before the customer readout.

* Another note
Link again to [[id:copper-1][Copper launch]].
`, "utf8");

const projectBrief = execFileSync("node", ["dist/cli.js", "brief", "project", "copper", "--dir", tmp, "--recursive", "--limit", "5"], { encoding: "utf8" });
assert.match(projectBrief, /# Org2 Briefing: Project copper/);
assert.match(projectBrief, /Source-backed notes/);
assert.match(projectBrief, /notes\.org2:1-16/);
assert.match(projectBrief, /review-required/i);
assert.match(projectBrief, /Citations/);

const nodeBrief = execFileSync("node", ["dist/cli.js", "brief", "node", "--id", "copper-1", "--dir", tmp, "--recursive"], { encoding: "utf8" });
assert.match(nodeBrief, /# Org2 Briefing: Node Copper launch/);
assert.match(nodeBrief, /Backlinks: 2 references across 1 file/);
assert.match(nodeBrief, /## Referencing files/);
assert.match(nodeBrief, /references\.org2 \(2\)/);
assert.match(nodeBrief, /## Related nodes/);

const out = path.join(tmp, "views", "copper-brief.org");
const writeMsg = execFileSync("node", ["dist/cli.js", "brief", "project", "copper", "--dir", tmp, "--out", out, "--format", "org"], { encoding: "utf8" });
assert.match(writeMsg, /Wrote briefing/);
const stored = fs.readFileSync(out, "utf8");
assert.match(stored, /^\* Org2 Briefing: Project copper/m);
assert.match(stored, /REVIEW REQUIRED|Source-backed/);

const today = execFileSync("node", ["dist/cli.js", "brief", "today", "--dir", tmp, "--recursive", "--limit", "3"], { encoding: "utf8", env: { ...process.env, ORG2_TODAY: "2026-06-07" } });
assert.match(today, /Org2 Briefing: Today \(2026-06-07\)/);
assert.match(today, /Follow up on briefing UX/);

console.log("brief tests passed");
