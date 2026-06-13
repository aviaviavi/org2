#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import assert from "node:assert/strict";

const repo = process.cwd();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-data-query-"));
const note = path.join(tmp, "report.org2");
const orgStyleNote = path.join(tmp, "org-style-report.org2");
const tableNote = path.join(tmp, "table-report.org2");
const data = path.join(tmp, "package-fetches.csv");
const fakeDuckdb = path.join(tmp, "duckdb");
const out = path.join(tmp, "fetches_by_state.org");

fs.writeFileSync(data, "state,fetches\nCA,42\nNY,24\n", "utf8");
fs.writeFileSync(note, `* Package fetch report

\`\`\`dataset fetches
type: csv
path: ./package-fetches.csv
engine: duckdb
\`\`\`

\`\`\`sql results=fetches_by_state
SELECT state, sum(fetches) AS fetches
FROM fetches
GROUP BY state
ORDER BY fetches DESC
\`\`\`

\`\`\`chart bar
source: fetches_by_state
x: state
y: fetches
\`\`\`
`, "utf8");

fs.writeFileSync(tableNote, `* Package fetch report

#+name: raw_fetches
| state | fetches |
|-------+---------|
| CA    | 42      |
| NY    | 24      |

\`\`\`dataset fetches
type: table
source: raw_fetches
engine: duckdb
\`\`\`

\`\`\`sql results=fetches_total
SELECT sum(fetches) AS fetches
FROM fetches
\`\`\`
`, "utf8");

fs.writeFileSync(orgStyleNote, `* Package fetch report

#+begin_dataset fetches
type: csv
path: ./package-fetches.csv
engine: duckdb
#+end_dataset

#+name: fetches_by_state_src
#+begin_src sql
SELECT state, sum(fetches) AS fetches
FROM fetches
GROUP BY state
ORDER BY fetches DESC
#+end_src

#+begin_src sql :id fetches_by_state_header
SELECT state, sum(fetches) AS fetches
FROM fetches
GROUP BY state
ORDER BY fetches DESC
#+end_src
`, "utf8");

fs.writeFileSync(fakeDuckdb, `#!/usr/bin/env node
import fs from "node:fs";
const input = fs.readFileSync(0, "utf8");
if (input.includes('CREATE OR REPLACE VIEW "fetches" AS SELECT * FROM (VALUES')) {
  if (!input.includes('(VALUES (\\'CA\\', 42), (\\'NY\\', 24)) AS t("state", "fetches")')) {
    console.error("missing org table dataset view");
    process.exit(4);
  }
  if (!input.includes("SELECT sum(fetches) AS fetches")) {
    console.error("missing table SQL query");
    process.exit(5);
  }
  process.stdout.write(JSON.stringify([{ fetches: 66 }]));
  process.exit(0);
}
if (!input.includes('CREATE OR REPLACE VIEW "fetches" AS SELECT * FROM read_csv_auto(')) {
  console.error("missing csv dataset view");
  process.exit(2);
}
if (!input.includes("SELECT state, sum(fetches) AS fetches")) {
  console.error("missing SQL query");
  process.exit(3);
}
process.stdout.write(JSON.stringify([{ state: "CA", fetches: 42 }, { state: "NY", fetches: 24 }]));
`, "utf8");
fs.chmodSync(fakeDuckdb, 0o755);

function cli(args, opts = {}) {
  return execFileSync("node", ["dist/cli.js", ...args], { cwd: repo, encoding: "utf8", ...opts });
}

const json = JSON.parse(cli(["query-data", "--file", note, "--results", "fetches_by_state", "--duckdb", fakeDuckdb, "--format", "json", "--include-script"]));
assert.equal(json.ok, true);
assert.equal(json.engine, "duckdb");
assert.equal(json.resultId, "fetches_by_state");
assert.equal(json.rowCount, 2);
assert.equal(json.datasets[0].id, "fetches");
assert.equal(json.rows[0].state, "CA");
assert.match(json.duckdbScript, /read_csv_auto/);
assert.match(json.orgTable, /#\+name: fetches_by_state/);
assert.match(json.orgTable, /\| state \| fetches \|/);

const org = cli(["query-data", "--file", note, "--results", "fetches_by_state", "--duckdb", fakeDuckdb]);
assert.match(org, /#\+name: fetches_by_state/);
assert.match(org, /\| state \| fetches \|/);
assert.match(org, /\| CA    \| 42      \|/);

const orgStyleByName = JSON.parse(cli(["query-data", "--file", orgStyleNote, "--results", "fetches_by_state_src", "--duckdb", fakeDuckdb, "--format", "json"]));
assert.equal(orgStyleByName.ok, true);
assert.equal(orgStyleByName.resultId, "fetches_by_state_src");
assert.equal(orgStyleByName.rowCount, 2);

const orgStyleByHeaderArg = JSON.parse(cli(["query-data", "--file", orgStyleNote, "--results", "fetches_by_state_header", "--duckdb", fakeDuckdb, "--format", "json"]));
assert.equal(orgStyleByHeaderArg.ok, true);
assert.equal(orgStyleByHeaderArg.resultId, "fetches_by_state_header");
assert.equal(orgStyleByHeaderArg.rows[0].state, "CA");

cli(["query-data", "--file", note, "--results", "fetches_by_state", "--duckdb", fakeDuckdb, "--out", out]);
assert.match(fs.readFileSync(out, "utf8"), /\| NY    \| 24      \|/);

const tableJson = JSON.parse(cli(["query-data", "--file", tableNote, "--results", "fetches_total", "--duckdb", fakeDuckdb, "--format", "json", "--include-script"]));
assert.equal(tableJson.ok, true);
assert.equal(tableJson.datasets[0].type, "table");
assert.equal(tableJson.datasets[0].sourceTable, "raw_fetches");
assert.equal(tableJson.datasets[0].rowCount, 2);
assert.match(tableJson.duckdbScript, /VALUES \('CA', 42\), \('NY', 24\)/);
assert.equal(tableJson.rows[0].fetches, 66);
assert.match(tableJson.orgTable, /\| fetches \|/);

const stdinJson = JSON.parse(cli(["query-data", "--stdin", "--results", "fetches_total", "--duckdb", fakeDuckdb, "--format", "json"], {
  input: fs.readFileSync(tableNote, "utf8"),
}));
assert.equal(stdinJson.ok, true);
assert.equal(stdinJson.resultId, "fetches_total");
assert.equal(stdinJson.source.file, undefined);
assert.equal(stdinJson.datasets[0].sourceTable, "raw_fetches");
assert.equal(stdinJson.rows[0].fetches, 66);

const bad = spawnSync("node", ["dist/cli.js", "query-data", "--file", note, "--results", "missing", "--duckdb", fakeDuckdb, "--format", "json"], { cwd: repo, encoding: "utf8" });
assert.notEqual(bad.status, 0);
const badJson = JSON.parse(bad.stdout);
assert.equal(badJson.ok, false);
assert.match(badJson.diagnostics[0].message, /No SQL result block/);

console.log("✓ query-data CLI");
