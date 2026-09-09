import fs from "node:fs";
import path from "node:path";
import { parseTodoSequenceDefinitions, TODO_KEYWORDS } from "./todo.js";
import { guardedContentRevision, guardedWriteFile } from "./guardedFile.js";

export async function runTodoConfigCommand(args: string[]): Promise<void> {
  if (args.includes("--help") || args.includes("-h")) {
    console.log(`org2 todo-config <show|set> --dir CORPUS [--sequences-json '["TODO WAITING | DONE CANCELED"]'] [--if-revision REVISION] [--apply]

Reads or previews corpus-wide TODO defaults in org2.json. Output is JSON.
set requires --sequences-json; [] restores built-in defaults. File-local
#+TODO:, #+SEQ_TODO:, and #+TYP_TODO: declarations override these defaults.
Writes require --apply; use --if-revision from show/preview to reject stale edits.`);
    return;
  }
  const [action = "show", ...rest] = args;
  if (!["show", "set"].includes(action)) throw new Error("TODO config action must be show or set.");
  const flags = new Map<string, string>();
  let apply = false;
  for (let i = 0; i < rest.length; i++) {
    const key = rest[i];
    if (key === "--apply") { apply = true; continue; }
    if (!["--dir", "--sequences-json", "--if-revision"].includes(key)) throw new Error(`Unknown TODO config option: ${key}`);
    const value = rest[++i];
    if (value === undefined || flags.has(key)) throw new Error(`Missing or repeated ${key}.`);
    flags.set(key, value);
  }
  if (action === "show" && (apply || flags.has("--sequences-json"))) throw new Error("Use todo-config set to change defaults.");
  const file = path.join(path.resolve(flags.get("--dir") ?? process.cwd()), "org2.json");
  const raw = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : undefined;
  const revision = raw === undefined ? "absent" : guardedContentRevision(raw);
  const expected = flags.get("--if-revision");
  if (expected !== undefined && expected !== revision) throw new Error("Corpus settings changed since they were loaded. Reload the settings before saving.");
  const config = raw === undefined ? {} : JSON.parse(raw);
  if (!config || Array.isArray(config) || typeof config !== "object") throw new Error("org2.json must contain an object.");
  if (config.todo !== undefined && (!config.todo || Array.isArray(config.todo) || typeof config.todo !== "object")) throw new Error("org2.json todo must contain an object.");
  const previous = config.todo?.sequences ?? [];
  const sequences = action === "set" ? JSON.parse(flags.get("--sequences-json") ?? "null") : previous;
  const parsed = parseTodoSequenceDefinitions(sequences);
  const changed = JSON.stringify(previous) !== JSON.stringify(sequences);
  let outputRevision = revision;
  if (action === "set" && changed && apply) {
    config.todo = { ...config.todo, sequences };
    const updated = guardedWriteFile(file, `${JSON.stringify(config, null, 2)}\n`, {
      expectedRevision: raw === undefined ? null : revision, preserveMode: true,
    });
    outputRevision = updated.revision;
  }
  console.log(JSON.stringify({ schema: "org2:todo-config:v1", file, revision: outputRevision, sequences,
    sequenceFields: sequences.map((definition: string) => {
      const tokens = definition.trim().split(/\s+/);
      const separator = tokens.indexOf("|");
      return { active: tokens.slice(0, separator < 0 ? -1 : separator).join(" "),
        terminal: tokens.slice(separator < 0 ? -1 : separator + 1).join(" ") };
    }),
    effectiveSequences: parsed.length ? parsed : [{ keywords: [...TODO_KEYWORDS], terminal: ["DONE", "CANCELED", "CANCELLED"] }],
    changed: action === "set" && changed, applied: action === "set" && changed && apply }, null, 2));
}
