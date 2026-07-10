#!/usr/bin/env node
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const {
  buildBuiltInLinkAbbreviations,
  collectLinkAbbreviationsFromDoc,
  collectLinkAbbreviationsFromRecord,
  collectLinkAbbreviationsFromText,
  expandLinkAbbreviationTarget,
  mergeLinkAbbreviations,
} = await import(path.join(repo, "dist", "link-abbrev.js"));
const { parseOrgToCanonicalAst } = await import(path.join(repo, "dist", "parser.js"));

const fromRecord = collectLinkAbbreviationsFromRecord({
  GH: "https://git.example/%s",
  "bad prefix": "https://example.invalid/%s",
  "9bad": "https://example.invalid/%s",
  blank: "   ",
});

assert.deepEqual(Array.from(fromRecord.entries()), [
  ["gh", "https://git.example/%s"],
]);

const fromText = collectLinkAbbreviationsFromText(`
#+LINK: gh https://text.example/%s?mirror=%s
#+LINK: ticket https://tickets.example/
#+LINK: bad_prefix https://example.invalid/%s
#+LINK: missing-template
`);

assert.deepEqual(Array.from(fromText.entries()), [
  ["gh", "https://text.example/%s?mirror=%s"],
  ["ticket", "https://tickets.example/"],
]);

const doc = parseOrgToCanonicalAst(`
#+TITLE: Link Abbreviations
#+LINK: gh https://doc.example/%s
#+LINK: linear https://linear.example/%s

See [[gh:org2/org2][Org2]].
`);
const fromDoc = collectLinkAbbreviationsFromDoc(doc);
assert.deepEqual(Array.from(fromDoc.entries()), [
  ["gh", "https://doc.example/%s"],
  ["linear", "https://linear.example/%s"],
]);

const merged = mergeLinkAbbreviations([
  buildBuiltInLinkAbbreviations("org2"),
  fromRecord,
  fromText,
  fromDoc,
]);

assert.equal(expandLinkAbbreviationTarget("gh:aviaviavi/org2", merged), "https://doc.example/aviaviavi/org2");
assert.equal(expandLinkAbbreviationTarget("linear:APP-123", merged), "https://linear.example/APP-123");
assert.equal(expandLinkAbbreviationTarget("ticket:APP-123", merged), "https://tickets.example/APP-123");
assert.equal(expandLinkAbbreviationTarget("yt:dQw4w9WgXcQ", merged), "https://www.youtube.com/watch?v=dQw4w9WgXcQ");

const repeated = mergeLinkAbbreviations([fromText]);
assert.equal(
  expandLinkAbbreviationTarget("gh:org/repo", repeated),
  "https://text.example/org/repo?mirror=org/repo",
);

const reserved = mergeLinkAbbreviations([collectLinkAbbreviationsFromRecord({ http: "https://proxy.example/%s" })]);
assert.equal(expandLinkAbbreviationTarget("http://example.com", reserved), "http://example.com");
assert.equal(expandLinkAbbreviationTarget("unknown:value", merged), "unknown:value");

console.log("✓ link-abbrev");
