#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { once } from "node:events";
import { applyDataQueryResult, runOrg2DataQuery } from "../dist/dataQuery.js";
import { loadRemoteDataset } from "../dist/dataSources.js";

const requests = [];
const server = http.createServer(async (request, response) => {
  let body = "";
  for await (const chunk of request) body += chunk;
  requests.push({ url: request.url, headers: request.headers, body });
  response.setHeader("content-type", "application/json");

  if (request.url?.startsWith("/metabase/") && request.headers["x-api-key"] === "expired-key") {
    response.statusCode = 401;
    response.end(JSON.stringify({ message: "API key is invalid" }));
    return;
  }

  if (request.url?.startsWith("/clickhouse")) {
    response.end(body.includes("large")
      ? JSON.stringify({ data: [{ value: "x".repeat(2_000) }] })
      : JSON.stringify({ data: [{ state: "CA", fetches: 42 }, { state: "NY", fetches: 24 }] }));
    return;
  }
  if (request.url?.startsWith("/metabase/api/card/42/query/json")) {
    response.end(JSON.stringify([{ quarter: "2026-Q1", revenue: 1200 }, { quarter: "2026-Q2", revenue: 1500 }]));
    return;
  }
  if (request.url === "/metabase/api/dataset") {
    response.end(JSON.stringify({
      data: {
        cols: [{ name: "day" }, { name: "messages" }],
        rows: [["2026-07-12", 6], ["2026-07-13", 20]],
      },
    }));
    return;
  }
  response.statusCode = 404;
  response.end(JSON.stringify({ error: "not found" }));
});

server.listen(0, "127.0.0.1");
await once(server, "listening");
const address = server.address();
assert.ok(address && typeof address === "object");
const origin = `http://127.0.0.1:${address.port}`;

const profiles = {
  "scarf-clickhouse": {
    type: "clickhouse",
    url: `${origin}/clickhouse`,
    database: "analytics",
    userEnv: "TEST_CLICKHOUSE_USER",
    passwordEnv: "TEST_CLICKHOUSE_PASSWORD",
    timeoutMs: 5_000,
    maxRows: 100,
  },
  "scarf-metabase": {
    type: "metabase",
    url: `${origin}/metabase/`,
    apiKeyEnv: "TEST_METABASE_API_KEY",
    databaseIdEnv: "TEST_METABASE_DATABASE_ID",
    timeoutMs: 5_000,
    maxRows: 100,
  },
};
const env = {
  TEST_CLICKHOUSE_USER: "reader",
  TEST_CLICKHOUSE_PASSWORD: "clickhouse-secret",
  TEST_METABASE_API_KEY: "metabase-secret",
  TEST_METABASE_DATABASE_ID: "7",
};

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-data-sources-"));
const fakeDuckdb = path.join(tmp, "duckdb");
fs.writeFileSync(fakeDuckdb, `#!/usr/bin/env node
import fs from "node:fs";
const sql = fs.readFileSync(0, "utf8");
if (!sql.includes('CREATE OR REPLACE VIEW "warehouse_fetches" AS SELECT * FROM (VALUES')) process.exit(11);
if (!sql.includes("('CA', 42), ('NY', 24)")) process.exit(12);
if (!sql.includes('CREATE OR REPLACE VIEW "metabase_revenue" AS SELECT * FROM (VALUES')) process.exit(13);
if (!sql.includes('CREATE OR REPLACE VIEW "metabase_chat_daily" AS SELECT * FROM (VALUES')) process.exit(14);
if (!sql.includes("('2026-07-12', 6), ('2026-07-13', 20)")) process.exit(15);
if (/clickhouse-secret|metabase-secret/.test(sql)) process.exit(16);
process.stdout.write(JSON.stringify([{state: "CA", fetches: 42, revenue: 1200}]));
`, "utf8");
fs.chmodSync(fakeDuckdb, 0o755);

const note = `* Warehouse report

\`\`\`dataset warehouse_fetches
type: clickhouse
profile: scarf-clickhouse
query: |
  SELECT state, count() AS fetches
  FROM package_downloads
  GROUP BY state
\`\`\`

\`\`\`dataset metabase_revenue
type: metabase
profile: scarf-metabase
question: 42
parameters: |
  [{"type":"category","value":"active","target":["variable",["template-tag","status"]]}]
\`\`\`

\`\`\`dataset metabase_chat_daily
type: metabase
profile: scarf-metabase
query: |
  SELECT sent_at::date AS day, count(*) AS messages
  FROM chat_v3_messages
  GROUP BY 1
\`\`\`

\`\`\`sql results=combined sources=warehouse_fetches,metabase_revenue,metabase_chat_daily
SELECT warehouse_fetches.state, warehouse_fetches.fetches, metabase_revenue.revenue
FROM warehouse_fetches
CROSS JOIN metabase_revenue
CROSS JOIN metabase_chat_daily
LIMIT 1
\`\`\`
`;
const notePath = path.join(tmp, "warehouse-report.org2");
fs.writeFileSync(notePath, note, "utf8");
fs.writeFileSync(path.join(tmp, "org2.json"), JSON.stringify({ dataSources: profiles }, null, 2), "utf8");

try {
  const result = await runOrg2DataQuery(note, {
    file: notePath,
    env,
    duckdbPath: fakeDuckdb,
    includeScript: true,
  });
  assert.equal(result.ok, true);
  assert.equal(result.rowCount, 1);
  assert.deepEqual(result.resultBlocks[0].sourceIds, ["warehouse_fetches", "metabase_revenue", "metabase_chat_daily"]);
  assert.equal(result.datasets[0].type, "clickhouse");
  assert.equal(result.datasets[0].profile, "scarf-clickhouse");
  assert.equal(result.datasets[0].rowCount, 2);
  assert.match(result.datasets[0].query, /GROUP BY state/);
  assert.equal(result.datasets[1].type, "metabase");
  assert.equal(result.datasets[1].questionId, 42);
  assert.equal(result.datasets[1].rowCount, 2);
  assert.equal(result.datasets[2].type, "metabase");
  assert.match(result.datasets[2].query, /chat_v3_messages/);
  assert.equal(result.datasets[2].rowCount, 2);
  assert.doesNotMatch(result.duckdbScript, /clickhouse-secret|metabase-secret/);

  const bootstrapNote = `${note}\n#+query-data: result=combined rows=1 bootstrap=true\n#+name: combined\n#+results: query-data-combined\n| stale |\n|-------|\n| yes   |\n`;
  const firstApply = applyDataQueryResult(bootstrapNote, result);
  assert.equal(firstApply.changed, true);
  assert.equal((firstApply.text.match(/#\+query-data: result=combined/g) || []).length, 1);
  assert.doesNotMatch(firstApply.text, /bootstrap=true|\| stale \|/);
  const secondApply = applyDataQueryResult(firstApply.text, result);
  assert.equal(secondApply.changed, false);

  const clickhouse = requests.find((request) => request.url?.startsWith("/clickhouse"));
  assert.ok(clickhouse);
  assert.match(clickhouse.url, /readonly=2/);
  assert.match(clickhouse.url, /max_result_rows=100/);
  assert.equal(clickhouse.headers["x-clickhouse-user"], "reader");
  assert.equal(clickhouse.headers["x-clickhouse-key"], "clickhouse-secret");
  assert.equal(clickhouse.headers["x-clickhouse-database"], "analytics");
  assert.match(clickhouse.body, /SELECT state/);

  const metabase = requests.find((request) => request.url?.startsWith("/metabase/api/card/42/query/json"));
  assert.ok(metabase);
  assert.match(metabase.url, /format_rows=false/);
  assert.equal(metabase.headers["x-api-key"], "metabase-secret");
  assert.equal(JSON.parse(metabase.body).parameters[0].value, "active");

  const metabaseNative = requests.find((request) => request.url === "/metabase/api/dataset");
  assert.ok(metabaseNative);
  assert.equal(metabaseNative.headers["x-api-key"], "metabase-secret");
  const nativeBody = JSON.parse(metabaseNative.body);
  assert.equal(nativeBody.database, 7);
  assert.equal(nativeBody.type, "native");
  assert.match(nativeBody.native.query, /chat_v3_messages/);
  assert.deepEqual(nativeBody.parameters, []);

  await assert.rejects(
    loadRemoteDataset({ type: "metabase", profile: "scarf-metabase", questionId: 42 }, profiles, {}),
    /TEST_METABASE_API_KEY.*not set/,
  );
  await assert.rejects(
    loadRemoteDataset({ type: "metabase", profile: "scarf-metabase", query: "SELECT 1" }, profiles, {
      TEST_METABASE_API_KEY: "metabase-secret",
    }),
    /TEST_METABASE_DATABASE_ID.*not set/,
  );
  await assert.rejects(
    loadRemoteDataset({ type: "metabase", profile: "scarf-metabase", questionId: 42 }, profiles, {
      TEST_METABASE_API_KEY: "expired-key",
      TEST_METABASE_DATABASE_ID: "7",
    }),
    /authentication failed \(HTTP 401\).*API key is invalid/,
  );
  await assert.rejects(
    loadRemoteDataset(
      { type: "metabase", profile: "insecure", questionId: 42 },
      { insecure: { type: "metabase", url: "http://metabase.example.com", apiKeyEnv: "TEST_METABASE_API_KEY" } },
      env,
    ),
    /must use HTTPS unless it targets localhost/,
  );
  await assert.rejects(
    loadRemoteDataset(
      { type: "clickhouse", profile: "tiny", query: "SELECT 'large'" },
      { tiny: { type: "clickhouse", url: `${origin}/clickhouse`, maxResponseBytes: 1_024 } },
      env,
    ),
    /returned more than 1024 bytes/,
  );
} finally {
  server.close();
  await once(server, "close");
}

console.log("data source adapters: ok");
