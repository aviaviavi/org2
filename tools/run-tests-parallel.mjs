#!/usr/bin/env node
// Run an npm test script's leaf commands concurrently.
//
// The serial `a && b && c` chains in package.json stay the canonical list of
// tests. This runner expands `npm run X` references recursively, runs the
// independent leaves on a bounded worker pool, and runs wall-clock-sensitive
// performance tests afterwards, one at a time, on an otherwise idle pool so
// their timing budgets are not measured against concurrent CPU load.
//
// A failed leaf is retried once, alone, after the pool drains. A pass on retry
// is reported as FLAKY in the summary and the JSON report instead of being
// hidden; `--no-retry` restores fail-fast semantics.

import { spawn } from "node:child_process";
import { availableParallelism } from "node:os";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// Leaves whose assertions compare elapsed wall-clock time against a budget.
export const SERIAL_LEAF_PATTERNS = [
  /--performance\b/,
  /performance/,
  /test-cli-startup\.mjs/,
];

// Long-running leaves start first so they do not become the pool's tail.
export const SLOW_FIRST_LEAVES = [
  "node tools/cli-test-runner.mjs",
  "node test/test-ios-mobile-navigation.mjs",
  "node tools/fixture-runner.mjs",
  "node test/test-data-query.mjs",
  "node test/test-cli-approvals.mjs",
  "node test/test-agentic-workspace.mjs",
  "node test/test-server.mjs",
];

export function expandScript(scripts, name, seen = new Set()) {
  const command = scripts[name];
  if (typeof command !== "string") throw new Error(`Unknown npm script: ${name}`);
  if (seen.has(name)) throw new Error(`Recursive npm script: ${name}`);
  const nextSeen = new Set(seen).add(name);
  const leaves = [];
  for (const segment of command.split("&&").map((part) => part.trim()).filter(Boolean)) {
    const reference = segment.match(/^npm run ([^\s]+)$/);
    if (reference && typeof scripts[reference[1]] === "string") {
      leaves.push(...expandScript(scripts, reference[1], nextSeen));
    } else {
      leaves.push(segment);
    }
  }
  return [...new Set(leaves)];
}

export function partitionLeaves(leaves, patterns = SERIAL_LEAF_PATTERNS) {
  const serial = [];
  const parallel = [];
  for (const leaf of leaves) (patterns.some((pattern) => pattern.test(leaf)) ? serial : parallel).push(leaf);
  const rank = (leaf) => {
    const index = SLOW_FIRST_LEAVES.indexOf(leaf);
    return index === -1 ? SLOW_FIRST_LEAVES.length : index;
  };
  parallel.sort((a, b) => rank(a) - rank(b));
  return { parallel, serial };
}

function parseArgs(argv) {
  const options = {
    jobs: Math.max(2, Math.min(8, Math.floor(availableParallelism() * 0.75))),
    report: "",
    retry: true,
    script: "test:built",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--jobs") options.jobs = Number(argv[++index]);
    else if (argument === "--report") options.report = argv[++index] ?? "";
    else if (argument === "--no-retry") options.retry = false;
    else if (argument === "--list") options.list = true;
    else if (argument === "--help" || argument === "-h") options.help = true;
    else if (!argument.startsWith("-")) options.script = argument;
    else throw new Error(`Unknown option: ${argument}`);
  }
  if (!Number.isInteger(options.jobs) || options.jobs < 1) throw new Error("--jobs must be a positive integer");
  return options;
}

function runLeaf(command) {
  const startedAt = Date.now();
  return new Promise((resolvePromise) => {
    const child = spawn("/bin/sh", ["-c", command], {
      cwd: repoRoot,
      env: { ...process.env, FORCE_COLOR: "0" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const chunks = [];
    child.stdout.on("data", (chunk) => chunks.push(chunk));
    child.stderr.on("data", (chunk) => chunks.push(chunk));
    child.once("error", (error) => chunks.push(Buffer.from(String(error))));
    child.once("close", (code, signal) => resolvePromise({
      command,
      durationMs: Date.now() - startedAt,
      ok: code === 0,
      output: Buffer.concat(chunks).toString("utf8"),
      status: signal ?? code,
    }));
  });
}

async function runPool(commands, jobs, onResult) {
  const queue = [...commands];
  const results = [];
  const worker = async () => {
    while (queue.length > 0) {
      const result = await runLeaf(queue.shift());
      results.push(result);
      onResult(result);
    }
  };
  await Promise.all(Array.from({ length: Math.min(jobs, commands.length) }, worker));
  return results;
}

function seconds(ms) {
  return `${(ms / 1000).toFixed(1)}s`;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log("Usage: node tools/run-tests-parallel.mjs [SCRIPT=test:built] [--jobs N] [--no-retry] [--report FILE] [--list]");
    return;
  }
  const scripts = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).scripts;
  const leaves = expandScript(scripts, options.script);
  const { parallel, serial } = partitionLeaves(leaves);
  if (options.list) {
    console.log(JSON.stringify({ parallel, serial }, null, 2));
    return;
  }
  const startedAt = Date.now();
  const report = (result, phase) => {
    console.log(`${result.ok ? "✓" : "✗"} [${phase}] ${result.command} (${seconds(result.durationMs)})`);
    if (!result.ok) process.stdout.write(result.output.split("\n").slice(-40).join("\n") + "\n");
  };
  console.log(`Running ${parallel.length} tests on ${options.jobs} workers, then ${serial.length} timing-sensitive tests serially`);
  const results = [
    ...await runPool(parallel, options.jobs, (result) => report(result, "parallel")),
    ...await runPool(serial, 1, (result) => report(result, "serial")),
  ];
  const failed = results.filter((result) => !result.ok);
  const retries = [];
  if (options.retry) {
    for (const failure of failed) {
      const retry = await runLeaf(failure.command);
      retries.push(retry);
      report(retry, "retry");
    }
  }
  const flaky = retries.filter((retry) => retry.ok).map((retry) => retry.command);
  const stillFailing = options.retry
    ? retries.filter((retry) => !retry.ok).map((retry) => retry.command)
    : failed.map((failure) => failure.command);
  const summary = {
    durationMs: Date.now() - startedAt,
    failed: stillFailing,
    flaky,
    jobs: options.jobs,
    script: options.script,
    slowest: [...results].sort((a, b) => b.durationMs - a.durationMs).slice(0, 15)
      .map(({ command, durationMs }) => ({ command, durationMs })),
    tests: results.length,
  };
  if (options.report) {
    mkdirSync(dirname(resolve(options.report)), { recursive: true });
    writeFileSync(resolve(options.report), JSON.stringify({
      ...summary,
      results: results.map(({ command, durationMs, ok, status }) => ({ command, durationMs, ok, status })),
    }, null, 2) + "\n");
  }
  console.log(`\n${results.length} tests in ${seconds(summary.durationMs)}; slowest:`);
  for (const { command, durationMs } of summary.slowest.slice(0, 8)) console.log(`  ${seconds(durationMs).padStart(7)}  ${command}`);
  for (const command of flaky) console.log(`FLAKY (passed on isolated retry): ${command}`);
  if (stillFailing.length > 0) {
    for (const command of stillFailing) console.log(`FAILED: ${command}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
