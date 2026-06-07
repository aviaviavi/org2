#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
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
assert.deepEqual(context.results[0].sourceRange, { startLine: 3, endLine: 14 });
assert.equal(context.results[0].properties.CUSTOM, "value");
assert.equal(context.results[0].claimState.reviewStatus, "reviewed");
assert.equal(context.results[0].claimState.freshness, "fresh");
assert.ok(context.results[0].citation.endsWith("alpha.org2:3-14"));
assert.ok(context.results[0].neighbors.some((n) => n.id === "beta-1" && n.direction === "out"));
assert.ok(context.context.text.includes("Source: alpha.org2:3-14"));
assert.ok(context.context.text.includes("Review: reviewed; freshness: fresh"));
assert.ok(context.context.citations[0].citation.endsWith("alpha.org2:3-14"));

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
const freshnessSearch = runJson("agent", "search", "--query", "pricing policy copper", "--dir", staleDir, "--limit", "2");
assert.equal(freshnessSearch.results[0].id, "fresh-memory");
assert.equal(freshnessSearch.results[0].claimState.freshness, "fresh");
assert.equal(freshnessSearch.results[1].claimState.freshness, "stale");

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

const explainedContext = execFileSync("node", ["dist/cli.js", "context", "Copper launch retrieval", "--dir", rankingDir, "--limit", "1", "--recency-weight", "0", "--salience-weight", "1"], { encoding: "utf8" });
assert.match(explainedContext, /Selected because:/);
assert.match(explainedContext, /explicit salience/);
