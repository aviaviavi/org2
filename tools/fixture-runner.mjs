#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

function fail(message) {
  console.error(message);
  process.exitCode = 1;
}

function readJson(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  return JSON.parse(raw);
}

function listFilesRecursive(dirPath) {
  const out = [];
  const entries = fs.readdirSync(dirPath, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      out.push(...listFilesRecursive(full));
    } else {
      out.push(full);
    }
  }
  return out;
}

function normalizePath(filePath) {
  return filePath.split(path.sep).join("/");
}

function loadSchema(schemaPath) {
  const schema = readJson(schemaPath);

  const defs = schema.$defs ?? {};
  return {
    schema,
    resolveRef(ref) {
      if (!ref.startsWith("#/$defs/")) {
        throw new Error(`Unsupported $ref: ${ref}`);
      }
      const key = ref.slice("#/$defs/".length);
      const resolved = defs[key];
      if (!resolved) {
        throw new Error(`Unresolvable $ref: ${ref}`);
      }
      return resolved;
    },
  };
}

function getType(value) {
  if (Array.isArray(value)) return "array";
  if (value === null) return "null";
  return typeof value;
}

function validateAgainstSchema(ctx, schemaNode, value, pointer) {
  if (schemaNode.$ref) {
    return validateAgainstSchema(ctx, ctx.resolveRef(schemaNode.$ref), value, pointer);
  }

  if (schemaNode.oneOf) {
    const errors = [];
    for (const option of schemaNode.oneOf) {
      try {
        validateAgainstSchema(ctx, option, value, pointer);
        return;
      } catch (err) {
        errors.push(err);
      }
    }

    const details = errors.map((e) => e.message).join("; ");
    throw new Error(`${pointer}: value does not match any oneOf option (${details})`);
  }

  if (schemaNode.const !== undefined) {
    if (value !== schemaNode.const) {
      throw new Error(`${pointer}: expected const ${JSON.stringify(schemaNode.const)}, got ${JSON.stringify(value)}`);
    }
  }

  if (schemaNode.type) {
    const t = schemaNode.type;
    const actual = getType(value);
    if (t === "object") {
      if (actual !== "object") {
        throw new Error(`${pointer}: expected object, got ${actual}`);
      }
    } else if (t === "array") {
      if (actual !== "array") {
        throw new Error(`${pointer}: expected array, got ${actual}`);
      }
    } else if (t === "integer") {
      if (actual !== "number" || !Number.isInteger(value)) {
        throw new Error(`${pointer}: expected integer, got ${actual}`);
      }
      if (schemaNode.minimum !== undefined && value < schemaNode.minimum) {
        throw new Error(`${pointer}: expected >= ${schemaNode.minimum}, got ${value}`);
      }
    } else if (t === "string") {
      if (actual !== "string") {
        throw new Error(`${pointer}: expected string, got ${actual}`);
      }
    } else if (t === "boolean") {
      if (actual !== "boolean") {
        throw new Error(`${pointer}: expected boolean, got ${actual}`);
      }
    } else {
      throw new Error(`${pointer}: unsupported schema type ${t}`);
    }
  }

  if (schemaNode.required) {
    for (const key of schemaNode.required) {
      if (value == null || typeof value !== "object" || !(key in value)) {
        throw new Error(`${pointer}: missing required property ${key}`);
      }
    }
  }

  if (schemaNode.properties) {
    for (const [key, childSchema] of Object.entries(schemaNode.properties)) {
      if (value != null && typeof value === "object" && key in value) {
        validateAgainstSchema(ctx, childSchema, value[key], `${pointer}/${key}`);
      }
    }
  }

  if (schemaNode.additionalProperties === false) {
    const allowed = new Set(Object.keys(schemaNode.properties ?? {}));
    for (const key of Object.keys(value ?? {})) {
      if (!allowed.has(key)) {
        throw new Error(`${pointer}: additional property not allowed: ${key}`);
      }
    }
  }

  if (schemaNode.items) {
    if (!Array.isArray(value)) {
      throw new Error(`${pointer}: expected array for items validation`);
    }
    for (let i = 0; i < value.length; i += 1) {
      validateAgainstSchema(ctx, schemaNode.items, value[i], `${pointer}/${i}`);
    }
  }
}

function collectFixturePairs(testsDir) {
  const files = listFilesRecursive(testsDir).map(normalizePath);

  const org = new Map();
  const json = new Map();

  for (const filePath of files) {
    if (filePath.endsWith(".org")) {
      org.set(filePath.slice(0, -".org".length), filePath);
    }
    if (filePath.endsWith(".json")) {
      json.set(filePath.slice(0, -".json".length), filePath);
    }
  }

  const bases = new Set([...org.keys(), ...json.keys()]);
  const pairs = [];

  for (const base of [...bases].sort()) {
    pairs.push({
      base,
      orgPath: org.get(base) ?? null,
      jsonPath: json.get(base) ?? null,
    });
  }

  return pairs;
}

function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null) return a === b;

  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b)) return false;
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i += 1) {
      if (!deepEqual(a[i], b[i])) return false;
    }
    return true;
  }

  if (typeof a === "object") {
    const aKeys = Object.keys(a).sort();
    const bKeys = Object.keys(b).sort();
    if (!deepEqual(aKeys, bKeys)) return false;
    for (const key of aKeys) {
      if (!deepEqual(a[key], b[key])) return false;
    }
    return true;
  }

  return false;
}

function parseOrgViaCli(parseEntrypoint, orgPath) {
  const raw = execFileSync(process.execPath, [parseEntrypoint, orgPath], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });

  return JSON.parse(raw);
}

function printAstViaCli(printEntrypoint, jsonPath) {
  return execFileSync(process.execPath, [printEntrypoint, jsonPath], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function printHelp() {
  console.log("Usage: node tools/fixture-runner.mjs [--schema-only | --e2e]");
  console.log("\nModes:");
  console.log("  (default)       Auto: run e2e if parser is available, otherwise schema-only");
  console.log("  --schema-only   Validate fixture pairs + JSON schema only");
  console.log("  --e2e           Also parse each .org fixture via dist/parse.js and compare to sibling .json");
}

function parseArgs(argv) {
  const args = new Set(argv);

  if (args.has("--help") || args.has("-h")) {
    return { help: true };
  }

  const known = new Set(["--schema-only", "--e2e"]);
  for (const arg of args) {
    if (!known.has(arg)) {
      return { error: `Unknown argument: ${arg}` };
    }
  }

  if (args.has("--schema-only") && args.has("--e2e")) {
    return { error: "--schema-only and --e2e are mutually exclusive" };
  }

  if (args.has("--schema-only")) return { mode: "schema-only" };
  if (args.has("--e2e")) return { mode: "e2e" };
  return { mode: "auto" };
}

function main() {
  const repoRoot = process.cwd();
  const specV0Dir = path.join(repoRoot, "spec", "v0");
  const schemaPath = path.join(specV0Dir, "canonical-ast.schema.json");
  const testsDir = path.join(specV0Dir, "tests");

  const parsedArgs = parseArgs(process.argv.slice(2));
  if (parsedArgs.help) {
    printHelp();
    process.exitCode = 0;
    return;
  }

  if (parsedArgs.error) {
    console.error(`ERROR: ${parsedArgs.error}`);
    printHelp();
    process.exitCode = 2;
    return;
  }

  const parseEntrypoint = path.join(repoRoot, "dist", "parse.js");
  const printEntrypoint = path.join(repoRoot, "dist", "print.js");
  const hasParser = fs.existsSync(parseEntrypoint);
  const hasPrinter = fs.existsSync(printEntrypoint);

  const endToEnd =
    parsedArgs.mode === "e2e" ? hasParser : parsedArgs.mode === "auto" ? hasParser : false;

  const canPrint = endToEnd && hasPrinter;

  if (parsedArgs.mode === "e2e" && !hasParser) {
    console.log(
      `SKIP: e2e requested but parser not available (expected ${normalizePath(
        parseEntrypoint,
      )}). Running schema-only.`,
    );
  }

  if (!fs.existsSync(schemaPath) || !fs.existsSync(testsDir)) {
    console.log(
      `SKIP: spec v0 not present (expected ${normalizePath(schemaPath)} and ${normalizePath(
        testsDir,
      )})`,
    );
    return;
  }

  const ctx = loadSchema(schemaPath);
  const pairs = collectFixturePairs(testsDir);

  if (pairs.length === 0) {
    console.log(`SKIP: no fixtures found in ${normalizePath(testsDir)}`);
    return;
  }

  let okCount = 0;

  for (const pair of pairs) {
    if (!pair.orgPath) {
      fail(`Missing .org fixture for base: ${pair.base}`);
      continue;
    }
    if (!pair.jsonPath) {
      fail(`Missing .json fixture for base: ${pair.base}`);
      continue;
    }

    let jsonValue;
    try {
      jsonValue = readJson(pair.jsonPath);
    } catch (err) {
      fail(`Invalid JSON: ${pair.jsonPath} (${err.message})`);
      continue;
    }

    try {
      validateAgainstSchema(ctx, ctx.schema, jsonValue, "$");
    } catch (err) {
      fail(`Schema validation failed: ${pair.jsonPath}: ${err.message}`);
      continue;
    }

    if (endToEnd) {
      let parsed;
      try {
        parsed = parseOrgViaCli(parseEntrypoint, pair.orgPath);
      } catch (err) {
        fail(`Parse failed: ${pair.orgPath}: ${err.message}`);
        continue;
      }

      if (!deepEqual(parsed, jsonValue)) {
        fail(`E2E mismatch: ${pair.orgPath} did not match ${pair.jsonPath}`);
        continue;
      }

      try {
        validateAgainstSchema(ctx, ctx.schema, parsed, "$ (parsed)");
      } catch (err) {
        fail(`Schema validation failed (parsed): ${pair.orgPath}: ${err.message}`);
        continue;
      }

      // Optional printer validation: only run for fixtures with printer coverage.
      if (canPrint && /(timestamp|emphasis|link|keyword|planning|list|table|drawer|block|comment)/.test(pair.base)) {
        let printed;
        try {
          printed = printAstViaCli(printEntrypoint, pair.jsonPath);
        } catch (err) {
          fail(`Print failed: ${pair.jsonPath}: ${err.message}`);
          continue;
        }

        const orgRaw = fs.readFileSync(pair.orgPath, "utf8");
        if (printed !== orgRaw) {
          fail(`E2E print mismatch: ${pair.jsonPath} did not round-trip to ${pair.orgPath}`);
          continue;
        }
      }
    }

    okCount += 1;
  }

  if (process.exitCode === 1) {
    console.error("\nFixture validation failed.");
    return;
  }

  const suffix = endToEnd ? " (schema + e2e parse)" : " (schema only)";
  console.log(`OK: validated ${okCount} fixture(s)${suffix}`);
}

main();
