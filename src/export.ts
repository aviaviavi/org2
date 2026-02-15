import path from "node:path";
import type {
  BlockNode,
  DocumentNode,
  EmphasisNode,
  HeadlineNode,
  InlineNode,
  LinkNode,
  ListItemNode,
  ListNode,
  Node,
  ParagraphNode,
  PlanningNode,
  PropertyDrawerNode,
  SrcBlockNode,
  TableHlineNode,
  TableNode,
  TableRowNode,
  TimestampNode,
  TimestampRangeNode,
} from "./ast.js";

function escapeHtml(value: string): string {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function escapeAttr(value: string): string {
  return escapeHtml(value).replace(/`/g, "&#96;");
}

function normalizeStylesheets(stylesheets: string[] | undefined): string[] {
  if (!Array.isArray(stylesheets)) return [];
  return stylesheets.map((href) => String(href || "").trim()).filter((href) => href.length > 0);
}

const DEFAULT_DOCUMENT_STYLE = `:root { color-scheme: light dark; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem auto; max-width: 860px; padding: 0 1rem; line-height: 1.5; }
main { display: grid; gap: 0.75rem; }
section.org2-headline { margin: 0.5rem 0 1rem; }
h1,h2,h3,h4,h5,h6 { margin: 1rem 0 0.5rem; line-height: 1.25; }
.org2-todo { font-size: 0.8em; font-weight: 700; letter-spacing: 0.02em; text-transform: uppercase; opacity: 0.9; }
.org2-tags { font-size: 0.8em; opacity: 0.8; }
.org2-tag { border: 1px solid currentColor; border-radius: 999px; padding: 0 0.35em; }
.org2-planning { font-size: 0.95em; opacity: 0.9; }
.org2-planning-kind { font-weight: 600; }
.org2-properties { display: grid; grid-template-columns: max-content 1fr; gap: 0.15rem 0.75rem; margin: 0.5rem 0; }
.org2-properties dt { font-weight: 600; }
.org2-properties dd { margin: 0; }
.org2-src, .org2-example, .org2-verse, .org2-comment, .org2-directive, pre { overflow-x: auto; padding: 0.75rem; border-radius: 0.5rem; background: rgba(127,127,127,0.12); }
.org2-center { text-align: center; }
.org2-underline { text-decoration: underline; }
table { border-collapse: collapse; width: 100%; margin: 0.5rem 0 1rem; }
th, td { border: 1px solid rgba(127,127,127,0.35); padding: 0.35rem 0.5rem; text-align: left; }
thead th { background: rgba(127,127,127,0.16); }
a { text-decoration-thickness: 0.08em; text-underline-offset: 0.15em; }`;

const DEFAULT_INDEX_STYLE = `:root { color-scheme: light dark; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem auto; max-width: 860px; padding: 0 1rem; line-height: 1.5; }
main { display: grid; gap: 1rem; }
h1 { margin: 0; }
ul.org2-export-index { padding-left: 1.25rem; margin: 0; display: grid; gap: 0.35rem; }
.org2-export-source { opacity: 0.75; font-size: 0.9em; }
a { text-decoration-thickness: 0.08em; text-underline-offset: 0.15em; }`;

function renderHeadStyleSection(opts: {
  stylesheets?: string[];
  includeDefaultStyle?: boolean;
  defaultStyle: string;
}): string {
  const includeDefaultStyle = opts.includeDefaultStyle !== false;
  const stylesheets = normalizeStylesheets(opts.stylesheets);
  const stylesheetLinks = stylesheets
    .map((href) => `<link rel="stylesheet" href="${escapeAttr(href)}" />`)
    .join("\n");

  const defaultStyleBlock = includeDefaultStyle ? `<style>\n${opts.defaultStyle}\n</style>` : "";

  if (stylesheetLinks && defaultStyleBlock) {
    return `${stylesheetLinks}\n${defaultStyleBlock}\n`;
  }

  if (stylesheetLinks) {
    return `${stylesheetLinks}\n`;
  }

  if (defaultStyleBlock) {
    return `${defaultStyleBlock}\n`;
  }

  return "";
}

function inlineToText(node: InlineNode): string {
  if (node.type === "Text") return node.value;
  if (node.type === "Timestamp") return node.raw;
  if (node.type === "TimestampRange") return `${node.start.raw}${node.separatorRaw}${node.end.raw}`;
  if (node.type === "Emphasis") return node.content;
  if (node.type === "Link") return node.descriptionRaw || node.targetRaw;
  return "";
}

function renderTimestamp(node: TimestampNode): string {
  const klass = node.active ? "org2-timestamp active" : "org2-timestamp inactive";
  return `<time class="${klass}">${escapeHtml(node.raw)}</time>`;
}

function renderTimestampRange(node: TimestampRangeNode): string {
  const klass = node.start.active ? "org2-timestamp-range active" : "org2-timestamp-range inactive";
  return `<time class="${klass}">${escapeHtml(node.start.raw + node.separatorRaw + node.end.raw)}</time>`;
}

function renderEmphasis(node: EmphasisNode): string {
  const content = escapeHtml(node.content);
  if (node.kind === "bold") return `<strong>${content}</strong>`;
  if (node.kind === "italic") return `<em>${content}</em>`;
  if (node.kind === "underline") return `<span class="org2-underline">${content}</span>`;
  if (node.kind === "strike") return `<del>${content}</del>`;
  return `<code>${content}</code>`;
}

function renderLink(node: LinkNode): string {
  const href = String(node.targetRaw || "").trim();
  const text = String(node.descriptionRaw || node.targetRaw || "").trim() || href;
  return `<a href="${escapeAttr(href)}">${escapeHtml(text)}</a>`;
}

function renderInline(node: InlineNode): string {
  if (node.type === "Text") return escapeHtml(node.value);
  if (node.type === "Timestamp") return renderTimestamp(node);
  if (node.type === "TimestampRange") return renderTimestampRange(node);
  if (node.type === "Emphasis") return renderEmphasis(node);
  if (node.type === "Link") return renderLink(node);
  return "";
}

function renderInlineChildren(nodes: InlineNode[]): string {
  return nodes.map((node) => renderInline(node)).join("");
}

function renderParagraph(node: ParagraphNode): string {
  return `<p>${renderInlineChildren(node.children)}</p>`;
}

function renderPlanning(node: PlanningNode): string {
  const raw = node.timestamp
    ? node.timestamp.type === "Timestamp"
      ? node.timestamp.raw
      : node.timestamp.start.raw + node.timestamp.separatorRaw + node.timestamp.end.raw
    : node.raw;
  return `<p class="org2-planning"><span class="org2-planning-kind">${escapeHtml(node.kind)}</span> ${escapeHtml(raw)}</p>`;
}

function renderPropertyDrawer(node: PropertyDrawerNode): string {
  if (!node.properties.length) return "";

  const rows = node.properties
    .map((property) => `<dt>${escapeHtml(property.key)}</dt><dd>${escapeHtml(property.value)}</dd>`)
    .join("\n");

  return `<dl class="org2-properties">\n${rows}\n</dl>`;
}

function renderSrcBlock(node: SrcBlockNode): string {
  const language = String(node.begin.afterKeywordRaw || "")
    .trim()
    .split(/\s+/)[0];
  const classAttr = language ? ` class="language-${escapeAttr(language)}"` : "";
  const body = escapeHtml(node.bodyRaw.replace(/\n$/, ""));
  return `<pre class="org2-src"><code${classAttr}>${body}</code></pre>`;
}

function renderBlock(node: BlockNode): string {
  const body = escapeHtml(node.bodyRaw.replace(/\n$/, ""));

  if (node.kind === "quote") return `<blockquote>${body}</blockquote>`;
  if (node.kind === "center") return `<div class="org2-center">${body}</div>`;
  if (node.kind === "verse") return `<pre class="org2-verse">${body}</pre>`;
  if (node.kind === "comment") return `<pre class="org2-comment">${body}</pre>`;
  return `<pre class="org2-example">${body}</pre>`;
}

function renderTableRow(row: TableRowNode, asHeader: boolean): string {
  const cellTag = asHeader ? "th" : "td";
  const cells = row.cells.map((cell) => `<${cellTag}>${escapeHtml(String(cell || "").trim())}</${cellTag}>`).join("");
  return `<tr>${cells}</tr>`;
}

function renderTable(node: TableNode): string {
  const rows = node.rows;
  const firstHline = rows.findIndex((row): row is TableHlineNode => row.type === "TableHline");

  const headerRows =
    firstHline > 0
      ? rows.slice(0, firstHline).filter((row): row is TableRowNode => row.type === "TableRow")
      : [];

  const bodyRows =
    firstHline >= 0
      ? rows.slice(firstHline + 1).filter((row): row is TableRowNode => row.type === "TableRow")
      : rows.filter((row): row is TableRowNode => row.type === "TableRow");

  const resolvedBodyRows = bodyRows.length > 0 ? bodyRows : headerRows;
  const renderedHead = headerRows.length > 0 ? `<thead>\n${headerRows.map((row) => renderTableRow(row, true)).join("\n")}\n</thead>` : "";
  const renderedBody = `<tbody>\n${resolvedBodyRows.map((row) => renderTableRow(row, false)).join("\n")}\n</tbody>`;

  return `<table>\n${[renderedHead, renderedBody].filter(Boolean).join("\n")}\n</table>`;
}

function renderListItem(node: ListItemNode): string {
  const body = renderNodes(node.children);
  const checkbox =
    node.checkbox === "checked"
      ? '<input type="checkbox" checked disabled /> '
      : node.checkbox === "unchecked"
        ? '<input type="checkbox" disabled /> '
        : "";

  if (!body.trim()) return `<li>${checkbox}</li>`;
  if (body.includes("\n")) return `<li>${checkbox}\n${body}\n</li>`;
  return `<li>${checkbox}${body}</li>`;
}

function renderList(node: ListNode): string {
  const tag = node.ordered ? "ol" : "ul";
  const items = node.items.map((item) => renderListItem(item)).join("\n");
  return `<${tag}>\n${items}\n</${tag}>`;
}

function renderHeadline(node: HeadlineNode): string {
  const headingLevel = Math.max(1, Math.min(6, node.level));
  const headingTag = `h${headingLevel}`;
  const title = renderInlineChildren(node.title);
  const todo = node.todo ? `<span class="org2-todo">${escapeHtml(node.todo)}</span> ` : "";
  const tags =
    node.tags && node.tags.length > 0
      ? ` <span class="org2-tags">${node.tags.map((tag) => `<span class="org2-tag">${escapeHtml(tag)}</span>`).join(" ")}</span>`
      : "";

  const childrenHtml = renderNodes(node.children);
  if (!childrenHtml.trim()) {
    return `<section class="org2-headline level-${node.level}">\n<${headingTag}>${todo}${title}${tags}</${headingTag}>\n</section>`;
  }

  return `<section class="org2-headline level-${node.level}">\n<${headingTag}>${todo}${title}${tags}</${headingTag}>\n${childrenHtml}\n</section>`;
}

function renderNode(node: Node): string {
  if (node.type === "Headline") return renderHeadline(node);
  if (node.type === "Paragraph") return renderParagraph(node);
  if (node.type === "List") return renderList(node);
  if (node.type === "ListItem") return renderListItem(node);
  if (node.type === "Planning") return renderPlanning(node);
  if (node.type === "PropertyDrawer") return renderPropertyDrawer(node);
  if (node.type === "SrcBlock") return renderSrcBlock(node);
  if (node.type === "Block") return renderBlock(node);
  if (node.type === "Table") return renderTable(node);
  if (node.type === "Drawer") {
    const name = escapeHtml(node.nameRaw);
    const body = escapeHtml(node.bodyRaw.replace(/\n$/, ""));
    return `<details class="org2-drawer"><summary>${name}</summary><pre>${body}</pre></details>`;
  }
  if (node.type === "KeywordLine") {
    const key = String(node.keyRaw || "").trim().toUpperCase();
    if (key === "TITLE" || key === "AUTHOR" || key === "DATE") return "";
    return `<p class="org2-keyword"><span class="org2-keyword-name">${escapeHtml(node.keyRaw)}</span>: ${escapeHtml(node.valueRaw)}</p>`;
  }
  if (node.type === "DirectiveLine") {
    return `<pre class="org2-directive">${escapeHtml(node.raw)}</pre>`;
  }
  if (node.type === "CommentLine") return "";
  if (node.type === "Text") {
    const text = String(node.value || "");
    return text.trim().length > 0 ? `<p>${escapeHtml(text)}</p>` : "";
  }

  return "";
}

function renderNodes(nodes: Node[]): string {
  return nodes
    .map((node) => renderNode(node))
    .filter((html) => String(html || "").trim().length > 0)
    .join("\n");
}

function findTitleFromKeywords(doc: DocumentNode): string | null {
  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    if (String(node.keyRaw || "").trim().toUpperCase() !== "TITLE") continue;
    const value = String(node.valueRaw || "").trim();
    if (value) return value;
  }
  return null;
}

function findTitleFromHeadlines(doc: DocumentNode): string | null {
  for (const node of doc.children) {
    if (node.type !== "Headline") continue;
    const text = node.title.map((child) => inlineToText(child)).join("").trim();
    if (text) return text;
  }
  return null;
}

function resolveTitle(doc: DocumentNode, explicitTitle: string | undefined, sourcePath: string | undefined): string {
  const explicit = String(explicitTitle || "").trim();
  if (explicit) return explicit;

  const keyword = findTitleFromKeywords(doc);
  if (keyword) return keyword;

  const headline = findTitleFromHeadlines(doc);
  if (headline) return headline;

  if (sourcePath) return path.basename(sourcePath);
  return "Org2 Document";
}

export function renderOrgDocumentToHtml(
  doc: DocumentNode,
  opts: { title?: string; sourcePath?: string; stylesheets?: string[]; includeDefaultStyle?: boolean } = {},
): { html: string; title: string } {
  const title = resolveTitle(doc, opts.title, opts.sourcePath);
  const body = renderNodes(doc.children);
  const headStyleSection = renderHeadStyleSection({
    stylesheets: opts.stylesheets,
    includeDefaultStyle: opts.includeDefaultStyle,
    defaultStyle: DEFAULT_DOCUMENT_STYLE,
  });

  const html = `<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8" />\n<meta name="viewport" content="width=device-width, initial-scale=1" />\n<title>${escapeHtml(title)}</title>\n${headStyleSection}</head>\n<body>\n<main class="org2-document">\n${body}\n</main>\n</body>\n</html>\n`;

  return { html, title };
}

export type OrgExportIndexItem = {
  title: string;
  href: string;
  sourcePath?: string;
};

export function renderOrgExportIndexToHtml(opts: {
  title?: string;
  sourcePath?: string;
  items: OrgExportIndexItem[];
  stylesheets?: string[];
  includeDefaultStyle?: boolean;
}): { html: string; title: string } {
  const title = String(opts.title || "").trim() || (opts.sourcePath ? path.basename(opts.sourcePath) : "Org2 Export Index");
  const items = Array.isArray(opts.items) ? opts.items : [];

  const listHtml = items
    .map((item) => {
      const itemTitle = String(item.title || "").trim() || String(item.href || "").trim() || "Untitled";
      const href = String(item.href || "").trim() || "#";
      const source = String(item.sourcePath || "").trim();
      const sourceHtml = source ? ` <span class="org2-export-source">(${escapeHtml(source)})</span>` : "";
      return `<li><a href="${escapeAttr(href)}">${escapeHtml(itemTitle)}</a>${sourceHtml}</li>`;
    })
    .join("\n");

  const body = listHtml || "<li>No exported files.</li>";
  const headStyleSection = renderHeadStyleSection({
    stylesheets: opts.stylesheets,
    includeDefaultStyle: opts.includeDefaultStyle,
    defaultStyle: DEFAULT_INDEX_STYLE,
  });

  const html = `<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8" />\n<meta name="viewport" content="width=device-width, initial-scale=1" />\n<title>${escapeHtml(title)}</title>\n${headStyleSection}</head>\n<body>\n<main class="org2-export-index-document">\n<h1>${escapeHtml(title)}</h1>\n<ul class="org2-export-index">\n${body}\n</ul>\n</main>\n</body>\n</html>\n`;

  return { html, title };
}
