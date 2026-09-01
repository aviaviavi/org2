#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  assertOutputOutsideSourceCorpus,
  cloneReadOnlyPerformanceCorpus,
  generatePerformanceCorpus,
  profilePerformanceCorpus,
} from "./openorg-performance-corpus.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const shapePath = resolve(repoRoot, "test/fixtures/openorg-performance-corpus-shape-v1.json");
const budgetsPath = resolve(repoRoot, "test/fixtures/openorg-performance-budgets-v1.json");
export const performanceChildTimeoutMilliseconds = 25 * 60 * 1_000;

function parseArguments(argv) {
  const options = { keepFixture: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--real-corpus") options.realCorpus = argv[++index];
    else if (argument === "--keep-fixture") options.keepFixture = true;
    else if (argument === "--help" || argument === "-h") options.help = true;
    else throw new Error(`Unknown argument: ${argument}`);
  }
  return options;
}

function usage() {
  return [
    "Usage: node tools/test-macos-performance.mjs [--real-corpus DIR] [--keep-fixture]",
    "",
    "--real-corpus profiles the source read-only, then renders a disposable private clone.",
    "No source contents, names, IDs, or paths are copied into test artifacts.",
  ].join("\n");
}

function readJSONLines(raw) {
  return raw
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

const sourceCorpusEnvironmentKeys = [
  "OPENORG_REAL_CORPUS",
  "OPENORG_PERFORMANCE_REAL_CORPUS",
  "OPENORG_PERFORMANCE_REAL_CORPUS_ROOT",
  "OPENORG_PERFORMANCE_REAL_CORPUS_CLONE",
  "OPENORG_PERFORMANCE_REAL_ATTACHMENT_THREAD_IDS",
];

export function makePerformanceChildEnvironment(baseEnvironment, overrides = {}) {
  const environment = { ...baseEnvironment };
  for (const key of sourceCorpusEnvironmentKeys) delete environment[key];
  return { ...environment, ...overrides };
}

export function runPerformanceChild(
  command,
  args,
  {
    cwd = repoRoot,
    env = process.env,
    stdio = "inherit",
    timeoutMilliseconds = performanceChildTimeoutMilliseconds,
  } = {}
) {
  return spawnSync(command, args, {
    cwd,
    env,
    stdio,
    timeout: timeoutMilliseconds,
    killSignal: "SIGTERM",
  });
}

export function describePerformanceChildFailure(
  result,
  timeoutMilliseconds = performanceChildTimeoutMilliseconds
) {
  if (result.error?.code === "ETIMEDOUT") {
    return `Swift performance tests timed out after ${Math.round(timeoutMilliseconds / 60_000)} minutes`;
  }
  if (result.error) {
    return `Swift performance tests failed to launch (${result.error.code ?? result.error.name ?? "unknown error"})`;
  }
  if (result.signal) {
    return `Swift performance tests terminated by ${result.signal}`;
  }
  if ((result.status ?? 1) !== 0) {
    return `Swift performance tests exited with status ${result.status ?? 1}`;
  }
  return undefined;
}

export async function withPerformanceWorkspaceCleanup(
  {
    temporaryRoot,
    corpusRoot,
    realCorpusCloneRoot,
    indexRoot,
    keepFixture = false,
    log = console.log,
  },
  operation
) {
  try {
    return await operation();
  } finally {
    if (keepFixture) {
      // `--keep-fixture` is only for the privacy-safe generated corpus. Never
      // retain the private real-corpus clone or its derived indexes.
      await rm(realCorpusCloneRoot, { recursive: true, force: true });
      await rm(indexRoot, { recursive: true, force: true });
      log(`Kept privacy-safe generated fixture at ${corpusRoot}`);
    } else {
      await rm(temporaryRoot, { recursive: true, force: true });
    }
  }
}

export function assertRealCorpusIsCovered(realShape, fixtureShape) {
  const failures = [];
  const compare = (label, realValue, fixtureValue) => {
    const realNumber = Number(realValue ?? 0);
    const fixtureNumber = Number(fixtureValue ?? 0);
    if (realNumber > fixtureNumber) {
      failures.push(`${label} grew to ${realNumber}; fixture has ${fixtureNumber}`);
    }
  };

  compare("active documents", realShape.documents.activeFileCount, fixtureShape.documents.activeFileCount);
  compare("root documents", realShape.documents.rootFileCount, fixtureShape.documents.rootFileCount);
  for (const extension of new Set([
    ...Object.keys(realShape.documents.extensionMix ?? {}),
    ...Object.keys(fixtureShape.documents.extensionMix ?? {}),
  ])) {
    compare(
      `${extension} documents`,
      realShape.documents.extensionMix?.[extension],
      fixtureShape.documents.extensionMix?.[extension]
    );
  }
  const realZones = Object.fromEntries(
    (realShape.documents.zones ?? []).map((zone) => [zone.kind, zone.fileCount])
  );
  const fixtureZones = Object.fromEntries(
    (fixtureShape.documents.zones ?? []).map((zone) => [zone.kind, zone.fileCount])
  );
  for (const zone of new Set([...Object.keys(realZones), ...Object.keys(fixtureZones)])) {
    compare(`${zone} zone documents`, realZones[zone], fixtureZones[zone]);
  }
  for (const percentileName of ["p50", "p90", "p95", "p99", "max"]) {
    compare(
      `document ${percentileName} bytes`,
      realShape.documents.sizeBytes?.[percentileName],
      fixtureShape.documents.sizeBytes?.[percentileName]
    );
  }

  for (const [field, label] of [
    ["threadCount", "chat threads"],
    ["activeThreadCount", "active chat threads"],
    ["archivedThreadCount", "archived chat threads"],
    ["messageCount", "chat messages"],
    ["maxMessagesPerThread", "largest chat thread messages"],
    ["attachmentBytes", "decoded chat attachment bytes"],
    ["largestMessageBytes", "largest chat message bytes"],
    ["encodedTranscriptBytes", "encoded chat storage bytes"],
  ]) {
    compare(label, realShape.chat?.[field], fixtureShape.chat?.[field]);
  }

  for (const [field, label] of [
    ["agentRunCount", "agent-run catalog"],
    ["approvalItemCount", "approval catalog"],
    ["externalThreadCount", "external-thread catalog"],
    ["sourceProfileCount", "source profiles"],
  ]) {
    compare(label, realShape.workspaceScale?.[field], fixtureShape.workspaceScale?.[field]);
  }
  if (failures.length > 0) {
    throw new Error(
      `The checked-in OpenOrg performance shape no longer covers the real corpus:\n- ${failures.join("\n- ")}\n` +
      "Refresh the aggregate shape before accepting performance results."
    );
  }
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    console.log(usage());
    return;
  }
  if (process.platform !== "darwin") {
    throw new Error("OpenOrg's macOS performance gate must run on macOS");
  }

  const fixtureShape = JSON.parse(await readFile(shapePath, "utf8"));
  const budgets = JSON.parse(await readFile(budgetsPath, "utf8"));
  if (fixtureShape.$schema !== "org2:openorg-performance-corpus-shape:v1") {
    throw new Error(`Unsupported OpenOrg performance shape: ${fixtureShape.$schema ?? "missing schema"}`);
  }
  if (budgets.$schema !== "org2:openorg-performance-budgets:v1") {
    throw new Error(`Unsupported OpenOrg performance budgets: ${budgets.$schema ?? "missing schema"}`);
  }
  let expectedScenarios = Object.entries(budgets.scenarios)
    .filter(([, budget]) => budget.optional !== true)
    .map(([scenario]) => scenario)
    .sort();
  const knownScenarios = Object.keys(budgets.scenarios).sort();
  const temporaryRoot = await mkdtemp(join(tmpdir(), "openorg-performance-"));
  const corpusRoot = join(temporaryRoot, "corpus");
  const realCorpusCloneRoot = join(temporaryRoot, "real-corpus-clone");
  const indexRoot = join(temporaryRoot, "index");
  const configuredArtifactDirectory = process.env.OPENORG_PERFORMANCE_ARTIFACT_DIR;
  const artifactDirectory = configuredArtifactDirectory
    ? resolve(configuredArtifactDirectory)
    : join(temporaryRoot, "artifacts");
  const resultsPath = join(artifactDirectory, "measurements.jsonl");
  const realCorpus = options.realCorpus
    ?? process.env.OPENORG_REAL_CORPUS
    ?? process.env.OPENORG_PERFORMANCE_REAL_CORPUS
    ?? process.env.OPENORG_PERFORMANCE_REAL_CORPUS_ROOT;

  await withPerformanceWorkspaceCleanup({
    temporaryRoot,
    corpusRoot,
    realCorpusCloneRoot,
    indexRoot,
    keepFixture: options.keepFixture,
  }, async () => {
    if (realCorpus) {
      await Promise.all([
        assertOutputOutsideSourceCorpus(realCorpus, artifactDirectory, "Performance artifact directory"),
        assertOutputOutsideSourceCorpus(realCorpus, resultsPath, "Performance results file"),
        assertOutputOutsideSourceCorpus(realCorpus, realCorpusCloneRoot, "Real-corpus clone"),
        assertOutputOutsideSourceCorpus(realCorpus, indexRoot, "Performance index"),
      ]);
    }
    await mkdir(artifactDirectory, { recursive: true });
    await writeFile(resultsPath, "", { mode: 0o600 });

    const generated = await generatePerformanceCorpus(shapePath, corpusRoot);
    console.log(
      `Generated privacy-safe performance corpus: ${generated.manifest.activeFileCount} documents, ` +
      `${fixtureShape.documents.sizeBytes.max} byte maximum document`
    );

    let realCorpusShape;
    let realCorpusClone;
    if (realCorpus) {
      const realShapePath = join(artifactDirectory, "real-corpus-shape.json");
      realCorpusShape = await profilePerformanceCorpus(realCorpus, realShapePath);
      assertRealCorpusIsCovered(realCorpusShape, fixtureShape);
      realCorpusClone = await cloneReadOnlyPerformanceCorpus(realCorpus, realCorpusCloneRoot);
      expectedScenarios = Object.keys(budgets.scenarios)
        .filter((scenario) => budgets.scenarios[scenario].optional !== true || scenario.startsWith("real-"))
        .sort();
      console.log(
        `Read-only real-corpus snapshot ready: ${realCorpusShape.documents.activeFileCount} active documents, ` +
        `${realCorpusClone.runFileCount} run records, ${realCorpusClone.chatStoreFileCount} sharded chat files`
      );
    }

    const supportsArm64 = spawnSync("sysctl", ["-n", "hw.optional.arm64"], {
      encoding: "utf8",
    }).stdout?.trim() === "1";
    const testArgs = [
      "test",
      "--package-path", "apps/macos/Org2Workspace",
      "--configuration", "release",
      "--filter", "OpenOrgPerformanceGateTests|WorkspacePerformanceRegressionTests",
    ];
    const command = supportsArm64 ? "arch" : "swift";
    const args = supportsArm64
      ? ["-arm64", "swift", ...testArgs, "--arch", "arm64"]
      : testArgs;
    const result = runPerformanceChild(command, args, {
      cwd: repoRoot,
      stdio: "inherit",
      env: makePerformanceChildEnvironment(process.env, {
        OPENORG_PERFORMANCE_CORPUS_ROOT: corpusRoot,
        OPENORG_PERFORMANCE_SHAPE_PATH: shapePath,
        OPENORG_PERFORMANCE_BUDGETS_PATH: budgetsPath,
        OPENORG_PERFORMANCE_RESULTS_PATH: resultsPath,
        ORG2_INDEX_HOME: indexRoot,
        ...(realCorpusClone ? {
          OPENORG_PERFORMANCE_REAL_CORPUS_CLONE: realCorpusClone.root,
        } : {}),
      }),
    });
    const childFailure = describePerformanceChildFailure(result);
    if (childFailure) console.error(childFailure);

    let measurements = [];
    try {
      measurements = readJSONLines(await readFile(resultsPath, "utf8"));
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    const measuredScenarios = [...new Set(measurements.map((measurement) => measurement.scenario))].sort();
    const missingScenarios = expectedScenarios.filter((scenario) => !measuredScenarios.includes(scenario));
    const unexpectedScenarios = measuredScenarios.filter((scenario) => !knownScenarios.includes(scenario));
    const scenarioCounts = measurements.reduce((counts, measurement) => {
      counts.set(measurement.scenario, (counts.get(measurement.scenario) ?? 0) + 1);
      return counts;
    }, new Map());
    const duplicateScenarios = [...scenarioCounts]
      .filter(([, count]) => count !== 1)
      .map(([scenario]) => scenario)
      .sort();
    const invalidMeasurements = measurements.filter((measurement) =>
      measurement.schema !== "org2:openorg-performance-result:v1"
        || measurement.shapeVersion !== fixtureShape.version
        || measurement.budgetVersion !== budgets.version
        || measurement.buildConfiguration !== "release"
        || !Number.isFinite(measurement.p95Milliseconds)
        || !Number.isFinite(measurement.maximumMilliseconds)
    );

    const report = {
      $schema: "org2:openorg-performance-report:v1",
      generatedCorpus: {
        shapeVersion: fixtureShape.version,
        activeFileCount: generated.manifest.activeFileCount,
        maximumDocumentBytes: fixtureShape.documents.sizeBytes.max,
        chatThreadCount: fixtureShape.chat.threadCount,
        chatMessageCount: fixtureShape.chat.messageCount,
        agentRunCount: fixtureShape.workspaceScale.agentRunCount,
      },
      realCorpusValidation: realCorpusShape ? {
        activeFileCount: realCorpusShape.documents.activeFileCount,
        maximumDocumentBytes: realCorpusShape.documents.sizeBytes.max,
        chatThreadCount: realCorpusShape.chat?.threadCount ?? 0,
        chatMessageCount: realCorpusShape.chat?.messageCount ?? 0,
        agentRunCount: realCorpusShape.workspaceScale?.agentRunCount ?? 0,
      } : null,
      swiftTestExitStatus: result.status ?? 1,
      swiftTestSignal: result.signal ?? null,
      swiftTestErrorCode: result.error?.code ?? null,
      expectedScenarios,
      missingScenarios,
      unexpectedScenarios,
      duplicateScenarios,
      invalidMeasurementCount: invalidMeasurements.length,
      measurements: measurements.sort((left, right) => left.scenario.localeCompare(right.scenario)),
    };
    const reportPath = join(artifactDirectory, "openorg-performance-report.json");
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
    await cp(shapePath, join(artifactDirectory, "corpus-shape.json"));
    await cp(budgetsPath, join(artifactDirectory, "budgets.json"));
    console.log(`Performance report: ${reportPath}`);

    if ((result.status ?? 1) !== 0) {
      process.exitCode = result.status ?? 1;
      return;
    }
    if (missingScenarios.length > 0
        || unexpectedScenarios.length > 0
        || duplicateScenarios.length > 0
        || invalidMeasurements.length > 0) {
      throw new Error(
        `Incomplete performance report. Missing: ${missingScenarios.join(", ") || "none"}; ` +
        `unexpected: ${unexpectedScenarios.join(", ") || "none"}; ` +
        `duplicates: ${duplicateScenarios.join(", ") || "none"}; ` +
        `invalid measurements: ${invalidMeasurements.length}`
      );
    }
  });
}

if (fileURLToPath(import.meta.url) === resolve(process.argv[1] ?? "")) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
