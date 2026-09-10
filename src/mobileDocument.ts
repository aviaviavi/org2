import type { DocumentNode, HeadlineNode, InlineNode, Node } from "./ast.js";
import { parseInlinesFromText, parseOrgToCanonicalAst } from "./parser.js";
import { documentTodoSequences, parseTodoSequenceDefinitions } from "./todo.js";
import { renderOrgDocumentToAppHtml } from "./export.js";

type Ranged = Node & { sourceRange?: { startLine: number; endLine: number } };

function inlineText(nodes: InlineNode[]): string {
  return nodes.map(node => node.type === "Text" ? node.value
    : node.type === "Emphasis" ? node.content
    : node.type === "Link" ? node.descriptionRaw ?? node.targetRaw
    : "raw" in node ? node.raw : "").join("");
}

function visibleText(nodes: Node[]): string {
  return nodes.map(node => {
    switch (node.type) {
      case "Paragraph": return inlineText(node.children);
      case "Headline": return `${inlineText(node.title)} ${visibleText(node.children)}`;
      case "List": return visibleText(node.items);
      case "ListItem": return `${inlineText(node.descriptionTag ?? [])} ${visibleText(node.children)}`;
      case "Text": return node.value;
      case "SrcBlock": return node.bodyRaw;
      case "Table": return node.rows.filter(row => row.type === "TableRow").map(row => row.cells.map(cell => inlineText(parseInlinesFromText(cell))).join(" ")).join("\n");
      case "Block": return ["quote", "verse", "example", "center"].includes(node.kind) ? node.bodyRaw : "";
      default: return "";
    }
  }).join("\n").trim();
}

function parse(source: string, sequences: string[] = []): DocumentNode {
  const normalized = source.replace(/\r\n?/g, "\n");
  const options = { sourceRanges: true, todoSequences: documentTodoSequences(normalized,
    sequences.length ? parseTodoSequenceDefinitions(sequences) : []) };
  try { return parseOrgToCanonicalAst(normalized, options); }
  catch (error) {
    if (!(error instanceof Error) || !error.message.includes("Unsupported construct: tab character")) throw error;
    return parseOrgToCanonicalAst(normalized.replace(/\t/g, "  "), options);
  }
}

export function indexDocument(source: string, path: string, sequences: string[] = []) {
  const doc = parse(source, sequences);
  const title = doc.children.find(node => node.type === "KeywordLine" && node.keyRaw.toUpperCase() === "TITLE");
  const pageTitle = title?.type === "KeywordLine" ? title.valueRaw.trim() : path.split("/").pop() ?? path;
  const entries = [{ path, title: pageTitle, parent: "", line: 0, nodeID: "", body: visibleText(doc.children.filter(n => n.type !== "Headline")) }];
  function walk(nodes: Node[], parents: string[]) {
    for (const node of nodes) {
      if (node.type !== "Headline") continue;
      const title = inlineText(node.title);
      const drawer = node.children.find(n => n.type === "PropertyDrawer");
      const nodeID = drawer?.type === "PropertyDrawer" ? drawer.properties.find(p => p.key.toUpperCase() === "ID")?.value ?? "" : "";
      entries.push({ path, title, parent: parents.join(" › "), line: (node as Ranged).sourceRange!.startLine,
        nodeID, body: visibleText(node.children.filter(n => n.type !== "Headline")) });
      walk(node.children, [...parents, title]);
    }
  }
  walk(doc.children, [pageTitle]);
  return entries;
}

export function renderDocument(source: string, path: string, line = 0, nodeID = "", sequences: string[] = [], expectedTitle = "") {
  const doc = parse(source, sequences);
  let selected: HeadlineNode | undefined;
  function walk(nodes: Node[]) {
    for (const node of nodes) {
      if (node.type !== "Headline") continue;
      const drawer = node.children.find(n => n.type === "PropertyDrawer");
      const id = drawer?.type === "PropertyDrawer" ? drawer.properties.find(p => p.key.toUpperCase() === "ID")?.value : undefined;
      if (nodeID ? id === nodeID : (node as Ranged).sourceRange?.startLine === line) selected = node;
      walk(node.children);
    }
  }
  if (line > 0) {
    walk(doc.children);
    if (!selected || (!nodeID && expectedTitle && inlineText(selected.title) !== expectedTitle)) throw new Error("This entry changed. Refresh search and try again.");
  }
  const rendered = renderOrgDocumentToAppHtml(selected ? { ...doc, children: [selected] } : doc, {
    sourcePath: path,
    title: selected ? inlineText(selected.title) : undefined,
    customCss: "body{padding:16px;margin:0;max-width:none} .org2-document-title::before,.org2-headline-summary::before,.org2-headline-summary>h1::before,.org2-headline-summary>h2::before,.org2-headline-summary>h3::before,.org2-headline-summary>h4::before,.org2-headline-summary>h5::before,.org2-headline-summary>h6::before{content:none} .org2-headline{border-left:0}"
  });
  // The local reader never executes source-provided scripts or loads remote embeds.
  const policy = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; script-src 'none'">`;
  return { title: rendered.title, html: rendered.html.replace("<head>", `<head>${policy}`) };
}
