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
const urlNote = path.join(tmp, "url-report.org2");
const unsafeCredentialNote = path.join(tmp, "unsafe-credential-report.org2");
const viewNote = path.join(tmp, "view-report.org2");
const orgViewNote = path.join(tmp, "org-view-report.org2");
const duplicateDatasetNote = path.join(tmp, "duplicate-dataset-report.org2");
const conflictingRelationNote = path.join(tmp, "conflicting-relation-report.org2");
const duplicateResultNote = path.join(tmp, "duplicate-result-report.org2");
const fourTickDatasetNote = path.join(tmp, "four-tick-dataset-report.org2");
const data = path.join(tmp, "package-fetches.csv");
const fakeDuckdb = path.join(tmp, "duckdb");
const out = path.join(tmp, "fetches_by_state.org");
const jsonOut = path.join(tmp, "fetches_by_state.json");

function regexEscape(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

fs.writeFileSync(data, "state,fetches\nCA,42\nNY,24\n", "utf8");
fs.writeFileSync(note, `* Package fetch report

\`\`\`dataset fetches
type: csv
path: ./package-fetches.csv
engine: duckdb
\`\`\`

\`\`\`sql results=fetches_by_state artifact=views/fetches_by_state.org freshness=24h
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

fs.writeFileSync(urlNote, `* Remote package fetch report

\`\`\`dataset remote_fetches
type: csv
url: https://data.example.test/package-fetches.csv
engine: duckdb
credential: env:SCARF_API_TOKEN
config: profile:product-analytics
\`\`\`

\`\`\`sql results=remote_fetches_by_state
SELECT state, sum(fetches) AS fetches
FROM remote_fetches
GROUP BY state
ORDER BY fetches DESC
\`\`\`
`, "utf8");

fs.writeFileSync(unsafeCredentialNote, `* Remote package fetch report with unsafe auth metadata

\`\`\`dataset remote_fetches
type: csv
url: https://data.example.test/package-fetches.csv
engine: duckdb
auth: Bearer inline-secret-token
\`\`\`

\`\`\`sql results=remote_fetches_by_state
SELECT state, sum(fetches) AS fetches
FROM remote_fetches
GROUP BY state
\`\`\`
`, "utf8");

fs.writeFileSync(fourTickDatasetNote, `* Package fetch report with quoted dataset example

\`\`\`\`dataset fetches
type: csv
path: ./package-fetches.csv
engine: duckdb
\`\`\`\`

\`\`\`\`sql results=fetches_by_state
SELECT state, sum(fetches) AS fetches
FROM fetches
GROUP BY state
\`\`\`\`
`, "utf8");

fs.writeFileSync(viewNote, `* Package fetch report with reusable SQL views

\`\`\`dataset fetches
type: csv
path: ./package-fetches.csv
engine: duckdb
\`\`\`

\`\`\`sql view=big_fetches
SELECT state, fetches
FROM fetches
WHERE fetches >= 40
\`\`\`

#+name: fetches_by_state
#+begin_src sql
SELECT state, sum(fetches) AS fetches
FROM big_fetches
GROUP BY state
ORDER BY fetches DESC
#+end_src
`, "utf8");

fs.writeFileSync(orgViewNote, `* Package fetch report with org-style SQL views

#+begin_dataset fetches
type: csv
path: ./package-fetches.csv
engine: duckdb
#+end_dataset

#+name: big_fetches
#+begin_src sql :view
SELECT state, fetches
FROM fetches
WHERE fetches >= 40
#+end_src

\`\`\`sql results=fetches_by_state
SELECT state, sum(fetches) AS fetches
FROM big_fetches
GROUP BY state
ORDER BY fetches DESC
\`\`\`
`, "utf8");

fs.writeFileSync(duplicateDatasetNote, `* Package fetch report with duplicate datasets

\`\`\`dataset fetches
type: csv
path: ./package-fetches.csv
engine: duckdb
\`\`\`

\`\`\`dataset fetches
type: csv
path: ./package-fetches.csv
engine: duckdb
\`\`\`

\`\`\`sql results=fetches_by_state
SELECT state, sum(fetches) AS fetches
FROM fetches
GROUP BY state
\`\`\`
`, "utf8");

fs.writeFileSync(conflictingRelationNote, `* Package fetch report with conflicting relation ids

\`\`\`dataset fetches
type: csv
path: ./package-fetches.csv
engine: duckdb
\`\`\`

\`\`\`sql view=fetches
SELECT state, fetches
FROM fetches
WHERE fetches > 0
\`\`\`

\`\`\`sql results=fetches_by_state
SELECT state, sum(fetches) AS fetches
FROM fetches
GROUP BY state
\`\`\`
`, "utf8");

fs.writeFileSync(duplicateResultNote, `* Package fetch report with duplicate SQL results

\`\`\`dataset fetches
type: csv
path: ./package-fetches.csv
engine: duckdb
\`\`\`

\`\`\`sql results=fetches_by_state
SELECT state, sum(fetches) AS fetches
FROM fetches
GROUP BY state
\`\`\`

\`\`\`sql results=fetches_by_state
SELECT state, count(*) AS rows
FROM fetches
GROUP BY state
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
if (input.includes('CREATE OR REPLACE VIEW "remote_fetches" AS SELECT * FROM read_csv_auto(\\'https://data.example.test/package-fetches.csv\\')')) {
  if (!input.includes("FROM remote_fetches")) {
    console.error("missing remote SQL query");
    process.exit(6);
  }
  process.stdout.write(JSON.stringify([{ state: "CA", fetches: 42 }, { state: "NY", fetches: 24 }]));
  process.exit(0);
}
if (input.includes('CREATE OR REPLACE VIEW "big_fetches" AS SELECT * FROM (SELECT state, fetches')) {
  if (!input.includes("FROM fetches\\nWHERE fetches >= 40) AS org2_view;")) {
    console.error("missing SQL view body");
    process.exit(7);
  }
  if (!input.includes("FROM big_fetches")) {
    console.error("missing query over SQL view");
    process.exit(8);
  }
  process.stdout.write(JSON.stringify([{ state: "CA", fetches: 42 }]));
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

function lineOf(file, needle) {
  const lines = fs.readFileSync(file, "utf8").split("\n");
  const index = lines.findIndex((line) => line.includes(needle));
  assert.notEqual(index, -1, `missing ${needle}`);
  return String(index + 1);
}

const json = JSON.parse(cli(["query-data", "--file", note, "--results", "fetches_by_state", "--duckdb", fakeDuckdb, "--format", "json", "--include-script"]));
assert.equal(json.ok, true);
assert.equal(json.mode, "execute");
assert.equal(json.engine, "duckdb");
assert.equal(json.resultId, "fetches_by_state");
assert.equal(json.rowCount, 2);
assert.equal(json.datasets[0].id, "fetches");
assert.deepEqual(json.resultBlocks, [{
  resultId: "fetches_by_state",
  artifact: "views/fetches_by_state.org",
  freshness: "24h",
  line: 9,
  endLine: 14,
}]);
assert.equal(json.rows[0].state, "CA");
assert.equal(json.provenance.resultId, "fetches_by_state");
assert.equal(json.provenance.artifact, "views/fetches_by_state.org");
assert.equal(json.provenance.freshness, "24h");
assert.deepEqual(json.provenance.datasetIds, ["fetches"]);
assert.deepEqual(json.provenance.viewIds, []);
assert.match(json.provenance.querySha256, /^[a-f0-9]{64}$/);
assert.match(json.provenance.scriptSha256, /^[a-f0-9]{64}$/);
assert.match(json.provenance.ranAt, /^\d{4}-\d{2}-\d{2}T/);
assert.match(json.duckdbScript, /read_csv_auto/);
assert.match(json.orgTable, /^#\+query-data: result=fetches_by_state rows=2 artifact=views\/fetches_by_state\.org freshness=24h query_sha256=[a-f0-9]{64} script_sha256=[a-f0-9]{64}/);
assert.match(json.orgTable, / ran_at=\d{4}-\d{2}-\d{2}T/);
assert.match(json.orgTable, /#\+name: fetches_by_state/);
assert.match(json.orgTable, /\| state \| fetches \|/);

const org = cli(["query-data", "--file", note, "--results", "fetches_by_state", "--duckdb", fakeDuckdb]);
assert.match(org, /^#\+query-data: result=fetches_by_state rows=2 artifact=views\/fetches_by_state\.org freshness=24h query_sha256=[a-f0-9]{64} script_sha256=[a-f0-9]{64}/);
assert.match(org, / ran_at=\d{4}-\d{2}-\d{2}T/);
assert.match(org, /#\+name: fetches_by_state/);
assert.match(org, /\| state \| fetches \|/);
assert.match(org, /\| CA    \| 42      \|/);

const inspect = JSON.parse(cli(["query-data", "--file", note, "--inspect", "--duckdb", path.join(tmp, "missing-duckdb")]));
assert.equal(inspect.ok, true);
assert.equal(inspect.mode, "inspect");
assert.equal(inspect.rowCount, 0);
assert.deepEqual(inspect.rows, []);
assert.equal(inspect.provenance.resultId, "fetches_by_state");
assert.equal(inspect.provenance.artifact, "views/fetches_by_state.org");
assert.equal(inspect.provenance.freshness, "24h");
assert.deepEqual(inspect.provenance.datasetIds, ["fetches"]);
assert.deepEqual(inspect.provenance.viewIds, []);
assert.match(inspect.provenance.querySha256, /^[a-f0-9]{64}$/);
assert.match(inspect.provenance.scriptSha256, /^[a-f0-9]{64}$/);
assert.equal(inspect.orgTable, undefined);
assert.equal(inspect.duckdbScript, undefined);
assert.equal(inspect.datasets[0].id, "fetches");
assert.deepEqual(inspect.resultBlocks, [{
  resultId: "fetches_by_state",
  artifact: "views/fetches_by_state.org",
  freshness: "24h",
  line: 9,
  endLine: 14,
}]);

const inspectWithScript = JSON.parse(cli(["query-data", "--file", note, "--inspect", "--results", "fetches_by_state", "--duckdb", path.join(tmp, "missing-duckdb"), "--include-script"]));
assert.equal(inspectWithScript.ok, true);
assert.equal(inspectWithScript.mode, "inspect");
assert.equal(inspectWithScript.rowCount, 0);
assert.deepEqual(inspectWithScript.rows, []);
assert.equal(inspectWithScript.provenance.resultId, "fetches_by_state");
assert.equal(inspectWithScript.provenance.artifact, "views/fetches_by_state.org");
assert.equal(inspectWithScript.provenance.freshness, "24h");
assert.match(inspectWithScript.duckdbScript, /CREATE OR REPLACE VIEW "fetches" AS SELECT \* FROM read_csv_auto/);
assert.match(inspectWithScript.duckdbScript, /SELECT state, sum\(fetches\) AS fetches/);

const inspectLine = JSON.parse(cli(["query-data", "--file", note, "--inspect", "--line", lineOf(note, "SELECT state"), "--duckdb", path.join(tmp, "missing-duckdb")]));
assert.equal(inspectLine.ok, true);
assert.equal(inspectLine.mode, "inspect");
assert.equal(inspectLine.resultId, "fetches_by_state");
assert.equal(inspectLine.source.line, Number(lineOf(note, "```sql results=fetches_by_state")));
assert.equal(inspectLine.provenance.resultId, "fetches_by_state");

const lineJson = JSON.parse(cli(["query-data", "--file", note, "--line", lineOf(note, "SELECT state"), "--duckdb", fakeDuckdb, "--format", "json"]));
assert.equal(lineJson.ok, true);
assert.equal(lineJson.resultId, "fetches_by_state");
assert.equal(lineJson.source.line, Number(lineOf(note, "```sql results=fetches_by_state")));
assert.equal(lineJson.rows[0].state, "CA");

const orgStyleByName = JSON.parse(cli(["query-data", "--file", orgStyleNote, "--results", "fetches_by_state_src", "--duckdb", fakeDuckdb, "--format", "json"]));
assert.equal(orgStyleByName.ok, true);
assert.equal(orgStyleByName.resultId, "fetches_by_state_src");
assert.equal(orgStyleByName.rowCount, 2);

const orgStyleByHeaderArg = JSON.parse(cli(["query-data", "--file", orgStyleNote, "--results", "fetches_by_state_header", "--duckdb", fakeDuckdb, "--format", "json"]));
assert.equal(orgStyleByHeaderArg.ok, true);
assert.equal(orgStyleByHeaderArg.resultId, "fetches_by_state_header");
assert.equal(orgStyleByHeaderArg.rows[0].state, "CA");

cli(["query-data", "--file", note, "--results", "fetches_by_state", "--duckdb", fakeDuckdb, "--out", out]);
assert.match(fs.readFileSync(out, "utf8"), new RegExp(`^#\\+query-data: result=fetches_by_state rows=2 artifact=${regexEscape(out)} freshness=24h query_sha256=[a-f0-9]{64} script_sha256=[a-f0-9]{64}`));
assert.match(fs.readFileSync(out, "utf8"), /\| NY    \| 24      \|/);

cli(["query-data", "--file", note, "--results", "fetches_by_state", "--duckdb", fakeDuckdb, "--format", "json", "--out", jsonOut]);
const writtenJson = JSON.parse(fs.readFileSync(jsonOut, "utf8"));
assert.equal(writtenJson.provenance.artifact, jsonOut);
assert.equal(writtenJson.provenance.freshness, "24h");
assert.match(writtenJson.orgTable, new RegExp(`artifact=${regexEscape(jsonOut)} freshness=24h`));

const tableJson = JSON.parse(cli(["query-data", "--file", tableNote, "--results", "fetches_total", "--duckdb", fakeDuckdb, "--format", "json", "--include-script"]));
assert.equal(tableJson.ok, true);
assert.equal(tableJson.datasets[0].type, "table");
assert.equal(tableJson.datasets[0].sourceTable, "raw_fetches");
assert.equal(tableJson.datasets[0].rowCount, 2);
assert.match(tableJson.duckdbScript, /VALUES \('CA', 42\), \('NY', 24\)/);
assert.equal(tableJson.rows[0].fetches, 66);
assert.match(tableJson.orgTable, /\| fetches \|/);

const urlJson = JSON.parse(cli(["query-data", "--file", urlNote, "--results", "remote_fetches_by_state", "--duckdb", fakeDuckdb, "--format", "json", "--include-script"]));
assert.equal(urlJson.ok, true);
assert.equal(urlJson.datasets[0].id, "remote_fetches");
assert.equal(urlJson.datasets[0].url, "https://data.example.test/package-fetches.csv");
assert.equal(urlJson.datasets[0].credentialRef, "env:SCARF_API_TOKEN");
assert.equal(urlJson.datasets[0].configRef, "profile:product-analytics");
assert.equal(urlJson.datasets[0].path, undefined);
assert.match(urlJson.duckdbScript, /read_csv_auto\('https:\/\/data\.example\.test\/package-fetches\.csv'\)/);
assert.doesNotMatch(urlJson.duckdbScript, /SCARF_API_TOKEN|product-analytics/);
assert.equal(urlJson.rows[0].state, "CA");

const unsafeCredential = spawnSync("node", ["dist/cli.js", "query-data", "--file", unsafeCredentialNote, "--inspect", "--format", "json"], { cwd: repo, encoding: "utf8" });
assert.notEqual(unsafeCredential.status, 0);
const unsafeCredentialJson = JSON.parse(unsafeCredential.stdout);
assert.equal(unsafeCredentialJson.ok, false);
assert.match(unsafeCredentialJson.diagnostics[0].message, /credential\/auth metadata must be a reference/);

const fourTickDataset = spawnSync("node", ["dist/cli.js", "query-data", "--file", fourTickDatasetNote, "--inspect", "--format", "json"], { cwd: repo, encoding: "utf8" });
assert.notEqual(fourTickDataset.status, 0);
const fourTickDatasetJson = JSON.parse(fourTickDataset.stdout);
assert.equal(fourTickDatasetJson.ok, false);
assert.deepEqual(fourTickDatasetJson.datasets, []);
assert.deepEqual(fourTickDatasetJson.resultBlocks, []);
assert.match(fourTickDatasetJson.diagnostics[0].message, /No SQL result blocks found|No dataset blocks found/);

const viewJson = JSON.parse(cli(["query-data", "--file", viewNote, "--results", "fetches_by_state", "--duckdb", fakeDuckdb, "--format", "json", "--include-script"]));
assert.equal(viewJson.ok, true);
assert.equal(viewJson.views[0].id, "big_fetches");
assert.equal(viewJson.views[0].line, 9);
assert.match(viewJson.duckdbScript, /CREATE OR REPLACE VIEW "big_fetches" AS SELECT \* FROM/);
assert.match(viewJson.duckdbScript, /FROM big_fetches/);
assert.equal(viewJson.rows[0].fetches, 42);

const orgViewJson = JSON.parse(cli(["query-data", "--file", orgViewNote, "--results", "fetches_by_state", "--duckdb", fakeDuckdb, "--format", "json", "--include-script"]));
assert.equal(orgViewJson.ok, true);
assert.equal(orgViewJson.views[0].id, "big_fetches");
assert.equal(orgViewJson.views[0].line, 10);
assert.equal(orgViewJson.rows[0].state, "CA");

const stdinJson = JSON.parse(cli(["query-data", "--stdin", "--results", "fetches_total", "--duckdb", fakeDuckdb, "--format", "json"], {
  input: fs.readFileSync(tableNote, "utf8"),
}));
assert.equal(stdinJson.ok, true);
assert.equal(stdinJson.resultId, "fetches_total");
assert.equal(stdinJson.source.file, undefined);
assert.equal(stdinJson.datasets[0].sourceTable, "raw_fetches");
assert.equal(stdinJson.rows[0].fetches, 66);

const stdinLineJson = JSON.parse(cli(["query-data", "--stdin", "--line", lineOf(tableNote, "SELECT sum(fetches)"), "--duckdb", fakeDuckdb, "--format", "json"], {
  input: fs.readFileSync(tableNote, "utf8"),
}));
assert.equal(stdinLineJson.ok, true);
assert.equal(stdinLineJson.resultId, "fetches_total");
assert.equal(stdinLineJson.source.file, undefined);
assert.equal(stdinLineJson.rows[0].fetches, 66);

const bad = spawnSync("node", ["dist/cli.js", "query-data", "--file", note, "--results", "missing", "--duckdb", fakeDuckdb, "--format", "json"], { cwd: repo, encoding: "utf8" });
assert.notEqual(bad.status, 0);
const badJson = JSON.parse(bad.stdout);
assert.equal(badJson.ok, false);
assert.match(badJson.diagnostics[0].message, /No SQL result block/);

const duplicateDataset = spawnSync("node", ["dist/cli.js", "query-data", "--file", duplicateDatasetNote, "--results", "fetches_by_state", "--duckdb", fakeDuckdb, "--format", "json"], { cwd: repo, encoding: "utf8" });
assert.notEqual(duplicateDataset.status, 0);
const duplicateDatasetJson = JSON.parse(duplicateDataset.stdout);
assert.equal(duplicateDatasetJson.ok, false);
assert.match(duplicateDatasetJson.diagnostics[0].message, /Duplicate dataset block "fetches"/);

const conflictingRelation = spawnSync("node", ["dist/cli.js", "query-data", "--file", conflictingRelationNote, "--results", "fetches_by_state", "--duckdb", fakeDuckdb, "--format", "json"], { cwd: repo, encoding: "utf8" });
assert.notEqual(conflictingRelation.status, 0);
const conflictingRelationJson = JSON.parse(conflictingRelation.stdout);
assert.equal(conflictingRelationJson.ok, false);
assert.match(conflictingRelationJson.diagnostics[0].message, /SQL view block "fetches" conflicts with a dataset block/);

const duplicateResult = spawnSync("node", ["dist/cli.js", "query-data", "--file", duplicateResultNote, "--results", "fetches_by_state", "--duckdb", fakeDuckdb, "--format", "json"], { cwd: repo, encoding: "utf8" });
assert.notEqual(duplicateResult.status, 0);
const duplicateResultJson = JSON.parse(duplicateResult.stdout);
assert.equal(duplicateResultJson.ok, false);
assert.deepEqual(duplicateResultJson.resultBlocks.map((block) => ({
  resultId: block.resultId,
  line: block.line,
  endLine: block.endLine,
})), [
  { resultId: "fetches_by_state", line: 9, endLine: 13 },
  { resultId: "fetches_by_state", line: 15, endLine: 19 },
]);
assert.match(duplicateResultJson.diagnostics[0].message, /Duplicate SQL result block "fetches_by_state"/);

console.log("✓ query-data CLI");
