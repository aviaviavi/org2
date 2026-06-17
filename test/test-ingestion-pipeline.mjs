import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ingestDemoSource } from "../dist/ingestionPipeline.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-ingest-"));
const rawDir = path.join(root, "raw", "demo");
const reviewDir = path.join(root, "review", "demo");

const input = {
  sourceType: "demo",
  externalId: "meeting-123",
  authors: ["Ada", "Ben"],
  capturedAt: "2026-05-23T18:00:00.000Z",
  occurredAt: "2026-05-23T17:30:00.000Z",
  visibility: "team",
  sensitivity: "private",
  sourceRef: "demo://meeting/123",
  content: `Project Apollo sync\nDecision: use raw captures before durable notes\nAction item: Ben drafts the importer docs\nApollo should preserve provenance for every claim\n`,
};

const first = ingestDemoSource({ input, rawDir, reviewDir, now: "2026-05-23T18:00:00.000Z" });
const second = ingestDemoSource({ input, rawDir, reviewDir, now: "2026-05-23T18:00:00.000Z" });

assert.equal(first.rawPath, second.rawPath, "same source/hash should resolve to same raw path");
assert.equal(first.reviewPath, second.reviewPath, "same source/hash should resolve to same review path");
assert.equal(first.rawCreated, true);
assert.equal(second.rawCreated, false);
assert.equal(second.reviewCreated, false);

const raw = JSON.parse(fs.readFileSync(first.rawPath, "utf8"));
assert.equal(raw.schemaVersion, "org2-ingestion/v1");
assert.equal(raw.sourceType, "demo");
assert.equal(raw.externalId, "meeting-123");
assert.match(raw.contentHash, /^[a-f0-9]{64}$/);
assert.equal(raw.rawRef, `demo:meeting-123@sha256:${raw.contentHash}`);

const review = fs.readFileSync(first.reviewPath, "utf8");
assert.match(review, /:ORG2_REVIEW_STATUS: review-required/);
assert.match(review, /:ORG2_PROVENANCE: demo:meeting-123@sha256:/);
assert.match(review, /\* Decisions\n- use raw captures before durable notes/);
assert.match(review, /\* TODO candidates\n- Ben drafts the importer docs/);
assert.match(review, /\[cite:demo:meeting-123@sha256:/);

const rawFiles = fs.readdirSync(rawDir);
const reviewFiles = fs.readdirSync(reviewDir);
assert.equal(rawFiles.length, 1, "idempotent re-run should not duplicate raw captures");
assert.equal(reviewFiles.length, 1, "idempotent re-run should not duplicate review artifacts");

console.log("ingestion pipeline fixture OK");
