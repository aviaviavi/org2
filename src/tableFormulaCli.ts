import path from "node:path";
import { buildUnifiedDiff } from "./unifiedDiff.js";
import { guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { recalculateOrgTableFormulas } from "./tableFormula.js";

function usage(exitCode: number): never {
  console.error(`Usage: org2 table recalculate --file FILE [--line N] [--formula-index N] [--apply] [--format text|diff|json]

Recalculates one formula-backed Org table. The command previews by default;
--apply performs an atomic revision-guarded write.`);
  process.exit(exitCode);
}

export async function runTableFormulaCommand(args: string[]): Promise<boolean> {
  if (args[0] !== "table") return false;
  if (args.includes("--help") || args.includes("-h")) usage(0);
  if (args[1] !== "recalculate" && args[1] !== "recalc") usage(1);
  let file = "";
  let line: number | undefined;
  let formulaIndex = 0;
  let apply = false;
  let format: "text" | "diff" | "json" = "text";
  for (let i = 2; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--file") file = args[++i] ?? "";
    else if (arg === "--line") line = Number(args[++i]);
    else if (arg === "--formula-index") formulaIndex = Number(args[++i]) - 1;
    else if (arg === "--apply") apply = true;
    else if (arg === "--json") format = "json";
    else if (arg === "--format") {
      const value = args[++i];
      if (value !== "text" && value !== "diff" && value !== "json") throw new Error("--format must be text, diff, or json");
      format = value;
    } else throw new Error(`Unknown table option: ${arg}`);
  }
  if (!file) throw new Error("table recalculate requires --file FILE");
  if (line !== undefined && (!Number.isInteger(line) || line < 1)) throw new Error("--line must be a positive integer");
  if (!Number.isInteger(formulaIndex) || formulaIndex < 0) throw new Error("--formula-index must be a positive integer");
  const snapshot = readGuardedFile(path.resolve(file));
  const result = recalculateOrgTableFormulas(snapshot.content, { line, formulaIndex });
  const payload = { ...result, file: snapshot.file, applied: apply && result.ok && result.changed, preview: result.text };
  if (!result.ok) {
    if (format === "json") console.log(JSON.stringify(payload, null, 2));
    else for (const diagnostic of result.diagnostics) console.error(`Error: ${diagnostic.message}${diagnostic.row ? ` at @${diagnostic.row}$${diagnostic.column}` : ""}`);
    process.exitCode = 1;
    return true;
  }
  if (apply && result.changed) guardedWriteFile(snapshot.file, result.text, { expectedRevision: snapshot.revision });
  if (format === "json") console.log(JSON.stringify(payload, null, 2));
  else if (format === "diff") process.stdout.write(buildUnifiedDiff(snapshot.content, result.text, {
    targetPath: snapshot.file,
    temporaryDirectoryPrefix: "org2-table-formula-",
  }));
  else {
    console.log(`${apply ? (result.changed ? "recalculated" : "already current") : "would recalculate"}: ${snapshot.file}`);
    console.log(`${result.changes.length} cell${result.changes.length === 1 ? "" : "s"} changed${apply ? "" : "; pass --apply to write"}`);
    for (const change of result.changes) {
      console.log(`@${change.row}$${change.column}: ${JSON.stringify(change.before)} -> ${JSON.stringify(change.after)}`);
    }
  }
  return true;
}
