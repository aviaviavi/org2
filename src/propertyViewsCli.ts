import { editPropertyViewSource, listPropertyViews, loadPropertyView, queryPropertyView, savePropertyView } from "./propertyViews.js";

const HELP = `org2 property-view

Saved, portable table/card views over canonical note and heading properties.
Usage:
  org2 property-view list --dir CORPUS
  org2 property-view query --dir CORPUS (--view ID | --definition JSON)
  org2 property-view save --dir CORPUS --definition JSON [--if-revision SHA] [--apply]
  org2 property-view edit --dir CORPUS --file FILE --kind file|heading --line N --property KEY --value TEXT --if-revision SHA [--apply]

All responses are JSON. Writes preview by default. Existing view saves require
--if-revision; source edits always require the revision returned by query.
Definitions live in views/ID.org2-view.json and contain scope, columns, filters,
sort and groupBy. OpenOrg's Property Views builder needs no SQL. Properties use
shared compiler inheritance; edits create a local override in the selected source.
Identity/built-in fields, ORG2 runtime metadata, raw/ and hidden paths are read-only.
Use --help for this contract; see the tooling reference for the definition schema.`;
export async function runPropertyViewsCommand(args: string[]): Promise<void> {
  if (args.includes("--help") || args.includes("-h")) { process.stdout.write(HELP + "\n"); return; }
  const values = [...args], action = values.shift();
  if (!["list", "query", "save", "edit"].includes(action ?? "")) throw new Error("Expected property-view list, query, save or edit");
  const flags = new Map<string, string>(); let apply = false;
  const allowed = action === "list" ? [] : action === "query" ? ["--view", "--definition"] : action === "save" ? ["--definition", "--if-revision"] : ["--file", "--kind", "--line", "--property", "--value", "--if-revision"];
  while (values.length) {
    const key = values.shift()!;
    if (key === "--json") continue;
    if (key === "--apply" && ["save", "edit"].includes(action!)) { apply = true; continue; }
    if (!["--dir", ...allowed].includes(key) || flags.has(key)) throw new Error(`Unknown or duplicate property-view option: ${key}`);
    const value = values.shift();
    if (value === undefined) throw new Error(`Missing value for ${key}`);
    flags.set(key, value);
  }
  const required = (key: string) => { const value = flags.get(key); if (value === undefined) throw new Error(`Required: ${key}`); return value; };
  const root = required("--dir");
  let result: unknown;
  if (action === "list") result = listPropertyViews(root);
  else if (action === "query") {
    if (flags.has("--view") === flags.has("--definition")) throw new Error("Choose --view or --definition");
    result = queryPropertyView(root, flags.has("--view") ? loadPropertyView(root, required("--view")) : JSON.parse(required("--definition")));
  } else if (action === "save") result = savePropertyView(root, JSON.parse(required("--definition")), { apply, expectedRevision: flags.get("--if-revision") });
  else result = editPropertyViewSource(root, { file: required("--file"), kind: required("--kind") as "file" | "heading", line: Number(required("--line")), property: required("--property"), value: required("--value"), expectedRevision: required("--if-revision"), apply });
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
}
