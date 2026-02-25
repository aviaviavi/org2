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
import { parseInlinesFromText } from "./parser.js";
import {
  buildBuiltInLinkAbbreviations,
  collectLinkAbbreviationsFromDoc,
  collectLinkAbbreviationsFromRecord,
  expandLinkAbbreviationTarget,
  mergeLinkAbbreviations,
  type LinkAbbreviationMap,
  type LinkAbbreviationRecord,
} from "./link-abbrev.js";
import { COMPAT_CONTENT_CLOSE, COMPAT_CONTENT_OPEN, COMPAT_CONTENT_STYLE_SECTION } from "./publish-defaults.js";

function escapeHtml(value: string): string {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;");
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

const DOCUMENT_TOC_STYLE = `.org2-toc { border: 1px solid rgba(127,127,127,0.35); border-radius: 0.5rem; padding: 0.75rem 1rem; margin: 0.25rem 0 1rem; }
.org2-toc h2 { margin: 0 0 0.5rem; font-size: 1rem; }
.org2-toc ul { margin: 0; padding-left: 1.25rem; display: grid; gap: 0.25rem; }
.org2-toc li.org2-toc-level-2 { margin-left: 0.75rem; }
.org2-toc li.org2-toc-level-3 { margin-left: 1.5rem; }
.org2-toc li.org2-toc-level-4 { margin-left: 2.25rem; }
.org2-toc li.org2-toc-level-5 { margin-left: 3rem; }
.org2-toc li.org2-toc-level-6 { margin-left: 3.75rem; }`;

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

type TocItem = {
  id: string;
  title: string;
  level: number;
  number?: string;
};

type RenderContext = {
  headlineIds?: WeakMap<HeadlineNode, string>;
  headlineSlugIds?: Map<string, string>;
  headlineNumbers?: WeakMap<HeadlineNode, string>;
  rewriteFileLinks?: boolean;
  linkAbbreviations?: LinkAbbreviationMap;
};

export type OrgExportMetadata = {
  author?: string;
  date?: string;
  subtitle?: string;
  description?: string;
  keywords?: string[];
  language?: string;
  htmlHead?: string[];
};

type OrgExportOptions = {
  toc?: boolean;
  tocDepth?: number;
  num?: boolean;
  numDepth?: number;
};

const HIDDEN_DOCUMENT_KEYWORDS = new Set([
  "TITLE",
  "AUTHOR",
  "DATE",
  "SUBTITLE",
  "DESCRIPTION",
  "KEYWORDS",
  "LANGUAGE",
  "HTML_HEAD",
  "HTML_HEAD_EXTRA",
  "OPTIONS",
  "LINK",
]);

function parseKeywordList(value: string): string[] {
  const values = String(value || "")
    .split(/[;,]/)
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
  return Array.from(new Set(values));
}

function normalizeDocumentLanguage(value: string): string | null {
  const normalized = String(value || "").trim();
  if (!normalized) return null;
  if (!/^[A-Za-z0-9-]+$/.test(normalized)) return null;
  return normalized;
}

function parseKeywordOptionsMap(value: string): Map<string, string> {
  const assignments = new Map<string, string>();
  const tokens = String(value || "")
    .trim()
    .split(/\s+/)
    .filter((token) => token.length > 0);

  for (const token of tokens) {
    const separatorIndex = token.indexOf(":");
    if (separatorIndex <= 0) continue;
    const key = token.slice(0, separatorIndex).trim().toLowerCase();
    const optionValue = token.slice(separatorIndex + 1).trim();
    if (!key || !optionValue) continue;
    assignments.set(key, optionValue);
  }

  return assignments;
}

function parseKeywordBooleanOption(value: string | undefined): boolean | null {
  const normalized = String(value || "").trim().toLowerCase();
  if (!normalized) return null;

  if (["t", "true", "yes", "on"].includes(normalized)) return true;
  if (["nil", "false", "no", "off"].includes(normalized)) return false;

  if (/^\d+$/.test(normalized)) {
    return Number(normalized) > 0;
  }

  return null;
}

function parseKeywordPositiveIntegerOption(value: string | undefined): number | null {
  const normalized = String(value || "").trim();
  if (!/^\d+$/.test(normalized)) return null;

  const parsed = Number.parseInt(normalized, 10);
  if (!Number.isFinite(parsed) || parsed < 1) return null;
  return parsed;
}

function collectKeywordOptions(doc: DocumentNode): OrgExportOptions {
  const options: OrgExportOptions = {};

  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    const key = String(node.keyRaw || "").trim().toUpperCase();
    if (key !== "OPTIONS") continue;

    const assignments = parseKeywordOptionsMap(node.valueRaw);
    if (assignments.has("toc")) {
      const tocRaw = assignments.get("toc");
      const parsed = parseKeywordBooleanOption(tocRaw);
      if (parsed !== null) {
        options.toc = parsed;
      }

      const parsedDepth = parseKeywordPositiveIntegerOption(tocRaw);
      if (parsedDepth !== null) {
        options.toc = true;
        options.tocDepth = parsedDepth;
      }
    }

    if (assignments.has("num")) {
      const numRaw = assignments.get("num");
      const parsed = parseKeywordBooleanOption(numRaw);
      if (parsed !== null) {
        options.num = parsed;
      }

      const parsedDepth = parseKeywordPositiveIntegerOption(numRaw);
      if (parsedDepth !== null) {
        options.num = true;
        options.numDepth = parsedDepth;
      }
    }
  }

  return options;
}

function collectKeywordMetadata(doc: DocumentNode): OrgExportMetadata {
  const metadata: OrgExportMetadata = {};

  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    const key = String(node.keyRaw || "").trim().toUpperCase();
    const value = String(node.valueRaw || "").trim();
    if (!value) continue;

    if (key === "AUTHOR" && !metadata.author) {
      metadata.author = value;
      continue;
    }

    if (key === "DATE" && !metadata.date) {
      metadata.date = value;
      continue;
    }

    if (key === "SUBTITLE" && !metadata.subtitle) {
      metadata.subtitle = value;
      continue;
    }

    if (key === "DESCRIPTION" && !metadata.description) {
      metadata.description = value;
      continue;
    }

    if (key === "KEYWORDS" && !metadata.keywords) {
      const parsedKeywords = parseKeywordList(value);
      if (parsedKeywords.length > 0) {
        metadata.keywords = parsedKeywords;
      }
      continue;
    }

    if (key === "LANGUAGE" && !metadata.language) {
      const normalizedLanguage = normalizeDocumentLanguage(value);
      if (normalizedLanguage) {
        metadata.language = normalizedLanguage;
      }
      continue;
    }

    if (key === "HTML_HEAD" || key === "HTML_HEAD_EXTRA") {
      if (!metadata.htmlHead) metadata.htmlHead = [];
      metadata.htmlHead.push(value);
    }
  }

  return metadata;
}

function hasKeywordMetadata(metadata: OrgExportMetadata): boolean {
  return Boolean(
    metadata.author ||
      metadata.date ||
      metadata.subtitle ||
      metadata.description ||
      (Array.isArray(metadata.keywords) && metadata.keywords.length > 0) ||
      metadata.language ||
      (Array.isArray(metadata.htmlHead) && metadata.htmlHead.length > 0),
  );
}

function renderHeadMetaSection(metadata: OrgExportMetadata): string {
  if (!hasKeywordMetadata(metadata)) return "";

  const rows: string[] = [];
  if (metadata.author) {
    rows.push(`<meta name="author" content="${escapeAttr(metadata.author)}" />`);
  }
  if (metadata.date) {
    rows.push(`<meta name="date" content="${escapeAttr(metadata.date)}" />`);
  }
  if (metadata.subtitle) {
    rows.push(`<meta name="subtitle" content="${escapeAttr(metadata.subtitle)}" />`);
  }
  if (metadata.description) {
    rows.push(`<meta name="description" content="${escapeAttr(metadata.description)}" />`);
  }
  if (Array.isArray(metadata.keywords) && metadata.keywords.length > 0) {
    rows.push(`<meta name="keywords" content="${escapeAttr(metadata.keywords.join(", "))}" />`);
  }

  return rows.length > 0 ? `${rows.join("\n")}\n` : "";
}

function renderHeadExtraSection(metadata: OrgExportMetadata, extraHead?: string[]): string {
  const snippets = [
    ...(Array.isArray(metadata.htmlHead) ? metadata.htmlHead : []),
    ...(Array.isArray(extraHead) ? extraHead : []),
  ]
    .map((snippet) => String(snippet || "").trim())
    .filter((snippet) => snippet.length > 0);
  return snippets.length > 0 ? `${snippets.join("\n")}\n` : "";
}

function slugifyHeadlineTitle(value: string): string {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return normalized || "section";
}

function normalizeAnchorId(value: string): string | null {
  const normalized = String(value || "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/[^A-Za-z0-9_.:-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return normalized || null;
}

function findHeadlineCustomId(node: HeadlineNode): string | null {
  for (const child of node.children) {
    if (child.type !== "PropertyDrawer") continue;
    for (const property of child.properties) {
      if (String(property.key || "").trim().toUpperCase() !== "CUSTOM_ID") continue;
      const normalized = normalizeAnchorId(property.value);
      if (normalized) return normalized;
    }
  }

  return null;
}

function normalizeTocDepth(value: number | undefined): number | null {
  if (value === undefined || value === null) return null;
  if (!Number.isFinite(value)) return null;
  const normalized = Math.trunc(value);
  if (normalized < 1) return null;
  return Math.min(6, normalized);
}

function normalizeHeadlineNumberDepth(value: number | undefined): number | null {
  if (value === undefined || value === null) return null;
  if (!Number.isFinite(value)) return null;
  const normalized = Math.trunc(value);
  if (normalized < 1) return null;
  return Math.min(6, normalized);
}

function buildHeadlineAnchors(
  doc: DocumentNode,
  opts: {
    includeToc?: boolean;
    includeTocDepth?: number;
    includeHeadlineNumbers?: boolean;
    includeHeadlineNumberDepth?: number;
  } = {},
): {
  items: TocItem[];
  headlineIds: WeakMap<HeadlineNode, string>;
  headlineSlugIds: Map<string, string>;
  headlineNumbers: WeakMap<HeadlineNode, string>;
} {
  const includeToc = opts.includeToc === true;
  const includeTocDepth = normalizeTocDepth(opts.includeTocDepth);
  const includeHeadlineNumbers = opts.includeHeadlineNumbers === true;
  const includeHeadlineNumberDepth = normalizeHeadlineNumberDepth(opts.includeHeadlineNumberDepth);
  const items: TocItem[] = [];
  const headlineIds = new WeakMap<HeadlineNode, string>();
  const headlineSlugIds = new Map<string, string>();
  const headlineNumbers = new WeakMap<HeadlineNode, string>();
  const headlineNumberCounts = [0, 0, 0, 0, 0, 0];
  const idCounts = new Map<string, number>();

  const nextId = (baseId: string): string => {
    const normalizedBase = normalizeAnchorId(baseId) || "section";
    const key = normalizedBase.toLowerCase();
    const count = (idCounts.get(key) || 0) + 1;
    idCounts.set(key, count);
    if (count === 1) return normalizedBase;
    return `${normalizedBase}-${count}`;
  };

  const visitNodes = (nodes: Node[]): void => {
    for (const node of nodes) {
      if (node.type !== "Headline") continue;
      const title = node.title.map((child) => inlineToText(child)).join("").trim() || "Untitled";
      const titleSlug = slugifyHeadlineTitle(title);
      const customId = findHeadlineCustomId(node);
      const id = nextId(customId || titleSlug);
      const level = Math.max(1, Math.min(6, node.level));
      headlineIds.set(node, id);
      const titleKey = titleSlug.toLowerCase();
      if (!headlineSlugIds.has(titleKey)) {
        headlineSlugIds.set(titleKey, id);
      }

      headlineNumberCounts[level - 1] += 1;
      for (let idx = level; idx < headlineNumberCounts.length; idx += 1) {
        headlineNumberCounts[idx] = 0;
      }

      let headlineNumber: string | null = null;
      if (includeHeadlineNumbers && (includeHeadlineNumberDepth === null || level <= includeHeadlineNumberDepth)) {
        const parts = headlineNumberCounts.slice(0, level).filter((value) => value > 0);
        if (parts.length > 0) {
          headlineNumber = parts.join(".");
          headlineNumbers.set(node, headlineNumber);
        }
      }

      if (includeToc && (includeTocDepth === null || level <= includeTocDepth)) {
        items.push({
          id,
          title,
          level,
          ...(headlineNumber ? { number: headlineNumber } : {}),
        });
      }

      visitNodes(node.children);
    }
  };

  visitNodes(doc.children);
  return { items, headlineIds, headlineSlugIds, headlineNumbers };
}

function renderToc(items: TocItem[]): string {
  if (!Array.isArray(items) || items.length === 0) return "";
  const rows = items
    .map((item) => {
      const level = Math.max(1, Math.min(6, item.level));
      const numberPrefix = item.number ? `${escapeHtml(item.number)} ` : "";
      return `<li class="org2-toc-level-${level}"><a href="#${escapeAttr(item.id)}">${numberPrefix}${escapeHtml(item.title)}</a></li>`;
    })
    .join("\n");
  return `<nav class="org2-toc" aria-label="Table of contents">\n<h2>Contents</h2>\n<ul>\n${rows}\n</ul>\n</nav>`;
}

function rewriteOrgFileHrefForHtml(rawHref: string): string {
  const href = String(rawHref || "").trim();
  if (!href) return href;

  const hasScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(href);
  const isFileScheme = /^file:/i.test(href);
  if (hasScheme && !isFileScheme) return href;

  const source = isFileScheme ? href.slice(5) : href;
  const searchSeparatorIndex = source.indexOf("::");
  const pathPart = searchSeparatorIndex >= 0 ? source.slice(0, searchSeparatorIndex) : source;
  const searchSuffix = searchSeparatorIndex >= 0 ? source.slice(searchSeparatorIndex + 2) : "";

  if (!/\.(org|org2)(?=($|[?#]))/i.test(pathPart)) return href;
  const rewrittenPath = pathPart.replace(/\.(org|org2)(?=($|[?#]))/i, ".html");

  if (!searchSuffix.trim()) return rewrittenPath;

  const trimmedSearchSuffix = searchSuffix.trim();
  if (trimmedSearchSuffix.startsWith("#")) {
    return `${rewrittenPath}${trimmedSearchSuffix}`;
  }

  if (trimmedSearchSuffix.startsWith("*")) {
    const headingText = trimmedSearchSuffix.replace(/^\*+\s*/, "").trim();
    return `${rewrittenPath}#${slugifyHeadlineTitle(headingText || "section")}`;
  }

  return href;
}

function rewriteOrgInternalHrefForHtml(rawHref: string, context: RenderContext): string {
  const href = String(rawHref || "").trim();
  if (!href) return href;

  if (href.startsWith("#")) {
    const normalizedAnchor = normalizeAnchorId(href.slice(1));
    return normalizedAnchor ? `#${normalizedAnchor}` : href;
  }

  if (!href.startsWith("*")) return href;

  const headingText = href.replace(/^\*+\s*/, "").trim();
  const headingSlug = slugifyHeadlineTitle(headingText || "section");
  const resolvedHeadingId = context.headlineSlugIds?.get(headingSlug.toLowerCase()) || headingSlug;
  return `#${resolvedHeadingId}`;
}

function linkTargetNeedsHeadingAnchor(rawTarget: string): boolean {
  const target = String(rawTarget || "").trim();
  if (!target) return false;
  return target.startsWith("#") || target.startsWith("*");
}

function resolveDefaultInternalLinkText(rawTarget: string): string | null {
  const target = String(rawTarget || "").trim();
  if (!target) return null;

  if (target.startsWith("*")) {
    const headingText = target.replace(/^\*+\s*/, "").trim();
    return headingText || null;
  }

  if (target.startsWith("#")) {
    const anchorRaw = target.slice(1).trim();
    if (!anchorRaw) return null;
    return normalizeAnchorId(anchorRaw) || anchorRaw;
  }

  return null;
}

function inlineNodesNeedHeadingAnchors(nodes: InlineNode[]): boolean {
  for (const node of nodes) {
    if (node.type !== "Link") continue;
    if (linkTargetNeedsHeadingAnchor(node.targetRaw)) return true;
  }

  return false;
}

function nodesNeedHeadingAnchors(nodes: Node[]): boolean {
  for (const node of nodes) {
    if (node.type === "Headline") {
      if (inlineNodesNeedHeadingAnchors(node.title)) return true;
      if (nodesNeedHeadingAnchors(node.children)) return true;
      continue;
    }

    if (node.type === "Paragraph") {
      if (inlineNodesNeedHeadingAnchors(node.children)) return true;
      continue;
    }

    if (node.type === "List") {
      for (const item of node.items) {
        if (nodesNeedHeadingAnchors(item.children)) return true;
      }
      continue;
    }

    if (node.type === "ListItem") {
      if (nodesNeedHeadingAnchors(node.children)) return true;
    }
  }

  return false;
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

function renderLink(node: LinkNode, context: RenderContext): string {
  const hrefRaw = String(node.targetRaw || "").trim();
  const expandedHrefRaw = expandLinkAbbreviationTarget(hrefRaw, context.linkAbbreviations);
  let href = expandedHrefRaw;

  if (context.rewriteFileLinks) {
    href = rewriteOrgFileHrefForHtml(expandedHrefRaw);
  }

  if (linkTargetNeedsHeadingAnchor(expandedHrefRaw)) {
    href = rewriteOrgInternalHrefForHtml(expandedHrefRaw, context);
  }

  const explicitDescription = String(node.descriptionRaw || "").trim();
  const defaultInternalText = resolveDefaultInternalLinkText(hrefRaw);
  const text = explicitDescription || defaultInternalText || String(node.targetRaw || "").trim() || href;
  return `<a href="${escapeAttr(href)}">${escapeHtml(text)}</a>`;
}

function renderInline(node: InlineNode, context: RenderContext): string {
  if (node.type === "Text") return escapeHtml(node.value);
  if (node.type === "Timestamp") return renderTimestamp(node);
  if (node.type === "TimestampRange") return renderTimestampRange(node);
  if (node.type === "Emphasis") return renderEmphasis(node);
  if (node.type === "Link") return renderLink(node, context);
  return "";
}

function renderInlineChildren(nodes: InlineNode[], context: RenderContext): string {
  return nodes.map((node) => renderInline(node, context)).join("");
}

function renderParagraph(node: ParagraphNode, context: RenderContext): string {
  if (node.children.length === 1 && node.children[0]?.type === "Text") {
    const raw = String(node.children[0].value || "").trim();
    if (raw === "--") return "<p>&#x2013;</p>";
    if (raw === "---") return "<p>&#x2014;</p>";
  }
  return `<p>${renderInlineChildren(node.children, context)}</p>`;
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
  const languageRaw = String(node.begin.afterKeywordRaw || "")
    .trim()
    .split(/\s+/)[0];
  const language = languageRaw.toLowerCase().replace(/[^a-z0-9_+-]/g, "");
  const languageClass = language ? ` language-${language}` : "";
  const codeClassAttr = language ? ` class="language-${escapeAttr(language)}"` : "";
  const body = escapeHtml(node.bodyRaw.replace(/\n$/, ""));
  const baseStyle = "padding: 0.9rem 1rem; border: 1px solid rgba(127,127,127,0.28); border-radius: 0.6rem; background: rgba(127,127,127,0.11); font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace; font-size: 0.92rem; line-height: 1.28;";
  return `<pre class="org2-src${languageClass}" style="${escapeAttr(baseStyle)}"><code${codeClassAttr}>${body}</code></pre>`;
}

function renderBlock(node: BlockNode): string {
  const bodyRaw = node.bodyRaw.replace(/\n$/, "");
  const body = escapeHtml(bodyRaw);

  if (node.kind === "quote") return `<blockquote>${body}</blockquote>`;
  if (node.kind === "center") return `<div class="org2-center">${body}</div>`;
  if (node.kind === "verse") return `<pre class="org2-verse">${body}</pre>`;
  if (node.kind === "comment") return `<pre class="org2-comment">${body}</pre>`;
  if (node.kind === "export") {
    const exportTarget = String(node.begin.afterKeywordRaw || "").trim().toLowerCase();
    if (exportTarget === "html") return bodyRaw;
    return `<pre class="org2-export">${body}</pre>`;
  }
  return `<pre class="org2-example">${body}</pre>`;
}

function renderTableRow(row: TableRowNode, asHeader: boolean, context: RenderContext): string {
  const cellTag = asHeader ? "th" : "td";
  const cells = row.cells
    .map((cell) => {
      const parsed = parseInlinesFromText(String(cell || "").trim());
      const rendered = renderInlineChildren(parsed, context);
      return `<${cellTag}>${rendered}</${cellTag}>`;
    })
    .join("");
  return `<tr>${cells}</tr>`;
}

function renderTable(node: TableNode, context: RenderContext): string {
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
  const renderedHead =
    headerRows.length > 0 ? `<thead>\n${headerRows.map((row) => renderTableRow(row, true, context)).join("\n")}\n</thead>` : "";
  const renderedBody = `<tbody>\n${resolvedBodyRows.map((row) => renderTableRow(row, false, context)).join("\n")}\n</tbody>`;

  return `<table>\n${[renderedHead, renderedBody].filter(Boolean).join("\n")}\n</table>`;
}

function renderListItem(node: ListItemNode, context: RenderContext): string {
  const body = renderNodes(node.children, context);
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

function renderList(node: ListNode, context: RenderContext): string {
  const tag = node.ordered ? "ol" : "ul";
  const items = node.items.map((item) => renderListItem(item, context)).join("\n");
  return `<${tag}>\n${items}\n</${tag}>`;
}

function renderHeadline(node: HeadlineNode, context: RenderContext): string {
  const headingLevel = Math.max(1, Math.min(6, node.level));
  const headingTag = `h${headingLevel}`;
  const title = renderInlineChildren(node.title, context);
  const headingNumberRaw = context.headlineNumbers?.get(node);
  const headingNumber = headingNumberRaw ? `<span class="org2-headline-number">${escapeHtml(headingNumberRaw)}</span> ` : "";
  const todo = node.todo ? `<span class="org2-todo">${escapeHtml(node.todo)}</span> ` : "";
  const tags =
    node.tags && node.tags.length > 0
      ? ` <span class="org2-tags">${node.tags.map((tag) => `<span class="org2-tag">${escapeHtml(tag)}</span>`).join(" ")}</span>`
      : "";
  const headingId = context.headlineIds?.get(node);
  const headingIdAttr = headingId ? ` id="${escapeAttr(headingId)}"` : "";

  const childrenHtml = renderNodes(node.children, context);
  if (!childrenHtml.trim()) {
    return `<section class="org2-headline level-${node.level}">\n<${headingTag}${headingIdAttr}>${headingNumber}${todo}${title}${tags}</${headingTag}>\n</section>`;
  }

  return `<section class="org2-headline level-${node.level}">\n<${headingTag}${headingIdAttr}>${headingNumber}${todo}${title}${tags}</${headingTag}>\n${childrenHtml}\n</section>`;
}

function renderNode(node: Node, context: RenderContext): string {
  if (node.type === "Headline") return renderHeadline(node, context);
  if (node.type === "Paragraph") return renderParagraph(node, context);
  if (node.type === "List") return renderList(node, context);
  if (node.type === "ListItem") return renderListItem(node, context);
  if (node.type === "Planning") return renderPlanning(node);
  if (node.type === "PropertyDrawer") return renderPropertyDrawer(node);
  if (node.type === "SrcBlock") return renderSrcBlock(node);
  if (node.type === "Block") return renderBlock(node);
  if (node.type === "Table") return renderTable(node, context);
  if (node.type === "Drawer") {
    const name = escapeHtml(node.nameRaw);
    const body = escapeHtml(node.bodyRaw.replace(/\n$/, ""));
    return `<details class="org2-drawer"><summary>${name}</summary><pre>${body}</pre></details>`;
  }
  if (node.type === "KeywordLine") {
    const key = String(node.keyRaw || "").trim().toUpperCase();
    if (HIDDEN_DOCUMENT_KEYWORDS.has(key)) return "";
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

function renderNodes(nodes: Node[], context: RenderContext = {}): string {
  return nodes
    .map((node) => renderNode(node, context))
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

function findSubtitleFromKeywords(doc: DocumentNode): string | null {
  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    if (String(node.keyRaw || "").trim().toUpperCase() !== "SUBTITLE") continue;
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

function renderDocumentHeader(opts: { title: string; subtitle?: string }): string {
  const title = String(opts.title || "").trim();
  if (!title) return "";

  const subtitle = String(opts.subtitle || "").trim();
  const subtitleHtml = subtitle ? `\n<p class="org2-document-subtitle" role="doc-subtitle">${escapeHtml(subtitle)}</p>` : "";
  return `<header class="org2-document-header">\n<h1 class="org2-document-title">${escapeHtml(title)}</h1>${subtitleHtml}\n</header>`;
}

type ResolvedDocumentRenderOptions = {
  includeToc: boolean;
  includeTocDepth: number | undefined;
  includeHeadlineNumbers: boolean;
  includeHeadlineNumberDepth: number | undefined;
  includeDocumentHeader: boolean;
};

function resolveDocumentRenderOptions(
  doc: DocumentNode,
  opts: {
    includeToc?: boolean;
    includeTocDepth?: number;
    includeHeadlineNumbers?: boolean;
    includeHeadlineNumberDepth?: number;
    includeDocumentHeader?: boolean;
  },
): ResolvedDocumentRenderOptions {
  const exportOptions = collectKeywordOptions(doc);
  const includeToc = opts.includeToc === true || (opts.includeToc !== false && exportOptions.toc === true);
  const includeTocDepth =
    normalizeTocDepth(opts.includeTocDepth) ?? normalizeTocDepth(exportOptions.tocDepth) ?? undefined;
  const includeHeadlineNumbers =
    opts.includeHeadlineNumbers === true ||
    (opts.includeHeadlineNumbers !== false && exportOptions.num === true);
  const includeHeadlineNumberDepth =
    normalizeHeadlineNumberDepth(opts.includeHeadlineNumberDepth) ??
    normalizeHeadlineNumberDepth(exportOptions.numDepth) ??
    undefined;
  const includeDocumentHeader =
    opts.includeDocumentHeader === true ||
    (opts.includeDocumentHeader !== false && Boolean(findSubtitleFromKeywords(doc)));

  return {
    includeToc,
    includeTocDepth,
    includeHeadlineNumbers,
    includeHeadlineNumberDepth,
    includeDocumentHeader,
  };
}

function buildDocumentRenderContext(
  doc: DocumentNode,
  opts: {
    includeToc: boolean;
    includeTocDepth?: number;
    includeHeadlineNumbers: boolean;
    includeHeadlineNumberDepth?: number;
    rewriteFileLinks?: boolean;
    linkAbbreviations?: LinkAbbreviationRecord;
    linearTeam?: string;
  },
): { context: RenderContext; tocItems: TocItem[] } {
  let tocItems: TocItem[] = [];
  const includeHeadingAnchors = opts.includeToc || opts.rewriteFileLinks === true || nodesNeedHeadingAnchors(doc.children);
  const includeHeadlineData = includeHeadingAnchors || opts.includeHeadlineNumbers;
  const builtIns = buildBuiltInLinkAbbreviations(opts.linearTeam);
  const configAbbreviations = collectLinkAbbreviationsFromRecord(opts.linkAbbreviations);
  const documentAbbreviations = collectLinkAbbreviationsFromDoc(doc);

  const context: RenderContext = {
    rewriteFileLinks: opts.rewriteFileLinks === true,
    // Precedence: built-ins < config < document-local #+LINK
    linkAbbreviations: mergeLinkAbbreviations([builtIns, configAbbreviations, documentAbbreviations]),
  };

  if (includeHeadlineData) {
    const anchors = buildHeadlineAnchors(doc, {
      includeToc: opts.includeToc,
      includeTocDepth: opts.includeTocDepth,
      includeHeadlineNumbers: opts.includeHeadlineNumbers,
      includeHeadlineNumberDepth: opts.includeHeadlineNumberDepth,
    });
    tocItems = anchors.items;
    context.headlineIds = anchors.headlineIds;
    context.headlineSlugIds = anchors.headlineSlugIds;
    context.headlineNumbers = anchors.headlineNumbers;
  }

  return { context, tocItems };
}

function renderMainBody(opts: {
  doc: DocumentNode;
  context: RenderContext;
  includeToc: boolean;
  tocItems: TocItem[];
  includeDocumentHeader: boolean;
  title: string;
  subtitle?: string;
}): string {
  const body = renderNodes(opts.doc.children, opts.context);
  const tocHtml = opts.includeToc ? renderToc(opts.tocItems) : "";
  const documentHeader = opts.includeDocumentHeader
    ? renderDocumentHeader({ title: opts.title, subtitle: opts.subtitle })
    : "";

  return [documentHeader, tocHtml, body]
    .filter((segment) => String(segment || "").trim().length > 0)
    .join("\n");
}

function renderDocumentHtml(opts: {
  title: string;
  language: string;
  metadata: OrgExportMetadata;
  headIncludes?: string[];
  stylesheets?: string[];
  includeDefaultStyle?: boolean;
  includeToc: boolean;
  mainBody: string;
  preambleHtml?: string;
  postambleHtml?: string;
  compatContentWrapper?: boolean;
}): string {
  const headMetaSection = renderHeadMetaSection(opts.metadata);
  const headExtraSection = renderHeadExtraSection(opts.metadata, opts.headIncludes);
  const headStyleSection = renderHeadStyleSection({
    stylesheets: opts.stylesheets,
    includeDefaultStyle: opts.includeDefaultStyle,
    defaultStyle: opts.includeToc ? `${DEFAULT_DOCUMENT_STYLE}
${DOCUMENT_TOC_STYLE}` : DEFAULT_DOCUMENT_STYLE,
  });

  const preambleSection = opts.preambleHtml ? `${opts.preambleHtml}
` : "";
  const postambleSection = opts.postambleHtml ? `${opts.postambleHtml}
` : "";
  const compatOpen = opts.compatContentWrapper ? COMPAT_CONTENT_OPEN : "";
  const compatClose = opts.compatContentWrapper ? COMPAT_CONTENT_CLOSE : "";
  const compatStyleSection = opts.compatContentWrapper ? COMPAT_CONTENT_STYLE_SECTION : "";

  return `<!doctype html>
<html lang="${escapeAttr(opts.language)}">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(opts.title)}</title>
${headMetaSection}${headExtraSection}${headStyleSection}${compatStyleSection}</head>
<body>
${compatOpen}<main class="org2-document">
${preambleSection}${opts.mainBody}
</main>
${compatClose}${postambleSection}</body>
</html>
`;
}

export function renderOrgDocumentToHtml(
  doc: DocumentNode,
  opts: {
    title?: string;
    sourcePath?: string;
    stylesheets?: string[];
    includeDefaultStyle?: boolean;
    includeToc?: boolean;
    includeTocDepth?: number;
    includeHeadlineNumbers?: boolean;
    includeHeadlineNumberDepth?: number;
    rewriteFileLinks?: boolean;
    preambleHtml?: string;
    postambleHtml?: string;
    headIncludes?: string[];
    includeDocumentHeader?: boolean;
    compatContentWrapper?: boolean;
    linkAbbreviations?: LinkAbbreviationRecord;
    linearTeam?: string;
  } = {},
): { html: string; title: string; metadata: OrgExportMetadata } {
  const title = resolveTitle(doc, opts.title, opts.sourcePath);
  const metadata = collectKeywordMetadata(doc);
  const renderOptions = resolveDocumentRenderOptions(doc, opts);
  const { context, tocItems } = buildDocumentRenderContext(doc, {
    includeToc: renderOptions.includeToc,
    includeTocDepth: renderOptions.includeTocDepth,
    includeHeadlineNumbers: renderOptions.includeHeadlineNumbers,
    includeHeadlineNumberDepth: renderOptions.includeHeadlineNumberDepth,
    rewriteFileLinks: opts.rewriteFileLinks,
    linkAbbreviations: opts.linkAbbreviations,
    linearTeam: opts.linearTeam,
  });

  const mainBody = renderMainBody({
    doc,
    context,
    includeToc: renderOptions.includeToc,
    tocItems,
    includeDocumentHeader: renderOptions.includeDocumentHeader,
    title,
    subtitle: metadata.subtitle,
  });

  const html = renderDocumentHtml({
    title,
    language: metadata.language || "en",
    metadata,
    headIncludes: opts.headIncludes,
    stylesheets: opts.stylesheets,
    includeDefaultStyle: opts.includeDefaultStyle,
    includeToc: renderOptions.includeToc,
    mainBody,
    preambleHtml: String(opts.preambleHtml || "").trim(),
    postambleHtml: String(opts.postambleHtml || "").trim(),
    compatContentWrapper: opts.compatContentWrapper,
  });

  return { html, title, metadata };
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
