#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agent-test-"));
const a = path.join(tmp, "alpha.org2");
const b = path.join(tmp, "beta.org2");
fs.writeFileSync(a, `#+title: Alpha File

* Alpha plan :work:
:PROPERTIES:
:ID: alpha-1
:CUSTOM: value
:ORG2_REVIEW_STATUS: reviewed
:ORG2_CLAIM_STATE: human-reviewed
:ORG2_VALID_AS_OF: 2026-05-20
:ORG2_STALE_AFTER: 2099-01-01
:OWNER: Casey
:ASSIGNEE: openclaw
:NEXT_ACTION: Prepare implementation handoff
:WAITING_ON: API review
:REQUIRES_HUMAN_APPROVAL: yes
:ALLOW_AGENT_EDIT: yes
:ALLOW_EXTERNAL_SEND: no
:END:
We decided to ship the retrieval API.
See [[id:beta-1][Beta note]].
`, "utf8");
fs.writeFileSync(b, `#+title: Beta File

* Beta note :ref:
:PROPERTIES:
:ID: beta-1
:END:
Backlink to [[id:alpha-1][Alpha plan]].
`, "utf8");

const runJson = (...args) => JSON.parse(execFileSync("node", ["dist/cli.js", ...args], { encoding: "utf8" }));

const context = runJson("agent", "context", "--query", "retrieval API", "--dir", tmp, "--recursive", "--include", "sources,neighbors,backlinks", "--limit", "5", "--max-chars", "800");
assert.equal(context.$schema, "org2:agent-context:v1");
assert.equal(context.action, "context");
assert.equal(context.results[0].id, "alpha-1");
assert.equal(context.results[0].file, "alpha.org2");
assert.deepEqual(context.results[0].sourceRange, { startLine: 3, endLine: 21 });
assert.equal(context.results[0].properties.CUSTOM, "value");
assert.equal(context.results[0].claimState.reviewStatus, "reviewed");
assert.equal(context.results[0].claimState.freshness, "fresh");
assert.equal(context.results[0].collaboration.owner, "Casey");
assert.equal(context.results[0].collaboration.assignee, "openclaw");
assert.equal(context.results[0].collaboration.nextAction, "Prepare implementation handoff");
assert.equal(context.results[0].collaboration.waitingOn, "API review");
assert.equal(context.results[0].collaboration.policy.requiresHumanApproval, true);
assert.equal(context.results[0].collaboration.policy.allowAgentEdit, true);
assert.equal(context.results[0].collaboration.policy.allowExternalSend, false);
assert.ok(context.results[0].citation.endsWith("alpha.org2:3-21"));
assert.ok(context.results[0].neighbors.some((n) => n.id === "beta-1" && n.direction === "out"));
assert.ok(context.context.text.includes("Source: alpha.org2:3-21"));
assert.ok(context.context.text.includes("Review: reviewed; freshness: fresh"));
assert.ok(context.context.citations[0].citation.endsWith("alpha.org2:3-21"));

const fetched = runJson("agent", "fetch", "--id", "beta-1", "--dir", tmp, "--include", "backlinks,neighbors");
assert.equal(fetched.results.length, 1);
assert.equal(fetched.results[0].title, "Beta note");
assert.ok(fetched.results[0].backlinks.some((link) => link.sourceId === "alpha-1"));
assert.ok(fetched.results[0].neighbors.some((n) => n.id === "alpha-1" && n.direction === "in"));

const search = runJson("agent", "search", "--query", "work value", "--dir", tmp, "--limit", "1");
assert.equal(search.results.length, 1);
assert.equal(search.results[0].id, "alpha-1");
assert.ok(search.results[0].matchedTerms.includes("work"));

const c = path.join(tmp, "bundle.org2");
fs.writeFileSync(c, `#+title: Bundle File

* TODO Scarf pricing decision :scarf:
:PROPERTIES:
:ID: scarf-price-1
:PROJECT: scarf
:SOURCE_TYPE: meeting
:REVIEW_STATUS: reviewed
:UPDATED: 2026-05-01
:END:
Decision: ClickHouse-backed Scarf pricing bundle should cite reviewed customer-call context.

* Noisy Scarf draft :scarf:
:PROPERTIES:
:ID: scarf-noise-1
:PROJECT: scarf
:SOURCE_TYPE: draft
:REVIEW_STATUS: draft
:UPDATED: 2026-05-01
:END:
ClickHouse pricing maybe maybe maybe.

* Old reviewed note :scarf:
:PROPERTIES:
:ID: scarf-old-1
:PROJECT: scarf
:SOURCE_TYPE: meeting
:REVIEW_STATUS: reviewed
:UPDATED: 2020-01-01
:END:
ClickHouse Scarf pricing old context.
`, "utf8");

const bundle = runJson(
  "agent", "bundle",
  "--query", "ClickHouse Scarf pricing",
  "--scope", "project:scarf",
  "--since", "365d",
  "--source-type", "meeting",
  "--review-status", "reviewed",
  "--dir", tmp,
  "--recursive",
  "--include", "sources,neighbors,backlinks",
  "--max-tokens", "12000",
  "--format", "json",
);
assert.equal(bundle.$schema, "org2:agent-context:v1");
assert.equal(bundle.action, "bundle");
assert.deepEqual(bundle.filters, { scope: "project:scarf", since: "365d", sourceType: "meeting", reviewStatus: "reviewed" });
assert.equal(bundle.results.length, 1);
assert.equal(bundle.results[0].id, "scarf-price-1");
assert.equal(bundle.results[0].todo, "TODO");
assert.ok(bundle.results[0].sources[0].citation.endsWith("bundle.org2:3-12"));
assert.ok(bundle.context.citations[0].citation.endsWith("bundle.org2:3-12"));
assert.ok(!bundle.context.text.includes("Noisy Scarf draft"));
assert.ok(!bundle.context.text.includes("Old reviewed note"));

const staleDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agent-freshness-test-"));
fs.writeFileSync(path.join(staleDir, "old.org2"), `#+title: Old

* Project memory
:PROPERTIES:
:ID: old-memory
:ORG2_REVIEW_STATUS: generated
:ORG2_CLAIM_STATE: source-backed
:ORG2_VALID_AS_OF: 2020-01-01
:ORG2_STALE_AFTER: 2020-02-01
:END:
pricing policy copper
`, "utf8");
fs.writeFileSync(path.join(staleDir, "fresh.org2"), `#+title: Fresh

* Project memory
:PROPERTIES:
:ID: fresh-memory
:ORG2_REVIEW_STATUS: reviewed
:ORG2_CLAIM_STATE: human-reviewed
:ORG2_VALID_AS_OF: 2026-05-20
:ORG2_STALE_AFTER: 2099-01-01
:END:
pricing policy copper
`, "utf8");
fs.writeFileSync(path.join(staleDir, "malformed.org2"), `#+title: Malformed Freshness

* Invalid stale date
:PROPERTIES:
:ID: invalid-stale-date
:ORG2_REVIEW_STATUS: reviewed
:ORG2_VALID_AS_OF: 2026-05-20
:ORG2_STALE_AFTER: 2020-02-30
:END:
pricing policy copper

* Invalid expiry date
:PROPERTIES:
:ID: invalid-expiry-date
:ORG2_REVIEW_STATUS: reviewed
:ORG2_VALID_AS_OF: 2026-05-20
:ORG2_EXPIRES_AT: 2020-02-30T00:00:00Z
:END:
pricing policy copper
`, "utf8");
const freshnessSearch = runJson("agent", "search", "--query", "pricing policy copper", "--dir", staleDir, "--limit", "4");
const freshMemoryIndex = freshnessSearch.results.findIndex((result) => result.id === "fresh-memory");
const oldMemoryIndex = freshnessSearch.results.findIndex((result) => result.id === "old-memory");
assert.ok(freshMemoryIndex >= 0);
assert.ok(oldMemoryIndex >= 0);
assert.ok(freshMemoryIndex < oldMemoryIndex);
assert.equal(freshnessSearch.results[freshMemoryIndex].claimState.freshness, "fresh");
assert.equal(freshnessSearch.results.find((result) => result.id === "old-memory").claimState.freshness, "stale");
const invalidStaleDate = runJson("agent", "fetch", "--id", "invalid-stale-date", "--dir", staleDir);
assert.equal(invalidStaleDate.results[0].claimState.staleAfter, "2020-02-30");
assert.equal(invalidStaleDate.results[0].claimState.freshness, "fresh");
const invalidExpiryDate = runJson("agent", "fetch", "--id", "invalid-expiry-date", "--dir", staleDir);
assert.equal(invalidExpiryDate.results[0].claimState.expiresAt, "2020-02-30T00:00:00Z");
assert.equal(invalidExpiryDate.results[0].claimState.freshness, "fresh");

const rankingDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agent-ranking-test-"));
fs.writeFileSync(path.join(rankingDir, "ranking.org2"), `#+title: Ranking

* Recent trivial note
:PROPERTIES:
:ID: recent-trivial
:UPDATED: 2026-06-01
:END:
Copper launch retrieval note.

* Old important policy
:PROPERTIES:
:ID: old-important
:UPDATED: 2020-01-01
:ORG2_SALIENCE: 5
:PINNED: true
:END:
Copper launch retrieval note.
`, "utf8");
const salienceFirst = runJson("agent", "search", "--query", "Copper launch retrieval", "--dir", rankingDir, "--limit", "2", "--recency-weight", "0", "--salience-weight", "1");
assert.equal(salienceFirst.ranking.salienceWeight, 1);
assert.equal(salienceFirst.results[0].id, "old-important");
assert.ok(salienceFirst.results[0].selectionReason.some((reason) => reason.includes("explicit salience")));
assert.ok(salienceFirst.results[0].selectionReason.some((reason) => reason.includes("pinned")));

const recencyFirst = runJson("agent", "search", "--query", "Copper launch retrieval", "--dir", rankingDir, "--limit", "2", "--recency-weight", "8", "--salience-weight", "0");
assert.equal(recencyFirst.ranking.recencyWeight, 8);
assert.equal(recencyFirst.results[0].id, "recent-trivial");
assert.ok(recencyFirst.results[0].selectionReason.some((reason) => reason.includes("recency weight 8")));

const strictRankingDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agent-strict-ranking-test-"));
fs.writeFileSync(path.join(strictRankingDir, "strict-ranking.org2"), `#+title: Strict Ranking

* Malformed salience metadata
:PROPERTIES:
:ID: malformed-salience
:ORG2_SALIENCE: 20 high
:END:
Zirconium guardrail token.

* Valid salience metadata
:PROPERTIES:
:ID: valid-salience
:ORG2_SALIENCE: 1
:END:
Zirconium guardrail token.
`, "utf8");
const strictNumericRanking = runJson("agent", "search", "--query", "Zirconium guardrail token", "--dir", strictRankingDir, "--limit", "2", "--recency-weight", "0", "--salience-weight", "1");
assert.equal(strictNumericRanking.results[0].id, "valid-salience");
assert.ok(strictNumericRanking.results[0].selectionReason.some((reason) => reason.includes("explicit salience 1")));
const malformedSalience = strictNumericRanking.results.find((result) => result.id === "malformed-salience");
assert.ok(malformedSalience);
assert.ok(!malformedSalience.selectionReason.some((reason) => reason.includes("explicit salience")));

const explainedContext = execFileSync("node", ["dist/cli.js", "context", "Copper launch retrieval", "--dir", rankingDir, "--limit", "1", "--recency-weight", "0", "--salience-weight", "1"], { encoding: "utf8" });
assert.match(explainedContext, /Selected because:/);
assert.match(explainedContext, /explicit salience/);

const malformedRecencyWeight = spawnSync("node", ["dist/cli.js", "agent", "search", "--query", "Copper launch retrieval", "--dir", rankingDir, "--recency-weight", "2x"], { encoding: "utf8" });
assert.equal(malformedRecencyWeight.status, 1);
assert.equal(malformedRecencyWeight.stderr, "Error: --recency-weight requires a numeric value\n");

const malformedSalienceWeight = spawnSync("node", ["dist/cli.js", "context", "Copper launch retrieval", "--dir", rankingDir, "--salience-weight", "1 high"], { encoding: "utf8" });
assert.equal(malformedSalienceWeight.status, 1);
assert.equal(malformedSalienceWeight.stderr, "Error: --salience-weight requires a numeric value\n");

const threadDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agent-thread-test-"));
fs.writeFileSync(path.join(threadDir, "threads.org2"), `#+title: Agent Threads

* Report: Firebolt package usage
:PROPERTIES:
:ID: report-1
:KIND: report
:END:
Report context for Firebolt package usage.

* Thread: Firebolt report help
:PROPERTIES:
:ID: thread-1
:KIND: agent-thread
:AGENT: openclaw
:SESSION: openclaw:session:abc123
:STATUS: active
:CONTEXT: id:report-1, report:report-1, file:reports/firebolt.csv, ticket:REP-52
:TRANSCRIPT: file:threads/thread-1.transcript.org2
:STORAGE: summary
:END:
Current working summary of the thread.

** Context attachments
- [[id:report-1][Firebolt report]]
- [[file:reports/firebolt.csv][latest CSV artifact]]

** Durable outputs
- [ ] Follow up on validation notes.
`, "utf8");

const thread = runJson("agent", "fetch", "--id", "thread-1", "--dir", threadDir, "--include", "neighbors", "--format", "json");
assert.equal(thread.results.length, 1);
assert.equal(thread.results[0].thread.agent, "openclaw");
assert.equal(thread.results[0].thread.session, "openclaw:session:abc123");
assert.equal(thread.results[0].thread.status, "active");
assert.equal(thread.results[0].thread.transcript, "file:threads/thread-1.transcript.org2");
assert.equal(thread.results[0].thread.storage, "summary");
assert.ok(thread.results[0].thread.contextAttachments.some((attachment) => attachment.type === "id" && attachment.ref === "id:report-1" && attachment.label === "Firebolt report"));
assert.ok(thread.results[0].thread.contextAttachments.some((attachment) => attachment.type === "file" && attachment.ref === "file:reports/firebolt.csv"));
assert.ok(thread.results[0].thread.contextAttachments.some((attachment) => attachment.type === "ticket" && attachment.ref === "ticket:REP-52"));
const reportAttachment = thread.results[0].thread.contextAttachments.find((attachment) => attachment.ref === "id:report-1");
assert.equal(reportAttachment.target.id, "report-1");
assert.equal(reportAttachment.target.title, "Report: Firebolt package usage");
assert.ok(reportAttachment.target.citation.endsWith("threads.org2:3-9"));
const typedReportAttachment = thread.results[0].thread.contextAttachments.find((attachment) => attachment.ref === "report:report-1");
assert.equal(typedReportAttachment.target.id, "report-1");

const reportWithThread = runJson("agent", "fetch", "--id", "report-1", "--dir", threadDir, "--format", "json");
assert.equal(reportWithThread.results.length, 1);
assert.equal(reportWithThread.results[0].relatedThreads.length, 1);
assert.equal(reportWithThread.results[0].relatedThreads[0].id, "thread-1");
assert.equal(reportWithThread.results[0].relatedThreads[0].agent, "openclaw");
assert.equal(reportWithThread.results[0].relatedThreads[0].session, "openclaw:session:abc123");
assert.ok(reportWithThread.results[0].relatedThreads[0].matchingAttachments.some((attachment) => attachment.ref === "id:report-1"));
assert.ok(reportWithThread.results[0].relatedThreads[0].matchingAttachments.some((attachment) => attachment.ref === "report:report-1"));

const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-agent-data-link-test-"));
fs.writeFileSync(path.join(dataDir, "reports.org2"), `#+title: Data Links

* Report: package fetches
:PROPERTIES:
:ID: report-fetches
:KIND: report
:END:
Business question for package fetch activity.

** Data link: package fetches by company
:PROPERTIES:
:ID: query-fetches-by-company
:KIND: warehouse-query
:SYSTEM: clickhouse
:DATABASE: scarf_analytics
:SCHEMA: package_usage
:TABLE: package_fetches_by_company
:COLUMNS: company_id:string, package:string, fetches:int
:PRIMARY_KEY: company_id, package
:PARTITION_BY: package
:SORT_BY: -fetches, company_id:asc
:DIMENSIONS: company_id, package
:MEASURES: fetches
:GRAIN: daily
:FILTERS: package = 'firebolt/foo'; fetches > 0
:GROUP_BY: company_id, package
:TIME_COLUMN: fetched_at
:TIMEZONE: America/Los_Angeles
:SOURCE: s3://analytics/package_fetches_by_company/
:QUERY_ID: scarf.package_fetches_by_company.v1
:QUERY: SELECT company_id, package, fetches FROM package_fetches_by_company WHERE package = {package}
:QUERY_HASH: sha256:queryabc123
:PARAMS: {"packages":["firebolt/foo"],"from":"2026-01-01"}
:LAST_RUN: 2026-06-12T12:30:00-07:00
:ARTIFACT: customer-reports/firebolt/package_fetches_by_company.csv
:MATERIALIZED: true
:ROW_COUNT: 1,234
:RESULT_LIMIT: 500
:RESULT_OFFSET: 100
:SAMPLE_SIZE: 250
:SAMPLE_RATE: 10%
:SAMPLING_METHOD: stratified
:COVERAGE: customers-with-package-fetches
:WINDOW_START: 2026-01-01
:WINDOW_END: 2026-06-12
:FRESHNESS_SLA: 2h
:WATERMARK: 2026-06-12T12:00:00-07:00
:DATA_LATENCY: 30m
:AVAILABILITY: available
:BACKFILL_STATUS: complete
:FRESHNESS: live
:REFRESH_REF: query-data:fetches_by_company
:REFRESH_COMMAND: org2 query-data --file reports.org2 --results fetches_by_company --out views/fetches.org2
:REFRESH_STATUS: ready
:REFRESH_AFTER: 24h
:NEXT_REFRESH: 2026-06-13T12:30:00-07:00
:VALIDATION_STATUS: sampled
:VALIDATION_AT: 2026-06-12T13:00:00-07:00
:VALIDATION_BY: Casey
:VALIDATION_NOTE: Compared row counts against the dashboard export.
:CONFIDENCE: high
:VALIDATION_REFS: file:validation/package-fetches-check.md
:DATA_OWNER: Product Analytics
:DATA_STEWARD: Casey
:SENSITIVITY: customer-private
:VISIBILITY: internal
:ACCESS_POLICY: approval-required
:RETENTION: 90d
:LINEAGE_REFS: id:dataset-package-fetches, query:raw.package_fetches.v1
:DATA_CONTRACT: contract:package-fetches-v1
:SCHEMA_VERSION: v3
:QUALITY_STATUS: passed
:QUALITY_SCORE: 0.98
:QUALITY_CHECKS: row-count-reconciled, no-null-company-id
:QUALITY_NOTE: Latest warehouse checks passed before materialization.
:ORG2_PROVENANCE: query:scarf.package_fetches_by_company.v1, artifact:customer-reports/firebolt/package_fetches_by_company.csv
:ORG2_SOURCE_HASHES: query:scarf.package_fetches_by_company.v1=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
:END:
Materialized query metadata for [[id:report-fetches][package fetch report]].

** Dataset: local package CSV
:PROPERTIES:
:ID: dataset-package-fetches
:KIND: dataset
:ENGINE: duckdb
:PATH: data/package-fetches.csv
:TABLE: package_fetches
:COLUMNS: state:string, fetches:int
:CREDENTIAL: env:SCARF_DATA_TOKEN
:CONFIG: profile:local-analytics
:PARAMS: packages=firebolt/foo
:RESULTS: table:package_fetches
:END:
Local ad hoc dataset definition.
`, "utf8");
fs.writeFileSync(path.join(dataDir, "catalog.org2"), `#+title: Data Catalog

* Catalog query: package fetch error rate
:PROPERTIES:
:ID: query-fetch-error-rate
:KIND: warehouse-query
:SYSTEM: firebolt
:DATABASE: scarf_warehouse
:SCHEMA: product
:VIEW: package_fetch_error_rate_daily
:QUERY_ID: scarf.package_fetch_error_rate.v1
:REPORT_ID: report-fetches
:ARTIFACT: customer-reports/firebolt/package_fetch_error_rate.csv
:ROW_COUNT: 7
:FRESHNESS: hourly
:END:
External data catalog entry for [[id:report-fetches][package fetch report]].

* Event stream: package customer changes
:PROPERTIES:
:ID: stream-package-customer-changes
:KIND: event-stream
:SYSTEM: clickhouse
:EVENT_STREAM: scarf.package_customer_events
:EVENT_TYPE: package_fetch_spike
:ENTITY: package:firebolt/foo
:ACTOR: ingest:scarf
:OCCURRED_AT: 2026-06-12T11:45:00-07:00
:CAPTURED_AT: 2026-06-12T11:46:10-07:00
:SOURCE_CURSOR: ch:customer_events:92017
:STREAM_POSITION: 92017
:PARTITION_KEY: package:firebolt/foo
:CORRELATION_ID: sync-run-20260612
:CAUSATION_ID: ingest-batch-17
:CHANGE_ID: evt_123
:CHANGE_HASH: sha256:abc123
:ORG2_PROVENANCE: run:ingest-package-events, url:https://warehouse.example/events/evt_123
:ORG2_SOURCE_HASHES: artifact:events/package-customer-changes.json=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
:TARGET_ID: report-fetches
:END:
Timeline-backed evidence for [[id:report-fetches][package fetch report]].
`, "utf8");

const dataLink = runJson("agent", "fetch", "--id", "query-fetches-by-company", "--dir", dataDir, "--format", "json");
assert.equal(dataLink.results.length, 1);
assert.equal(dataLink.results[0].dataLink.kind, "warehouse-query");
assert.equal(dataLink.results[0].dataLink.system, "clickhouse");
assert.equal(dataLink.results[0].dataLink.database, "scarf_analytics");
assert.equal(dataLink.results[0].dataLink.schema, "package_usage");
assert.equal(dataLink.results[0].dataLink.table, "package_fetches_by_company");
assert.deepEqual(dataLink.results[0].dataLink.columns, [
  { name: "company_id", type: "string" },
  { name: "package", type: "string" },
  { name: "fetches", type: "int" },
]);
assert.deepEqual(dataLink.results[0].dataLink.primaryKey, ["company_id", "package"]);
assert.deepEqual(dataLink.results[0].dataLink.partitionBy, ["package"]);
assert.deepEqual(dataLink.results[0].dataLink.sortBy, [
  { field: "fetches", direction: "desc" },
  { field: "company_id", direction: "asc" },
]);
assert.deepEqual(dataLink.results[0].dataLink.dimensions, ["company_id", "package"]);
assert.deepEqual(dataLink.results[0].dataLink.measures, ["fetches"]);
assert.equal(dataLink.results[0].dataLink.grain, "daily");
assert.deepEqual(dataLink.results[0].dataLink.filters, ["package = 'firebolt/foo'", "fetches > 0"]);
assert.deepEqual(dataLink.results[0].dataLink.groupBy, ["company_id", "package"]);
assert.equal(dataLink.results[0].dataLink.timeColumn, "fetched_at");
assert.equal(dataLink.results[0].dataLink.timezone, "America/Los_Angeles");
assert.equal(dataLink.results[0].dataLink.source, "s3://analytics/package_fetches_by_company/");
assert.equal(dataLink.results[0].dataLink.queryId, "scarf.package_fetches_by_company.v1");
assert.equal(dataLink.results[0].dataLink.query, "SELECT company_id, package, fetches FROM package_fetches_by_company WHERE package = {package}");
assert.equal(dataLink.results[0].dataLink.queryHash, "sha256:queryabc123");
assert.deepEqual(dataLink.results[0].dataLink.params, { packages: ["firebolt/foo"], from: "2026-01-01" });
assert.equal(dataLink.results[0].dataLink.lastRun, "2026-06-12T12:30:00-07:00");
assert.equal(dataLink.results[0].dataLink.artifact, "customer-reports/firebolt/package_fetches_by_company.csv");
assert.equal(dataLink.results[0].dataLink.materialized, "true");
assert.equal(dataLink.results[0].dataLink.rowCount, 1234);
assert.equal(dataLink.results[0].dataLink.resultLimit, 500);
assert.equal(dataLink.results[0].dataLink.resultOffset, 100);
assert.equal(dataLink.results[0].dataLink.sampleSize, 250);
assert.equal(dataLink.results[0].dataLink.sampleRate, "10%");
assert.equal(dataLink.results[0].dataLink.samplingMethod, "stratified");
assert.equal(dataLink.results[0].dataLink.coverage, "customers-with-package-fetches");
assert.equal(dataLink.results[0].dataLink.windowStart, "2026-01-01");
assert.equal(dataLink.results[0].dataLink.windowEnd, "2026-06-12");
assert.equal(dataLink.results[0].dataLink.freshnessSla, "2h");
assert.equal(dataLink.results[0].dataLink.watermark, "2026-06-12T12:00:00-07:00");
assert.equal(dataLink.results[0].dataLink.dataLatency, "30m");
assert.equal(dataLink.results[0].dataLink.availability, "available");
assert.equal(dataLink.results[0].dataLink.backfillStatus, "complete");
assert.equal(dataLink.results[0].dataLink.freshness, "live");
assert.equal(dataLink.results[0].dataLink.refreshRef, "query-data:fetches_by_company");
assert.equal(dataLink.results[0].dataLink.refreshCommand, "org2 query-data --file reports.org2 --results fetches_by_company --out views/fetches.org2");
assert.equal(dataLink.results[0].dataLink.refreshStatus, "ready");
assert.equal(dataLink.results[0].dataLink.refreshAfter, "24h");
assert.equal(dataLink.results[0].dataLink.nextRefresh, "2026-06-13T12:30:00-07:00");
assert.equal(dataLink.results[0].dataLink.validationStatus, "sampled");
assert.equal(dataLink.results[0].dataLink.validationAt, "2026-06-12T13:00:00-07:00");
assert.equal(dataLink.results[0].dataLink.validationBy, "Casey");
assert.equal(dataLink.results[0].dataLink.validationNote, "Compared row counts against the dashboard export.");
assert.equal(dataLink.results[0].dataLink.confidence, "high");
assert.ok(dataLink.results[0].dataLink.validationRefs.some((ref) => ref.ref === "file:validation/package-fetches-check.md"));
assert.equal(dataLink.results[0].dataLink.dataOwner, "Product Analytics");
assert.equal(dataLink.results[0].dataLink.dataSteward, "Casey");
assert.equal(dataLink.results[0].dataLink.sensitivity, "customer-private");
assert.equal(dataLink.results[0].dataLink.visibility, "internal");
assert.equal(dataLink.results[0].dataLink.accessPolicy, "approval-required");
assert.equal(dataLink.results[0].dataLink.retention, "90d");
assert.ok(dataLink.results[0].dataLink.lineageRefs.some((ref) => ref.ref === "id:dataset-package-fetches"));
assert.ok(dataLink.results[0].dataLink.lineageRefs.some((ref) => ref.ref === "query:raw.package_fetches.v1"));
assert.equal(dataLink.results[0].dataLink.dataContract, "contract:package-fetches-v1");
assert.equal(dataLink.results[0].dataLink.schemaVersion, "v3");
assert.equal(dataLink.results[0].dataLink.qualityStatus, "passed");
assert.equal(dataLink.results[0].dataLink.qualityScore, 0.98);
assert.deepEqual(dataLink.results[0].dataLink.qualityChecks, ["row-count-reconciled", "no-null-company-id"]);
assert.equal(dataLink.results[0].dataLink.qualityNote, "Latest warehouse checks passed before materialization.");
assert.ok(dataLink.results[0].dataLink.provenance.some((ref) => ref.ref === "query:scarf.package_fetches_by_company.v1"));
assert.equal(dataLink.results[0].dataLink.sourceHashes[0].kind, "query");
assert.equal(dataLink.results[0].dataLink.sourceHashes[0].value, "scarf.package_fetches_by_company.v1");
assert.equal(dataLink.results[0].dataLink.sourceHashes[0].sha256, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

const dataset = runJson("agent", "fetch", "--id", "dataset-package-fetches", "--dir", dataDir, "--format", "json");
assert.equal(dataset.results[0].dataLink.kind, "dataset");
assert.equal(dataset.results[0].dataLink.engine, "duckdb");
assert.equal(dataset.results[0].dataLink.path, "data/package-fetches.csv");
assert.equal(dataset.results[0].dataLink.table, "package_fetches");
assert.deepEqual(dataset.results[0].dataLink.columns, [
  { name: "state", type: "string" },
  { name: "fetches", type: "int" },
]);
assert.equal(dataset.results[0].dataLink.credentialRef, "env:SCARF_DATA_TOKEN");
assert.equal(dataset.results[0].dataLink.configRef, "profile:local-analytics");
assert.equal(dataset.results[0].dataLink.paramsRaw, "packages=firebolt/foo");
assert.equal(dataset.results[0].dataLink.result, "table:package_fetches");

const eventStream = runJson("agent", "fetch", "--id", "stream-package-customer-changes", "--dir", dataDir, "--format", "json");
assert.equal(eventStream.results[0].dataLink.kind, "event-stream");
assert.equal(eventStream.results[0].dataLink.eventStream, "scarf.package_customer_events");
assert.equal(eventStream.results[0].dataLink.eventType, "package_fetch_spike");
assert.equal(eventStream.results[0].dataLink.entity, "package:firebolt/foo");
assert.equal(eventStream.results[0].dataLink.actor, "ingest:scarf");
assert.equal(eventStream.results[0].dataLink.occurredAt, "2026-06-12T11:45:00-07:00");
assert.equal(eventStream.results[0].dataLink.capturedAt, "2026-06-12T11:46:10-07:00");
assert.equal(eventStream.results[0].dataLink.sourceCursor, "ch:customer_events:92017");
assert.equal(eventStream.results[0].dataLink.streamPosition, "92017");
assert.equal(eventStream.results[0].dataLink.partitionKey, "package:firebolt/foo");
assert.equal(eventStream.results[0].dataLink.correlationId, "sync-run-20260612");
assert.equal(eventStream.results[0].dataLink.causationId, "ingest-batch-17");
assert.equal(eventStream.results[0].dataLink.changeId, "evt_123");
assert.equal(eventStream.results[0].dataLink.changeHash, "sha256:abc123");
assert.ok(eventStream.results[0].dataLink.provenance.some((ref) => ref.ref === "run:ingest-package-events"));
assert.equal(eventStream.results[0].dataLink.sourceHashes[0].kind, "artifact");
assert.equal(eventStream.results[0].dataLink.sourceHashes[0].value, "events/package-customer-changes.json");

const reportWithDataLinks = runJson("agent", "fetch", "--id", "report-fetches", "--dir", dataDir, "--format", "json");
assert.equal(reportWithDataLinks.results.length, 1);
assert.equal(reportWithDataLinks.results[0].relatedDataLinks.length, 4);
const descendantQuery = reportWithDataLinks.results[0].relatedDataLinks.find((item) => item.id === "query-fetches-by-company");
assert.equal(descendantQuery.kind, "warehouse-query");
assert.equal(descendantQuery.dataLink.source, "s3://analytics/package_fetches_by_company/");
assert.equal(descendantQuery.dataLink.query, "SELECT company_id, package, fetches FROM package_fetches_by_company WHERE package = {package}");
assert.equal(descendantQuery.dataLink.queryHash, "sha256:queryabc123");
assert.equal(descendantQuery.dataLink.artifact, "customer-reports/firebolt/package_fetches_by_company.csv");
assert.equal(descendantQuery.dataLink.materialized, "true");
assert.deepEqual(descendantQuery.dataLink.partitionBy, ["package"]);
assert.deepEqual(descendantQuery.dataLink.sortBy, [
  { field: "fetches", direction: "desc" },
  { field: "company_id", direction: "asc" },
]);
assert.deepEqual(descendantQuery.dataLink.dimensions, ["company_id", "package"]);
assert.deepEqual(descendantQuery.dataLink.measures, ["fetches"]);
assert.equal(descendantQuery.dataLink.grain, "daily");
assert.deepEqual(descendantQuery.dataLink.filters, ["package = 'firebolt/foo'", "fetches > 0"]);
assert.deepEqual(descendantQuery.dataLink.groupBy, ["company_id", "package"]);
assert.equal(descendantQuery.dataLink.timeColumn, "fetched_at");
assert.equal(descendantQuery.dataLink.timezone, "America/Los_Angeles");
assert.equal(descendantQuery.dataLink.freshnessSla, "2h");
assert.equal(descendantQuery.dataLink.watermark, "2026-06-12T12:00:00-07:00");
assert.equal(descendantQuery.dataLink.dataLatency, "30m");
assert.equal(descendantQuery.dataLink.availability, "available");
assert.equal(descendantQuery.dataLink.backfillStatus, "complete");
assert.equal(descendantQuery.dataLink.resultLimit, 500);
assert.equal(descendantQuery.dataLink.samplingMethod, "stratified");
assert.equal(descendantQuery.dataLink.refreshStatus, "ready");
assert.equal(descendantQuery.dataLink.validationStatus, "sampled");
assert.equal(descendantQuery.dataLink.sensitivity, "customer-private");
assert.equal(descendantQuery.dataLink.accessPolicy, "approval-required");
assert.equal(descendantQuery.dataLink.qualityStatus, "passed");
assert.ok(descendantQuery.dataLink.lineageRefs.some((ref) => ref.ref === "id:dataset-package-fetches"));
const descendantDataset = reportWithDataLinks.results[0].relatedDataLinks.find((item) => item.id === "dataset-package-fetches");
assert.equal(descendantDataset.kind, "dataset");
assert.equal(descendantDataset.dataLink.path, "data/package-fetches.csv");
const externalQuery = reportWithDataLinks.results[0].relatedDataLinks.find((item) => item.id === "query-fetch-error-rate");
assert.equal(externalQuery.kind, "warehouse-query");
assert.equal(externalQuery.dataLink.system, "firebolt");
assert.equal(externalQuery.dataLink.database, "scarf_warehouse");
assert.equal(externalQuery.dataLink.schema, "product");
assert.equal(externalQuery.dataLink.view, "package_fetch_error_rate_daily");
assert.equal(externalQuery.dataLink.artifact, "customer-reports/firebolt/package_fetch_error_rate.csv");
assert.ok(externalQuery.matchingAttachments.some((attachment) => attachment.ref === "id:report-fetches" && attachment.target.id === "report-fetches"));
assert.ok(externalQuery.matchingAttachments.some((attachment) => attachment.ref === "report:report-fetches" && attachment.target.id === "report-fetches"));
const externalEventStream = reportWithDataLinks.results[0].relatedDataLinks.find((item) => item.id === "stream-package-customer-changes");
assert.equal(externalEventStream.kind, "event-stream");
assert.equal(externalEventStream.dataLink.eventStream, "scarf.package_customer_events");
assert.equal(externalEventStream.dataLink.eventType, "package_fetch_spike");
assert.equal(externalEventStream.dataLink.occurredAt, "2026-06-12T11:45:00-07:00");
assert.equal(externalEventStream.dataLink.streamPosition, "92017");
assert.equal(externalEventStream.dataLink.partitionKey, "package:firebolt/foo");
assert.equal(externalEventStream.dataLink.correlationId, "sync-run-20260612");
assert.equal(externalEventStream.dataLink.causationId, "ingest-batch-17");
assert.ok(externalEventStream.matchingAttachments.some((attachment) => attachment.ref === "id:report-fetches" && attachment.target.id === "report-fetches"));
