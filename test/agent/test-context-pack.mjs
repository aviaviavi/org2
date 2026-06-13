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
:END:
Support needs a deterministic context pack with citations for Scarf triage.
See [[id:decision-1][decision note]].

** Data link: ticket volume
:PROPERTIES:
:ID: support-ticket-volume
:KIND: warehouse-query
:SYSTEM: clickhouse
:QUERY_ID: support.ticket_volume.v1
:ARTIFACT: reports/support-ticket-volume.csv
:ROW_COUNT: 42
:FRESHNESS: daily
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
assert.match(md, /support\.org2:3-27/);
assert.match(md, /## Recent timeline entries/);
assert.match(md, /## Active TODOs \/ scheduled items/);
assert.match(md, /TODO Scarf support triage/);
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
assert.match(selected, /query: support\.ticket_volume\.v1/);
assert.match(selected, /artifact: reports\/support-ticket-volume\.csv/);

const selectedDataLink = run("context", "--id", "support-ticket-volume", "--dir", tmp, "--format", "markdown");
assert.match(selectedDataLink, /## Related data links/);
assert.match(selectedDataLink, /Data link: ticket volume/);
assert.match(selectedDataLink, /kind: warehouse-query/);
assert.match(selectedDataLink, /query: support\.ticket_volume\.v1/);
assert.match(selectedDataLink, /rows: 42/);

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
assert.equal(selectedJson.results[0].relatedThreads[0].id, "thread-scarf-triage");
assert.equal(selectedJson.results[0].relatedDataLinks[0].id, "support-ticket-volume");
assert.equal(selectedJson.results[0].relatedDataLinks[0].dataLink.rowCount, 42);
