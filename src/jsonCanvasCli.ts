import fs from "node:fs";
import path from "node:path";
import { readStdinText } from "./stdin.js";
import { canvasTargets, createJSONCanvas, editJSONCanvas, exportJSONCanvas, showJSONCanvas, type JSONCanvasOperation } from "./jsonCanvas.js";

export async function runJSONCanvasCommand(args: string[]): Promise<void> {
  if (args.includes("--help") || args.includes("-h") || args.length < 2) {
    console.log(`org2 canvas show --dir DIR --file FILE [--json]
org2 canvas targets --dir DIR [--query TEXT] [--json]
org2 canvas create --dir DIR --file FILE [--apply] [--json]
org2 canvas edit --dir DIR --file FILE --if-revision HASH --stdin [--apply] [--json]
org2 canvas import --dir DIR --file NEW_FILE --from FILE [--apply] [--json]
org2 canvas export --dir DIR --file FILE --out NEW_FILE [--apply] [--json]

JSON Canvas 1.0 files remain canonical. Edits read a JSON operation array from stdin.
Operations: add-node {node}, update-node {id,patch}, remove-node {id};
            add-edge {edge}, update-edge {id,patch}, remove-edge {id}.
Mutations preview by default, preserve unknown fields, and require guarded --apply.
File nodes use corpus-relative paths. org2Ref:"id:ID" preserves stable source navigation.`);
    return;
  }
  const values: Record<string, string> = {};
  let apply = false, stdin = false;
  const flags = new Set(["--dir", "--file", "--query", "--if-revision", "--from", "--out", "--format"]);
  for (let i = 2; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === "--apply") { apply = true; continue; }
    if (arg === "--stdin") { stdin = true; continue; }
    if (arg === "--json") continue;
    if (!flags.has(arg)) throw new Error(`Unknown canvas flag: ${arg}`);
    const value = args[++i];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${arg}`);
    values[arg] = value;
  }
  if (!values["--dir"]) throw new Error("--dir DIR is required");
  if (values["--format"] && values["--format"] !== "json") throw new Error("Canvas supports --format json");
  const root = path.resolve(values["--dir"]);
  if (args[1] !== "targets" && !values["--file"]) throw new Error("--file FILE is required");
  const file = values["--file"] || "";
  let payload: unknown;
  switch (args[1]) {
    case "show":
      if (apply) throw new Error("canvas show is read-only");
      payload = showJSONCanvas(root, file); break;
    case "targets":
      if (apply) throw new Error("canvas targets is read-only");
      payload = canvasTargets(root, values["--query"]); break;
    case "create": payload = createJSONCanvas(root, file, apply); break;
    case "edit":
      if (!values["--if-revision"] || !stdin) throw new Error("canvas edit requires --if-revision and --stdin");
      payload = editJSONCanvas(root, file, values["--if-revision"], JSON.parse(await readStdinText()) as JSONCanvasOperation[], apply); break;
    case "import":
      if (!values["--from"]) throw new Error("canvas import requires --from FILE");
      if (fs.statSync(path.resolve(values["--from"])).size > 8 * 1024 * 1024) throw new Error("Canvas exceeds the 8 MiB document limit");
      payload = createJSONCanvas(root, file, apply, fs.readFileSync(path.resolve(values["--from"]), "utf8")); break;
    case "export":
      if (!values["--out"]) throw new Error("canvas export requires --out FILE");
      payload = exportJSONCanvas(root, file, values["--out"], apply); break;
    default: throw new Error(`Unknown canvas action: ${args[1]}`);
  }
  console.log(JSON.stringify(payload, null, 2));
}
