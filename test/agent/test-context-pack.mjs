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

* Data catalog: support satisfaction score
:PROPERTIES:
:ID: support-satisfaction-score
:KIND: dataset
:PATH: reports/support-satisfaction.csv
:CREDENTIAL_REF: secret:support-analytics
:CONFIG_REF: profile:support-local
:ROW_COUNT: 5
:FRESHNESS: weekly
:CONTEXT: id:scarf-support-1
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
assert.match(selected, /query: support\.ticket_volume\.v1/);
assert.match(selected, /artifact: reports\/support-ticket-volume\.csv/);
assert.match(selected, /Data catalog: support satisfaction score/);
assert.match(selected, /credential: secret:support-analytics/);
assert.match(selected, /config: profile:support-local/);
assert.match(selected, /Event stream: support state changes/);
assert.match(selected, /kind: timeline-link/);
assert.match(selected, /timeline: support\.ticket\.lifecycle/);
assert.match(selected, /event: status_changed/);
assert.match(selected, /entity: ticket:SUP-42/);
assert.match(selected, /occurred: 2026-05-15T09:30:00-07:00/);
assert.match(selected, /Matching attachments: id:scarf-support-1/);

const selectedDataLink = run("context", "--id", "support-ticket-volume", "--dir", tmp, "--format", "markdown");
assert.match(selectedDataLink, /## Related data links/);
assert.match(selectedDataLink, /Data link: ticket volume/);
assert.match(selectedDataLink, /kind: warehouse-query/);
assert.match(selectedDataLink, /query: support\.ticket_volume\.v1/);
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
assert.equal(selectedJson.results[0].relatedDataLinks[0].id, "support-ticket-volume");
assert.equal(selectedJson.results[0].relatedDataLinks[0].dataLink.rowCount, 42);
assert.ok(selectedJson.results[0].relatedDataLinks.some((item) => item.id === "support-satisfaction-score" && item.matchingAttachments.some((attachment) => attachment.ref === "id:scarf-support-1")));
assert.ok(selectedJson.results[0].relatedDataLinks.some((item) => item.id === "support-state-changes" && item.dataLink.timeline === "support.ticket.lifecycle"));
assert.ok(selectedJson.results[0].relatedDataLinks.some((item) => item.id === "support-state-changes" && item.dataLink.changeId === "change-42"));
