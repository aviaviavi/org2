import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type {
  CitationNode,
  DocumentNode,
  InlineNode,
  ListItemNode,
  Node,
  TableNode,
  TimestampNode,
} from "./ast.js";
import { renderOrgCharts, type ChartTableData } from "./chartRender.js";
import { renderOrgDocumentToHtml } from "./export.js";
import {
  buildBuiltInLinkAbbreviations,
  collectLinkAbbreviationsFromDoc,
  collectLinkAbbreviationsFromRecord,
  expandLinkAbbreviationTarget,
  mergeLinkAbbreviations,
  type LinkAbbreviationMap,
  type LinkAbbreviationRecord,
} from "./link-abbrev.js";
import { parseInlinesFromText, parseOrgToCanonicalAst } from "./parser.js";
import { computeSubtreeRange, findHeadingAtOrAbove, getHeadlineLevel, isHeadlineLine, splitSourceLines } from "./sourceLines.js";
import { renderPublishedDocumentToDocx, type PreparedDocxDocument } from "./publishedDocumentDocx.js";
import {
  renderPublishedDocumentToOdp,
  renderPublishedDocumentToOds,
  type PreparedOdfDocument,
} from "./publishedDocumentOdf.js";

export const PUBLISHED_DOCUMENT_SCHEMA = "org2:published-document:v1" as const;
export const GOOGLE_DOCS_PUBLICATION_SCHEMA = "org2:google-docs-publication:v1" as const;
export const GOOGLE_SLIDES_PUBLICATION_SCHEMA = "org2:google-slides-publication:v1" as const;
export const GOOGLE_SHEETS_PUBLICATION_SCHEMA = "org2:google-sheets-publication:v1" as const;
export const GOOGLE_DRIVE_PDF_PUBLICATION_SCHEMA = "org2:google-drive-pdf-publication:v1" as const;
export const GOOGLE_DRIVE_FILE_SCOPE = "https://www.googleapis.com/auth/drive.file" as const;
export const GOOGLE_DOCS_MIME_TYPE = "application/vnd.google-apps.document" as const;
export const GOOGLE_SLIDES_MIME_TYPE = "application/vnd.google-apps.presentation" as const;
export const GOOGLE_SHEETS_MIME_TYPE = "application/vnd.google-apps.spreadsheet" as const;
export const PDF_MEDIA_TYPE = "application/pdf" as const;
export const GOOGLE_DRIVE_MULTIPART_MAX_BYTES = 5_000_000;

const DEFAULT_MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const DEFAULT_MAX_TOTAL_IMAGE_BYTES = 25 * 1024 * 1024;
const SAFE_DOCUMENT_KEYWORDS = new Set([
  "AUTHOR",
  "DATE",
  "DESCRIPTION",
  "KEYWORDS",
  "LANGUAGE",
  "SUBTITLE",
  "TITLE",
]);
const SAFE_SLIDE_LEVEL_KEYWORDS = new Set([
  "BEAMER_FRAME_LEVEL",
  "ORG2_SLIDE_LEVEL",
  "SLIDE_LEVEL",
]);

const SAFE_IMAGE_MIME_TYPES: Record<string, string> = {
  ".avif": "image/avif",
  ".gif": "image/gif",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".png": "image/png",
  ".webp": "image/webp",
};

export type PublicationRedactionKind =
  | "comments"
  | "commentedSubtrees"
  | "internalLinks"
  | "localFiles"
  | "metadata"
  | "planning"
  | "rawHtml"
  | "runtimeData"
  | "unsafeLinks";

export type PublicationRedactions = Record<PublicationRedactionKind, number>;

export type PublishedAsset = {
  name: string;
  mediaType: string;
  bytes: number;
  sha256: string;
};

export type PublishedDocumentManifest = {
  $schema: typeof PUBLISHED_DOCUMENT_SCHEMA;
  title: string;
  mediaType: "text/html";
  selection: "document" | "subtree";
  artifactHash: string;
  bytes: number;
};

export type PreparedPublishedDocument = {
  html: string;
  document: DocumentNode;
  manifest: PublishedDocumentManifest;
  sourceHash: string;
  projectionHash: string;
  assets: PublishedAsset[];
  redactions: PublicationRedactions;
  warnings: string[];
};

export type PreparePublishedDocumentOptions = {
  sourceText: string;
  sourcePath?: string;
  title?: string;
  line?: number;
  allowIndexing?: boolean;
  linkAbbreviations?: LinkAbbreviationRecord;
  linearTeam?: string;
  maxImageBytes?: number;
  maxTotalImageBytes?: number;
};

export type WebPublicationWriteResult = {
  destination: "web";
  outDir: string;
  indexPath: string;
  manifestPath: string;
  artifactHash: string;
};

export type GoogleDriveFileMetadata = {
  id: string;
  name?: string;
  mimeType?: string;
  modifiedTime?: string;
  version?: string;
  webViewLink?: string;
  trashed?: boolean;
  capabilities?: {
    canEdit?: boolean;
  };
};

export type GoogleDocsPublicationResult = {
  $schema: typeof GOOGLE_DOCS_PUBLICATION_SCHEMA;
  destination: "google-docs";
  action: "create" | "update";
  fileId: string;
  name: string;
  version?: string;
  modifiedTime?: string;
  webViewLink: string;
  sourceHash: string;
  projectionHash: string;
  artifactHash: string;
};

export type GoogleWorkspaceDestination = "google-docs" | "google-slides" | "google-sheets" | "google-drive-pdf";

export type GoogleWorkspacePublicationResult = {
  $schema:
    | typeof GOOGLE_DOCS_PUBLICATION_SCHEMA
    | typeof GOOGLE_SLIDES_PUBLICATION_SCHEMA
    | typeof GOOGLE_SHEETS_PUBLICATION_SCHEMA
    | typeof GOOGLE_DRIVE_PDF_PUBLICATION_SCHEMA;
  destination: GoogleWorkspaceDestination;
  action: "create" | "update";
  fileId: string;
  name: string;
  version?: string;
  modifiedTime?: string;
  webViewLink: string;
  sourceHash: string;
  projectionHash: string;
  artifactHash: string;
};

export type PublishToGoogleDocsOptions = {
  accessToken: string;
  documentId?: string;
  folderId?: string;
  expectedVersion?: string;
  replaceExisting?: boolean;
  fetchImpl?: typeof fetch;
};

export type PublishToGoogleWorkspaceOptions = PublishToGoogleDocsOptions & {
  pdfBytes?: Buffer;
};

export type PreparedPdfDocument = {
  mediaType: typeof PDF_MEDIA_TYPE;
  bytes: Buffer;
  byteLength: number;
  sha256: string;
};

export type PreparedGoogleWorkspaceUpload = PreparedDocxDocument | PreparedOdfDocument | PreparedPdfDocument;

type EmbeddedAsset = PublishedAsset & {
  resolvedPath: string;
  dataUri: string;
};

type SanitizationContext = {
  sourceDirectory?: string;
  abbreviations: LinkAbbreviationMap;
  assetsByPath: Map<string, EmbeddedAsset>;
  redactions: PublicationRedactions;
  warnings: string[];
  maxImageBytes: number;
  maxTotalImageBytes: number;
  totalImageBytes: number;
};

function sha256(value: string | Buffer): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function emptyRedactions(): PublicationRedactions {
  return {
    comments: 0,
    commentedSubtrees: 0,
    internalLinks: 0,
    localFiles: 0,
    metadata: 0,
    planning: 0,
    rawHtml: 0,
    runtimeData: 0,
    unsafeLinks: 0,
  };
}

function redact(context: SanitizationContext, kind: PublicationRedactionKind, count = 1): void {
  context.redactions[kind] += count;
}

function normalizeSourceText(value: string): string {
  return String(value || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

function selectedSourceText(sourceText: string, line: number | undefined): { text: string; selection: "document" | "subtree" } {
  if (line === undefined) return { text: sourceText, selection: "document" };
  if (!Number.isInteger(line) || line < 1) throw new Error("line must be a positive integer");

  const lines = splitSourceLines(sourceText);
  const headingIndex = findHeadingAtOrAbove(lines, line);
  const range = computeSubtreeRange(lines, headingIndex);
  const levelOffset = Math.max(0, range.level - 1);
  const selectedLines = lines.slice(range.start, range.endExclusive).map((sourceLine) => {
    if (!isHeadlineLine(sourceLine)) return sourceLine;
    const currentLevel = getHeadlineLevel(sourceLine);
    return `${"*".repeat(Math.max(1, currentLevel - levelOffset))}${sourceLine.slice(currentLevel)}`;
  });
  return { text: selectedLines.join("\n"), selection: "subtree" };
}

function cloneTimestamp(node: TimestampNode): TimestampNode {
  return {
    type: "Timestamp",
    active: node.active,
    raw: node.raw,
    ...(node.repeater ? { repeater: { ...node.repeater } } : {}),
    ...(node.warning ? { warning: { ...node.warning } } : {}),
  };
}

function cloneCitation(node: CitationNode): CitationNode {
  return {
    type: "Citation",
    raw: node.raw,
    references: node.references.map((reference) => ({ ...reference })),
    ...(node.styleRaw !== undefined ? { styleRaw: node.styleRaw } : {}),
    ...(node.prefixRaw !== undefined ? { prefixRaw: node.prefixRaw } : {}),
    ...(node.suffixRaw !== undefined ? { suffixRaw: node.suffixRaw } : {}),
  };
}

function cloneProgressCookie(node: Extract<InlineNode, { type: "ProgressCookie" }>): Extract<InlineNode, { type: "ProgressCookie" }> {
  return {
    type: "ProgressCookie",
    raw: node.raw,
    format: node.format,
    ...(node.done !== undefined ? { done: node.done } : {}),
    ...(node.total !== undefined ? { total: node.total } : {}),
    ...(node.percent !== undefined ? { percent: node.percent } : {}),
  };
}

function displayTextForLink(target: string, description: string | undefined): string {
  const label = String(description || "").trim();
  if (label) return label;
  if (/^id:/i.test(target)) return "Internal link";
  if (/^(?:file:|\.\.?\/|\/)/i.test(target)) return "Attachment not included";
  return target.trim() || "Link removed";
}

function textInline(value: string): InlineNode {
  return { type: "Text", value };
}

function linkInline(target: string, description: string | undefined, format: "bracket" | "plain" | "angle"): InlineNode {
  const raw = description === undefined ? `[[${target}]]` : `[[${target}][${description}]]`;
  return {
    type: "Link",
    format,
    raw,
    targetRaw: target,
    ...(description !== undefined ? { descriptionRaw: description } : {}),
  };
}

function pathPartFromTarget(target: string): string {
  return (target.split("::", 1)[0] || "").split(/[?#]/, 1)[0] || "";
}

function imageMimeTypeForTarget(target: string): string | null {
  const extension = path.extname(pathPartFromTarget(target)).toLowerCase();
  return SAFE_IMAGE_MIME_TYPES[extension] || null;
}

function imageDisplayName(target: string): string {
  const raw = path.basename(pathPartFromTarget(target).replace(/^file:/i, ""));
  try {
    return decodeURIComponent(raw) || "image";
  } catch {
    return raw || "image";
  }
}

function localPathForTarget(target: string, sourceDirectory: string | undefined): string | null {
  const targetPath = pathPartFromTarget(target);
  if (!targetPath || /^https?:/i.test(targetPath)) return null;
  if (/^[a-z][a-z0-9+.-]*:/i.test(targetPath) && !/^file:/i.test(targetPath)) return null;

  let filePath = targetPath.replace(/^file:/i, "");
  if (filePath.startsWith("//")) {
    try {
      const fileUrl = new URL(`file:${filePath}`);
      if (fileUrl.hostname && fileUrl.hostname !== "localhost") return null;
      filePath = fileUrl.pathname;
    } catch {
      return null;
    }
  }
  try {
    filePath = decodeURIComponent(filePath);
  } catch {
    return null;
  }
  if (!filePath || filePath.includes("\0")) return null;
  if (path.isAbsolute(filePath)) return path.normalize(filePath);
  if (!sourceDirectory) return null;
  return path.resolve(sourceDirectory, filePath);
}

function embedLocalImage(target: string, context: SanitizationContext): EmbeddedAsset | null {
  const mediaType = imageMimeTypeForTarget(target);
  if (!mediaType) return null;
  const resolvedPath = localPathForTarget(target, context.sourceDirectory);
  const displayName = imageDisplayName(target);
  if (!resolvedPath) {
    redact(context, "localFiles");
    context.warnings.push(`Image ${JSON.stringify(displayName)} was not included because its local path could not be resolved.`);
    return null;
  }

  const existing = context.assetsByPath.get(resolvedPath);
  if (existing) return existing;

  let stat: fs.Stats;
  try {
    stat = fs.statSync(resolvedPath);
  } catch {
    redact(context, "localFiles");
    context.warnings.push(`Image ${JSON.stringify(displayName)} was not included because it could not be read.`);
    return null;
  }
  if (!stat.isFile()) {
    redact(context, "localFiles");
    context.warnings.push(`Image ${JSON.stringify(displayName)} was not included because it is not a regular file.`);
    return null;
  }
  if (stat.size > context.maxImageBytes) {
    redact(context, "localFiles");
    context.warnings.push(`Image ${JSON.stringify(displayName)} exceeds the per-image publish limit.`);
    return null;
  }
  if (context.totalImageBytes + stat.size > context.maxTotalImageBytes) {
    redact(context, "localFiles");
    context.warnings.push(`Image ${JSON.stringify(displayName)} exceeds the total publish-asset limit.`);
    return null;
  }

  const data = fs.readFileSync(resolvedPath);
  const asset: EmbeddedAsset = {
    name: displayName,
    mediaType,
    bytes: data.byteLength,
    sha256: sha256(data),
    resolvedPath,
    dataUri: `data:${mediaType};base64,${data.toString("base64")}`,
  };
  context.assetsByPath.set(resolvedPath, asset);
  context.totalImageBytes += data.byteLength;
  return asset;
}

function sanitizeLink(node: Extract<InlineNode, { type: "Link" }>, context: SanitizationContext): InlineNode {
  const targetRaw = String(node.targetRaw || "").trim();
  const expandedTarget = expandLinkAbbreviationTarget(targetRaw, context.abbreviations);
  const description = node.descriptionRaw;

  if (/^https?:/i.test(expandedTarget)) {
    if (imageMimeTypeForTarget(expandedTarget) && description === undefined) {
      return linkInline(expandedTarget, imageDisplayName(expandedTarget), node.format);
    }
    return linkInline(expandedTarget, description, node.format);
  }
  if (/^(?:mailto|tel):/i.test(expandedTarget)) {
    return linkInline(expandedTarget, description, node.format);
  }
  if (/^#[A-Za-z0-9_.:-]+$/.test(expandedTarget)) {
    return linkInline(expandedTarget, description, node.format);
  }

  const image = embedLocalImage(expandedTarget, context);
  if (image) return linkInline(image.dataUri, undefined, node.format);

  if (/^(?:id:|file:|\.\.?\/|\/)/i.test(expandedTarget) || !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(expandedTarget)) {
    redact(context, "internalLinks");
    return textInline(displayTextForLink(expandedTarget, description));
  }

  redact(context, "unsafeLinks");
  return textInline(displayTextForLink(expandedTarget, description));
}

function sanitizeInline(node: InlineNode, context: SanitizationContext): InlineNode | null {
  switch (node.type) {
    case "Text":
      return { type: "Text", value: node.value };
    case "Timestamp":
      return cloneTimestamp(node);
    case "TimestampRange":
      return {
        type: "TimestampRange",
        start: cloneTimestamp(node.start),
        separatorRaw: node.separatorRaw,
        end: cloneTimestamp(node.end),
      };
    case "Emphasis":
      return { type: "Emphasis", kind: node.kind, marker: node.marker, content: node.content };
    case "Link":
      return sanitizeLink(node, context);
    case "ProgressCookie":
      return cloneProgressCookie(node);
    case "Entity":
      return { type: "Entity", raw: node.raw, nameRaw: node.nameRaw };
    case "LatexFragment":
      return { type: "LatexFragment", raw: node.raw, display: node.display };
    case "ExportSnippet":
      redact(context, "rawHtml");
      return null;
    case "FootnoteReference":
      return {
        type: "FootnoteReference",
        raw: node.raw,
        ...(node.labelRaw !== undefined ? { labelRaw: node.labelRaw } : {}),
        ...(node.definitionRaw !== undefined ? { definitionRaw: node.definitionRaw } : {}),
      };
    case "Citation":
      return cloneCitation(node);
    case "Target":
      redact(context, "metadata");
      return null;
    case "Script":
      return { type: "Script", raw: node.raw, kind: node.kind, valueRaw: node.valueRaw };
    case "LineBreak":
      return { type: "LineBreak", raw: node.raw };
  }
}

function sanitizeInlines(nodes: InlineNode[], context: SanitizationContext): InlineNode[] {
  return nodes.map((node) => sanitizeInline(node, context)).filter((node): node is InlineNode => node !== null);
}

function inlinePlainText(nodes: InlineNode[]): string {
  return nodes.map((node) => {
    switch (node.type) {
      case "Text": return node.value;
      case "Timestamp": return node.raw;
      case "TimestampRange": return `${node.start.raw}${node.separatorRaw}${node.end.raw}`;
      case "Emphasis": return node.content;
      case "Link": return node.descriptionRaw || (/^data:image\//i.test(node.targetRaw) ? "Image" : node.targetRaw);
      case "ProgressCookie": return node.raw;
      case "Entity": return node.raw;
      case "LatexFragment": return node.raw;
      case "FootnoteReference": return node.labelRaw ? `[${node.labelRaw}]` : "[footnote]";
      case "Citation": return node.references.map((reference) => `@${reference.keyRaw}`).join("; ");
      case "Script": return node.valueRaw;
      case "LineBreak": return " ";
      case "ExportSnippet":
      case "Target":
        return "";
    }
  }).join("");
}

function safeTableCellText(nodes: InlineNode[]): string {
  return inlinePlainText(nodes)
    .replace(/@@/g, "@\u200b@")
    .replace(/\[\[/g, "[\u200b[")
    .replace(/<<+/g, (value) => `${value[0]}\u200b${value.slice(1)}`);
}

function stripAffiliatedKeywords(node: { affiliatedKeywords?: unknown[] }, context: SanitizationContext): void {
  if (node.affiliatedKeywords?.length) redact(context, "metadata", node.affiliatedKeywords.length);
}

function sanitizeListItem(node: ListItemNode, context: SanitizationContext): ListItemNode {
  return {
    type: "ListItem",
    ...(node.ordinal !== undefined ? { ordinal: node.ordinal } : {}),
    ...(node.counter !== undefined ? { counter: node.counter } : {}),
    ...(node.checkbox !== undefined ? { checkbox: node.checkbox } : {}),
    ...(node.progressCookie ? { progressCookie: cloneProgressCookie(node.progressCookie) } : {}),
    ...(node.descriptionTag ? { descriptionTag: sanitizeInlines(node.descriptionTag, context) } : {}),
    children: sanitizeNodes(node.children, context),
  };
}

function sanitizeTable(node: TableNode, context: SanitizationContext): TableNode {
  stripAffiliatedKeywords(node, context);
  if (node.formulas?.length) redact(context, "runtimeData", node.formulas.length);
  return {
    type: "Table",
    rows: node.rows.map((row) => {
      if (row.type === "TableHline") return { type: "TableHline", indent: row.indent, raw: row.raw };
      const contents = row.cells.map((cell) => sanitizeInlines(parseInlinesFromText(cell), context));
      return {
        type: "TableRow",
        indent: row.indent,
        cells: contents.map((cell) => safeTableCellText(cell)),
        contents,
      };
    }),
  };
}

function sanitizeNode(node: Node, context: SanitizationContext): Node | null {
  switch (node.type) {
    case "Headline":
      if (node.commented) {
        redact(context, "commentedSubtrees");
        return null;
      }
      redact(
        context,
        "metadata",
        (node.todo ? 1 : 0) + (node.priority ? 1 : 0) + (node.tags?.length || 0),
      );
      return {
        type: "Headline",
        level: node.level,
        title: sanitizeInlines(node.title, context),
        children: sanitizeNodes(node.children, context),
      };
    case "Paragraph": {
      const children = sanitizeInlines(node.children, context);
      return children.length > 0 ? { type: "Paragraph", children } : null;
    }
    case "List":
      return { type: "List", ordered: node.ordered, items: node.items.map((item) => sanitizeListItem(item, context)) };
    case "ListItem":
      return sanitizeListItem(node, context);
    case "KeywordLine": {
      const key = String(node.keyRaw || "").trim().toUpperCase();
      if (SAFE_SLIDE_LEVEL_KEYWORDS.has(key)) {
        const parsed = Number.parseInt(String(node.valueRaw || "").trim(), 10);
        if (!Number.isInteger(parsed) || parsed < 1 || parsed > 12) {
          redact(context, "metadata");
          context.warnings.push(`${key} was removed because its slide level was invalid.`);
          return null;
        }
        return {
          type: "KeywordLine",
          raw: `#+${key}: ${parsed}`,
          indent: "",
          keyRaw: key,
          valueRaw: String(parsed),
        };
      }
      if (!SAFE_DOCUMENT_KEYWORDS.has(key)) {
        redact(context, key === "HTML_HEAD" || key === "HTML_HEAD_EXTRA" ? "rawHtml" : "metadata");
        return null;
      }
      return {
        type: "KeywordLine",
        raw: `#+${key}: ${node.valueRaw}`,
        indent: "",
        keyRaw: key,
        valueRaw: node.valueRaw,
      };
    }
    case "DirectiveLine":
      redact(context, "metadata");
      return null;
    case "CommentLine":
      redact(context, "comments");
      return null;
    case "Planning":
    case "Clock":
      redact(context, "planning");
      return null;
    case "PropertyDrawer":
    case "Drawer":
      redact(context, "metadata");
      return null;
    case "SrcBlock":
      stripAffiliatedKeywords(node, context);
      return {
        type: "SrcBlock",
        terminated: node.terminated,
        begin: { ...node.begin },
        bodyRaw: node.bodyRaw,
        ...(node.end ? { end: { ...node.end } } : {}),
      };
    case "Block":
      stripAffiliatedKeywords(node, context);
      if (node.kind === "comment") {
        redact(context, "comments");
        return null;
      }
      if (node.kind === "export") {
        redact(context, "rawHtml");
        return null;
      }
      return {
        type: "Block",
        kind: node.kind,
        terminated: node.terminated,
        begin: { ...node.begin },
        bodyRaw: node.bodyRaw,
        ...(node.end ? { end: { ...node.end } } : {}),
      };
    case "DynamicBlock":
      redact(context, "runtimeData");
      return null;
    case "FixedWidth":
      return { type: "FixedWidth", lines: node.lines.map((line) => ({ ...line })) };
    case "HorizontalRule":
      return { type: "HorizontalRule", raw: node.raw, indent: node.indent };
    case "LatexEnvironment":
      return {
        type: "LatexEnvironment",
        nameRaw: node.nameRaw,
        beginRaw: node.beginRaw,
        bodyRaw: node.bodyRaw,
        terminated: node.terminated,
        ...(node.endRaw !== undefined ? { endRaw: node.endRaw } : {}),
      };
    case "DiarySexp":
      redact(context, "runtimeData");
      return null;
    case "FootnoteDefinition":
      return { type: "FootnoteDefinition", labelRaw: node.labelRaw, children: sanitizeInlines(node.children, context) };
    case "Table":
      return sanitizeTable(node, context);
    case "Text":
      return { type: "Text", value: node.value };
  }
}

function sanitizeNodes(nodes: Node[], context: SanitizationContext): Node[] {
  return nodes.map((node) => {
    const sanitized = sanitizeNode(node, context);
    if (!sanitized) return null;

    const sourceRange = (node as Node & { sourceRange?: { startLine: number; endLine: number } }).sourceRange;
    if (sourceRange) {
      // Publishing needs source locations only long enough to attach deterministic
      // chart SVGs to their sanitized chart blocks. Keep them non-enumerable so
      // they never enter the public projection, manifest, or projection hash.
      Object.defineProperty(sanitized, "sourceRange", {
        value: { ...sourceRange },
        enumerable: false,
      });
    }
    return sanitized;
  }).filter((node): node is Node => node !== null);
}

function publishedChartTableData(nodes: Node[], originalNodes: Node[]): ReadonlyMap<number, ChartTableData> {
  const originalHeaders = new Map<number, string[]>();
  const visitOriginal = (node: Node): void => {
    if (node.type === "Table") {
      const sourceRange = (node as Node & { sourceRange?: { startLine: number } }).sourceRange;
      const header = node.rows.find((row) => row.type === "TableRow");
      if (sourceRange && header?.type === "TableRow") originalHeaders.set(sourceRange.startLine, [...header.cells]);
      return;
    }
    if (node.type === "Headline" || node.type === "ListItem") {
      node.children.forEach(visitOriginal);
      return;
    }
    if (node.type === "List") node.items.forEach(visitOriginal);
  };
  originalNodes.forEach(visitOriginal);

  const tables = new Map<number, ChartTableData>();
  const visit = (node: Node): void => {
    if (node.type === "Table") {
      const sourceRange = (node as Node & { sourceRange?: { startLine: number } }).sourceRange;
      const rows = node.rows
        .filter((row) => row.type === "TableRow")
        .map((row) => [...row.cells]);
      if (sourceRange && rows.length > 0) {
        tables.set(sourceRange.startLine, {
          // Header cells are chart column identifiers. Preserve their literal
          // spelling (for example rolling_7d) while taking every rendered data
          // value from the sanitized projection below.
          headers: originalHeaders.get(sourceRange.startLine) || rows[0] || [],
          rows: rows.slice(1),
        });
      }
      return;
    }
    if (node.type === "Headline" || node.type === "ListItem") {
      node.children.forEach(visit);
      return;
    }
    if (node.type === "List") node.items.forEach(visit);
  };
  nodes.forEach(visit);
  return tables;
}

function firstDocumentTitle(doc: DocumentNode): string {
  for (const node of doc.children) {
    if (node.type === "KeywordLine" && String(node.keyRaw || "").trim().toUpperCase() === "TITLE") {
      const title = String(node.valueRaw || "").trim();
      if (title) return title;
    }
  }
  for (const node of doc.children) {
    if (node.type !== "Headline") continue;
    const title = inlinePlainText(node.title).trim();
    if (title) return title;
  }
  return "Org2 Document";
}

function disclosureHeadIncludes(allowIndexing: boolean): string[] {
  const indexing = allowIndexing ? "index, follow" : "noindex, nofollow, noarchive";
  return [
    `<meta name="robots" content="${indexing}" />`,
    '<meta name="referrer" content="no-referrer" />',
    '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\'; base-uri \'none\'; form-action \'none\'; frame-ancestors \'none\'; object-src \'none\'" />',
  ];
}

function hardenExternalLinks(html: string): string {
  return html.replace(/<a href="(https?:[^\"]*)">/gi, '<a rel="noopener noreferrer" href="$1">');
}

export function preparePublishedDocument(options: PreparePublishedDocumentOptions): PreparedPublishedDocument {
  const normalizedSource = normalizeSourceText(options.sourceText);
  const selected = selectedSourceText(normalizedSource, options.line);
  const originalDocument = parseOrgToCanonicalAst(selected.text, { sourceRanges: true });
  const abbreviations = mergeLinkAbbreviations([
    buildBuiltInLinkAbbreviations(options.linearTeam),
    collectLinkAbbreviationsFromRecord(options.linkAbbreviations),
    collectLinkAbbreviationsFromDoc(originalDocument),
  ]);
  const context: SanitizationContext = {
    sourceDirectory: options.sourcePath ? path.dirname(path.resolve(options.sourcePath)) : undefined,
    abbreviations,
    assetsByPath: new Map(),
    redactions: emptyRedactions(),
    warnings: [],
    maxImageBytes: options.maxImageBytes ?? DEFAULT_MAX_IMAGE_BYTES,
    maxTotalImageBytes: options.maxTotalImageBytes ?? DEFAULT_MAX_TOTAL_IMAGE_BYTES,
    totalImageBytes: 0,
  };
  const document: DocumentNode = {
    type: "Document",
    version: "0",
    children: sanitizeNodes(originalDocument.children, context),
  };
  const chartResults = renderOrgCharts(selected.text, {
    tableDataByLine: publishedChartTableData(document.children, originalDocument.children),
  });
  const charts = chartResults
    .filter((chart): chart is typeof chart & { svg: string; source: NonNullable<typeof chart.source> } => (
      chart.ok && Boolean(chart.svg && chart.source)
    ))
    .map((chart) => ({ svg: chart.svg, source: chart.source, presentation: chart.presentation }));
  for (const chart of chartResults) {
    if (chart.ok) continue;
    const detail = chart.diagnostics
      .filter((diagnostic) => diagnostic.severity === "error")
      .map((diagnostic) => diagnostic.message)
      .join("; ");
    context.warnings.push(`Chart was not rendered${detail ? `: ${detail}` : "."}`);
  }
  const title = String(options.title || "").trim() || firstDocumentTitle(document);
  const rendered = renderOrgDocumentToHtml(document, {
    title,
    includeDefaultStyle: true,
    includeToc: false,
    includeHeadlineNumbers: false,
    includeDocumentHeader: selected.selection === "document",
    headIncludes: disclosureHeadIncludes(options.allowIndexing === true),
    profile: "publish",
    charts,
  });
  const html = hardenExternalLinks(rendered.html);
  const assets = [...context.assetsByPath.values()]
    .map(({ name, mediaType, bytes, sha256: assetHash }) => ({ name, mediaType, bytes, sha256: assetHash }))
    .sort((left, right) => left.name.localeCompare(right.name) || left.sha256.localeCompare(right.sha256));
  const sourceHash = sha256(selected.text);
  const projectionHash = sha256(JSON.stringify(document));
  const artifactHash = sha256(html);
  return {
    html,
    document,
    manifest: {
      $schema: PUBLISHED_DOCUMENT_SCHEMA,
      title: rendered.title,
      mediaType: "text/html",
      selection: selected.selection,
      artifactHash,
      bytes: Buffer.byteLength(html),
    },
    sourceHash,
    projectionHash,
    assets,
    redactions: context.redactions,
    warnings: context.warnings,
  };
}

function atomicWriteFile(filePath: string, content: string): void {
  const parent = path.dirname(filePath);
  fs.mkdirSync(parent, { recursive: true });
  const temporaryPath = path.join(parent, `.${path.basename(filePath)}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`);
  try {
    fs.writeFileSync(temporaryPath, content, { encoding: "utf8", mode: 0o644, flag: "wx" });
    fs.renameSync(temporaryPath, filePath);
  } finally {
    if (fs.existsSync(temporaryPath)) fs.unlinkSync(temporaryPath);
  }
}

export function writeWebPublicationBundle(
  publication: PreparedPublishedDocument,
  options: { outDir: string; replaceExisting?: boolean },
): WebPublicationWriteResult {
  const outDir = path.resolve(options.outDir);
  const indexPath = path.join(outDir, "index.html");
  const manifestPath = path.join(outDir, "manifest.json");
  const existingEntries = fs.existsSync(outDir) ? fs.readdirSync(outDir) : [];
  if (existingEntries.length > 0 && options.replaceExisting !== true) {
    throw new Error(`Web publication directory is not empty: ${outDir}. Pass --replace-existing to update it.`);
  }

  fs.mkdirSync(outDir, { recursive: true });
  atomicWriteFile(indexPath, publication.html);
  atomicWriteFile(manifestPath, `${JSON.stringify(publication.manifest, null, 2)}\n`);
  return {
    destination: "web",
    outDir,
    indexPath,
    manifestPath,
    artifactHash: publication.manifest.artifactHash,
  };
}

function multipartBody(
  boundary: string,
  metadata: Record<string, unknown>,
  mediaType: string,
  media: Buffer,
): Buffer {
  const prefix = Buffer.from([
    `--${boundary}`,
    "Content-Type: application/json; charset=UTF-8",
    "",
    JSON.stringify(metadata),
    `--${boundary}`,
    `Content-Type: ${mediaType}`,
    "",
  ].join("\r\n") + "\r\n");
  const suffix = Buffer.from(`\r\n--${boundary}--\r\n`);
  return Buffer.concat([prefix, media, suffix]);
}

function requestBodyBytes(value: Buffer): ArrayBuffer {
  const bytes = new Uint8Array(value.length);
  bytes.set(value);
  return bytes.buffer;
}

async function googleJsonResponse(response: Response, operation: string, secrets: string[] = []): Promise<GoogleDriveFileMetadata> {
  const body = await response.text();
  if (!response.ok) {
    let detail = body.trim().slice(0, 1_000);
    for (const secret of secrets) {
      if (secret) detail = detail.split(secret).join("[redacted]");
    }
    throw new Error(`Google Drive ${operation} failed (${response.status})${detail ? `: ${detail}` : ""}`);
  }
  let parsed: unknown;
  try {
    parsed = body ? JSON.parse(body) : {};
  } catch {
    throw new Error(`Google Drive ${operation} returned invalid JSON`);
  }
  if (!parsed || typeof parsed !== "object") throw new Error(`Google Drive ${operation} returned an invalid file record`);
  return parsed as GoogleDriveFileMetadata;
}

async function googleCommentsPresent(response: Response, accessToken: string): Promise<boolean> {
  const body = await response.text();
  if (!response.ok) {
    let detail = body.trim().slice(0, 1_000).split(accessToken).join("[redacted]");
    if (!detail) detail = response.statusText;
    throw new Error(`Google Drive comment check failed (${response.status})${detail ? `: ${detail}` : ""}`);
  }
  let parsed: unknown;
  try {
    parsed = body ? JSON.parse(body) : {};
  } catch {
    throw new Error("Google Drive comment check returned invalid JSON");
  }
  if (!parsed || typeof parsed !== "object") throw new Error("Google Drive comment check returned an invalid response");
  const commentList = parsed as { comments?: unknown; nextPageToken?: unknown };
  return (Array.isArray(commentList.comments) && commentList.comments.length > 0)
    || (typeof commentList.nextPageToken === "string" && commentList.nextPageToken.length > 0);
}

function googleFileFields(): string {
  return "id,name,mimeType,modifiedTime,version,webViewLink,trashed,capabilities(canEdit)";
}

function googleWorkspaceSpec(destination: GoogleWorkspaceDestination): {
  schema: GoogleWorkspacePublicationResult["$schema"];
  targetMediaType: string;
  displayName: string;
  fallbackLink(fileId: string): string;
} {
  switch (destination) {
    case "google-docs":
      return {
        schema: GOOGLE_DOCS_PUBLICATION_SCHEMA,
        targetMediaType: GOOGLE_DOCS_MIME_TYPE,
        displayName: "Google Docs",
        fallbackLink: (fileId) => `https://docs.google.com/document/d/${encodeURIComponent(fileId)}/edit`,
      };
    case "google-slides":
      return {
        schema: GOOGLE_SLIDES_PUBLICATION_SCHEMA,
        targetMediaType: GOOGLE_SLIDES_MIME_TYPE,
        displayName: "Google Slides",
        fallbackLink: (fileId) => `https://docs.google.com/presentation/d/${encodeURIComponent(fileId)}/edit`,
      };
    case "google-sheets":
      return {
        schema: GOOGLE_SHEETS_PUBLICATION_SCHEMA,
        targetMediaType: GOOGLE_SHEETS_MIME_TYPE,
        displayName: "Google Sheets",
        fallbackLink: (fileId) => `https://docs.google.com/spreadsheets/d/${encodeURIComponent(fileId)}/edit`,
      };
    case "google-drive-pdf":
      return {
        schema: GOOGLE_DRIVE_PDF_PUBLICATION_SCHEMA,
        targetMediaType: PDF_MEDIA_TYPE,
        displayName: "Google Drive PDF",
        fallbackLink: (fileId) => `https://drive.google.com/file/d/${encodeURIComponent(fileId)}/view`,
      };
  }
}

function googleResult(
  publication: PreparedPublishedDocument,
  upload: PreparedGoogleWorkspaceUpload,
  destination: GoogleWorkspaceDestination,
  file: GoogleDriveFileMetadata,
  action: "create" | "update",
): GoogleWorkspacePublicationResult {
  if (!file.id) throw new Error("Google Drive did not return a file ID");
  const spec = googleWorkspaceSpec(destination);
  return {
    $schema: spec.schema,
    destination,
    action,
    fileId: file.id,
    name: file.name || publication.manifest.title,
    ...(file.version ? { version: String(file.version) } : {}),
    ...(file.modifiedTime ? { modifiedTime: file.modifiedTime } : {}),
    webViewLink: file.webViewLink || spec.fallbackLink(file.id),
    sourceHash: publication.sourceHash,
    projectionHash: publication.projectionHash,
    artifactHash: upload.sha256,
  };
}

export function prepareGoogleDocsUpload(publication: PreparedPublishedDocument): PreparedDocxDocument {
  const unsupportedImages = publication.assets.filter((asset) => !["image/gif", "image/jpeg", "image/png"].includes(asset.mediaType));
  if (unsupportedImages.length > 0) {
    throw new Error(`Google Docs publishing supports embedded PNG, JPEG, and GIF images; convert ${unsupportedImages.map((asset) => asset.name).join(", ")} or publish a web bundle`);
  }
  return renderPublishedDocumentToDocx(publication.document, publication.manifest.title, {
    includeTitle: publication.manifest.selection === "document",
  });
}

export function prepareGoogleSlidesUpload(publication: PreparedPublishedDocument): PreparedOdfDocument {
  const unsupportedImages = publication.assets.filter((asset) => !["image/gif", "image/jpeg", "image/png"].includes(asset.mediaType));
  if (unsupportedImages.length > 0) {
    throw new Error(`Google Slides publishing supports embedded PNG, JPEG, and GIF images; convert ${unsupportedImages.map((asset) => asset.name).join(", ")} or publish a web bundle`);
  }
  return renderPublishedDocumentToOdp(publication.document, publication.manifest.title, {
    includeTitle: publication.manifest.selection === "document",
  });
}

export function prepareGoogleSheetsUpload(publication: PreparedPublishedDocument): PreparedOdfDocument {
  return renderPublishedDocumentToOds(publication.document, publication.manifest.title);
}

export function prepareGoogleDrivePdfUpload(pdfBytes: Buffer): PreparedPdfDocument {
  const bytes = Buffer.from(pdfBytes);
  if (bytes.length < 8 || !bytes.subarray(0, 5).equals(Buffer.from("%PDF-"))) {
    throw new Error("Google Drive PDF publishing requires a valid PDF produced from the disclosure-safe publication");
  }
  return {
    mediaType: PDF_MEDIA_TYPE,
    bytes,
    byteLength: bytes.length,
    sha256: sha256(bytes),
  };
}

export function prepareGoogleWorkspaceUpload(
  publication: PreparedPublishedDocument,
  destination: GoogleWorkspaceDestination,
  pdfBytes?: Buffer,
): PreparedGoogleWorkspaceUpload {
  if (destination === "google-docs") return prepareGoogleDocsUpload(publication);
  if (destination === "google-slides") return prepareGoogleSlidesUpload(publication);
  if (destination === "google-sheets") return prepareGoogleSheetsUpload(publication);
  if (!pdfBytes) throw new Error("Google Drive PDF publishing requires rendered PDF bytes");
  return prepareGoogleDrivePdfUpload(pdfBytes);
}

export async function publishToGoogleWorkspace(
  publication: PreparedPublishedDocument,
  destination: GoogleWorkspaceDestination,
  options: PublishToGoogleWorkspaceOptions,
): Promise<GoogleWorkspacePublicationResult> {
  const spec = googleWorkspaceSpec(destination);
  const accessToken = String(options.accessToken || "").trim();
  if (!accessToken) throw new Error(`${spec.displayName} publishing requires an access token`);
  const upload = prepareGoogleWorkspaceUpload(publication, destination, options.pdfBytes);
  if (upload.byteLength > GOOGLE_DRIVE_MULTIPART_MAX_BYTES) {
    throw new Error(`${spec.displayName} publishing currently supports artifacts up to ${GOOGLE_DRIVE_MULTIPART_MAX_BYTES} bytes; reduce embedded assets or publish a web bundle`);
  }
  const request = options.fetchImpl || globalThis.fetch;
  if (typeof request !== "function") throw new Error(`${spec.displayName} publishing requires a fetch implementation`);
  const authorization = `Bearer ${accessToken}`;
  const appProperties = {
    org2Schema: PUBLISHED_DOCUMENT_SCHEMA,
    org2SourceHash: publication.sourceHash,
    org2ProjectionHash: publication.projectionHash,
    org2ArtifactHash: upload.sha256,
    org2Destination: destination,
  };
  const boundary = `org2-${upload.sha256.slice(0, 24)}`;

  if (!options.documentId) {
    const metadata: Record<string, unknown> = {
      name: publication.manifest.title,
      mimeType: spec.targetMediaType,
      appProperties,
      ...(options.folderId ? { parents: [options.folderId] } : {}),
    };
    const query = new URLSearchParams({
      uploadType: "multipart",
      supportsAllDrives: "true",
      fields: googleFileFields(),
    });
    const response = await request(`https://www.googleapis.com/upload/drive/v3/files?${query}`, {
      method: "POST",
      headers: {
        authorization,
        "content-type": `multipart/related; boundary=${boundary}`,
      },
      body: requestBodyBytes(multipartBody(boundary, metadata, upload.mediaType, upload.bytes)),
    });
    return googleResult(
      publication,
      upload,
      destination,
      await googleJsonResponse(response, "create", [accessToken]),
      "create",
    );
  }

  if (options.replaceExisting !== true) {
    throw new Error(`Updating ${spec.displayName} requires replaceExisting: true`);
  }
  const expectedVersion = String(options.expectedVersion || "").trim();
  if (!expectedVersion) throw new Error(`Updating ${spec.displayName} requires an expected remote version`);

  const documentId = encodeURIComponent(options.documentId);
  const metadataQuery = new URLSearchParams({ supportsAllDrives: "true", fields: googleFileFields() });
  const metadataResponse = await request(`https://www.googleapis.com/drive/v3/files/${documentId}?${metadataQuery}`, {
    method: "GET",
    headers: { authorization },
  });
  const current = await googleJsonResponse(metadataResponse, "metadata check", [accessToken]);
  if (current.trashed) throw new Error(`The ${spec.displayName} file is in the trash`);
  if (current.mimeType !== spec.targetMediaType) throw new Error(`The target Google Drive file is not a ${spec.displayName} file`);
  if (current.capabilities?.canEdit === false) throw new Error("The connected Google account cannot edit the target file");
  if (String(current.version || "") !== expectedVersion) {
    throw new Error(`${spec.displayName} version changed: expected ${expectedVersion}, found ${current.version || "unknown"}. Import the remote changes or publish as a new copy.`);
  }

  const commentQuery = new URLSearchParams({
    includeDeleted: "false",
    pageSize: "1",
    fields: "comments(id),nextPageToken",
  });
  const commentResponse = await request(`https://www.googleapis.com/drive/v3/files/${documentId}/comments?${commentQuery}`, {
    method: "GET",
    headers: { authorization },
  });
  if (await googleCommentsPresent(commentResponse, accessToken)) {
    throw new Error(`The ${spec.displayName} file has comments. Full-content replacement could detach their anchors; publish as a new copy instead.`);
  }

  const updateQuery = new URLSearchParams({
    uploadType: "multipart",
    supportsAllDrives: "true",
    fields: googleFileFields(),
  });
  const etag = metadataResponse.headers.get("etag");
  const response = await request(`https://www.googleapis.com/upload/drive/v3/files/${documentId}?${updateQuery}`, {
    method: "PATCH",
    headers: {
      authorization,
      "content-type": `multipart/related; boundary=${boundary}`,
      ...(etag ? { "if-match": etag } : {}),
    },
    body: requestBodyBytes(multipartBody(boundary, { appProperties }, upload.mediaType, upload.bytes)),
  });
  return googleResult(
    publication,
    upload,
    destination,
    await googleJsonResponse(response, "update", [accessToken]),
    "update",
  );
}

export async function publishToGoogleDocs(
  publication: PreparedPublishedDocument,
  options: PublishToGoogleDocsOptions,
): Promise<GoogleDocsPublicationResult> {
  return await publishToGoogleWorkspace(publication, "google-docs", options) as GoogleDocsPublicationResult;
}
