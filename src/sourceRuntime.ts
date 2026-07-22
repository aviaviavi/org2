import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { findConfigFile, loadConfig, type Org2ExternalSourceConfig } from "./config.js";
import { org2CorpusIndexDir } from "./indexPaths.js";
import { importCrawlerArchive } from "./sourceIngestion.js";

export type SourceBinding = {
  binary?: string;
  configPath?: string;
  workingDirectory?: string;
};

type SourceBindingsEnvelope = {
  schemaVersion: 1;
  bindings: Record<string, SourceBinding>;
};

type SourceStatus = {
  id: string;
  type: "slack" | "notion";
  enabled: boolean;
  scopes: string[];
  workspaceId?: string;
  rawZone: string;
  reviewZone: string;
  ingestionSince?: string;
  ingestionLimit: number;
  syncArgs: string[];
  media: "lazy" | "metadata-only";
  schedule?: {
    enabled: boolean;
    kind: "interval" | "daily";
    everyMinutes?: number;
    time?: string;
    timezone: string;
  };
  bindingPath: string;
  binary: string;
  binaryAvailable: boolean;
  configPath?: string;
  configAvailable: boolean;
  ready: boolean;
};

const DEFAULT_CRAWLER_TIMEOUT_MS = 30 * 60_000;
const MAX_CRAWLER_TIMEOUT_SECONDS = 24 * 60 * 60;

function normalizedSchedule(id: string, profile: Org2ExternalSourceConfig): SourceStatus["schedule"] {
  const schedule = profile.schedule;
  if (!schedule) return undefined;
  const timezone = String(schedule.timezone || "local").trim() || "local";
  if (timezone !== "local") {
    try {
      new Intl.DateTimeFormat("en-US", { timeZone: timezone }).format(new Date());
    } catch {
      throw new Error(`external source ${id} schedule timezone is invalid: ${timezone}`);
    }
  }
  if (schedule.kind === "interval") {
    const everyMinutes = Number(schedule.everyMinutes);
    if (!Number.isInteger(everyMinutes) || everyMinutes <= 0) {
      throw new Error(`external source ${id} interval schedule requires a positive integer everyMinutes`);
    }
    return { enabled: schedule.enabled !== false, kind: "interval", everyMinutes, timezone };
  }
  if (schedule.kind === "daily") {
    const time = String(schedule.time || "").trim();
    if (!/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(time)) {
      throw new Error(`external source ${id} daily schedule requires time in HH:MM form`);
    }
    return { enabled: schedule.enabled !== false, kind: "daily", time, timezone };
  }
  throw new Error(`external source ${id} schedule kind must be interval or daily`);
}

function usage(): string {
  return `External source commands:
  org2 source list [--dir CORPUS] [--json]
  org2 source doctor [PROFILE...] [--timeout SECONDS] [--dir CORPUS] [--json]
  org2 source bind PROFILE [--binary PATH] [--config PATH] [--working-directory PATH] [--dir CORPUS] [--apply] [--json]
  org2 source status [PROFILE...] [--timeout SECONDS] [--dir CORPUS] [--json]
  org2 source import [PROFILE...] [--since 14d|TIMESTAMP] [--limit N] [--timeout SECONDS] [--dir CORPUS] [--apply] [--json]
  org2 source sync [PROFILE...] [--ingest] [--since 14d|TIMESTAMP] [--limit N] [--timeout SECONDS] [--dir CORPUS] [--apply] [--json]

The corpus declares non-secret externalSources in org2.json. Machine-local bindings are stored
outside the corpus under ORG2_INDEX_HOME (or ~/.org2/index). Sync delegates to slacrawl/notcrawl.`;
}

function optionValue(args: string[], index: number, option: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("-")) throw new Error(`${option} requires a value`);
  return value;
}

function parseArgs(args: string[]) {
  const positional: string[] = [];
  let dir = "";
  let json = false;
  let apply = false;
  let ingest = false;
  let binary: string | undefined;
  let configPath: string | undefined;
  let workingDirectory: string | undefined;
  let since: string | undefined;
  let limit: number | undefined;
  let timeoutMs = DEFAULT_CRAWLER_TIMEOUT_MS;
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i]!;
    if (arg === "--dir") {
      dir = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--json") json = true;
    else if (arg === "--format") {
      const format = optionValue(args, i, arg);
      i += 1;
      if (format !== "json") throw new Error("source --format must be json");
      json = true;
    } else if (arg === "--apply") apply = true;
    else if (arg === "--ingest") ingest = true;
    else if (arg === "--binary") {
      binary = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--config") {
      configPath = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--working-directory") {
      workingDirectory = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--since") {
      since = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--limit") {
      const value = Number(optionValue(args, i, arg));
      if (!Number.isInteger(value) || value <= 0) throw new Error("source --limit must be a positive integer");
      limit = value;
      i += 1;
    } else if (arg === "--timeout") {
      const seconds = Number(optionValue(args, i, arg));
      if (!Number.isFinite(seconds) || seconds <= 0 || seconds > MAX_CRAWLER_TIMEOUT_SECONDS) {
        throw new Error(`source --timeout must be a positive number of seconds no greater than ${MAX_CRAWLER_TIMEOUT_SECONDS}`);
      }
      timeoutMs = Math.max(1, Math.ceil(seconds * 1_000));
      i += 1;
    } else if (arg === "--help" || arg === "-h") positional.push("help");
    else if (arg.startsWith("-")) throw new Error(`unknown source option: ${arg}`);
    else positional.push(arg);
  }
  return { positional, dir, json, apply, ingest, binary, configPath, workingDirectory, since, limit, timeoutMs };
}

function resolveCorpus(dir: string): { root: string; profiles: Record<string, Org2ExternalSourceConfig> } {
  const start = path.resolve(dir || process.cwd());
  const configFile = findConfigFile(start);
  if (!configFile) throw new Error(`no org2.json found from ${start}`);
  const root = path.dirname(configFile);
  return { root, profiles: loadConfig(configFile).externalSources || {} };
}

export function sourceBindingsPath(root: string): string {
  return path.join(org2CorpusIndexDir(root), "source-bindings-v1.json");
}

function readBindings(root: string): SourceBindingsEnvelope {
  const file = sourceBindingsPath(root);
  if (!fs.existsSync(file)) return { schemaVersion: 1, bindings: {} };
  const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as SourceBindingsEnvelope;
  if (parsed.schemaVersion !== 1 || !parsed.bindings || typeof parsed.bindings !== "object") {
    throw new Error(`invalid source bindings file: ${file}`);
  }
  return parsed;
}

function binaryFor(profile: Org2ExternalSourceConfig, binding: SourceBinding): string {
  return binding.binary || (profile.type === "slack" ? "slacrawl" : "notcrawl");
}

function configFor(profile: Org2ExternalSourceConfig, binding: SourceBinding): string {
  return path.resolve(binding.configPath || path.join(os.homedir(), profile.type === "slack" ? ".slacrawl/config.toml" : ".notcrawl/config.toml"));
}

function commandAvailable(binary: string): boolean {
  if (binary.includes(path.sep)) return fs.existsSync(path.resolve(binary));
  return spawnSync("/usr/bin/env", ["which", binary], { encoding: "utf8" }).status === 0;
}

function statuses(root: string, profiles: Record<string, Org2ExternalSourceConfig>): SourceStatus[] {
  const bindingFile = sourceBindingsPath(root);
  const bindings = readBindings(root).bindings;
  return Object.entries(profiles).sort(([a], [b]) => a.localeCompare(b)).map(([id, profile]) => {
    const binding = bindings[id] || {};
    const binary = binaryFor(profile, binding);
    const configPath = configFor(profile, binding);
    const binaryAvailable = commandAvailable(binary);
    const configAvailable = fs.existsSync(configPath);
    return {
      id,
      type: profile.type,
      enabled: profile.enabled !== false,
      scopes: profile.scopes || [],
      ...(profile.workspaceId ? { workspaceId: profile.workspaceId } : {}),
      rawZone: profile.rawZone || `raw/connectors/${profile.type}/${id}`,
      reviewZone: profile.ingestion?.reviewZone || `views/connectors/${profile.type}/${id}`,
      ...(profile.ingestion?.since ? { ingestionSince: profile.ingestion.since } : {}),
      ingestionLimit: profile.ingestion?.maxItems || 5_000,
      syncArgs: profile.syncArgs || (profile.type === "slack" ? ["--source", "api", "--latest-only"] : ["--source", "api"]),
      media: profile.media || "metadata-only",
      ...(profile.schedule ? { schedule: normalizedSchedule(id, profile) } : {}),
      bindingPath: bindingFile,
      binary,
      binaryAvailable,
      configPath,
      configAvailable,
      ready: profile.enabled !== false && binaryAvailable && configAvailable,
    };
  });
}

function emit(value: unknown, json: boolean): void {
  if (json) process.stdout.write(JSON.stringify(value, null, 2) + "\n");
  else if (Array.isArray(value)) {
    for (const item of value as SourceStatus[]) {
      process.stdout.write(`${item.id}\t${item.type}\t${item.ready ? "ready" : item.enabled ? "needs-setup" : "disabled"}\t${item.binary}\n`);
    }
  } else if (value && typeof value === "object" && "sources" in value) {
    const payload = value as { ok?: boolean; sources: Array<SourceStatus & { doctorOk?: boolean }> };
    process.stdout.write(`${payload.ok === false ? "Source checks need attention" : "Source checks passed"}\n`);
    for (const item of payload.sources) process.stdout.write(`${item.id}\t${item.doctorOk ? "ready" : item.enabled ? "needs-setup" : "disabled"}\n`);
  } else process.stdout.write(String(value) + "\n");
}

function truncateOutput(value: string | null | undefined, max = 8_000): string {
  const text = value || "";
  return text.length <= max ? text : `${text.slice(0, max)}\n… ${text.length - max} characters omitted`;
}

function crawlerProcessError(binary: string, error: Error | undefined, timeoutMs: number): string | undefined {
  if (!error) return undefined;
  if ((error as NodeJS.ErrnoException).code === "ETIMEDOUT") {
    return `${path.basename(binary)} timed out after ${timeoutMs / 1_000} seconds`;
  }
  return `${path.basename(binary)} failed: ${error.message}`;
}

export async function runSourceCommand(args: string[]): Promise<boolean> {
  if (args[0] !== "source" && args[0] !== "sources") return false;
  const parsed = parseArgs(args.slice(1));
  const action = parsed.positional.shift() || "list";
  if (action === "help") { process.stdout.write(usage() + "\n"); return true; }
  const { root, profiles } = resolveCorpus(parsed.dir);
  const selected = parsed.positional;
  const select = <T extends { id: string }>(items: T[]) => selected.length ? items.filter((item) => selected.includes(item.id)) : items;
  if (selected.some((id) => !profiles[id])) throw new Error(`unknown external source profile: ${selected.find((id) => !profiles[id])}`);

  if (action === "list" || action === "doctor") {
    const result = select(statuses(root, profiles));
    if (action === "list") emit(result, parsed.json);
    else {
      const checked = result.map((item) => {
        if (!item.enabled || !item.ready) return { ...item, doctorOk: false };
        const child = spawnSync(item.binary, ["--config", item.configPath!, "doctor", "--json"], {
          encoding: "utf8",
          env: process.env,
          timeout: parsed.timeoutMs,
          killSignal: "SIGTERM",
        });
        const doctorError = crawlerProcessError(item.binary, child.error, parsed.timeoutMs);
        return {
          ...item,
          doctorOk: child.status === 0 && !doctorError,
          doctorStatus: child.status,
          ...(doctorError ? { doctorError } : {}),
          ...(parsed.json ? { doctorStdout: child.stdout, doctorStderr: child.stderr } : {}),
        };
      });
      const ok = checked.every((item) => !item.enabled || item.doctorOk);
      emit({ schema: "org2:source-doctor:v1", root, ok, sources: checked }, parsed.json);
      if (!ok) process.exitCode = 1;
    }
    return true;
  }

  if (action === "status") {
    const result = [];
    for (const item of select(statuses(root, profiles))) {
      if (!item.enabled || !item.ready) {
        result.push({ id: item.id, ok: false, skipped: true, error: "source binding is not ready; run org2 source doctor" });
        continue;
      }
      const child = spawnSync(item.binary, ["--config", item.configPath!, "status", "--json"], {
        encoding: "utf8",
        env: process.env,
        maxBuffer: 16 * 1024 * 1024,
        timeout: parsed.timeoutMs,
        killSignal: "SIGTERM",
      });
      const processError = crawlerProcessError(item.binary, child.error, parsed.timeoutMs);
      let crawlerStatus: unknown;
      try { crawlerStatus = JSON.parse(child.stdout || "null"); } catch { crawlerStatus = null; }
      result.push({
        id: item.id,
        type: item.type,
        ok: child.status === 0 && crawlerStatus !== null && !processError,
        status: child.status,
        crawlerStatus,
        ...(processError ? { error: processError } : {}),
        ...(child.status === 0 ? {} : { stderr: truncateOutput(child.stderr) }),
      });
    }
    emit({ schema: "org2:source-status:v1", root, sources: result }, parsed.json);
    if (result.some((item) => !item.ok)) process.exitCode = 1;
    return true;
  }

  if (action === "bind") {
    const id = selected[0];
    if (!id || selected.length !== 1) throw new Error("org2 source bind requires exactly one PROFILE");
    const envelope = readBindings(root);
    const current = envelope.bindings[id] || {};
    const next = {
      ...current,
      ...(parsed.binary !== undefined ? { binary: parsed.binary } : {}),
      ...(parsed.configPath !== undefined ? { configPath: path.resolve(parsed.configPath) } : {}),
      ...(parsed.workingDirectory !== undefined ? { workingDirectory: path.resolve(parsed.workingDirectory) } : {}),
    };
    const preview = { profile: id, bindingPath: sourceBindingsPath(root), binding: next, applied: parsed.apply };
    if (parsed.apply) {
      fs.mkdirSync(path.dirname(preview.bindingPath), { recursive: true });
      envelope.bindings[id] = next;
      fs.writeFileSync(preview.bindingPath, JSON.stringify(envelope, null, 2) + "\n", { mode: 0o600 });
      try { fs.chmodSync(preview.bindingPath, 0o600); } catch {}
    }
    emit(preview, parsed.json);
    return true;
  }

  if (action === "import") {
    const allStatuses = statuses(root, profiles);
    const requested = select(allStatuses).filter((item) => item.enabled);
    const results = requested.map((status) => {
      if (!status.ready) return { id: status.id, ok: false, skipped: true, error: "source binding is not ready; run org2 source doctor" };
      try {
        const imported = importCrawlerArchive({
          root,
          profileId: status.id,
          profile: profiles[status.id]!,
          binary: status.binary,
          configPath: status.configPath!,
          since: parsed.since,
          limit: parsed.limit,
          timeoutMs: parsed.timeoutMs,
          apply: parsed.apply,
        });
        return { id: status.id, ok: true, imported };
      } catch (error) {
        return { id: status.id, ok: false, error: error instanceof Error ? error.message : String(error) };
      }
    });
    emit({ schema: "org2:source-import-run:v1", root, applied: parsed.apply, results }, parsed.json);
    if (results.some((result) => !result.ok)) process.exitCode = 1;
    return true;
  }

  if (action === "sync") {
    const allStatuses = statuses(root, profiles);
    const requested = select(allStatuses).filter((item) => item.enabled);
    const bindings = readBindings(root).bindings;
    const results = [];
    for (const status of requested) {
      if (!status.ready) {
        results.push({ id: status.id, ok: false, skipped: true, error: "source binding is not ready; run org2 source doctor" });
        continue;
      }
      const profile = profiles[status.id]!;
      const binding = bindings[status.id] || {};
      const crawlerArgs = [
        "--config", configFor(profile, binding),
        "sync",
        ...(profile.syncArgs || (profile.type === "slack" ? ["--source", "api", "--latest-only"] : ["--source", "api"])),
      ];
      const lockDir = path.join(org2CorpusIndexDir(root), `source-${status.id}.lock`);
      try {
        fs.mkdirSync(lockDir);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "EEXIST") {
          results.push({ id: status.id, ok: false, skipped: true, error: "sync already running on this machine" });
          continue;
        }
        throw error;
      }
      try {
        const child = spawnSync(status.binary, crawlerArgs, {
          cwd: binding.workingDirectory ? path.resolve(binding.workingDirectory) : root,
          encoding: "utf8",
          stdio: parsed.json ? "pipe" : "inherit",
          env: process.env,
          timeout: parsed.timeoutMs,
          killSignal: "SIGTERM",
        });
        const processError = crawlerProcessError(status.binary, child.error, parsed.timeoutMs);
        const ok = child.status === 0 && !processError;
        let imported: unknown;
        if (ok && parsed.ingest) {
          try {
            imported = importCrawlerArchive({
              root,
              profileId: status.id,
              profile,
              binary: status.binary,
              configPath: status.configPath!,
              since: parsed.since,
              limit: parsed.limit,
              timeoutMs: parsed.timeoutMs,
              apply: parsed.apply,
            });
          } catch (error) {
            results.push({
              id: status.id,
              ok: false,
              status: child.status,
              error: `crawler sync succeeded but Org2 import failed: ${error instanceof Error ? error.message : String(error)}`,
              ...(parsed.json ? { stdout: truncateOutput(child.stdout), stderr: truncateOutput(child.stderr) } : {}),
            });
            continue;
          }
        }
        results.push({
          id: status.id,
          ok,
          status: child.status,
          signal: child.signal,
          ...(processError ? { error: processError } : {}),
          ...(imported ? { imported } : {}),
          ...(parsed.json ? { stdout: truncateOutput(child.stdout), stderr: truncateOutput(child.stderr) } : {}),
        });
      } finally {
        fs.rmdirSync(lockDir);
      }
    }
    if (parsed.json) emit({ schema: "org2:source-sync:v1", root, results }, true);
    if (results.some((result) => !result.ok)) process.exitCode = 1;
    return true;
  }

  throw new Error(`unknown source action: ${action}\n${usage()}`);
}
