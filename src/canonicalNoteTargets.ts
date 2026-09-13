import fs from "node:fs";
import path from "node:path";
import type { DocumentNode, HeadlineNode, Node } from "./ast.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import { printCanonicalAstToOrg } from "./printer.js";

/** A small source-backed projection for note/heading navigation and previews. */
export interface CanonicalNoteTarget {
  kind: "file" | "heading";
  file: string;
  title: string;
  id: string | null;
  properties: Record<string, string>;
  sourceRange: { startLine: number; endLine: number };
  snippet: string;
}

function sourceRange(node: object): CanonicalNoteTarget["sourceRange"] {
  return (node as { sourceRange: CanonicalNoteTarget["sourceRange"] }).sourceRange;
}

function properties(children: Node[]): Record<string, string> {
  return Object.fromEntries(children.filter(node => node.type === "PropertyDrawer")
    .flatMap(node => node.properties.map(prop => [prop.key.toUpperCase(), prop.value])));
}

function printNodes(children: Node[]): string {
  return printCanonicalAstToOrg({ type: "Document", version: "0", children }).trim();
}

/** Show canonical prose only; block examples, properties and planning stay out of snippets. */
function snippet(children: Node[]): string {
  const parts: string[] = [];
  let length = 0;
  const visit = (node: Node): void => {
    if (length >= 1200) return;
    if (node.type === "Headline") {
      if (!node.commented) node.children.forEach(visit);
    } else if (node.type === "List") {
      node.items.forEach(visit);
    } else if (node.type === "ListItem") {
      node.children.forEach(visit);
    } else if (node.type === "Paragraph" || node.type === "Table" || node.type === "FootnoteDefinition") {
      const text = printNodes([node]).replace(/\s+/g, " ");
      if (text) { parts.push(text); length += text.length + 1; }
    }
  };
  children.forEach(visit);
  return parts.join(" ").slice(0, 1200);
}

/** Parse the whole source before projecting targets; source/example body strings cannot create IDs. */
export function canonicalNoteTargets(root: string, file: string, maxBytes = 8 * 1024 * 1024): CanonicalNoteTarget[] {
  if (fs.statSync(file).size > maxBytes) return [];
  const text = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");
  let document: DocumentNode;
  try { document = parseOrgToCanonicalAst(text, { sourceRanges: true, sourcePath: file }); }
  catch { return []; }
  const relative = path.relative(root, file).split(path.sep).join("/");
  const firstHeading = document.children.findIndex(node => node.type === "Headline");
  const preamble = firstHeading < 0 ? document.children : document.children.slice(0, firstHeading);
  const keywords = preamble.filter(node => node.type === "KeywordLine");
  const fileProperties = properties(preamble);
  const fileID = keywords.find(node => node.keyRaw.toUpperCase() === "ID")?.valueRaw.trim() || fileProperties.ID || null;
  const title = keywords.find(node => node.keyRaw.toUpperCase() === "TITLE")?.valueRaw.trim()
    || path.basename(file).replace(/\.(org2|org)$/i, "");
  const targets: CanonicalNoteTarget[] = [{
    kind: "file", file: relative, title, id: fileID, properties: fileProperties,
    sourceRange: { startLine: 1, endLine: Math.max(1, text.split("\n").length - (text.endsWith("\n") ? 1 : 0)) },
    snippet: snippet(document.children),
  }];
  const visit = (heading: HeadlineNode) => {
    const ownProperties = properties(heading.children);
    targets.push({
      kind: "heading", file: relative,
      title: printNodes([{ type: "Paragraph", children: heading.title }]),
      id: ownProperties.ID || null, properties: ownProperties,
      sourceRange: sourceRange(heading), snippet: snippet(heading.children),
    });
    for (const child of heading.children) if (child.type === "Headline") visit(child);
  };
  for (const child of document.children) if (child.type === "Headline") visit(child);
  return targets;
}
