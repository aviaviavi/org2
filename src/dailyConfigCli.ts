import fs from "node:fs";
import path from "node:path";
import { guardedContentRevision, guardedWriteFile } from "./guardedFile.js";
import type { Org2Config } from "./config.js";
import {
  configuredDailyNoteTemplate,
  dailyNoteDateFromIso,
  dailyNoteDateToIso,
  dailyNoteTemplateProblem,
  inferDailyNoteTemplates,
  localDailyNoteDate,
  resolveDailyNotePath,
  type DailyNoteDate,
} from "./dailyNoteTemplate.js";
import { configFilePath } from "./brandNames.js";

const HELP = `celorga daily-config <show|infer|set> --dir CORPUS [options]

Reads, infers, or previews where daily notes live. Output is JSON.

  show   [--date YYYY-MM-DD]
         Print the configured format and the resolved yesterday/today/tomorrow
         paths (or one --date), with whether each file exists.
  infer  --file PATH [--date YYYY-MM-DD]
         Suggest formats from one existing daily note. PATH may be absolute or
         relative to the corpus. --date is the reference date used to rank
         ambiguous examples (default: today).
  set    (--template FORMAT | --clear) [--if-revision REVISION] [--apply]
         Preview or write roam.dailyFileTemplate in celorga.json. --clear restores
         the dailiesDir/YYYY-MM-DD.org convention.

Formats are corpus-relative paths with date tokens:
  {YYYY} {YY} {MM} {M} {DD} {D} {MMM} {MMMM} {ddd} {dddd}
Example: journal/{YYYY}/{MM}/{YYYY}-{MM}-{DD}-wind-down.md
Writes require --apply; use --if-revision from show/preview to reject stale edits.`;

type Flags = Map<string, string>;

function parseFlags(rest: string[]): { flags: Flags; apply: boolean; clear: boolean } {
  const flags: Flags = new Map();
  let apply = false;
  let clear = false;
  for (let i = 0; i < rest.length; i++) {
    const key = rest[i];
    if (key === "--apply") { apply = true; continue; }
    if (key === "--clear") { clear = true; continue; }
    if (key === "--json") continue;
    if (!["--dir", "--template", "--file", "--date", "--if-revision"].includes(key)) {
      throw new Error(`Unknown daily-config option: ${key}`);
    }
    const value = rest[++i];
    if (value === undefined || flags.has(key)) throw new Error(`Missing or repeated ${key}.`);
    flags.set(key, value);
  }
  return { flags, apply, clear };
}

function readConfig(file: string): { raw?: string; revision: string; config: Org2Config & Record<string, unknown> } {
  const raw = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : undefined;
  const revision = raw === undefined ? "absent" : guardedContentRevision(raw);
  const config = raw === undefined ? {} : JSON.parse(raw);
  if (!config || Array.isArray(config) || typeof config !== "object") throw new Error(`${path.basename(file)} must contain an object.`);
  if (config.roam !== undefined && (!config.roam || Array.isArray(config.roam) || typeof config.roam !== "object")) {
    throw new Error(`${path.basename(file)} roam must contain an object.`);
  }
  return { raw, revision, config };
}

function describePath(config: Org2Config, root: string, date: DailyNoteDate) {
  const file = resolveDailyNotePath(config, root, date);
  return {
    date: dailyNoteDateToIso(date),
    file,
    relativePath: path.relative(root, file).split(path.sep).join("/"),
    exists: fs.existsSync(file) && fs.statSync(file).isFile(),
  };
}

function previews(config: Org2Config, root: string, date?: DailyNoteDate) {
  if (date) return { date: describePath(config, root, date) };
  return {
    yesterday: describePath(config, root, localDailyNoteDate(new Date(), -1)),
    today: describePath(config, root, localDailyNoteDate()),
    tomorrow: describePath(config, root, localDailyNoteDate(new Date(), 1)),
  };
}

export async function runDailyConfigCommand(args: string[]): Promise<void> {
  if (args.includes("--help") || args.includes("-h")) {
    console.log(HELP);
    return;
  }
  const [action = "show", ...rest] = args;
  if (!["show", "infer", "set"].includes(action)) throw new Error("daily-config action must be show, infer, or set.");
  const { flags, apply, clear } = parseFlags(rest);
  const root = path.resolve(flags.get("--dir") ?? process.cwd());
  const file = configFilePath(root);
  const date = flags.has("--date") ? dailyNoteDateFromIso(flags.get("--date")!) : undefined;
  const { raw, revision, config } = readConfig(file);
  const expected = flags.get("--if-revision");
  if (expected !== undefined && expected !== revision) {
    throw new Error("Corpus settings changed since they were loaded. Reload the settings before saving.");
  }
  const current = configuredDailyNoteTemplate(config);

  if (action === "show") {
    if (apply || clear || flags.has("--template") || flags.has("--file")) throw new Error("Use daily-config set to change the format.");
    const problem = current ? dailyNoteTemplateProblem(current) : null;
    console.log(JSON.stringify({
      schema: "org2:daily-config:v1", file, revision, template: current, problem,
      effective: current && !problem ? "template" : "dailiesDir",
      paths: previews(config, root, date),
    }, null, 2));
    return;
  }

  if (action === "infer") {
    const example = flags.get("--file");
    if (!example) throw new Error("daily-config infer requires --file PATH.");
    const absolute = path.resolve(root, example);
    const relative = path.relative(root, absolute);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
      throw new Error("Choose a daily note inside the corpus folder.");
    }
    const relativePath = relative.split(path.sep).join("/");
    const candidates = inferDailyNoteTemplates(relativePath, date ?? localDailyNoteDate()).map((candidate) => {
      const candidateConfig: Org2Config = { ...config, roam: { ...config.roam, dailyFileTemplate: candidate.template } };
      return { ...candidate, paths: previews(candidateConfig, root) };
    });
    console.log(JSON.stringify({
      schema: "org2:daily-config-inference:v1", file, revision, example: relativePath,
      exampleExists: fs.existsSync(absolute), candidates,
    }, null, 2));
    return;
  }

  if (clear === flags.has("--template")) throw new Error("daily-config set requires exactly one of --template FORMAT or --clear.");
  const next = clear ? null : flags.get("--template")!.trim();
  if (next !== null) {
    const problem = dailyNoteTemplateProblem(next);
    if (problem) throw new Error(problem);
  }
  const changed = next !== current;
  const updatedConfig: Org2Config & Record<string, unknown> = { ...config };
  const roam: Record<string, unknown> = { ...(config.roam ?? {}) };
  if (next === null) delete roam.dailyFileTemplate; else roam.dailyFileTemplate = next;
  if (Object.keys(roam).length) updatedConfig.roam = roam; else delete updatedConfig.roam;
  let outputRevision = revision;
  if (changed && apply) {
    const written = guardedWriteFile(file, `${JSON.stringify(updatedConfig, null, 2)}\n`, {
      expectedRevision: raw === undefined ? null : revision, preserveMode: true,
    });
    outputRevision = written.revision;
  }
  console.log(JSON.stringify({
    schema: "org2:daily-config:v1", file, revision: outputRevision, template: next, previous: current,
    effective: next ? "template" : "dailiesDir",
    changed, applied: changed && apply,
    paths: previews(updatedConfig, root, date),
  }, null, 2));
}
