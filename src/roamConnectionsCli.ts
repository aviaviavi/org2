import path from "node:path";
import { linkRoamMention, readRoamConnections } from "./roamConnections.js";

export async function runRoamConnectionsCommand(args: string[]): Promise<void> {
  if (args.includes("--help") || args.includes("-h")) {
    console.log(`org2 roam connections --dir DIR (--id ID | --file FILE [--line N]) [--depth 1|2] [--format json]
org2 roam mention-link --dir DIR --file FILE --mention KEY --target ID --if-revision HASH [--apply] [--format json]

Connections returns a bounded local graph (60 nodes) and exact unlinked mentions (200).
Linking previews one occurrence by default. --apply requires its unchanged source revision.
Ambiguous labels always require an explicit target ID. Only the active corpus is scanned.`);
    return;
  }
  const values: Record<string, string> = {};
  let apply = false;
  const allowed = new Set(["--dir", "--id", "--file", "--line", "--depth", "--format", "--mention", "--target", "--if-revision"]);
  for (let i = 2; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === "--apply") { apply = true; continue; }
    if (arg === "--json") continue;
    if (arg === "--recursive") continue; // This scoped surface always scans recursively.
    if (!allowed.has(arg)) throw new Error(`Unknown connection option: ${arg}`);
    const value = args[++i];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${arg}`);
    values[arg] = value;
  }
  if (!values["--dir"]) throw new Error("--dir DIR is required");
  if (values["--format"] && values["--format"] !== "json") throw new Error("--format must be json");
  const root = path.resolve(values["--dir"]);
  const line = Number(values["--line"] || 1), depth = Number(values["--depth"] || 1);
  if (!Number.isInteger(line) || line < 1) throw new Error("--line must be a positive integer");
  if (![1, 2].includes(depth)) throw new Error("--depth must be 1 or 2");
  if (args[1] === "connections") {
    if (apply) throw new Error("connections is read-only");
    if (!values["--id"] && !values["--file"]) throw new Error("Select --id ID or --file FILE");
    console.log(JSON.stringify(readRoamConnections(root, { id: values["--id"], file: values["--file"], line, depth }), null, 2));
  } else {
    for (const flag of ["--file", "--mention", "--target", "--if-revision"]) if (!values[flag]) throw new Error(`${flag} is required`);
    console.log(JSON.stringify(linkRoamMention(root, {
      file: values["--file"]!, mention: values["--mention"]!, target: values["--target"]!, revision: values["--if-revision"]!, apply,
    }), null, 2));
  }
}
