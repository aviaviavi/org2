#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { buildSearchIndex, searchIndexedCorpus } from "../dist/searchIndex.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-search-index-query-performance-"));

function searchOptions(query, overrides = {}) {
  return {
    query,
    context: 1,
    limit: 50,
    todoFilters: new Set(),
    tagFilters: new Set(),
    fileZoneFilters: [],
    headingNeedle: "",
    sort: "scan",
    dateFrom: "",
    dateTo: "",
    subtree: false,
    answerContext: false,
    ...overrides,
  };
}

function withoutQueryMetadata(index) {
  return {
    ...index,
    files: index.files.map(({ headings: _headings, ...file }) => file),
  };
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function measure(index, options) {
  const started = performance.now();
  const results = searchIndexedCorpus(index, options);
  return { elapsedMs: performance.now() - started, results };
}

try {
  const parityFile = path.join(tmp, "2026-08-27-parity.org2");
  fs.writeFileSync(parityFile, `Preamble target
* TODO Parent target :Work:urgent:
:PROPERTIES:
:ID: parent-id
:END:
Body TARGET
** Child
SCHEDULED: <2026-08-26 Wed>
Child target [literal].*?
* Sibling
Sibling target
* Unicode
K
İ
ſ
`, "utf8");

  const parityIndex = buildSearchIndex({
    rootDir: tmp,
    files: [parityFile],
    recursive: true,
    includeArchives: false,
  }).index;
  const legacyParityIndex = withoutQueryMetadata(parityIndex);
  const parityCases = [
    searchOptions("target"),
    searchOptions("TARGET", { sort: "relevance" }),
    searchOptions("[literal].*?"),
    searchOptions("target", { sort: "date-desc" }),
    searchOptions("target", { subtree: true }),
    searchOptions("target", { todoFilters: new Set(["TODO"]) }),
    searchOptions("target", { tagFilters: new Set(["work"]) }),
    searchOptions("k"),
    searchOptions("i"),
    searchOptions("s"),
  ];
  for (const options of parityCases) {
    assert.deepEqual(
      searchIndexedCorpus(parityIndex, options),
      searchIndexedCorpus(legacyParityIndex, options),
      `query metadata must preserve legacy results for ${JSON.stringify(options.query)}`,
    );
  }

  const perfDir = path.join(tmp, "perf");
  fs.mkdirSync(perfDir);
  const perfFiles = [];
  for (let fileIndex = 0; fileIndex < 160; fileIndex += 1) {
    const file = path.join(perfDir, `${String(fileIndex).padStart(4, "0")}.org2`);
    const filler = Array.from(
      { length: 500 },
      (_, lineIndex) => `Ordinary filler ${fileIndex}-${lineIndex} with stable corpus text.`,
    );
    filler[250] = `Common relevance marker for file ${fileIndex}.`;
    if (fileIndex === 159) filler[499] = "Rare terminal marker zxqv-348d5cd6.";
    fs.writeFileSync(file, `* TODO Synthetic heading ${fileIndex} :performance:\n${filler.join("\n")}\n`, "utf8");
    perfFiles.push(file);
  }

  const indexed = buildSearchIndex({
    rootDir: perfDir,
    files: perfFiles,
    recursive: true,
    includeArchives: false,
  }).index;
  assert.ok(indexed.files.every((file) => Array.isArray(file.headings)), "rebuilt indexes should contain query metadata");
  const legacy = withoutQueryMetadata(indexed);
  const benchmarkCases = [
    searchOptions("Common relevance marker", { sort: "relevance" }),
    searchOptions("zxqv-348d5cd6", { sort: "relevance" }),
    searchOptions("absent-348d5cd6", { sort: "relevance" }),
  ];

  const measurements = [];
  for (const options of benchmarkCases) {
    // Warm both implementations before measuring so JIT startup is not
    // attributed to either representation.
    searchIndexedCorpus(legacy, options);
    searchIndexedCorpus(indexed, options);

    const legacySamples = [];
    const metadataSamples = [];
    for (let sample = 0; sample < 3; sample += 1) {
      const first = sample % 2 === 0 ? legacy : indexed;
      const second = sample % 2 === 0 ? indexed : legacy;
      const firstMeasurement = measure(first, options);
      const secondMeasurement = measure(second, options);
      const legacyMeasurement = sample % 2 === 0 ? firstMeasurement : secondMeasurement;
      const metadataMeasurement = sample % 2 === 0 ? secondMeasurement : firstMeasurement;
      assert.deepEqual(metadataMeasurement.results, legacyMeasurement.results);
      legacySamples.push(legacyMeasurement.elapsedMs);
      metadataSamples.push(metadataMeasurement.elapsedMs);
    }

    const legacyMedianMs = median(legacySamples);
    const metadataMedianMs = median(metadataSamples);
    assert.ok(
      metadataMedianMs <= legacyMedianMs,
      `query metadata regressed ${JSON.stringify(options.query)}: ${metadataMedianMs.toFixed(1)}ms vs ${legacyMedianMs.toFixed(1)}ms`,
    );
    assert.ok(
      metadataMedianMs < 500,
      `indexed ${JSON.stringify(options.query)} query exceeded 500ms in-process budget: ${metadataMedianMs.toFixed(1)}ms`,
    );
    measurements.push({ query: options.query, legacyMedianMs, metadataMedianMs });
  }

  console.log(JSON.stringify({
    files: indexed.files.length,
    lines: indexed.files.reduce((count, file) => count + file.lines.length, 0),
    measurements,
  }, null, 2));
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
