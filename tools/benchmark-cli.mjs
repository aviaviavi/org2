#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const toolsDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(toolsDir, "..");
const cliPath = path.join(repoRoot, "dist", "cli.js");

function usage() {
  process.stdout.write(`Org2 CLI benchmark

Usage:
  npm run benchmark:cli -- --dir CORPUS [--suite interactive|full] [--runs N] [--query TEXT] [--json]

The benchmark only runs read-only corpus commands. Full index builds write to
an isolated temporary index directory that is removed when the run completes.
`);
}

function parseArgs(argv) {
  const parsed = {
    dir: "",
    suite: "interactive",
    runs: 3,
    query: "org2",
    json: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (arg === "--json") {
      parsed.json = true;
      continue;
    }
    const value = argv[index + 1];
    if (arg === "--dir") parsed.dir = value || "";
    else if (arg === "--suite") parsed.suite = value || "";
    else if (arg === "--runs") parsed.runs = Number.parseInt(value || "", 10);
    else if (arg === "--query") parsed.query = value || "";
    else throw new Error(`unknown argument: ${arg}`);
    index += 1;
  }

  if (!parsed.dir) throw new Error("--dir CORPUS is required");
  if (!["interactive", "full"].includes(parsed.suite)) {
    throw new Error("--suite must be interactive or full");
  }
  if (!Number.isInteger(parsed.runs) || parsed.runs < 1 || parsed.runs > 20) {
    throw new Error("--runs must be an integer from 1 to 20");
  }
  if (!parsed.query.trim()) throw new Error("--query must not be empty");
  return parsed;
}

function expandHome(input) {
  if (input === "~") return os.homedir();
  if (input.startsWith("~/")) return path.join(os.homedir(), input.slice(2));
  return input;
}

function localDateOffset(days) {
  const date = new Date();
  date.setDate(date.getDate() + days);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function percentile(sorted, fraction) {
  const index = Math.min(
    sorted.length - 1,
    Math.max(0, Math.ceil(fraction * sorted.length) - 1),
  );
  return sorted[index];
}

function runProcess(executable, args, environment = process.env) {
  return new Promise((resolve, reject) => {
    const started = process.hrtime.bigint();
    const child = spawn(executable, args, {
      cwd: repoRoot,
      env: environment,
      stdio: ["ignore", "ignore", "ignore"],
    });
    child.on("error", reject);
    child.on("close", (code, signal) => {
      resolve({
        milliseconds: Number(process.hrtime.bigint() - started) / 1e6,
        code,
        signal,
      });
    });
  });
}

function benchmarkCases(corpus, query, temporaryIndexHome, suite) {
  const today = localDateOffset(0);
  const end = localDateOffset(6);
  const corpusArgs = ["--dir", corpus, "--recursive"];
  const isolatedSearchEnvironment = { ...process.env, ORG2_INDEX_HOME: path.join(temporaryIndexHome, "search") };
  const isolatedCompileEnvironment = { ...process.env, ORG2_INDEX_HOME: path.join(temporaryIndexHome, "compile") };
  const isolatedContextEnvironment = { ...process.env, ORG2_INDEX_HOME: path.join(temporaryIndexHome, "context") };
  const cases = [
    {
      name: "startup/capabilities",
      args: ["agent", "capabilities"],
    },
    {
      name: "agenda/app refresh",
      args: ["agenda", ...corpusArgs, "--from", today, "--to", end, "--format", "json", "--workload"],
    },
    {
      name: "index/full isolated output",
      args: ["index", ...corpusArgs, "--format", "json"],
      environment: isolatedSearchEnvironment,
    },
    {
      name: "search/current index",
      args: ["search", query, ...corpusArgs, "--limit", "500", "--context", "1", "--index", "current", "--sort", "relevance", "--format", "json"],
      environment: isolatedSearchEnvironment,
    },
    {
      name: "search/full scan",
      args: ["search", query, ...corpusArgs, "--limit", "500", "--context", "1", "--index", "never", "--sort", "relevance", "--format", "json"],
    },
    {
      name: "approvals/full scan",
      args: ["approvals", ...corpusArgs, "--index", "never", "--format", "json"],
    },
  ];

  if (suite === "full") {
    cases.push(
      {
        name: "compile corpus/full",
        args: ["compile", "corpus", ...corpusArgs, "--format", "json"],
      },
      {
        name: "compile corpus/incremental",
        args: ["compile", "corpus", ...corpusArgs, "--incremental", "--format", "json"],
        environment: isolatedCompileEnvironment,
      },
      {
        name: "lint/full corpus",
        args: ["lint", ...corpusArgs, "--format", "json"],
      },
      {
        name: "graph audit/full corpus",
        args: ["graph", "audit", ...corpusArgs, "--format", "json"],
      },
      {
        name: "context/full corpus",
        args: ["context", query, ...corpusArgs, "--budget", "8k", "--format", "json"],
        environment: isolatedContextEnvironment,
      },
    );
  }
  return cases;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const corpus = path.resolve(expandHome(options.dir));
  if (!fs.statSync(corpus).isDirectory()) throw new Error(`not a directory: ${corpus}`);
  if (!fs.existsSync(cliPath)) throw new Error(`CLI not built at ${cliPath}; run npm run build`);

  const temporaryIndexHome = fs.mkdtempSync(path.join(os.tmpdir(), "org2-cli-benchmark-"));
  const results = [];
  try {
    for (const benchmark of benchmarkCases(corpus, options.query, temporaryIndexHome, options.suite)) {
      const samples = [];
      for (let run = 0; run < options.runs; run += 1) {
        samples.push(await runProcess(process.execPath, [cliPath, ...benchmark.args], benchmark.environment));
      }
      const timings = samples.map((sample) => sample.milliseconds).sort((left, right) => left - right);
      results.push({
        name: benchmark.name,
        runs: options.runs,
        firstMs: samples[0].milliseconds,
        medianMs: percentile(timings, 0.5),
        p90Ms: percentile(timings, 0.9),
        minMs: timings[0],
        maxMs: timings[timings.length - 1],
        exitCodes: Array.from(new Set(samples.map((sample) => sample.code))),
        signals: Array.from(new Set(samples.map((sample) => sample.signal).filter(Boolean))),
      });
    }
  } finally {
    if (!temporaryIndexHome.startsWith(`${os.tmpdir()}${path.sep}org2-cli-benchmark-`)) {
      throw new Error(`refusing to remove unexpected temporary path: ${temporaryIndexHome}`);
    }
    fs.rmSync(temporaryIndexHome, { recursive: true, force: true });
  }

  const payload = {
    schema: "org2:cli-benchmark:v1",
    corpus,
    suite: options.suite,
    query: options.query,
    runs: options.runs,
    measuredAt: new Date().toISOString(),
    results,
  };
  if (options.json) {
    process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
  } else {
    process.stdout.write(`Corpus: ${corpus}\nSuite: ${options.suite}; ${options.runs} run(s) per command\n\n`);
    process.stdout.write("| Command | First | Median | p90 | Min | Max | Exit |\n");
    process.stdout.write("|---|---:|---:|---:|---:|---:|---|\n");
    for (const result of results) {
      const format = (milliseconds) => `${(milliseconds / 1000).toFixed(3)}s`;
      process.stdout.write(`| ${result.name} | ${format(result.firstMs)} | ${format(result.medianMs)} | ${format(result.p90Ms)} | ${format(result.minMs)} | ${format(result.maxMs)} | ${result.exitCodes.join(",")} |\n`);
    }
  }

  if (results.some((result) => result.exitCodes.some((code) => code !== 0))) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  process.stderr.write(`benchmark failed: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
