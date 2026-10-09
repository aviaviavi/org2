import fs from "node:fs";
import path from "node:path";
import { listOrgLikeFiles } from "./corpusFiles.js";
import {
  CONFIG_FILE,
  LEGACY_CONFIG_FILE,
  LEGACY_PROPERTY_PREFIX,
  LEGACY_STATE_DIR,
  PROPERTY_PREFIX,
  STATE_DIR,
} from "./brandNames.js";

/**
 * `celorga migrate-names`: move one corpus from the pre-rename names to the
 * Celorga names. Preview by default; `--apply` writes. Safe to run again: each
 * step only acts on what is still left over.
 *
 * Steps:
 *   1. org2.json -> celorga.json
 *   2. .org2/ -> .celorga/ (merged entry by entry if both exist; never overwrites)
 *   3. :ORG2_X: property keys and #+ORG2_X: keywords -> CELORGA_X in Org documents
 *      (raw/ is left as captured; text inside #+begin_/#+end_ blocks is untouched)
 *   4. this device's .stignore: every .org2/ pattern gets a .celorga/ twin
 */

export const MIGRATE_NAMES_SCHEMA = "celorga:migrate-names:v1";
const LIVE_WINDOW_MS = 10 * 60 * 1000;

export type PropertyFileChange = { file: string; renamed: number; droppedDuplicates: number; conflicts: string[] };

export type MigrateNamesPlan = {
  $schema: string;
  root: string;
  applied: boolean;
  config: { action: "rename" | "none" | "conflict"; from?: string; to?: string; note?: string };
  stateDir: { action: "rename" | "merge" | "none"; from?: string; to?: string; entries?: number; conflicts?: string[] };
  properties: { files: PropertyFileChange[]; keys: number; conflicts: number };
  stignore: { file?: string; add: string[] };
  liveHosts: Array<{ name: string; kind: string; updatedAt: string }>;
  blocked?: string;
  nothingToDo: boolean;
};

const BLOCK_BEGIN = /^\s*#\+begin_/i;
const BLOCK_END = /^\s*#\+end_/i;
const DRAWER_START = /^\s*:PROPERTIES:\s*$/i;
const DRAWER_END = /^\s*:END:\s*$/i;
const LEGACY_PROPERTY_LINE = new RegExp(`^(\\s*):${LEGACY_PROPERTY_PREFIX}([A-Z0-9_]+)(\\+?):(.*)$`, "i");
const LEGACY_KEYWORD_LINE = new RegExp(`^(\\s*)#\\+${LEGACY_PROPERTY_PREFIX}([A-Z0-9_]+):(.*)$`, "i");

/**
 * Rename ORG2_ keys in property drawers and #+ORG2_ keywords. When a drawer
 * already holds the Celorga key, an identical legacy line is dropped and a
 * different one is left in place and reported, so no value is ever lost.
 */
export function migratePropertyText(text: string): { text: string; renamed: number; droppedDuplicates: number; conflicts: string[] } {
  const eol = text.includes("\r\n") ? "\r\n" : "\n";
  const lines = text.split(/\r?\n/);
  let renamed = 0;
  let droppedDuplicates = 0;
  const conflicts: string[] = [];
  let inBlock = false;
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]!;
    if (inBlock) { if (BLOCK_END.test(line)) inBlock = false; continue; }
    if (BLOCK_BEGIN.test(line)) { inBlock = true; continue; }
    const keyword = LEGACY_KEYWORD_LINE.exec(line);
    if (keyword) {
      lines[index] = `${keyword[1]}#+${PROPERTY_PREFIX}${keyword[2]!.toUpperCase()}:${keyword[3]}`;
      renamed++;
      continue;
    }
    if (!DRAWER_START.test(line)) continue;
    let end = index + 1;
    while (end < lines.length && !DRAWER_END.test(lines[end]!) && !/^\*+\s/.test(lines[end]!)) end++;
    if (end >= lines.length || !DRAWER_END.test(lines[end]!)) continue;
    const modernValues = new Map<string, string>();
    for (let i = index + 1; i < end; i++) {
      const modern = new RegExp(`^\\s*:${PROPERTY_PREFIX}([A-Z0-9_]+)(\\+?):(.*)$`, "i").exec(lines[i]!);
      if (modern) modernValues.set(`${modern[1]!.toUpperCase()}${modern[2]}`, modern[3]!.trim());
    }
    const drop = new Set<number>();
    for (let i = index + 1; i < end; i++) {
      const legacy = LEGACY_PROPERTY_LINE.exec(lines[i]!);
      if (!legacy) continue;
      const key = `${legacy[2]!.toUpperCase()}${legacy[3]}`;
      const existing = modernValues.get(key);
      if (existing === undefined) {
        lines[i] = `${legacy[1]}:${PROPERTY_PREFIX}${legacy[2]!.toUpperCase()}${legacy[3]}:${legacy[4]}`;
        modernValues.set(key, legacy[4]!.trim());
        renamed++;
      } else if (existing === legacy[4]!.trim()) {
        drop.add(i);
        droppedDuplicates++;
      } else {
        conflicts.push(`line ${i + 1}: ${LEGACY_PROPERTY_PREFIX}${legacy[2]} differs from ${PROPERTY_PREFIX}${legacy[2]}`);
      }
    }
    if (drop.size) {
      for (const i of [...drop].sort((a, b) => b - a)) lines.splice(i, 1);
      end -= drop.size;
    }
    index = end;
  }
  return { text: lines.join(eol), renamed, droppedDuplicates, conflicts };
}

function readLiveHosts(stateRoot: string, now: number): MigrateNamesPlan["liveHosts"] {
  const directory = path.join(stateRoot, "openclaw-chat.store", "live");
  if (!fs.existsSync(directory)) return [];
  const hosts: MigrateNamesPlan["liveHosts"] = [];
  for (const name of fs.readdirSync(directory)) {
    if (!name.endsWith(".json")) continue;
    const file = path.join(directory, name);
    try {
      const stat = fs.statSync(file);
      if (now - stat.mtimeMs > LIVE_WINDOW_MS) continue;
      const record = JSON.parse(fs.readFileSync(file, "utf8")) as { isOnline?: boolean; hostName?: string; hostKind?: string };
      if (record.isOnline === false) continue;
      hosts.push({ name: record.hostName || name, kind: record.hostKind || "unknown", updatedAt: stat.mtime.toISOString() });
    } catch {
      // A presence file mid-write is still a live host.
      hosts.push({ name, kind: "unknown", updatedAt: new Date(now).toISOString() });
    }
  }
  return hosts;
}

function relativeEntries(root: string, directory = root): string[] {
  const result: string[] = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory() && !entry.isSymbolicLink()) result.push(...relativeEntries(root, full));
    else result.push(path.relative(root, full));
  }
  return result;
}

function stignoreAdditions(file: string): string[] {
  if (!fs.existsSync(file)) return [];
  const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
  const present = new Set(lines.map((line) => line.trim()));
  const additions: string[] = [];
  const legacy = new RegExp(`(^|[/!*(])${LEGACY_STATE_DIR.replace(".", "\\.")}(?=/|$)`);
  for (const line of lines) {
    if (!legacy.test(line)) continue;
    const twin = line.replace(legacy, `$1${STATE_DIR}`);
    if (!present.has(twin.trim()) && !additions.includes(twin)) additions.push(twin);
  }
  return additions;
}

export function planMigrateNames(rootInput: string, now = Date.now()): MigrateNamesPlan {
  const root = path.resolve(rootInput);
  if (!fs.statSync(root).isDirectory()) throw new Error(`${root} is not a directory`);
  const legacyConfig = path.join(root, LEGACY_CONFIG_FILE);
  const modernConfig = path.join(root, CONFIG_FILE);
  const legacyState = path.join(root, LEGACY_STATE_DIR);
  const modernState = path.join(root, STATE_DIR);

  const config: MigrateNamesPlan["config"] = !fs.existsSync(legacyConfig)
    ? { action: "none" }
    : fs.existsSync(modernConfig)
      ? fs.readFileSync(legacyConfig, "utf8") === fs.readFileSync(modernConfig, "utf8")
        ? { action: "rename", from: LEGACY_CONFIG_FILE, to: CONFIG_FILE, note: "identical copy; the legacy file is removed" }
        : { action: "conflict", from: LEGACY_CONFIG_FILE, to: CONFIG_FILE, note: `both exist and differ; ${CONFIG_FILE} is in use. Merge by hand, then delete ${LEGACY_CONFIG_FILE}.` }
      : { action: "rename", from: LEGACY_CONFIG_FILE, to: CONFIG_FILE };

  let stateDir: MigrateNamesPlan["stateDir"] = { action: "none" };
  if (fs.existsSync(legacyState) && fs.statSync(legacyState).isDirectory()) {
    if (!fs.existsSync(modernState)) {
      stateDir = { action: "rename", from: LEGACY_STATE_DIR, to: STATE_DIR };
    } else {
      const entries = relativeEntries(legacyState);
      const conflicts = entries.filter((entry) => fs.existsSync(path.join(modernState, entry)));
      stateDir = { action: "merge", from: LEGACY_STATE_DIR, to: STATE_DIR, entries: entries.length - conflicts.length, conflicts };
    }
  }

  const files: PropertyFileChange[] = [];
  for (const file of listOrgLikeFiles(root, true, true)) {
    const relative = path.relative(root, file);
    if (relative.split(path.sep)[0] === "raw") continue;
    const text = fs.readFileSync(file, "utf8");
    if (!text.toUpperCase().includes(LEGACY_PROPERTY_PREFIX)) continue;
    const result = migratePropertyText(text);
    if (result.renamed || result.droppedDuplicates || result.conflicts.length) {
      files.push({ file: relative, renamed: result.renamed, droppedDuplicates: result.droppedDuplicates, conflicts: result.conflicts });
    }
  }

  const stignoreFile = path.join(root, ".stignore");
  const stignore = { ...(fs.existsSync(stignoreFile) ? { file: ".stignore" } : {}), add: stignoreAdditions(stignoreFile) };
  const liveHosts = [
    ...readLiveHosts(legacyState, now),
    ...(fs.existsSync(modernState) ? readLiveHosts(modernState, now) : []),
  ];
  const keys = files.reduce((sum, file) => sum + file.renamed + file.droppedDuplicates, 0);
  const nothingToDo = config.action !== "rename" && stateDir.action === "none" && keys === 0 && stignore.add.length === 0;
  return {
    $schema: MIGRATE_NAMES_SCHEMA,
    root,
    applied: false,
    config,
    stateDir,
    properties: { files, keys, conflicts: files.reduce((sum, file) => sum + file.conflicts.length, 0) },
    stignore,
    liveHosts,
    nothingToDo,
  };
}

function atomicWrite(file: string, text: string): void {
  const mode = fs.statSync(file).mode & 0o777;
  const temporary = `${file}.celorga-migrate-${process.pid}.tmp`;
  fs.writeFileSync(temporary, text, { mode });
  fs.renameSync(temporary, file);
}

function mergeDirectory(from: string, to: string): string[] {
  const conflicts: string[] = [];
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    const source = path.join(from, entry.name);
    const target = path.join(to, entry.name);
    if (!fs.existsSync(target)) { fs.renameSync(source, target); continue; }
    if (entry.isDirectory() && fs.statSync(target).isDirectory()) {
      conflicts.push(...mergeDirectory(source, target).map((child) => path.join(entry.name, child)));
      if (fs.readdirSync(source).length === 0) fs.rmdirSync(source);
    } else {
      conflicts.push(entry.name);
    }
  }
  return conflicts;
}

export function applyMigrateNames(rootInput: string, options: { force?: boolean; now?: number } = {}): MigrateNamesPlan {
  const plan = planMigrateNames(rootInput, options.now);
  if (plan.liveHosts.length && !options.force) {
    return {
      ...plan,
      blocked: `Celorga is still running on ${plan.liveHosts.map((host) => host.name).join(", ")}. Quit the app on every device and stop or drain headless servers, wait for their presence to expire, then run again (or pass --force).`,
    };
  }
  const root = plan.root;
  if (plan.config.action === "rename") {
    const legacy = path.join(root, LEGACY_CONFIG_FILE);
    const modern = path.join(root, CONFIG_FILE);
    if (fs.existsSync(modern)) fs.rmSync(legacy); else fs.renameSync(legacy, modern);
  }
  if (plan.stateDir.action === "rename") {
    fs.renameSync(path.join(root, LEGACY_STATE_DIR), path.join(root, STATE_DIR));
  } else if (plan.stateDir.action === "merge") {
    const legacy = path.join(root, LEGACY_STATE_DIR);
    const conflicts = mergeDirectory(legacy, path.join(root, STATE_DIR));
    if (!conflicts.length && fs.existsSync(legacy) && fs.readdirSync(legacy).length === 0) fs.rmdirSync(legacy);
    plan.stateDir.conflicts = conflicts;
  }
  for (const change of plan.properties.files) {
    const file = path.join(root, change.file);
    const result = migratePropertyText(fs.readFileSync(file, "utf8"));
    if (result.renamed || result.droppedDuplicates) atomicWrite(file, result.text);
  }
  if (plan.stignore.add.length) {
    const file = path.join(root, ".stignore");
    const current = fs.readFileSync(file, "utf8");
    atomicWrite(file, `${current}${current.endsWith("\n") || !current ? "" : "\n"}${plan.stignore.add.join("\n")}\n`);
  }
  return { ...plan, applied: true };
}

function printText(plan: MigrateNamesPlan): void {
  const out: string[] = [];
  out.push(`${plan.applied ? "Migrated" : "Preview for"} ${plan.root}`);
  if (plan.blocked) out.push(`Not applied: ${plan.blocked}`);
  if (plan.nothingToDo) out.push("Nothing left to migrate.");
  if (plan.config.action === "rename") out.push(`- Config: ${plan.config.from} -> ${plan.config.to}${plan.config.note ? ` (${plan.config.note})` : ""}`);
  if (plan.config.action === "conflict") out.push(`- Config: ${plan.config.note}`);
  if (plan.stateDir.action === "rename") out.push(`- State folder: ${plan.stateDir.from}/ -> ${plan.stateDir.to}/`);
  if (plan.stateDir.action === "merge") {
    out.push(`- State folder: move ${plan.stateDir.entries} file(s) from ${plan.stateDir.from}/ into ${plan.stateDir.to}/`);
    if (plan.stateDir.conflicts?.length) out.push(`  ${plan.stateDir.conflicts.length} already exist in ${plan.stateDir.to}/ and stay in ${plan.stateDir.from}/ for review, e.g. ${plan.stateDir.conflicts.slice(0, 3).join(", ")}`);
  }
  if (plan.properties.keys) out.push(`- Properties: ${plan.properties.keys} key(s) in ${plan.properties.files.length} file(s) renamed from ${LEGACY_PROPERTY_PREFIX}* to ${PROPERTY_PREFIX}*`);
  if (plan.properties.conflicts) {
    out.push(`  ${plan.properties.conflicts} value(s) differ between the two spellings and are left as they are:`);
    for (const file of plan.properties.files.filter((entry) => entry.conflicts.length).slice(0, 10)) out.push(`    ${file.file}: ${file.conflicts.join("; ")}`);
  }
  if (plan.stignore.add.length) out.push(`- .stignore on this device: add ${plan.stignore.add.join(", ")} (run migrate-names on each synced device to update its own .stignore)`);
  if (!plan.applied && plan.liveHosts.length) out.push(`- Still running: ${plan.liveHosts.map((host) => `${host.name} (${host.kind})`).join(", ")}. Quit or stop these before --apply.`);
  if (!plan.applied && !plan.nothingToDo && !plan.blocked) out.push("Run again with --apply to make these changes.");
  console.log(out.join("\n"));
}

export async function runMigrateNamesCommand(args: string[]): Promise<void> {
  if (args.includes("--help") || args.includes("-h")) {
    console.log(`celorga migrate-names [--dir CORPUS] [--apply] [--force] [--json]

Moves a corpus to the Celorga names: org2.json to celorga.json, the .org2/
state folder to .celorga/, :ORG2_X: properties and #+ORG2_X: keywords to
CELORGA_X, and adds .celorga/ twins of .org2/ patterns to this device's
.stignore. Files under raw/ and text inside blocks are not changed.

Previews by default. --apply refuses while any Celorga app or server is still
online for the corpus; quit them on every device first. Safe to run again.`);
    return;
  }
  let dir = process.cwd();
  let apply = false;
  let force = false;
  let json = false;
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === "--apply") apply = true;
    else if (arg === "--force") force = true;
    else if (arg === "--json") json = true;
    else if (arg === "--dir") { const value = args[++index]; if (!value) throw new Error("--dir needs a path"); dir = value; }
    else throw new Error(`Unknown migrate-names option: ${arg}`);
  }
  const plan = apply ? applyMigrateNames(dir, { force }) : planMigrateNames(dir);
  if (json) console.log(JSON.stringify(plan, null, 2));
  else printText(plan);
  if (plan.blocked) process.exitCode = 2;
}
