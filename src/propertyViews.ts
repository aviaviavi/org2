import fs from "node:fs";
import path from "node:path";
import { compileCorpus, type CompiledCorpusNode } from "./corpusCompile.js";
import { loadConfig, resolveFilesFromDir } from "./config.js";
import { guardedContentRevision, guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import type { Node } from "./ast.js";
import { isPlanningLine } from "./sourceLines.js";

export const PROPERTY_VIEW_SCHEMA = "org2:property-view:v1" as const;
export type PropertyViewFilter = { field: string; operator: "is" | "isNot" | "contains" | "exists" | "missing" | "gt" | "lt"; value?: string };
export interface PropertyViewDefinition {
  schema: typeof PROPERTY_VIEW_SCHEMA;
  id: string;
  title: string;
  layout: "table" | "cards";
  scope: { kind: "all" | "file" | "heading"; filePrefix?: string };
  columns: string[];
  match: "all" | "any";
  filters: PropertyViewFilter[];
  sort: Array<{ field: string; direction: "asc" | "desc" }>;
  groupBy?: string;
  limit: number;
}
const builtins = ["title", "file", "kind", "todo", "tags", "id"];
const operators = ["is", "isNot", "contains", "exists", "missing", "gt", "lt"];
const suffix = ".org2-view.json";
function record(value: unknown): value is Record<string, unknown> { return Boolean(value && typeof value === "object" && !Array.isArray(value)); }
function oneLine(value: unknown, label: string): string {
  if (typeof value !== "string" || /[\r\n\0]/.test(value) || value.length > 4096) throw new Error(`${label} must be a single line of at most 4096 characters`);
  return value;
}
export function propertyViewField(value: unknown): string {
  const field = oneLine(value, "Field").trim();
  if (builtins.includes(field)) return field;
  if (!/^[A-Za-z0-9_@#%+.-]+$/.test(field)) throw new Error("A field must be a property name or title, file, kind, todo, tags, id");
  return field.toUpperCase();
}
function viewID(value: unknown): string {
  if (typeof value !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$/.test(value)) throw new Error("View ID must contain 1–100 letters, numbers, underscores or hyphens");
  return value;
}
export function parsePropertyView(value: unknown): PropertyViewDefinition {
  if (!record(value) || value.schema !== PROPERTY_VIEW_SCHEMA) throw new Error(`Expected ${PROPERTY_VIEW_SCHEMA}`);
  const id = viewID(value.id);
  const title = oneLine(value.title, "Title").trim();
  if (!title) throw new Error("View title is required");
  if (value.layout !== "table" && value.layout !== "cards") throw new Error("View layout must be table or cards");
  if (!record(value.scope) || !["all", "file", "heading"].includes(String(value.scope.kind))) throw new Error("Scope kind must be all, file or heading");
  const prefix = value.scope.filePrefix === undefined ? "" : oneLine(value.scope.filePrefix, "File prefix").trim().replace(/\\/g, "/");
  if (prefix.startsWith("/") || prefix.split("/").some(p => p === ".." || p.startsWith(".")) || /^[A-Za-z]:/.test(prefix)) throw new Error("File prefix must be a portable corpus-relative path without hidden directories");
  if (!Array.isArray(value.columns) || !value.columns.length || value.columns.length > 24) throw new Error("Choose 1–24 columns");
  const columns = [...new Set(value.columns.map(propertyViewField))];
  if (value.match !== "all" && value.match !== "any") throw new Error("Match must be all or any");
  if (!Array.isArray(value.filters) || value.filters.length > 30) throw new Error("A view supports up to 30 filters");
  const filters = value.filters.map(f => {
    if (!record(f) || !operators.includes(String(f.operator))) throw new Error("Invalid filter operator");
    const operator = f.operator as PropertyViewFilter["operator"];
    const filterValue = f.value === undefined ? "" : oneLine(f.value, "Filter value");
    if (["gt", "lt"].includes(operator) && (!filterValue.trim() || !Number.isFinite(Number(filterValue)))) throw new Error("Numeric comparisons require a finite number");
    return { field: propertyViewField(f.field), operator, value: filterValue };
  });
  if (!Array.isArray(value.sort) || value.sort.length > 8) throw new Error("A view supports up to 8 sort fields");
  const sort = value.sort.map(s => {
    if (!record(s) || (s.direction !== "asc" && s.direction !== "desc")) throw new Error("Sort direction must be asc or desc");
    return { field: propertyViewField(s.field), direction: s.direction as "asc" | "desc" };
  });
  if (!Number.isInteger(value.limit) || Number(value.limit) < 1 || Number(value.limit) > 5000) throw new Error("View limit must be 1–5000");
  return { schema: PROPERTY_VIEW_SCHEMA, id, title, layout: value.layout, scope: { kind: value.scope.kind as PropertyViewDefinition["scope"]["kind"], ...(prefix ? { filePrefix: prefix } : {}) }, columns, match: value.match, filters, sort, ...(value.groupBy ? { groupBy: propertyViewField(value.groupBy) } : {}), limit: Number(value.limit) };
}

/** Resolve both existing and new paths through symlinks before granting corpus access. */
function inside(root: string, file: string): string {
  const base = fs.realpathSync(root);
  const target = path.resolve(base, file);
  let ancestor = target;
  while (!fs.existsSync(ancestor)) ancestor = path.dirname(ancestor);
  const resolved = path.resolve(fs.realpathSync(ancestor), path.relative(ancestor, target));
  const relative = path.relative(base, resolved);
  if (!relative || relative === ".." || relative.startsWith(".." + path.sep) || path.isAbsolute(relative) || relative.split(path.sep).some(p => p.startsWith("."))) throw new Error("Property views must stay inside the active corpus, outside hidden directories");
  return resolved;
}
function viewPath(root: string, id: string): string { return inside(root, path.join("views", viewID(id) + suffix)); }
export function listPropertyViews(root: string) {
  const views: Array<{ definition: PropertyViewDefinition; file: string; revision: string }> = [];
  const diagnostics: Array<{ file: string; message: string }> = [];
  const directory = inside(root, "views");
  if (fs.existsSync(directory)) for (const name of fs.readdirSync(directory).sort()) {
    if (!name.endsWith(suffix)) continue;
    try {
      const file = inside(root, path.join("views", name));
      const snapshot = readGuardedFile(file);
      const definition = parsePropertyView(JSON.parse(snapshot.content));
      if (name !== definition.id + suffix) throw new Error("View filename must match its ID");
      views.push({ definition, file: path.relative(fs.realpathSync(root), file), revision: snapshot.revision });
    } catch (error) { diagnostics.push({ file: name, message: error instanceof Error ? error.message : String(error) }); }
  }
  return { schema: "org2:property-view-list:v1", views, diagnostics };
}
export function savePropertyView(root: string, value: unknown, options: { apply?: boolean; expectedRevision?: string } = {}) {
  const definition = parsePropertyView(value);
  const file = viewPath(root, definition.id);
  const baseRevision = fs.existsSync(file) ? readGuardedFile(file).revision : null;
  if (baseRevision !== null && options.expectedRevision !== baseRevision) throw new Error("View changed or already exists; reload it and pass --if-revision before saving");
  if (baseRevision === null && options.expectedRevision) throw new Error("View was removed; reload before saving");
  const content = JSON.stringify(definition, null, 2) + "\n";
  if (options.apply) guardedWriteFile(file, content, { expectedRevision: baseRevision, preserveMode: true });
  return { schema: "org2:property-view-save:v1", applied: Boolean(options.apply), baseRevision, revision: guardedContentRevision(content), file: path.relative(fs.realpathSync(root), file), definition, content };
}
export function loadPropertyView(root: string, id: string): PropertyViewDefinition {
  const view = parsePropertyView(JSON.parse(readGuardedFile(viewPath(root, id)).content));
  if (view.id !== id) throw new Error("View ID and filename differ");
  return view;
}
export function propertyViewValue(node: CompiledCorpusNode, field: string): string {
  switch (field) {
    case "title": return node.title;
    case "file": return node.file;
    case "kind": return node.kind;
    case "todo": return node.todo ?? "";
    case "tags": return node.tags.join(", ");
    case "id": return node.id ?? "";
    default: return node.effectiveProperties[field] ?? "";
  }
}
export function matchesPropertyViewFilter(node: CompiledCorpusNode, filter: PropertyViewFilter): boolean {
  const actual = propertyViewValue(node, filter.field);
  const wanted = filter.value ?? "";
  switch (filter.operator) {
    case "is": return actual.toLowerCase() === wanted.toLowerCase();
    case "isNot": return actual.toLowerCase() !== wanted.toLowerCase();
    case "contains": return actual.toLowerCase().includes(wanted.toLowerCase());
    case "exists": return actual !== "";
    case "missing": return actual === "";
    case "gt": return actual.trim() !== "" && Number.isFinite(Number(actual)) && Number(actual) > Number(wanted);
    case "lt": return actual.trim() !== "" && Number.isFinite(Number(actual)) && Number(actual) < Number(wanted);
  }
}
function compare(a: string, b: string): number {
  if (a.trim() && b.trim() && Number.isFinite(Number(a)) && Number.isFinite(Number(b))) return Number(a) - Number(b);
  const left = a.toLowerCase(), right = b.toLowerCase();
  return left < right ? -1 : left > right ? 1 : 0;
}
export function editablePropertyViewField(field: string): boolean {
  return !builtins.includes(field) && !["ID", "CUSTOM_ID", "PROPERTIES", "END"].includes(field) && !field.startsWith("ORG2_");
}
/** The corpus index is optimized for broad scans. Use canonical source ranges to
 * exclude examples/fences from editable views and retain only semantic drawers. */
function canonicalPropertyViewNodes(nodes: CompiledCorpusNode[], raw: string): CompiledCorpusNode[] {
  const document = parseOrgToCanonicalAst(raw.replace(/\r\n?/g, "\n"), { sourceRanges: true });
  const lines = raw.split(/\r\n|\n|\r/);
  const fileNode = nodes.find(n => n.kind === "file")!;
  const headings = new Map(nodes.filter(n => n.kind === "heading").map(n => [n.sourceRange.startLine, n]));
  const firstHeading = document.children.findIndex(n => n.type === "Headline");
  const preamble = firstHeading < 0 ? document.children : document.children.slice(0, firstHeading);
  const drawerProperties = (node: Node | undefined): Record<string, string> => node?.type === "PropertyDrawer"
    ? Object.fromEntries(node.properties.map(p => [p.key.toUpperCase(), p.value.trim()])) : {};
  const properties = drawerProperties(preamble.find(n => n.type === "PropertyDrawer"));
  const keyword = (key: string) => preamble.find(n => n.type === "KeywordLine" && n.keyRaw.toUpperCase() === key);
  const keywordValue = (key: string) => { const node = keyword(key); return node?.type === "KeywordLine" ? node.valueRaw.trim() : ""; };
  if (keywordValue("ORG2_KIND") === "project" && !properties.ORG2_ENTITY_TYPE && !properties.ENTITY_TYPE && fileNode.properties.ORG2_ENTITY_TYPE === "project") properties.ORG2_ENTITY_TYPE = "project";
  const fileEnd = firstHeading < 0 ? lines.length : ((document.children[firstHeading] as RangedNode).sourceRange?.startLine ?? 1) - 1;
  const result: CompiledCorpusNode[] = [{ ...fileNode,
    title: keywordValue("TITLE") || path.basename(fileNode.file).replace(/\.(org2|org)$/i, ""),
    id: (keywordValue("ID") || properties.ID || "").trim().toLowerCase() || null,
    sourceRange: { startLine: 1, endLine: Math.max(1, fileEnd) },
    properties, effectiveProperties: { ...properties }, inheritedProperties: {},
  }];
  const visit = (children: Node[], inherited: Record<string, string>) => {
    for (const heading of children) if (heading.type === "Headline") {
      const range = (heading as RangedNode).sourceRange;
      if (!range) continue;
      const node = headings.get(range.startLine);
      if (!node) continue;
      let drawerStart = range.startLine;
      while (drawerStart < lines.length && (!lines[drawerStart]!.trim() || isPlanningLine(lines[drawerStart]!))) drawerStart++;
      const local = drawerProperties(heading.children.find(n => n.type === "PropertyDrawer" && (n as RangedNode).sourceRange?.startLine === drawerStart + 1));
      const effectiveProperties = { ...inherited, ...local };
      result.push({ ...node, sourceRange: range, id: local.ID?.trim().toLowerCase() || null, properties: local, effectiveProperties,
        inheritedProperties: Object.fromEntries(Object.entries(inherited).filter(([key]) => !(key in local))) });
      visit(heading.children, effectiveProperties);
    }
  };
  visit(document.children, properties);
  return result;
}

export function queryPropertyView(root: string, value: unknown) {
  const definition = parsePropertyView(value);
  const base = fs.realpathSync(root);
  const configFile = path.join(base, "org2.json");
  const config = fs.existsSync(configFile) ? loadConfig(configFile) : {};
  const files = resolveFilesFromDir(base, ["**/*.org", "**/*.org2"], ["node_modules", "node_modules/**", ...(config.ignorePatterns ?? [])], true);
  const corpus = compileCorpus(files, { rootDir: base });
  const revisions = new Map(files.map(file => [path.relative(base, file).replace(/\\/g, "/"), readGuardedFile(file).revision]));
  const nodes: CompiledCorpusNode[] = [];
  const diagnostics: Array<{ file: string; message: string }> = [];
  const nodesByFile = new Map<string, CompiledCorpusNode[]>();
  for (const node of corpus.nodes) {
    const fileNodes = nodesByFile.get(node.file);
    if (fileNodes) fileNodes.push(node);
    else nodesByFile.set(node.file, [node]);
  }
  // compileCorpus normalizes line endings when hashing; verify content did not change
  // between compilation and the raw-byte revisions attached to editable rows.
  for (const file of corpus.files) {
    const snapshot = readGuardedFile(file.absolutePath);
    if (snapshot.revision !== revisions.get(file.file) || guardedContentRevision(snapshot.content.replace(/\r\n?/g, "\n")) !== `sha256:${file.sha256}`) throw new Error("Corpus changed while querying; refresh the view");
    try { nodes.push(...canonicalPropertyViewNodes(nodesByFile.get(file.file) ?? [], snapshot.content)); }
    catch (error) { diagnostics.push({ file: file.file, message: error instanceof Error ? error.message : String(error) }); }
  }
  const matches = nodes.filter(node => {
    if (definition.scope.kind !== "all" && node.kind !== definition.scope.kind) return false;
    if (definition.scope.filePrefix && !node.file.startsWith(definition.scope.filePrefix)) return false;
    if (!definition.filters.length) return true;
    return definition.match === "all" ? definition.filters.every(f => matchesPropertyViewFilter(node, f)) : definition.filters.some(f => matchesPropertyViewFilter(node, f));
  }).sort((a, b) => {
    for (const sort of definition.sort) {
      const order = compare(propertyViewValue(a, sort.field), propertyViewValue(b, sort.field));
      if (order) return sort.direction === "desc" ? -order : order;
    }
    return a.key < b.key ? -1 : a.key > b.key ? 1 : 0;
  });
  const rows = matches.slice(0, definition.limit).map(node => ({
    key: node.key, kind: node.kind, file: node.file, line: node.sourceRange.startLine, endLine: node.sourceRange.endLine, id: node.id,
    title: node.title, revision: revisions.get(node.file)!, properties: node.properties, inheritedProperties: node.inheritedProperties,
    values: Object.fromEntries(definition.columns.map(field => [field, propertyViewValue(node, field)])),
    group: definition.groupBy ? propertyViewValue(node, definition.groupBy) : "",
    editable: node.file.split("/")[0] !== "raw",
  }));
  return { schema: "org2:property-view-result:v1", definition, total: matches.length, truncated: matches.length > rows.length,
    diagnostics, fields: [...builtins, ...new Set(nodes.flatMap(n => Object.keys(n.effectiveProperties)))].sort(),
    editableFields: definition.columns.filter(editablePropertyViewField), rows };
}

type RangedNode = Node & { sourceRange?: { startLine: number; endLine: number } };
/** Edit the canonical parser's exact drawer, retaining all unrelated source lines. */
export function editPropertyViewSource(root: string, input: { file: string; kind: "file" | "heading"; line: number; property: string; value: string; expectedRevision: string; apply?: boolean }) {
  const file = inside(root, input.file);
  if (![".org", ".org2"].includes(path.extname(file)) || path.relative(fs.realpathSync(root), file).split(path.sep)[0] === "raw") throw new Error("Only ordinary Org source outside raw/ is editable");
  const snapshot = readGuardedFile(file);
  if (!input.expectedRevision || input.expectedRevision !== snapshot.revision) throw new Error("Source changed since this row was read; refresh the view before editing");
  const property = propertyViewField(input.property);
  if (!editablePropertyViewField(property)) throw new Error("Identity, built-in fields and ORG2 runtime metadata are read-only in property views");
  const value = oneLine(input.value, "Property value");
  if (!Number.isInteger(input.line) || input.line < 1 || !["file", "heading"].includes(input.kind)) throw new Error("Choose an exact file or heading source row");
  const document = parseOrgToCanonicalAst(snapshot.content.replace(/\r\n?/g, "\n"), { sourceRanges: true });
  let children: Node[] = document.children;
  if (input.kind === "heading") {
    let heading: RangedNode | undefined;
    const visit = (nodes: Node[]) => { for (const node of nodes) if (node.type === "Headline") {
      if ((node as RangedNode).sourceRange?.startLine === input.line) heading = node;
      visit(node.children);
    } };
    visit(document.children);
    if (!heading || heading.type !== "Headline") throw new Error("Source row is no longer an actual heading");
    children = heading.children;
  } else if (input.line !== 1) throw new Error("A file property row starts at line 1");
  const newline = snapshot.content.includes("\r\n") ? "\r\n" : "\n";
  const lines = snapshot.content.split(/\r\n|\n|\r/);
  const endings = snapshot.content.match(/\r\n|\n|\r/g) ?? [];
  let insertAt = input.kind === "heading" ? input.line : 0;
  if (input.kind === "heading") while (insertAt < lines.length && (!lines[insertAt]!.trim() || isPlanningLine(lines[insertAt]!))) insertAt++;
  // A heading drawer is semantic only before the first body content, after
  // optional blank/planning lines, matching the shared compiler's inheritance.
  const drawer = children.find(n => n.type === "PropertyDrawer" && (input.kind === "file" || (n as RangedNode).sourceRange?.startLine === insertAt + 1)) as RangedNode | undefined;
  const range = drawer?.sourceRange;
  let oldValue: string | null = null;
  if (drawer?.type === "PropertyDrawer" && range) {
    if (lines[range.endLine - 1]?.trim().toUpperCase() !== ":END:") throw new Error("Property drawer is unterminated; repair source first");
    const matches = drawer.properties.filter(p => p.key.toUpperCase() === property);
    if (matches.length > 1) throw new Error("Duplicate property keys; repair source first");
    oldValue = matches[0]?.value ?? null;
    const index = lines.findIndex((line, i) => i >= range.startLine && i < range.endLine - 1 && new RegExp(`^\\s*:${property.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}:`, "i").test(line));
    if (index >= 0) lines[index] = lines[index]!.replace(/^([ \t]*:[^:]+:[ \t]*).*$/, (_line, prefix) => `${prefix}${value}`);
    else {
      const indent = /^[ \t]*/.exec(lines[range.startLine - 1] ?? "")?.[0] ?? "";
      lines.splice(range.endLine - 1, 0, `${indent}:${property}: ${value}`);
      endings.splice(range.endLine - 1, 0, newline);
    }
  } else {
    lines.splice(insertAt, 0, ":PROPERTIES:", `:${property}: ${value}`, ":END:");
    endings.splice(insertAt, 0, newline, newline, newline);
  }
  const content = lines.map((line, index) => line + (endings[index] ?? "")).join("");
  const changed = content !== snapshot.content;
  if (input.apply && changed) guardedWriteFile(file, content, { expectedRevision: input.expectedRevision, preserveMode: true });
  return { schema: "org2:property-view-edit:v1", file: input.file, line: input.line, property, oldValue, value, changed,
    applied: Boolean(input.apply && changed), revision: snapshot.revision, nextRevision: guardedContentRevision(content), content };
}
