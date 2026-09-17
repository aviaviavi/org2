import fs from "node:fs";
import { updateCheckboxInText, updateCheckboxProgressCookiesInText, type CheckboxState } from "./checkbox.js";
import { readGuardedFile, guardedWriteFile } from "./guardedFile.js";
import { buildUnifiedDiff } from "./unifiedDiff.js";

const HELP = `org2 checkbox

Usage:
  org2 checkbox [cycle|toggle] --file FILE --line N [--apply]
  org2 checkbox set --status unchecked|indeterminate|checked --file FILE --line N [--apply]
  org2 checkbox fix-cookies --file FILE [--apply]

Cycles [ ] -> [-] -> [X] -> [ ] on the exact one-based list-item line.
fix-cookies recalculates stale [n/m] and [p%] progress cookies using their
innermost containing heading, or the file preamble before the first heading.
The default action is cycle; toggle is an alias. Preview is the default.
Options:
  --format diff|text|json  Diff preview (default), full edited text, or JSON result
  --json                 Alias for --format json
  --if-revision SHA       Require the revision from a previous JSON preview
  --apply                Write the edit; preserves every unrelated source byte
  --help                 Show this help

cycle and set change only the selected marker. Use fix-cookies explicitly to
recalculate progress cookies.`;

export async function runCheckboxCommand(args: string[]): Promise<void> {
  if (args.includes("--help") || args.includes("-h")) {
    process.stdout.write(`${HELP}\n`);
    return;
  }
  const values = [...args];
  const action = values[0] && !values[0].startsWith("-") ? values.shift()! : "cycle";
  if (!["cycle", "toggle", "set", "fix-cookies"].includes(action)) throw new Error(`Unknown checkbox action: ${action}`);
  const flags = new Map<string, string>();
  let apply = false;
  while (values.length) {
    const arg = values.shift()!;
    if (arg === "--apply") { apply = true; continue; }
    if (arg === "--json") { flags.set("--format", "json"); continue; }
    const equal = arg.indexOf("=");
    const key = equal < 0 ? arg : arg.slice(0, equal);
    if (!["--file", "--line", "--status", "--format", "--if-revision"].includes(key)) {
      throw new Error(`Unknown checkbox option: ${arg}`);
    }
    const value = equal < 0 ? values.shift() : arg.slice(equal + 1);
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${key}`);
    if (flags.has(key)) throw new Error(`Duplicate checkbox option: ${key}`);
    flags.set(key, value);
  }
  const file = flags.get("--file");
  const line = flags.get("--line");
  const status = flags.get("--status");
  if (!file) throw new Error("Checkbox requires --file FILE.");
  if (action === "fix-cookies") {
    if (line !== undefined || status !== undefined) throw new Error("checkbox fix-cookies accepts --file but not --line or --status.");
  } else {
    if (!line || !/^[1-9]\d*$/.test(line)) throw new Error("Checkbox cycle/set requires --line N (a positive integer).");
    if ((action === "set") !== (status !== undefined)) throw new Error("Use checkbox set --status unchecked|indeterminate|checked to select a state.");
  }
  const format = flags.get("--format") ?? "diff";
  if (!["diff", "text", "json"].includes(format)) throw new Error("Checkbox format must be diff, text, or json.");
  // Resolve symlinks before the atomic write so the link itself remains intact.
  const snapshot = readGuardedFile(fs.realpathSync(file));
  const expected = flags.get("--if-revision");
  if (expected !== undefined && expected !== snapshot.revision) throw new Error("File changed since the checkbox preview. Preview again before applying.");
  const result = action === "fix-cookies"
    ? updateCheckboxProgressCookiesInText(snapshot.content)
    : updateCheckboxInText(snapshot.content, Number(line), status as CheckboxState | undefined);
  const diff = format === "diff" ? buildUnifiedDiff(snapshot.content, result.text, {
    targetPath: snapshot.file, temporaryDirectoryPrefix: "org2-checkbox-", useLabels: true,
  }) : "";
  if (apply && result.changed) guardedWriteFile(snapshot.file, result.text, { expectedRevision: snapshot.revision, preserveMode: true });
  if (format === "json") {
    const { text: _text, ...edit } = result;
    process.stdout.write(`${JSON.stringify({
      schema: action === "fix-cookies" ? "org2:checkbox-cookie-fix:v1" : "org2:checkbox-edit:v1",
      file: snapshot.file,
      revision: snapshot.revision,
      ...edit,
      applied: apply && result.changed,
    }, null, 2)}\n`);
  } else if (format === "text") process.stdout.write(result.text);
  else if (diff) process.stdout.write(diff);
  else if (action === "fix-cookies") process.stdout.write("Progress cookies are already current; no changes.\n");
  else process.stdout.write(`Checkbox is already ${"newState" in result ? result.newState : "current"}; no changes.\n`);
}
