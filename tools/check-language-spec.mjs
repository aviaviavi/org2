#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const repoRoot = process.cwd();
const specRoot = path.join(repoRoot, "spec", "v0");
const grammarPath = path.join(specRoot, "GRAMMAR.ebnf");
const parsingPath = path.join(specRoot, "PARSING.org");
const specPath = path.join(specRoot, "SPEC.org");
const conformancePath = path.join(specRoot, "CONFORMANCE.org");
const schemaPath = path.join(specRoot, "canonical-ast.schema.json");
const casesPath = path.join(specRoot, "parsing-cases.json");

function fail(message) {
  throw new Error(message);
}

function readRequired(filePath) {
  if (!fs.existsSync(filePath)) fail(`Missing required language-spec artifact: ${path.relative(repoRoot, filePath)}`);
  return fs.readFileSync(filePath, "utf8");
}

function maskDelimited(source) {
  const chars = [...source];
  let state = "normal";
  for (let i = 0; i < chars.length; i += 1) {
    const current = chars[i];
    const next = chars[i + 1];

    if (state === "normal") {
      if (current === "(" && next === "*") {
        chars[i] = " ";
        chars[i + 1] = " ";
        i += 1;
        state = "comment";
      } else if (current === "\"") {
        chars[i] = " ";
        state = "string";
      } else if (current === "?") {
        chars[i] = " ";
        state = "special";
      }
      continue;
    }

    if (state === "comment" && current === "*" && next === ")") {
      chars[i] = " ";
      chars[i + 1] = " ";
      i += 1;
      state = "normal";
      continue;
    }
    if (state === "string" && current === "\"") {
      chars[i] = " ";
      state = "normal";
      continue;
    }
    if (state === "special" && current === "?") {
      chars[i] = " ";
      state = "normal";
      continue;
    }

    if (current !== "\n") chars[i] = " ";
  }

  if (state !== "normal") fail(`Unterminated ${state} in ${path.relative(repoRoot, grammarPath)}`);
  return chars.join("");
}

function parseGrammar(source) {
  const masked = maskDelimited(source);
  const productions = new Map();
  let cursor = 0;

  while (cursor < masked.length) {
    while (/\s/.test(masked[cursor] ?? "")) cursor += 1;
    if (cursor >= masked.length) break;

    const nameMatch = /^[a-z][a-z0-9-]*/.exec(masked.slice(cursor));
    if (!nameMatch) fail(`Unexpected grammar text at byte ${cursor}`);
    const name = nameMatch[0];
    cursor += name.length;

    while (/\s/.test(masked[cursor] ?? "")) cursor += 1;
    if (masked[cursor] !== "=") fail(`Production ${name} is missing '='`);
    cursor += 1;
    const rhsStart = cursor;
    while (cursor < masked.length && masked[cursor] !== ";") cursor += 1;
    if (cursor >= masked.length) fail(`Production ${name} is missing ';'`);
    const rhs = masked.slice(rhsStart, cursor);
    cursor += 1;

    if (productions.has(name)) fail(`Duplicate grammar production: ${name}`);
    checkProductionSyntax(name, rhs);
    productions.set(name, rhs);
  }

  if (!productions.has("document")) fail("Grammar must define the document root production");
  if (productions.size < 80) fail(`Grammar is unexpectedly small: ${productions.size} productions`);
  return productions;
}

function checkProductionSyntax(name, rhs) {
  const stack = [];
  const matchingOpen = { ")": "(", "]": "[", "}": "{" };
  for (let i = 0; i < rhs.length; ) {
    const ch = rhs[i] ?? "";
    if (/\s/.test(ch) || ch === "," || ch === "|") {
      i += 1;
      continue;
    }
    if (ch === "(" || ch === "[" || ch === "{") {
      stack.push(ch);
      i += 1;
      continue;
    }
    if (ch === ")" || ch === "]" || ch === "}") {
      if (stack.pop() !== matchingOpen[ch]) fail(`Unbalanced ${ch} in production ${name}`);
      i += 1;
      continue;
    }
    const ref = /^[a-z][a-z0-9-]*/.exec(rhs.slice(i));
    if (ref) {
      i += ref[0].length;
      continue;
    }
    fail(`Unexpected EBNF token ${JSON.stringify(ch)} in production ${name}`);
  }
  if (stack.length > 0) fail(`Unclosed ${stack.at(-1)} in production ${name}`);
}

function checkGrammarGraph(productions) {
  const references = new Map();
  for (const [name, rhs] of productions) {
    const refs = new Set(rhs.match(/\b[a-z][a-z0-9-]*\b/g) ?? []);
    references.set(name, refs);
    for (const ref of refs) {
      if (!productions.has(ref)) fail(`Undefined grammar production ${ref}, referenced by ${name}`);
    }
  }

  const reachable = new Set();
  const pending = ["document"];
  while (pending.length > 0) {
    const name = pending.pop();
    if (!name || reachable.has(name)) continue;
    reachable.add(name);
    for (const ref of references.get(name) ?? []) pending.push(ref);
  }

  const unreachable = [...productions.keys()].filter((name) => !reachable.has(name));
  if (unreachable.length > 0) fail(`Unreachable grammar productions: ${unreachable.join(", ")}`);
}

function collectSchemaRefs(value, refs = []) {
  if (Array.isArray(value)) {
    for (const item of value) collectSchemaRefs(item, refs);
    return refs;
  }
  if (!value || typeof value !== "object") return refs;
  if (typeof value.$ref === "string") refs.push(value.$ref);
  for (const child of Object.values(value)) collectSchemaRefs(child, refs);
  return refs;
}

function checkSchema(source) {
  const schema = JSON.parse(source);
  const defs = schema.$defs ?? {};
  for (const ref of collectSchemaRefs(schema)) {
    const prefix = "#/$defs/";
    if (!ref.startsWith(prefix)) fail(`Unsupported canonical AST reference: ${ref}`);
    const name = ref.slice(prefix.length);
    if (!(name in defs)) fail(`Unresolved canonical AST reference: ${ref}`);
  }
}

function checkParsingCases(source) {
  const suite = JSON.parse(source);
  if (suite.version !== "0" || !Array.isArray(suite.cases) || suite.cases.length < 10) {
    fail("parsing-cases.json must contain at least ten v0 cases");
  }
  const ids = new Set();
  for (const entry of suite.cases) {
    if (!entry || typeof entry.id !== "string" || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(entry.id)) {
      fail("Every parsing case requires a stable kebab-case id");
    }
    if (ids.has(entry.id)) fail(`Duplicate parsing case id: ${entry.id}`);
    ids.add(entry.id);
    if (typeof entry.source !== "string") fail(`Parsing case ${entry.id} is missing source text`);
    if (entry.expectedAst?.type !== "Document" || entry.expectedAst?.version !== "0" || !Array.isArray(entry.expectedAst?.children)) {
      fail(`Parsing case ${entry.id} is missing a canonical v0 Document expectation`);
    }
  }
  return suite.cases.length;
}

function requireText(text, fileLabel, needles) {
  for (const needle of needles) {
    if (!text.includes(needle)) fail(`${fileLabel} is missing required language-contract text: ${needle}`);
  }
}

function main() {
  const grammar = readRequired(grammarPath);
  const parsing = readRequired(parsingPath);
  const spec = readRequired(specPath);
  const conformance = readRequired(conformancePath);
  const schema = readRequired(schemaPath);
  const cases = readRequired(casesPath);

  const productions = parseGrammar(grammar);
  checkGrammarGraph(productions);
  checkSchema(schema);
  const caseCount = checkParsingCases(cases);

  requireText(parsing, "PARSING.org", [
    "* Block candidate precedence",
    "* Multi-line grouping",
    "* Affiliated keyword algorithm",
    "* Headline construction",
    "* List construction",
    "* Inline candidate precedence",
    "* Diagnostics and recovery",
    "* AST construction and losslessness",
  ]);
  requireText(spec, "SPEC.org", ["GRAMMAR.ebnf", "PARSING.org", "parsing-cases.json"]);
  requireText(conformance, "CONFORMANCE.org", ["GRAMMAR.ebnf", "PARSING.org", "parsing-cases.json"]);

  console.log(`OK: language specification (${productions.size} grammar productions, ${caseCount} parsing cases)`);
}

try {
  main();
} catch (error) {
  console.error(`ERROR: ${error.message}`);
  process.exitCode = 1;
}
