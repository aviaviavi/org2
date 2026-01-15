#!/usr/bin/env node

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

function main() {
  const repoRoot = process.cwd();
  const specV0Dir = path.join(repoRoot, "spec", "v0");
  const schemaPath = path.join(specV0Dir, "canonical-ast.schema.json");
  const testsDir = path.join(specV0Dir, "tests");

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

    okCount += 1;
  }

  if (process.exitCode === 1) {
    console.error("\nFixture validation failed.");
    return;
  }

  console.log(`OK: validated ${okCount} fixture(s) against schema`);
}

main();
