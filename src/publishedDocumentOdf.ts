import crypto from "node:crypto";
import type {
  DocumentNode,
  InlineNode,
  ListItemNode,
  ListNode,
  Node,
  ParagraphNode,
  TableNode,
} from "./ast.js";
import {
  compilePresentation,
  type PresentationElement,
  type PresentationSlide,
} from "./presentation.js";
import { storedZipArchive } from "./zipArchive.js";

export const ODP_MEDIA_TYPE = "application/vnd.oasis.opendocument.presentation" as const;
export const ODS_MEDIA_TYPE = "application/vnd.oasis.opendocument.spreadsheet" as const;

export type PreparedOdfDocument = {
  mediaType: typeof ODP_MEDIA_TYPE | typeof ODS_MEDIA_TYPE;
  bytes: Buffer;
  byteLength: number;
  sha256: string;
  itemCount: number;
};

type OdfImage = {
  name: string;
  mediaType: "image/gif" | "image/jpeg" | "image/png";
  data: Buffer;
};

type OdfPresentationContext = {
  images: OdfImage[];
  imagesByHash: Map<string, OdfImage>;
};

type SpreadsheetTable = {
  name: string;
  rows: string[][];
  headerRow: boolean;
};

function sha256(value: Buffer): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function xml(value: string): string {
  return String(value || "")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function inlineText(node: InlineNode): string {
  switch (node.type) {
    case "Text": return node.value;
    case "Timestamp": return node.raw;
    case "TimestampRange": return `${node.start.raw}${node.separatorRaw}${node.end.raw}`;
    case "Emphasis": return node.content;
    case "Link": return node.descriptionRaw || (/^data:image\//i.test(node.targetRaw) ? "Image" : node.targetRaw);
    case "ProgressCookie": return node.raw;
    case "Entity": return node.raw;
    case "LatexFragment": return node.raw;
    case "ExportSnippet": return "";
    case "FootnoteReference": return node.labelRaw ? `[${node.labelRaw}]` : "[footnote]";
    case "Citation": return node.references.map((reference) => `@${reference.keyRaw}`).join("; ");
    case "Target": return "";
    case "Script": return node.valueRaw;
    case "LineBreak": return "\n";
  }
}

function inlinesText(nodes: InlineNode[]): string {
  return nodes.map(inlineText).join("");
}

function renderInline(node: InlineNode): string {
  if (node.type === "LineBreak") return "<text:line-break/>";
  if (node.type === "Link" && /^https?:/i.test(node.targetRaw)) {
    return `<text:a xlink:type="simple" xlink:href="${xml(node.targetRaw)}">${xml(node.descriptionRaw || node.targetRaw)}</text:a>`;
  }
  if (node.type === "Emphasis") {
    const style = node.kind === "bold"
      ? "Bold"
      : node.kind === "italic"
        ? "Italic"
        : node.kind === "underline"
          ? "Underline"
          : node.kind === "strike"
            ? "Strike"
            : "Code";
    return `<text:span text:style-name="${style}">${xml(node.content)}</text:span>`;
  }
  if (node.type === "Script") {
    const style = node.kind === "subscript" ? "Subscript" : "Superscript";
    return `<text:span text:style-name="${style}">${xml(node.valueRaw)}</text:span>`;
  }
  return xml(inlineText(node));
}

function renderInlines(nodes: InlineNode[]): string {
  return nodes.map(renderInline).join("");
}

function embeddedImage(target: string): { mediaType: OdfImage["mediaType"]; extension: string; data: Buffer } | null {
  const match = /^data:(image\/(?:gif|jpeg|png));base64,([a-z0-9+/=]+)$/i.exec(String(target || "").trim());
  if (!match) return null;
  const mediaType = match[1]!.toLowerCase() as OdfImage["mediaType"];
  const extension = mediaType === "image/jpeg" ? "jpg" : mediaType.slice("image/".length);
  return { mediaType, extension, data: Buffer.from(match[2]!, "base64") };
}

function standaloneImage(node: ParagraphNode): Extract<InlineNode, { type: "Link" }> | null {
  const meaningful = node.children.filter((child) => child.type !== "Text" || child.value.trim());
  if (meaningful.length !== 1 || meaningful[0]?.type !== "Link") return null;
  return embeddedImage(meaningful[0].targetRaw) ? meaningful[0] : null;
}

function addImage(context: OdfPresentationContext, target: string): OdfImage | null {
  const parsed = embeddedImage(target);
  if (!parsed) return null;
  const digest = sha256(parsed.data);
  const existing = context.imagesByHash.get(digest);
  if (existing) return existing;
  const image: OdfImage = {
    name: `Pictures/image${context.images.length + 1}.${parsed.extension}`,
    mediaType: parsed.mediaType,
    data: parsed.data,
  };
  context.images.push(image);
  context.imagesByHash.set(digest, image);
  return image;
}

function literalLines(value: string): string {
  const lines = String(value || "").replace(/\r\n/g, "\n").split("\n");
  return lines.map((line) => `<text:p text:style-name="CodeParagraph">${xml(line)}</text:p>`).join("");
}

function renderPresentationListItem(item: ListItemNode, context: OdfPresentationContext): string {
  const prefix = item.checkbox === "checked"
    ? "☒ "
    : item.checkbox === "unchecked"
      ? "☐ "
      : item.checkbox === "indeterminate"
        ? "◩ "
        : "";
  const description = item.descriptionTag?.length
    ? `<text:span text:style-name="Bold">${renderInlines(item.descriptionTag)} — </text:span>`
    : "";
  return `<text:list-item><text:p text:style-name="Body">${xml(prefix)}${description}</text:p>${renderPresentationNodes(item.children, context)}</text:list-item>`;
}

function renderPresentationList(node: ListNode, context: OdfPresentationContext): string {
  const style = node.ordered ? "NumberList" : "BulletList";
  return `<text:list text:style-name="${style}">${node.items.map((item) => renderPresentationListItem(item, context)).join("")}</text:list>`;
}

function renderPresentationTable(node: TableNode): string {
  const rows = node.rows.filter((row) => row.type === "TableRow");
  if (!rows.length) return "";
  const columnCount = Math.max(1, ...rows.map((row) => row.cells.length));
  const columns = Array.from({ length: columnCount }, () => "<table:table-column/>").join("");
  const body = rows.map((row) => {
    const cells = Array.from({ length: columnCount }, (_, index) => {
      const contents = row.contents?.[index];
      const value = contents ? renderInlines(contents) : xml(row.cells[index] || "");
      return `<table:table-cell office:value-type="string"><text:p text:style-name="TableText">${value}</text:p></table:table-cell>`;
    }).join("");
    return `<table:table-row>${cells}</table:table-row>`;
  }).join("");
  return `<table:table table:name="SlideTable">${columns}${body}</table:table>`;
}

function renderPresentationNode(node: Node, context: OdfPresentationContext): string {
  switch (node.type) {
    case "Paragraph": {
      const imageLink = standaloneImage(node);
      if (imageLink) {
        const image = addImage(context, imageLink.targetRaw);
        if (image) {
          return `<draw:frame draw:style-name="Image" draw:name="${xml(image.name)}" text:anchor-type="paragraph" svg:width="18cm" svg:height="8.5cm"><draw:image xlink:href="${xml(image.name)}" xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad"/></draw:frame>`;
        }
      }
      return `<text:p text:style-name="Body">${renderInlines(node.children)}</text:p>`;
    }
    case "List": return renderPresentationList(node, context);
    case "ListItem": return renderPresentationListItem(node, context);
    case "Table": return renderPresentationTable(node);
    case "SrcBlock": return literalLines(node.bodyRaw);
    case "Block": return literalLines(node.bodyRaw);
    case "FixedWidth": return literalLines(node.lines.map((line) => line.valueRaw).join("\n"));
    case "LatexEnvironment": return literalLines([node.beginRaw, node.bodyRaw, node.endRaw].filter(Boolean).join("\n"));
    case "FootnoteDefinition": return `<text:p text:style-name="Body">[${xml(node.labelRaw)}] ${renderInlines(node.children)}</text:p>`;
    case "HorizontalRule": return "<text:p text:style-name=\"Body\">────────</text:p>";
    case "Headline": return `<text:p text:style-name="GroupTitle">${renderInlines(node.title)}</text:p>${renderPresentationNodes(node.children, context)}`;
    case "Text": return `<text:p text:style-name="Body">${xml(node.value)}</text:p>`;
    default: return "";
  }
}

function renderPresentationNodes(nodes: Node[], context: OdfPresentationContext): string {
  return nodes.map((node) => renderPresentationNode(node, context)).join("");
}

function renderPresentationElements(elements: PresentationElement[], context: OdfPresentationContext): string {
  return elements.map((element) => {
    if (element.kind === "ast") return renderPresentationNode(element.node, context);
    const title = element.title.length > 0
      ? `<text:p text:style-name="GroupTitle">${renderInlines(element.title)}</text:p>`
      : "";
    return `${title}${renderPresentationElements(element.children, context)}`;
  }).join("");
}

function slidePage(
  slide: PresentationSlide,
  index: number,
  context: OdfPresentationContext,
): string {
  const title = renderInlines(slide.title);
  const body = renderPresentationElements(slide.elements, context);
  return `<draw:page draw:name="page${index}" draw:style-name="DrawingPage" draw:master-page-name="Default"><draw:frame draw:style-name="TitleFrame" draw:name="Title ${index}" presentation:class="title" svg:x="1cm" svg:y="0.6cm" svg:width="26cm" svg:height="1.5cm"><draw:text-box><text:p text:style-name="SlideTitle">${title}</text:p></draw:text-box></draw:frame><draw:frame draw:style-name="BodyFrame" draw:name="Body ${index}" presentation:class="outline" svg:x="1.2cm" svg:y="2.35cm" svg:width="25.6cm" svg:height="12.2cm"><draw:text-box>${body || '<text:p text:style-name="Body"/>'}</draw:text-box></draw:frame></draw:page>`;
}

function titlePage(title: string, author?: string, date?: string): string {
  const subtitle = [author, date].filter(Boolean).map((value) => xml(value || "")).join(" · ");
  return `<draw:page draw:name="title-page" draw:style-name="DrawingPage" draw:master-page-name="Default"><draw:frame draw:style-name="TitleFrame" draw:name="Presentation title" presentation:class="title" svg:x="1.5cm" svg:y="4.6cm" svg:width="25cm" svg:height="3cm"><draw:text-box><text:p text:style-name="DeckTitle">${xml(title)}</text:p></draw:text-box></draw:frame>${subtitle ? `<draw:frame draw:style-name="BodyFrame" draw:name="Presentation subtitle" presentation:class="subtitle" svg:x="2cm" svg:y="8.2cm" svg:width="24cm" svg:height="1.5cm"><draw:text-box><text:p text:style-name="DeckSubtitle">${subtitle}</text:p></draw:text-box></draw:frame>` : ""}</draw:page>`;
}

function commonStylesXml(): string {
  return `<office:styles><style:default-style style:family="paragraph"><style:paragraph-properties fo:margin-top="0cm" fo:margin-bottom="0.16cm"/><style:text-properties style:font-name="Aptos" fo:font-family="sans-serif" fo:font-size="18pt"/></style:default-style><style:style style:name="Body" style:family="paragraph"><style:text-properties fo:font-size="18pt"/></style:style><style:style style:name="TableText" style:family="paragraph"><style:text-properties fo:font-size="11pt"/></style:style><style:style style:name="CodeParagraph" style:family="paragraph"><style:text-properties style:font-name="Menlo" fo:font-family="monospace" fo:font-size="11pt"/></style:style><style:style style:name="GroupTitle" style:family="paragraph"><style:text-properties fo:font-size="18pt" fo:font-weight="bold"/></style:style><style:style style:name="SlideTitle" style:family="paragraph"><style:text-properties fo:font-size="28pt" fo:font-weight="bold"/></style:style><style:style style:name="DeckTitle" style:family="paragraph"><style:paragraph-properties fo:text-align="center"/><style:text-properties fo:font-size="34pt" fo:font-weight="bold"/></style:style><style:style style:name="DeckSubtitle" style:family="paragraph"><style:paragraph-properties fo:text-align="center"/><style:text-properties fo:font-size="18pt"/></style:style><style:style style:name="Bold" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style><style:style style:name="Italic" style:family="text"><style:text-properties fo:font-style="italic"/></style:style><style:style style:name="Underline" style:family="text"><style:text-properties style:text-underline-style="solid"/></style:style><style:style style:name="Strike" style:family="text"><style:text-properties style:text-line-through-style="solid"/></style:style><style:style style:name="Code" style:family="text"><style:text-properties style:font-name="Menlo" fo:font-family="monospace"/></style:style><style:style style:name="Subscript" style:family="text"><style:text-properties style:text-position="sub 58%"/></style:style><style:style style:name="Superscript" style:family="text"><style:text-properties style:text-position="super 58%"/></style:style><text:list-style style:name="BulletList"><text:list-level-style-bullet text:level="1" text:bullet-char="•"><style:list-level-properties text:space-before="0.8cm" text:min-label-width="0.5cm"/></text:list-level-style-bullet></text:list-style><text:list-style style:name="NumberList"><text:list-level-style-number text:level="1" style:num-format="1"><style:list-level-properties text:space-before="0.8cm" text:min-label-width="0.7cm"/></text:list-level-style-number></text:list-style></office:styles>`;
}

function odpStylesXml(): string {
  return `<?xml version="1.0" encoding="UTF-8"?><office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" office:version="1.3">${commonStylesXml()}<office:automatic-styles><style:page-layout style:name="PageLayout"><style:page-layout-properties fo:page-width="28cm" fo:page-height="15.75cm" style:print-orientation="landscape"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name="Default" style:page-layout-name="PageLayout" draw:style-name="DrawingPage"/></office:master-styles></office:document-styles>`;
}

function odfMetaXml(title: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?><office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/" office:version="1.3"><office:meta><meta:generator>Org2</meta:generator><dc:title>${xml(title)}</dc:title></office:meta></office:document-meta>`;
}

function odfSettingsXml(): string {
  return '<?xml version="1.0" encoding="UTF-8"?><office:document-settings xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" office:version="1.3"><office:settings/></office:document-settings>';
}

function odfManifestXml(mediaType: string, images: OdfImage[] = []): string {
  const imageEntries = images.map((image) => `<manifest:file-entry manifest:full-path="${xml(image.name)}" manifest:media-type="${xml(image.mediaType)}"/>`).join("");
  return `<?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3"><manifest:file-entry manifest:full-path="/" manifest:media-type="${xml(mediaType)}" manifest:version="1.3"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/><manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/><manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/><manifest:file-entry manifest:full-path="settings.xml" manifest:media-type="text/xml"/>${imageEntries}</manifest:manifest>`;
}

export function renderPublishedDocumentToOdp(
  document: DocumentNode,
  title: string,
  options: { includeTitle?: boolean } = {},
): PreparedOdfDocument {
  const presentation = compilePresentation(document);
  const fatal = presentation.diagnostics.find((diagnostic) => diagnostic.severity === "error");
  if (fatal) throw new Error(`Presentation publishing requires slide headings: ${fatal.message}`);
  const slides = presentation.sections.flatMap((section) => section.slides);
  if (!slides.length) throw new Error("Presentation publishing requires at least one slide heading");

  const context: OdfPresentationContext = { images: [], imagesByHash: new Map() };
  const pages = [
    ...(options.includeTitle === false
      ? []
      : [titlePage(title, presentation.metadata.author, presentation.metadata.date)]),
    ...slides.map((slide, index) => slidePage(slide, index + 1, context)),
  ].join("");
  const content = `<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" office:version="1.3"><office:scripts/><office:font-face-decls/><office:automatic-styles><style:style style:name="DrawingPage" style:family="drawing-page"><style:drawing-page-properties presentation:background-visible="true" presentation:background-objects-visible="true"/></style:style><style:style style:name="TitleFrame" style:family="graphic"><style:graphic-properties draw:stroke="none" draw:fill="none"/></style:style><style:style style:name="BodyFrame" style:family="graphic"><style:graphic-properties draw:stroke="none" draw:fill="none" fo:padding="0.15cm"/></style:style><style:style style:name="Image" style:family="graphic"><style:graphic-properties draw:stroke="none" draw:fill="none"/></style:style></office:automatic-styles><office:body><office:presentation>${pages}</office:presentation></office:body></office:document-content>`;
  const entries = [
    { name: "mimetype", data: Buffer.from(ODP_MEDIA_TYPE) },
    { name: "content.xml", data: Buffer.from(content) },
    { name: "styles.xml", data: Buffer.from(odpStylesXml()) },
    { name: "meta.xml", data: Buffer.from(odfMetaXml(title)) },
    { name: "settings.xml", data: Buffer.from(odfSettingsXml()) },
    { name: "META-INF/manifest.xml", data: Buffer.from(odfManifestXml(ODP_MEDIA_TYPE, context.images)) },
    ...context.images.map((image) => ({ name: image.name, data: image.data })),
  ];
  const bytes = storedZipArchive(entries);
  return {
    mediaType: ODP_MEDIA_TYPE,
    bytes,
    byteLength: bytes.length,
    sha256: sha256(bytes),
    itemCount: slides.length + (options.includeTitle === false ? 0 : 1),
  };
}

function uniqueSheetName(raw: string, used: Set<string>, fallbackIndex: number): string {
  const cleaned = String(raw || "")
    .replace(/[\\/?*\[\]:]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 80) || `Table ${fallbackIndex}`;
  let candidate = cleaned;
  let suffix = 2;
  while (used.has(candidate.toLowerCase())) {
    const marker = ` ${suffix++}`;
    candidate = `${cleaned.slice(0, Math.max(1, 80 - marker.length))}${marker}`;
  }
  used.add(candidate.toLowerCase());
  return candidate;
}

function collectSpreadsheetTables(
  nodes: Node[],
  tables: SpreadsheetTable[],
  usedNames: Set<string>,
  headingPath: string[] = [],
): void {
  for (const node of nodes) {
    if (node.type === "Headline") {
      collectSpreadsheetTables(node.children, tables, usedNames, [...headingPath, inlinesText(node.title)]);
      continue;
    }
    if (node.type === "List") {
      for (const item of node.items) collectSpreadsheetTables(item.children, tables, usedNames, headingPath);
      continue;
    }
    if (node.type !== "Table") continue;
    const rows = node.rows.filter((row) => row.type === "TableRow");
    if (!rows.length) continue;
    const headerRow = node.rows.length > 1 && node.rows[0]?.type === "TableRow" && node.rows[1]?.type === "TableHline";
    const tableIndex = tables.length + 1;
    tables.push({
      name: uniqueSheetName(headingPath.at(-1) || `Table ${tableIndex}`, usedNames, tableIndex),
      headerRow,
      rows: rows.map((row) => row.cells.map((cell, index) => {
        const contents = row.contents?.[index];
        return contents ? inlinesText(contents) : cell;
      })),
    });
  }
}

function spreadsheetCell(value: string, header: boolean): string {
  const normalized = String(value || "");
  const style = header ? ' table:style-name="HeaderCell"' : "";
  if (/^-?(?:\d+|\d*\.\d+)$/.test(normalized.trim())) {
    const number = Number(normalized.trim());
    if (Number.isFinite(number)) {
      return `<table:table-cell${style} office:value-type="float" office:value="${number}"><text:p>${xml(normalized)}</text:p></table:table-cell>`;
    }
  }
  return `<table:table-cell${style} office:value-type="string"><text:p>${xml(normalized)}</text:p></table:table-cell>`;
}

function odsStylesXml(): string {
  return `<?xml version="1.0" encoding="UTF-8"?><office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" office:version="1.3"><office:styles><style:default-style style:family="table-cell"><style:table-cell-properties fo:padding="0.08cm" fo:border="0.002cm solid #d0d7de"/><style:text-properties style:font-name="Aptos" fo:font-family="sans-serif" fo:font-size="10pt"/></style:default-style></office:styles><office:automatic-styles/><office:master-styles/></office:document-styles>`;
}

export function renderPublishedDocumentToOds(document: DocumentNode, title: string): PreparedOdfDocument {
  const tables: SpreadsheetTable[] = [];
  collectSpreadsheetTables(document.children, tables, new Set());
  if (!tables.length) throw new Error("Google Sheets publishing requires at least one table in the selected Org2 content");

  const sheets = tables.map((table) => {
    const columnCount = Math.max(1, ...table.rows.map((row) => row.length));
    const columns = Array.from({ length: columnCount }, () => '<table:table-column table:style-name="DataColumn"/>').join("");
    const rows = table.rows.map((row, rowIndex) => {
      const cells = Array.from({ length: columnCount }, (_, index) => spreadsheetCell(row[index] || "", table.headerRow && rowIndex === 0)).join("");
      return `<table:table-row>${cells}</table:table-row>`;
    }).join("");
    return `<table:table table:name="${xml(table.name)}">${columns}${rows}</table:table>`;
  }).join("");
  const content = `<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" office:version="1.3"><office:automatic-styles><style:style style:name="DataColumn" style:family="table-column"><style:table-column-properties style:column-width="3.5cm" style:use-optimal-column-width="true"/></style:style><style:style style:name="HeaderCell" style:family="table-cell"><style:table-cell-properties fo:background-color="#eef2f6"/><style:text-properties fo:font-weight="bold"/></style:style></office:automatic-styles><office:body><office:spreadsheet>${sheets}</office:spreadsheet></office:body></office:document-content>`;
  const entries = [
    { name: "mimetype", data: Buffer.from(ODS_MEDIA_TYPE) },
    { name: "content.xml", data: Buffer.from(content) },
    { name: "styles.xml", data: Buffer.from(odsStylesXml()) },
    { name: "meta.xml", data: Buffer.from(odfMetaXml(title)) },
    { name: "settings.xml", data: Buffer.from(odfSettingsXml()) },
    { name: "META-INF/manifest.xml", data: Buffer.from(odfManifestXml(ODS_MEDIA_TYPE)) },
  ];
  const bytes = storedZipArchive(entries);
  return { mediaType: ODS_MEDIA_TYPE, bytes, byteLength: bytes.length, sha256: sha256(bytes), itemCount: tables.length };
}
