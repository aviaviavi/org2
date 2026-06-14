#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-context-pack-test-"));
fs.writeFileSync(path.join(tmp, "support.org2"), `#+title: Scarf Support

* TODO Scarf support triage :scarf:support:
:PROPERTIES:
:ID: scarf-support-1
:PROJECT: scarf
:PERSON: Casey
:UPDATED: 2026-05-15
:ORG2_REVIEW_STATUS: reviewed
:ORG2_VALID_AS_OF: 2026-05-15
:ORG2_STALE_AFTER: 2099-01-01
:OWNER: Casey
:ASSIGNEE: openclaw
:AGENT: codex
:NEXT_ACTION: Draft the support response for review
:WAITING_ON: Casey approval
:LIFECYCLE: review
:REQUIRES_HUMAN_APPROVAL: true
:ALLOW_AGENT_EDIT: true
:ALLOW_EXTERNAL_SEND: false
:SESSION: openclaw:session:triage-1
:RUN_ID: run-42
:RUN_STARTED_AT: 2026-05-15T10:00:00-07:00
:RUN_FINISHED_AT: 2026-05-15T10:20:00-07:00
:RUN_LOG: file:runs/scarf-support-1.log
:SOURCE_ARTIFACTS: file:tickets/scarf-support.json, artifact:reports/support-ticket-volume.csv
:HANDOFF_SUMMARY: Response draft is ready but must be approved before sending.
:HANDOFF_LINKS: id:decision-1
:END:
Support needs a deterministic context pack with citations for Scarf triage.
See [[id:decision-1][decision note]].

** Data link: ticket volume
:PROPERTIES:
:ID: support-ticket-volume
:KIND: warehouse-query
:SYSTEM: clickhouse
:DATABASE: support_warehouse
:SCHEMA: support
:TABLE: ticket_volume_daily
:COLUMNS: date:date, ticket_count:int
:PRIMARY_KEY: date
:PARTITION_BY: date
:SORT_BY: date:desc
:DIMENSIONS: date
:MEASURES: ticket_count
:GRAIN: daily
:FILTERS: status = 'open'; ticket_count > 0
:GROUP_BY: date
:TIME_COLUMN: date
:TIMEZONE: America/Los_Angeles
:SOURCE: s3://support/ticket-volume/
:QUERY_ID: support.ticket_volume.v1
:SQL: SELECT date, ticket_count FROM support.ticket_volume_daily WHERE status IN ('open', 'pending')
:QUERY_HASH: sha256:supportquery123
:PARAMS: {"team":"support","statuses":["open","pending"]}
:ARTIFACT: reports/support-ticket-volume.csv
:MATERIALIZED: table
:ROW_COUNT: 42
:RESULT_LIMIT: 100
:SAMPLE_SIZE: 42
:SAMPLE_RATE: 25%
:SAMPLING_METHOD: latest-day
:COVERAGE: open-support-tickets
:WINDOW_START: 2026-05-01
:WINDOW_END: 2026-05-15
:FRESHNESS_SLA: 4h
:WATERMARK: 2026-05-15T09:45:00-07:00
:DATA_LATENCY: 15m
:AVAILABILITY: degraded
:BACKFILL_STATUS: pending
:FRESHNESS: daily
:REFRESH_REF: query-data:support-ticket-volume
:REFRESH_COMMAND: org2 query-data --file support.org2 --results support_ticket_volume --out views/support-ticket-volume.org2
:REFRESH_STATUS: due
:REFRESH_AFTER: 24h
:NEXT_REFRESH: 2026-05-16T10:00:00-07:00
:VALIDATION_STATUS: reconciled
:VALIDATION_AT: 2026-05-15T10:30:00-07:00
:VALIDATION_BY: Casey
:VALIDATION_NOTE: Compared against Zendesk dashboard totals.
:CONFIDENCE: medium
:VALIDATION_REFS: id:decision-1
:DATA_OWNER: Support Ops
:DATA_STEWARD: Casey
:SENSITIVITY: customer-private
:VISIBILITY: internal
:ACCESS_POLICY: support-approved
:RETENTION: 30d
:LINEAGE_REFS: id:decision-1, query:support.raw_ticket_volume.v1
:DATA_CONTRACT: contract:support-ticket-volume-v2
:SCHEMA_VERSION: v2
:QUALITY_STATUS: passed
:QUALITY_SCORE: 0.97
:QUALITY_CHECKS: row-count-reconciled, ticket-id-not-null
:QUALITY_NOTE: Zendesk export and warehouse aggregate matched.
:ORG2_PROVENANCE: query:support.ticket_volume.v1, artifact:reports/support-ticket-volume.csv
:ORG2_SOURCE_HASHES: query:support.ticket_volume.v1=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
:ORG2_REVIEW_STATUS: reviewed
:ORG2_VALID_AS_OF: 2026-05-15
:ORG2_STALE_AFTER: 2099-01-01
:END:
Daily materialized support ticket counts.

* DONE Old Scarf support note :scarf:
:PROPERTIES:
:ID: old-scarf
:PROJECT: scarf
:UPDATED: 2020-01-01
:END:
Old support context.

* Thread: Scarf triage help
:PROPERTIES:
:ID: thread-scarf-triage
:KIND: agent-thread
:AGENT: openclaw
:SESSION: openclaw:session:triage-1
:STATUS: active
:CONTEXT: id:scarf-support-1
:STORAGE: summary
:END:
Working notes for support triage.

* Data catalog: support satisfaction score
:PROPERTIES:
:ID: support-satisfaction-score
:KIND: dataset
:SOURCE: gs://support/satisfaction/
:PATH: reports/support-satisfaction.csv
:TABLE: support_satisfaction
:COLUMNS: account_id:string, satisfaction_score:double
:CREDENTIAL_REF: secret:support-analytics
:CONFIG_REF: profile:support-local
:PARAMS: score>=0.7
:ROW_COUNT: 5
:FRESHNESS: weekly
:CONTEXT: id:scarf-support-1
:ORG2_REVIEW_STATUS: review-required
:ORG2_VALID_AS_OF: 2020-01-01
:ORG2_STALE_AFTER: 2020-02-01
:END:
External catalog entry for [[id:scarf-support-1][Scarf support triage]].

* Event stream: support state changes
:PROPERTIES:
:ID: support-state-changes
:KIND: timeline-link
:SYSTEM: linear
:TIMELINE: support.ticket.lifecycle
:EVENT_TYPE: status_changed
:ENTITY: ticket:SUP-42
:ACTOR: Casey
:OCCURRED_AT: 2026-05-15T09:30:00-07:00
:CAPTURED_AT: 2026-05-15T09:31:00-07:00
:SOURCE_CURSOR: linear:SUP-42:9
:CHANGE_ID: change-42
:ORG2_PROVENANCE: run:linear-support-sync, url:https://linear.example/SUP-42
:ORG2_SOURCE_HASHES: artifact:reports/support-state-changes.json=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
:CONTEXT: id:scarf-support-1
:END:
Timeline projection for [[id:scarf-support-1][Scarf support triage]].
`, "utf8");
fs.writeFileSync(path.join(tmp, "decisions.org2"), `#+title: Decisions

* Decision note
:PROPERTIES:
:ID: decision-1
:PROJECT: scarf
:UPDATED: 2026-05-16
:END:
Context packs should include open questions, next actions, and source line provenance.
`, "utf8");

const run = (...args) => execFileSync("node", ["dist/cli.js", ...args], { encoding: "utf8" });
const md = run("context", "scarf support triage", "--dir", tmp, "--recursive", "--budget", "8k", "--include", "sources,neighbors,backlinks");
assert.match(md, /^# Org2 Context Pack/m);
assert.match(md, /## Objective \/ query/);
assert.match(md, /support\.org2:3-/);
assert.match(md, /## Recent timeline entries/);
assert.match(md, /## Active TODOs \/ scheduled items/);
assert.match(md, /TODO Scarf support triage/);
assert.match(md, /## Collaboration state/);
assert.match(md, /owner: Casey/);
assert.match(md, /assignee: openclaw/);
assert.match(md, /next: Draft the support response for review/);
assert.match(md, /Policy: human approval: required; agent edit: allowed; external send: not allowed/);
assert.match(md, /## Related entities and backlinks/);
assert.match(md, /Entity: scarf/);
assert.match(md, /## Related agent threads/);
assert.match(md, /## Related data links/);
assert.match(md, /## Open questions \/ known uncertainty/);
assert.match(md, /## Suggested next actions/);

const selected = run("context", "--id", "scarf-support-1", "--dir", tmp, "--format", "markdown");
assert.match(selected, /# Org2 Context Pack/);
assert.match(selected, /- scarf-support-1/);
assert.match(selected, /## Related agent threads/);
assert.match(selected, /Thread: Scarf triage help/);
assert.match(selected, /session: openclaw:session:triage-1/);
assert.match(selected, /Matching attachments: id:scarf-support-1/);
assert.match(selected, /## Related data links/);
assert.match(selected, /Data link: ticket volume/);
assert.match(selected, /review: reviewed/);
assert.match(selected, /claim freshness: fresh/);
assert.match(selected, /database: support_warehouse/);
assert.match(selected, /schema: support/);
assert.match(selected, /table: ticket_volume_daily/);
assert.match(selected, /columns: date:date, ticket_count:int/);
assert.match(selected, /primary key: date/);
assert.match(selected, /partition by: date/);
assert.match(selected, /sort by: date:desc/);
assert.match(selected, /dimensions: date/);
assert.match(selected, /measures: ticket_count/);
assert.match(selected, /grain: daily/);
assert.match(selected, /filters: status = 'open'; ticket_count > 0/);
assert.match(selected, /group by: date/);
assert.match(selected, /time column: date/);
assert.match(selected, /timezone: America\/Los_Angeles/);
assert.match(selected, /source: s3:\/\/support\/ticket-volume\//);
assert.match(selected, /query: support\.ticket_volume\.v1/);
assert.match(selected, /query text: SELECT date, ticket_count FROM support\.ticket_volume_daily WHERE status IN \('open', 'pending'\)/);
assert.match(selected, /query hash: sha256:supportquery123/);
assert.match(selected, /params: \{"team":"support","statuses":\["open","pending"\]\}/);
assert.match(selected, /artifact: reports\/support-ticket-volume\.csv/);
assert.match(selected, /materialized: table/);
assert.match(selected, /refresh ref: query-data:support-ticket-volume/);
assert.match(selected, /refresh command: org2 query-data --file support\.org2 --results support_ticket_volume --out views\/support-ticket-volume\.org2/);
assert.match(selected, /refresh status: due/);
assert.match(selected, /refresh after: 24h/);
assert.match(selected, /next refresh: 2026-05-16T10:00:00-07:00/);
assert.match(selected, /validation: reconciled/);
assert.match(selected, /validated at: 2026-05-15T10:30:00-07:00/);
assert.match(selected, /validated by: Casey/);
assert.match(selected, /confidence: medium/);
assert.match(selected, /validation note: Compared against Zendesk dashboard totals\./);
assert.match(selected, /validation refs: id:decision-1/);
assert.match(selected, /data owner: Support Ops/);
assert.match(selected, /data steward: Casey/);
assert.match(selected, /sensitivity: customer-private/);
assert.match(selected, /visibility: internal/);
assert.match(selected, /access: support-approved/);
assert.match(selected, /retention: 30d/);
assert.match(selected, /lineage: id:decision-1, query:support\.raw_ticket_volume\.v1/);
assert.match(selected, /contract: contract:support-ticket-volume-v2/);
assert.match(selected, /schema version: v2/);
assert.match(selected, /quality: passed/);
assert.match(selected, /quality score: 0\.97/);
assert.match(selected, /quality checks: row-count-reconciled, ticket-id-not-null/);
assert.match(selected, /quality note: Zendesk export and warehouse aggregate matched\./);
assert.match(selected, /provenance: artifact:reports\/support-ticket-volume\.csv, query:support\.ticket_volume\.v1/);
assert.match(selected, /source hashes: query:support\.ticket_volume\.v1=sha256:aaaaaaaaaaaa/);
assert.match(selected, /limit: 100/);
assert.match(selected, /sample size: 42/);
assert.match(selected, /sample rate: 25%/);
assert.match(selected, /sampling: latest-day/);
assert.match(selected, /coverage: open-support-tickets/);
assert.match(selected, /window start: 2026-05-01/);
assert.match(selected, /window end: 2026-05-15/);
assert.match(selected, /freshness SLA: 4h/);
assert.match(selected, /watermark: 2026-05-15T09:45:00-07:00/);
assert.match(selected, /data latency: 15m/);
assert.match(selected, /availability: degraded/);
assert.match(selected, /backfill: pending/);
assert.match(selected, /Data catalog: support satisfaction score/);
assert.match(selected, /review: review-required/);
assert.match(selected, /claim freshness: stale/);
assert.match(selected, /credential: secret:support-analytics/);
assert.match(selected, /config: profile:support-local/);
assert.match(selected, /params: score>=0\.7/);
assert.match(selected, /source: gs:\/\/support\/satisfaction\//);
assert.match(selected, /path: reports\/support-satisfaction\.csv/);
assert.match(selected, /table: support_satisfaction/);
assert.match(selected, /columns: account_id:string, satisfaction_score:double/);
assert.match(selected, /Event stream: support state changes/);
assert.match(selected, /kind: timeline-link/);
assert.match(selected, /timeline: support\.ticket\.lifecycle/);
assert.match(selected, /event: status_changed/);
assert.match(selected, /entity: ticket:SUP-42/);
assert.match(selected, /occurred: 2026-05-15T09:30:00-07:00/);
assert.match(selected, /provenance: run:linear-support-sync, url:https:\/\/linear\.example\/SUP-42/);
assert.match(selected, /Matching attachments: id:scarf-support-1/);

const selectedDataLink = run("context", "--id", "support-ticket-volume", "--dir", tmp, "--format", "markdown");
assert.match(selectedDataLink, /## Related data links/);
assert.match(selectedDataLink, /Data link: ticket volume/);
assert.match(selectedDataLink, /kind: warehouse-query/);
assert.match(selectedDataLink, /review: reviewed/);
assert.match(selectedDataLink, /claim freshness: fresh/);
assert.match(selectedDataLink, /query: support\.ticket_volume\.v1/);
assert.match(selectedDataLink, /query text: SELECT date, ticket_count FROM support\.ticket_volume_daily WHERE status IN \('open', 'pending'\)/);
assert.match(selectedDataLink, /rows: 42/);

const selectedThread = run("context", "--id", "thread-scarf-triage", "--dir", tmp, "--format", "markdown");
assert.match(selectedThread, /## Selected agent threads/);
assert.match(selectedThread, /Thread: Scarf triage help/);
assert.match(selectedThread, /agent: openclaw/);
assert.match(selectedThread, /session: openclaw:session:triage-1/);
assert.match(selectedThread, /storage: summary/);
assert.match(selectedThread, /Context attachments:/);
assert.match(selectedThread, /id:scarf-support-1 -> Scarf support triage \(support\.org2:3-/);

const org = run("context", "scarf support triage", "--dir", tmp, "--format", "org");
assert.match(org, /^\* Org2 Context Pack/m);
assert.match(org, /\*\* Top cited notes/);

const json = JSON.parse(run("context", "scarf support triage", "--dir", tmp, "--format", "json", "--budget", "8000"));
assert.equal(json.$schema, "org2:agent-context:v1");
assert.equal(json.action, "bundle");
assert.equal(json.query, "scarf support triage");
assert.ok(json.context.citations[0].citation.includes("support.org2"));
assert.equal(json.maxChars, 8000);

const selectedJson = JSON.parse(run("context", "--id", "scarf-support-1", "--dir", tmp, "--format", "json"));
assert.equal(selectedJson.action, "fetch");
assert.equal(selectedJson.id, "scarf-support-1");
assert.equal(selectedJson.results[0].collaboration.owner, "Casey");
assert.equal(selectedJson.results[0].collaboration.assignee, "openclaw");
assert.equal(selectedJson.results[0].collaboration.agent, "codex");
assert.equal(selectedJson.results[0].collaboration.nextAction, "Draft the support response for review");
assert.equal(selectedJson.results[0].collaboration.waitingOn, "Casey approval");
assert.equal(selectedJson.results[0].collaboration.lifecycle, "review");
assert.equal(selectedJson.results[0].collaboration.policy.requiresHumanApproval, true);
assert.equal(selectedJson.results[0].collaboration.policy.allowAgentEdit, true);
assert.equal(selectedJson.results[0].collaboration.policy.allowExternalSend, false);
assert.equal(selectedJson.results[0].collaboration.run.session, "openclaw:session:triage-1");
assert.equal(selectedJson.results[0].collaboration.run.runId, "run-42");
assert.equal(selectedJson.results[0].collaboration.run.sourceArtifacts.length, 2);
assert.ok(selectedJson.results[0].collaboration.run.sourceArtifacts.some((attachment) => attachment.ref === "file:tickets/scarf-support.json"));
assert.equal(selectedJson.results[0].collaboration.handoff.summary, "Response draft is ready but must be approved before sending.");
assert.ok(selectedJson.results[0].collaboration.handoff.links.some((attachment) => attachment.ref === "id:decision-1" && attachment.target.id === "decision-1"));
assert.equal(selectedJson.results[0].relatedThreads[0].id, "thread-scarf-triage");
const supportTicketVolume = selectedJson.results[0].relatedDataLinks.find((item) => item.id === "support-ticket-volume");
assert.ok(supportTicketVolume);
assert.equal(supportTicketVolume.dataLink.rowCount, 42);
assert.equal(supportTicketVolume.dataLink.source, "s3://support/ticket-volume/");
assert.equal(supportTicketVolume.dataLink.query, "SELECT date, ticket_count FROM support.ticket_volume_daily WHERE status IN ('open', 'pending')");
assert.equal(supportTicketVolume.dataLink.queryHash, "sha256:supportquery123");
assert.deepEqual(supportTicketVolume.dataLink.params, { team: "support", statuses: ["open", "pending"] });
assert.equal(supportTicketVolume.dataLink.materialized, "table");
assert.equal(supportTicketVolume.dataLink.resultLimit, 100);
assert.equal(supportTicketVolume.dataLink.sampleSize, 42);
assert.equal(supportTicketVolume.dataLink.sampleRate, "25%");
assert.equal(supportTicketVolume.dataLink.samplingMethod, "latest-day");
assert.equal(supportTicketVolume.dataLink.coverage, "open-support-tickets");
assert.equal(supportTicketVolume.dataLink.windowStart, "2026-05-01");
assert.equal(supportTicketVolume.dataLink.windowEnd, "2026-05-15");
assert.equal(supportTicketVolume.dataLink.freshnessSla, "4h");
assert.equal(supportTicketVolume.dataLink.watermark, "2026-05-15T09:45:00-07:00");
assert.equal(supportTicketVolume.dataLink.dataLatency, "15m");
assert.equal(supportTicketVolume.dataLink.availability, "degraded");
assert.equal(supportTicketVolume.dataLink.backfillStatus, "pending");
assert.equal(supportTicketVolume.dataLink.database, "support_warehouse");
assert.equal(supportTicketVolume.dataLink.schema, "support");
assert.equal(supportTicketVolume.dataLink.table, "ticket_volume_daily");
assert.deepEqual(supportTicketVolume.dataLink.columns, [
  { name: "date", type: "date" },
  { name: "ticket_count", type: "int" },
]);
assert.deepEqual(supportTicketVolume.dataLink.primaryKey, ["date"]);
assert.deepEqual(supportTicketVolume.dataLink.partitionBy, ["date"]);
assert.deepEqual(supportTicketVolume.dataLink.sortBy, [{ field: "date", direction: "desc" }]);
assert.deepEqual(supportTicketVolume.dataLink.dimensions, ["date"]);
assert.deepEqual(supportTicketVolume.dataLink.measures, ["ticket_count"]);
assert.equal(supportTicketVolume.dataLink.grain, "daily");
assert.deepEqual(supportTicketVolume.dataLink.filters, ["status = 'open'", "ticket_count > 0"]);
assert.deepEqual(supportTicketVolume.dataLink.groupBy, ["date"]);
assert.equal(supportTicketVolume.dataLink.timeColumn, "date");
assert.equal(supportTicketVolume.dataLink.timezone, "America/Los_Angeles");
assert.equal(supportTicketVolume.dataLink.refreshRef, "query-data:support-ticket-volume");
assert.equal(supportTicketVolume.dataLink.refreshCommand, "org2 query-data --file support.org2 --results support_ticket_volume --out views/support-ticket-volume.org2");
assert.equal(supportTicketVolume.dataLink.refreshStatus, "due");
assert.equal(supportTicketVolume.dataLink.refreshAfter, "24h");
assert.equal(supportTicketVolume.dataLink.nextRefresh, "2026-05-16T10:00:00-07:00");
assert.equal(supportTicketVolume.dataLink.validationStatus, "reconciled");
assert.equal(supportTicketVolume.dataLink.validationAt, "2026-05-15T10:30:00-07:00");
assert.equal(supportTicketVolume.dataLink.validationBy, "Casey");
assert.equal(supportTicketVolume.dataLink.validationNote, "Compared against Zendesk dashboard totals.");
assert.equal(supportTicketVolume.dataLink.confidence, "medium");
assert.ok(supportTicketVolume.dataLink.validationRefs.some((ref) => ref.ref === "id:decision-1" && ref.target.id === "decision-1"));
assert.equal(supportTicketVolume.dataLink.dataOwner, "Support Ops");
assert.equal(supportTicketVolume.dataLink.dataSteward, "Casey");
assert.equal(supportTicketVolume.dataLink.sensitivity, "customer-private");
assert.equal(supportTicketVolume.dataLink.visibility, "internal");
assert.equal(supportTicketVolume.dataLink.accessPolicy, "support-approved");
assert.equal(supportTicketVolume.dataLink.retention, "30d");
assert.ok(supportTicketVolume.dataLink.lineageRefs.some((ref) => ref.ref === "id:decision-1" && ref.target.id === "decision-1"));
assert.ok(supportTicketVolume.dataLink.lineageRefs.some((ref) => ref.ref === "query:support.raw_ticket_volume.v1"));
assert.equal(supportTicketVolume.dataLink.dataContract, "contract:support-ticket-volume-v2");
assert.equal(supportTicketVolume.dataLink.schemaVersion, "v2");
assert.equal(supportTicketVolume.dataLink.qualityStatus, "passed");
assert.equal(supportTicketVolume.dataLink.qualityScore, 0.97);
assert.deepEqual(supportTicketVolume.dataLink.qualityChecks, ["row-count-reconciled", "ticket-id-not-null"]);
assert.equal(supportTicketVolume.dataLink.qualityNote, "Zendesk export and warehouse aggregate matched.");
assert.ok(supportTicketVolume.dataLink.provenance.some((ref) => ref.ref === "query:support.ticket_volume.v1"));
assert.equal(supportTicketVolume.dataLink.sourceHashes[0].sha256, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
assert.equal(supportTicketVolume.claimState.reviewStatus, "reviewed");
assert.equal(supportTicketVolume.claimState.freshness, "fresh");
assert.ok(selectedJson.results[0].relatedDataLinks.some((item) => item.id === "support-satisfaction-score" && item.claimState.reviewStatus === "review-required" && item.claimState.freshness === "stale"));
assert.ok(selectedJson.results[0].relatedDataLinks.some((item) => item.id === "support-satisfaction-score" && item.dataLink.source === "gs://support/satisfaction/" && item.dataLink.path === "reports/support-satisfaction.csv"));
assert.ok(selectedJson.results[0].relatedDataLinks.some((item) => item.id === "support-satisfaction-score" && item.matchingAttachments.some((attachment) => attachment.ref === "id:scarf-support-1")));
assert.ok(selectedJson.results[0].relatedDataLinks.some((item) => item.id === "support-state-changes" && item.dataLink.timeline === "support.ticket.lifecycle"));
assert.ok(selectedJson.results[0].relatedDataLinks.some((item) => item.id === "support-state-changes" && item.dataLink.changeId === "change-42"));
