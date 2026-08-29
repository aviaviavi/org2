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

export const DOCX_MEDIA_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document" as const;

export type PreparedDocxDocument = {
  mediaType: typeof DOCX_MEDIA_TYPE;
  bytes: Buffer;
  byteLength: number;
  sha256: string;
};

type DocxMedia = {
  relationshipId: string;
  filename: string;
  extension: "gif" | "jpeg" | "png";
  mediaType: "image/gif" | "image/jpeg" | "image/png";
  data: Buffer;
  width: number;
  height: number;
};

type DocxRelationship = {
  id: string;
  type: string;
  target: string;
  external?: boolean;
};

type DocxContext = {
  media: DocxMedia[];
  mediaByHash: Map<string, DocxMedia>;
  relationships: DocxRelationship[];
  nextRelationshipId: number;
  nextDrawingId: number;
};

function sha256(value: Buffer): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function xml(value: string): string {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function cleanXmlText(value: string): string {
  return String(value || "").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "");
}

function runText(value: string, properties = ""): string {
  const parts = cleanXmlText(value).split("\n");
  return parts.map((part, index) => {
    const breakXml = index > 0 ? "<w:br/>" : "";
    return `<w:r>${properties ? `<w:rPr>${properties}</w:rPr>` : ""}${breakXml}<w:t xml:space="preserve">${xml(part)}</w:t></w:r>`;
  }).join("");
}

function paragraph(runs: string, options: { style?: string; indentTwips?: number; afterTwips?: number } = {}): string {
  const properties = [
    options.style ? `<w:pStyle w:val="${xml(options.style)}"/>` : "",
    options.indentTwips ? `<w:ind w:left="${options.indentTwips}"/>` : "",
    options.afterTwips !== undefined ? `<w:spacing w:after="${options.afterTwips}"/>` : "",
  ].filter(Boolean).join("");
  return `<w:p>${properties ? `<w:pPr>${properties}</w:pPr>` : ""}${runs || "<w:r><w:t></w:t></w:r>"}</w:p>`;
}

function imageDimensions(data: Buffer, mediaType: string): { width: number; height: number } {
  if (mediaType === "image/png" && data.length >= 24 && data.subarray(1, 4).toString("ascii") === "PNG") {
    return { width: data.readUInt32BE(16), height: data.readUInt32BE(20) };
  }
  if (mediaType === "image/gif" && data.length >= 10 && data.subarray(0, 3).toString("ascii") === "GIF") {
    return { width: data.readUInt16LE(6), height: data.readUInt16LE(8) };
  }
  if (mediaType === "image/jpeg" && data.length >= 4 && data[0] === 0xff && data[1] === 0xd8) {
    let offset = 2;
    while (offset + 9 < data.length) {
      if (data[offset] !== 0xff) {
        offset += 1;
        continue;
      }
      const marker = data[offset + 1] || 0;
      if (marker === 0xd8 || marker === 0xd9) {
        offset += 2;
        continue;
      }
      const segmentLength = data.readUInt16BE(offset + 2);
      if (segmentLength < 2 || offset + 2 + segmentLength > data.length) break;
      if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) {
        return { width: data.readUInt16BE(offset + 7), height: data.readUInt16BE(offset + 5) };
      }
      offset += 2 + segmentLength;
    }
  }
  return { width: 800, height: 600 };
}

function parseEmbeddedImage(target: string): { mediaType: DocxMedia["mediaType"]; extension: DocxMedia["extension"]; data: Buffer } | null {
  const match = /^data:(image\/(?:gif|jpeg|png));base64,([a-z0-9+/=]+)$/i.exec(String(target || "").trim());
  if (!match) return null;
  const mediaType = match[1].toLowerCase() as DocxMedia["mediaType"];
  const extension = mediaType === "image/jpeg" ? "jpeg" : mediaType.slice("image/".length) as "gif" | "png";
  return { mediaType, extension, data: Buffer.from(match[2], "base64") };
}

function addRelationship(context: DocxContext, relationship: Omit<DocxRelationship, "id">): string {
  const id = `rId${context.nextRelationshipId++}`;
  context.relationships.push({ id, ...relationship });
  return id;
}

function addEmbeddedImage(context: DocxContext, target: string): DocxMedia | null {
  const parsed = parseEmbeddedImage(target);
  if (!parsed) return null;
  const digest = sha256(parsed.data);
  const existing = context.mediaByHash.get(digest);
  if (existing) return existing;
  const sequence = context.media.length + 1;
  const media: DocxMedia = {
    relationshipId: addRelationship(context, {
      type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
      target: `media/image${sequence}.${parsed.extension}`,
    }),
    filename: `image${sequence}.${parsed.extension}`,
    extension: parsed.extension,
    mediaType: parsed.mediaType,
    data: parsed.data,
    ...imageDimensions(parsed.data, parsed.mediaType),
  };
  context.media.push(media);
  context.mediaByHash.set(digest, media);
  return media;
}

function drawingRun(media: DocxMedia, context: DocxContext): string {
  const drawingId = context.nextDrawingId++;
  const naturalCx = Math.max(1, media.width) * 9_525;
  const naturalCy = Math.max(1, media.height) * 9_525;
  const maxCx = 6 * 914_400;
  const maxCy = 7 * 914_400;
  const scale = Math.min(1, maxCx / naturalCx, maxCy / naturalCy);
  const cx = Math.max(9_525, Math.round(naturalCx * scale));
  const cy = Math.max(9_525, Math.round(naturalCy * scale));
  return `<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="${cx}" cy="${cy}"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="${drawingId}" name="Image ${drawingId}" descr="Embedded publication image"/><wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="${drawingId}" name="${xml(media.filename)}"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="${media.relationshipId}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="${cx}" cy="${cy}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>`;
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

function inlineRuns(nodes: InlineNode[], context: DocxContext): string {
  return nodes.map((node) => {
    if (node.type === "Link") {
      const image = addEmbeddedImage(context, node.targetRaw);
      if (image) return drawingRun(image, context);
      const label = node.descriptionRaw || node.targetRaw;
      if (/^https?:/i.test(node.targetRaw)) {
        const relationshipId = addRelationship(context, {
          type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
          target: node.targetRaw,
          external: true,
        });
        return `<w:hyperlink r:id="${relationshipId}">${runText(label, '<w:rStyle w:val="Hyperlink"/>')}</w:hyperlink>`;
      }
      return runText(label);
    }
    if (node.type === "Emphasis") {
      const properties = node.kind === "bold"
        ? "<w:b/>"
        : node.kind === "italic"
          ? "<w:i/>"
          : node.kind === "underline"
            ? '<w:u w:val="single"/>'
            : node.kind === "strike"
              ? "<w:strike/>"
              : "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/>";
      return runText(node.content, properties);
    }
    if (node.type === "Script") {
      return runText(node.valueRaw, `<w:vertAlign w:val="${node.kind === "subscript" ? "subscript" : "superscript"}"/>`);
    }
    if (node.type === "LineBreak") return "<w:r><w:br/></w:r>";
    return runText(inlineText(node));
  }).join("");
}

function standaloneImageParagraph(node: ParagraphNode, context: DocxContext): string | null {
  const meaningful = node.children.filter((child) => child.type !== "Text" || child.value.trim());
  if (meaningful.length !== 1 || meaningful[0]?.type !== "Link") return null;
  const image = addEmbeddedImage(context, meaningful[0].targetRaw);
  return image ? paragraph(drawingRun(image, context), { afterTwips: 160 }) : null;
}

function listItemPrefix(item: ListItemNode, ordered: boolean, index: number): string {
  const checkbox = item.checkbox === "checked"
    ? "☒ "
    : item.checkbox === "unchecked"
      ? "☐ "
      : item.checkbox === "indeterminate"
        ? "◩ "
        : "";
  const marker = ordered ? `${item.ordinal ?? index + 1}. ` : "• ";
  const description = item.descriptionTag?.length ? `${item.descriptionTag.map(inlineText).join("")} — ` : "";
  return `${marker}${checkbox}${description}`;
}

function renderList(node: ListNode, context: DocxContext, depth: number): string {
  return node.items.map((item, index) => {
    const prefix = listItemPrefix(item, node.ordered, index);
    const first = item.children[0];
    const indentTwips = Math.max(360, (depth + 1) * 360);
    if (first?.type === "Paragraph") {
      const initial = paragraph(`${runText(prefix)}${inlineRuns(first.children, context)}`, { indentTwips, afterTwips: 80 });
      return initial + renderNodes(item.children.slice(1), context, depth + 1);
    }
    return paragraph(runText(prefix), { indentTwips, afterTwips: 80 }) + renderNodes(item.children, context, depth + 1);
  }).join("");
}

function renderTable(node: TableNode, context: DocxContext): string {
  const rows = node.rows.filter((row) => row.type === "TableRow");
  if (!rows.length) return "";
  const borders = '<w:tblBorders><w:top w:val="single" w:sz="4" w:color="B7BDC5"/><w:left w:val="single" w:sz="4" w:color="B7BDC5"/><w:bottom w:val="single" w:sz="4" w:color="B7BDC5"/><w:right w:val="single" w:sz="4" w:color="B7BDC5"/><w:insideH w:val="single" w:sz="4" w:color="B7BDC5"/><w:insideV w:val="single" w:sz="4" w:color="B7BDC5"/></w:tblBorders>';
  const body = rows.map((row) => {
    const cells = row.cells.map((cell, index) => {
      const contents = row.contents?.[index];
      const runs = contents ? inlineRuns(contents, context) : runText(cell);
      return `<w:tc><w:tcPr><w:tcW w:w="0" w:type="auto"/><w:tcMar><w:top w:w="80" w:type="dxa"/><w:left w:w="100" w:type="dxa"/><w:bottom w:w="80" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tcMar></w:tcPr>${paragraph(runs, { afterTwips: 0 })}</w:tc>`;
    }).join("");
    return `<w:tr>${cells}</w:tr>`;
  }).join("");
  return `<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>${borders}</w:tblPr>${body}</w:tbl>`;
}

function renderNode(node: Node, context: DocxContext, depth: number): string {
  switch (node.type) {
    case "Headline":
      return `${paragraph(inlineRuns(node.title, context), { style: `Heading${Math.max(1, Math.min(6, node.level))}`, afterTwips: 100 })}${renderNodes(node.children, context, depth)}`;
    case "Paragraph":
      return standaloneImageParagraph(node, context) || paragraph(inlineRuns(node.children, context), { afterTwips: 140 });
    case "List":
      return renderList(node, context, depth);
    case "ListItem":
      return renderList({ type: "List", ordered: false, items: [node] }, context, depth);
    case "SrcBlock":
      return paragraph(runText(node.bodyRaw.replace(/\n$/, ""), '<w:rStyle w:val="CodeChar"/>'), { style: "Code", afterTwips: 140 });
    case "Block":
      return paragraph(runText(node.bodyRaw.replace(/\n$/, "")), { style: node.kind === "quote" ? "Quote" : "Code", afterTwips: 140 });
    case "FixedWidth":
      return paragraph(runText(node.lines.map((line) => line.valueRaw).join("\n"), '<w:rStyle w:val="CodeChar"/>'), { style: "Code", afterTwips: 140 });
    case "HorizontalRule":
      return '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="8" w:space="1" w:color="808080"/></w:pBdr></w:pPr></w:p>';
    case "LatexEnvironment":
      return paragraph(runText([node.beginRaw, node.bodyRaw, node.endRaw].filter(Boolean).join("\n")), { style: "Code", afterTwips: 140 });
    case "FootnoteDefinition":
      return paragraph(`${runText(`[${node.labelRaw}] `)}${inlineRuns(node.children, context)}`, { afterTwips: 100 });
    case "Table":
      return renderTable(node, context);
    case "Text":
      return node.value.trim() ? paragraph(runText(node.value), { afterTwips: 140 }) : "";
    case "KeywordLine":
    case "DirectiveLine":
    case "CommentLine":
    case "Planning":
    case "Clock":
    case "PropertyDrawer":
    case "Drawer":
    case "DynamicBlock":
    case "DiarySexp":
      return "";
  }
}

function renderNodes(nodes: Node[], context: DocxContext, depth = 0): string {
  return nodes.map((node) => renderNode(node, context, depth)).join("");
}

function stylesXml(): string {
  const headings = [
    [1, 32],
    [2, 28],
    [3, 24],
    [4, 22],
    [5, 20],
    [6, 18],
  ].map(([level, size]) => `<w:style w:type="paragraph" w:styleId="Heading${level}"><w:name w:val="heading ${level}"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="100"/></w:pPr><w:rPr><w:b/><w:sz w:val="${size}"/><w:szCs w:val="${size}"/></w:rPr></w:style>`).join("");
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="140" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/><w:szCs w:val="40"/></w:rPr></w:style>${headings}<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style><w:style w:type="character" w:styleId="CodeChar"><w:name w:val="Code Char"/><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="240" w:right="240"/><w:shd w:val="clear" w:color="auto" w:fill="F3F4F6"/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="480" w:right="480"/></w:pPr><w:rPr><w:i/></w:rPr></w:style></w:styles>`;
}

function documentRelationshipsXml(context: DocxContext): string {
  const relationships = context.relationships.map((relationship) => `<Relationship Id="${xml(relationship.id)}" Type="${xml(relationship.type)}" Target="${xml(relationship.target)}"${relationship.external ? ' TargetMode="External"' : ""}/>`).join("");
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${relationships}</Relationships>`;
}

function contentTypesXml(context: DocxContext): string {
  const imageDefaults = [...new Map(context.media.map((media) => [media.extension, media.mediaType])).entries()]
    .map(([extension, mediaType]) => `<Default Extension="${extension}" ContentType="${mediaType}"/>`)
    .join("");
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>${imageDefaults}<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>`;
}

function rootRelationshipsXml(): string {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>';
}

type ZipEntry = { name: string; data: Buffer };

let crcTable: Uint32Array | undefined;

function crc32(data: Buffer): number {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let index = 0; index < 256; index += 1) {
      let value = index;
      for (let bit = 0; bit < 8; bit += 1) value = (value & 1) ? (0xedb88320 ^ (value >>> 1)) : (value >>> 1);
      crcTable[index] = value >>> 0;
    }
  }
  let value = 0xffffffff;
  for (const byte of data) value = (crcTable[(value ^ byte) & 0xff] || 0) ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

function zipArchive(entries: ZipEntry[]): Buffer {
  const localParts: Buffer[] = [];
  const centralParts: Buffer[] = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name, "utf8");
    const checksum = crc32(entry.data);
    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(0, 6);
    localHeader.writeUInt16LE(0, 8);
    localHeader.writeUInt16LE(0, 10);
    localHeader.writeUInt16LE(0x21, 12);
    localHeader.writeUInt32LE(checksum, 14);
    localHeader.writeUInt32LE(entry.data.length, 18);
    localHeader.writeUInt32LE(entry.data.length, 22);
    localHeader.writeUInt16LE(name.length, 26);
    localHeader.writeUInt16LE(0, 28);
    localParts.push(localHeader, name, entry.data);

    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(20, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(0, 8);
    centralHeader.writeUInt16LE(0, 10);
    centralHeader.writeUInt16LE(0, 12);
    centralHeader.writeUInt16LE(0x21, 14);
    centralHeader.writeUInt32LE(checksum, 16);
    centralHeader.writeUInt32LE(entry.data.length, 20);
    centralHeader.writeUInt32LE(entry.data.length, 24);
    centralHeader.writeUInt16LE(name.length, 28);
    centralHeader.writeUInt16LE(0, 30);
    centralHeader.writeUInt16LE(0, 32);
    centralHeader.writeUInt16LE(0, 34);
    centralHeader.writeUInt16LE(0, 36);
    centralHeader.writeUInt32LE(0, 38);
    centralHeader.writeUInt32LE(offset, 42);
    centralParts.push(centralHeader, name);
    offset += localHeader.length + name.length + entry.data.length;
  }

  const central = Buffer.concat(centralParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(central.length, 12);
  end.writeUInt32LE(offset, 16);
  end.writeUInt16LE(0, 20);
  return Buffer.concat([...localParts, central, end]);
}

export function renderPublishedDocumentToDocx(
  document: DocumentNode,
  title: string,
  options: { includeTitle?: boolean } = {},
): PreparedDocxDocument {
  const context: DocxContext = {
    media: [],
    mediaByHash: new Map(),
    relationships: [{
      id: "rId1",
      type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles",
      target: "styles.xml",
    }],
    nextRelationshipId: 2,
    nextDrawingId: 1,
  };
  const titleParagraph = options.includeTitle === false ? "" : paragraph(runText(title), { style: "Title", afterTwips: 240 });
  const body = `${titleParagraph}${renderNodes(document.children, context)}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>`;
  const documentXml = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>${body}</w:body></w:document>`;
  const entries: ZipEntry[] = [
    { name: "[Content_Types].xml", data: Buffer.from(contentTypesXml(context)) },
    { name: "_rels/.rels", data: Buffer.from(rootRelationshipsXml()) },
    { name: "word/document.xml", data: Buffer.from(documentXml) },
    { name: "word/styles.xml", data: Buffer.from(stylesXml()) },
    { name: "word/_rels/document.xml.rels", data: Buffer.from(documentRelationshipsXml(context)) },
    ...context.media.map((media) => ({ name: `word/media/${media.filename}`, data: media.data })),
  ];
  const bytes = zipArchive(entries);
  return {
    mediaType: DOCX_MEDIA_TYPE,
    bytes,
    byteLength: bytes.length,
    sha256: sha256(bytes),
  };
}
