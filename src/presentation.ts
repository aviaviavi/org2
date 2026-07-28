import type {
  BlockNode,
  DocumentNode,
  DrawerNode,
  HeadlineNode,
  InlineNode,
  KeywordLineNode,
  ListItemNode,
  ListNode,
  Node,
  ParagraphNode,
  PropertyDrawerNode,
  SrcBlockNode,
  TableNode,
} from "./ast.js";
import { parseInlinesFromText, parseOrgToCanonicalAst } from "./parser.js";

export type PresentationDiagnostic = {
  severity: "warning" | "error";
  code: string;
  message: string;
  line?: number;
};

export type PresentationMetadata = {
  title: string;
  author?: string;
  email?: string;
  date?: string;
  language?: string;
  classOptions: string[];
  theme?: string;
  colorTheme?: string;
  fontTheme?: string;
  innerTheme?: string;
  outerTheme?: string;
  latexHeaders: string[];
  frameLevel: number;
  toc: boolean;
};

export type PresentationAstElement = {
  kind: "ast";
  node: Node;
};

export type PresentationGroupElement = {
  kind: "group";
  title: InlineNode[];
  environment: "block" | "note" | "ignoreheading" | "plain";
  columnWidth?: string;
  overlay?: string;
  children: PresentationElement[];
  sourceRange?: SourceRange;
};

export type PresentationElement = PresentationAstElement | PresentationGroupElement;

export type PresentationSlide = {
  title: InlineNode[];
  elements: PresentationElement[];
  fragile: boolean;
  overlay?: string;
  options: string[];
  sourceRange?: SourceRange;
};

export type PresentationSection = {
  title: InlineNode[];
  slides: PresentationSlide[];
  sourceRange?: SourceRange;
};

export type PresentationDocument = {
  metadata: PresentationMetadata;
  sections: PresentationSection[];
  diagnostics: PresentationDiagnostic[];
};

export type BeamerRenderResult = {
  tex: string;
  presentation: PresentationDocument;
  diagnostics: PresentationDiagnostic[];
};

type SourceRange = {
  startLine: number;
  endLine: number;
};

type HeadlineProperties = Record<string, string>;

function sourceRangeOf(value: object): SourceRange | undefined {
  const range = (value as { sourceRange?: SourceRange }).sourceRange;
  if (!range || !Number.isFinite(range.startLine) || !Number.isFinite(range.endLine)) return undefined;
  return range;
}

function inlinePlainText(nodes: InlineNode[]): string {
  return nodes
    .map((node) => {
      if (node.type === "Text") return node.value;
      if (node.type === "Emphasis") return node.content;
      if (node.type === "Link") return node.descriptionRaw || node.targetRaw;
      if (node.type === "ProgressCookie") return node.raw;
      if (node.type === "Timestamp") return node.raw;
      return `${node.start.raw}--${node.end.raw}`;
    })
    .join("");
}

function firstKeywordValue(doc: DocumentNode, key: string): string | undefined {
  const normalizedKey = key.toUpperCase();
  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    if (node.keyRaw.trim().toUpperCase() !== normalizedKey) continue;
    const value = node.valueRaw.trim();
    if (value) return value;
  }
  return undefined;
}

function keywordValues(doc: DocumentNode, ...keys: string[]): string[] {
  const normalizedKeys = new Set(keys.map((key) => key.toUpperCase()));
  return doc.children
    .filter((node): node is KeywordLineNode => node.type === "KeywordLine")
    .filter((node) => normalizedKeys.has(node.keyRaw.trim().toUpperCase()))
    .map((node) => node.valueRaw.trim())
    .filter(Boolean);
}

function parseBoolean(value: string | undefined, fallback: boolean): boolean {
  const normalized = String(value || "").trim().toLowerCase();
  if (!normalized) return fallback;
  if (["t", "true", "yes", "on", "1"].includes(normalized)) return true;
  if (["nil", "false", "no", "off", "0"].includes(normalized)) return false;
  return fallback;
}

function parseOptions(value: string | undefined): Map<string, string> {
  const result = new Map<string, string>();
  for (const token of String(value || "").trim().split(/\s+/)) {
    const match = /^([^:\s]+):(.*)$/.exec(token);
    if (match) result.set(match[1]!.toLowerCase(), match[2] || "");
  }
  return result;
}

function parseClassOptions(raw: string | undefined): string[] {
  return String(raw || "")
    .trim()
    .replace(/^\[/, "")
    .replace(/\]$/, "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
}

function parseTheme(raw: string | undefined): string | undefined {
  const value = String(raw || "").trim();
  if (!value) return undefined;
  const bracket = value.indexOf("[");
  return (bracket >= 0 ? value.slice(0, bracket) : value).trim() || undefined;
}

function presentationMetadata(doc: DocumentNode): PresentationMetadata {
  const options = parseOptions(firstKeywordValue(doc, "OPTIONS"));
  const frameLevelRaw =
    firstKeywordValue(doc, "ORG2_SLIDE_LEVEL") ||
    firstKeywordValue(doc, "SLIDE_LEVEL") ||
    firstKeywordValue(doc, "BEAMER_FRAME_LEVEL") ||
    options.get("h");
  const parsedFrameLevel = Number.parseInt(String(frameLevelRaw || "2"), 10);
  const frameLevel = Number.isFinite(parsedFrameLevel) && parsedFrameLevel > 0 ? parsedFrameLevel : 2;

  return {
    title: firstKeywordValue(doc, "TITLE") || "Untitled presentation",
    author: firstKeywordValue(doc, "AUTHOR"),
    email: firstKeywordValue(doc, "EMAIL"),
    date: firstKeywordValue(doc, "DATE"),
    language: firstKeywordValue(doc, "LANGUAGE"),
    classOptions: parseClassOptions(firstKeywordValue(doc, "LATEX_CLASS_OPTIONS")),
    theme: parseTheme(firstKeywordValue(doc, "BEAMER_THEME")),
    colorTheme: parseTheme(firstKeywordValue(doc, "BEAMER_COLOR_THEME")),
    fontTheme: parseTheme(firstKeywordValue(doc, "BEAMER_FONT_THEME")),
    innerTheme: parseTheme(firstKeywordValue(doc, "BEAMER_INNER_THEME")),
    outerTheme: parseTheme(firstKeywordValue(doc, "BEAMER_OUTER_THEME")),
    latexHeaders: keywordValues(doc, "LATEX_HEADER", "BEAMER_HEADER"),
    frameLevel,
    toc: parseBoolean(options.get("toc"), false),
  };
}

function drawerProperties(drawer: DrawerNode): HeadlineProperties {
  const result: HeadlineProperties = {};
  if (drawer.nameRaw.trim().toUpperCase() !== "PROPERTIES") return result;
  for (const line of drawer.bodyRaw.split("\n")) {
    const match = /^\s*:([^:\s]+):\s*(.*?)\s*$/.exec(line);
    if (match) result[match[1]!.toUpperCase()] = match[2] || "";
  }
  return result;
}

function propertyDrawerProperties(drawer: PropertyDrawerNode): HeadlineProperties {
  const result: HeadlineProperties = {};
  for (const property of drawer.properties) {
    result[property.key.trim().toUpperCase()] = property.value.trim();
  }
  return result;
}

function splitHeadlineMetadata(headline: HeadlineNode): {
  properties: HeadlineProperties;
  body: Node[];
} {
  const properties: HeadlineProperties = {};
  const body: Node[] = [];
  for (const child of headline.children) {
    if (child.type === "PropertyDrawer") {
      Object.assign(properties, propertyDrawerProperties(child));
      continue;
    }
    if (child.type === "Drawer" && child.nameRaw.trim().toUpperCase() === "PROPERTIES") {
      Object.assign(properties, drawerProperties(child));
      continue;
    }
    body.push(child);
  }
  return { properties, body };
}

function normalizeOverlay(raw: string | undefined): string | undefined {
  const value = String(raw || "").trim();
  if (!value) return undefined;
  if ((value.startsWith("<") && value.endsWith(">")) || (value.startsWith("[") && value.endsWith("]"))) {
    return value;
  }
  return `<${value}>`;
}

function normalizeColumnWidth(raw: string | undefined): string | undefined {
  const value = String(raw || "").trim();
  if (!value) return undefined;
  if (/^(?:0(?:\.\d+)?|1(?:\.0+)?)$/.test(value)) return value;
  if (/^\d+(?:\.\d+)?%$/.test(value)) {
    const percent = Number.parseFloat(value);
    if (Number.isFinite(percent) && percent > 0 && percent <= 100) {
      return String(percent / 100);
    }
  }
  return value;
}

function groupEnvironment(
  headline: HeadlineNode,
  properties: HeadlineProperties,
  diagnostics: PresentationDiagnostic[],
): PresentationGroupElement["environment"] {
  const raw =
    properties.SLIDE_ROLE ||
    properties.SLIDE_ENV ||
    properties.BEAMER_ENV ||
    "";
  const normalized = raw.trim().toLowerCase();
  if (normalized === "note" || headline.tags?.some((tag) => tag.toLowerCase() === "b_note")) return "note";
  if (normalized === "ignoreheading") return "ignoreheading";
  if (!normalized || normalized === "block") return "block";
  if (normalized === "plain") return "plain";
  diagnostics.push({
    severity: "warning",
    code: "unsupported-slide-environment",
    message: `Unsupported slide environment "${raw}"; rendering it as a block.`,
    line: sourceRangeOf(headline)?.startLine,
  });
  return "block";
}

function compileElements(nodes: Node[], diagnostics: PresentationDiagnostic[]): PresentationElement[] {
  return nodes.map((node): PresentationElement => {
    if (node.type !== "Headline") return { kind: "ast", node };
    const { properties, body } = splitHeadlineMetadata(node);
    return {
      kind: "group",
      title: node.title,
      environment: groupEnvironment(node, properties, diagnostics),
      columnWidth: normalizeColumnWidth(properties.SLIDE_COLUMN || properties.BEAMER_COL),
      overlay: normalizeOverlay(properties.SLIDE_REVEAL || properties.BEAMER_ACT),
      children: compileElements(body, diagnostics),
      sourceRange: sourceRangeOf(node),
    };
  });
}

function nodeNeedsFragile(node: Node): boolean {
  if (node.type === "SrcBlock") return true;
  if (node.type === "Block" && (node.kind === "example" || node.kind === "verse")) return true;
  if (node.type === "Headline") return node.children.some(nodeNeedsFragile);
  if (node.type === "List") return node.items.some((item) => item.children.some(nodeNeedsFragile));
  if (node.type === "ListItem") return node.children.some(nodeNeedsFragile);
  return false;
}

function elementsNeedFragile(elements: PresentationElement[]): boolean {
  return elements.some((element) =>
    element.kind === "group" ? elementsNeedFragile(element.children) : nodeNeedsFragile(element.node),
  );
}

function compileSlide(headline: HeadlineNode, diagnostics: PresentationDiagnostic[]): PresentationSlide {
  const { properties, body } = splitHeadlineMetadata(headline);
  const elements = compileElements(body, diagnostics);
  const options = String(properties.BEAMER_OPT || properties.SLIDE_OPTIONS || "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  return {
    title: headline.title,
    elements,
    fragile: elementsNeedFragile(elements),
    overlay: normalizeOverlay(properties.BEAMER_ACT || properties.SLIDE_REVEAL),
    options,
    sourceRange: sourceRangeOf(headline),
  };
}

function collectFrameHeadlines(nodes: Node[], frameLevel: number): HeadlineNode[] {
  const result: HeadlineNode[] = [];
  for (const node of nodes) {
    if (node.type !== "Headline") continue;
    if (node.level === frameLevel) result.push(node);
    else if (node.level < frameLevel) result.push(...collectFrameHeadlines(node.children, frameLevel));
  }
  return result;
}

export function compilePresentation(doc: DocumentNode): PresentationDocument {
  const metadata = presentationMetadata(doc);
  const diagnostics: PresentationDiagnostic[] = [];
  const sections: PresentationSection[] = [];
  const sectionLevel = Math.max(1, metadata.frameLevel - 1);
  const topHeadlines = doc.children.filter((node): node is HeadlineNode => node.type === "Headline");

  if (metadata.frameLevel === 1) {
    sections.push({
      title: [],
      slides: topHeadlines
        .filter((headline) => headline.level === 1)
        .map((headline) => compileSlide(headline, diagnostics)),
    });
  } else {
    for (const headline of topHeadlines) {
      if (headline.level !== sectionLevel) continue;
      sections.push({
        title: headline.title,
        slides: collectFrameHeadlines(headline.children, metadata.frameLevel)
          .map((frame) => compileSlide(frame, diagnostics)),
        sourceRange: sourceRangeOf(headline),
      });
    }

    const unsectionedFrames = collectFrameHeadlines(
      doc.children.filter((node) => node.type !== "Headline" || node.level !== sectionLevel),
      metadata.frameLevel,
    );
    if (unsectionedFrames.length > 0) {
      sections.unshift({
        title: [],
        slides: unsectionedFrames.map((frame) => compileSlide(frame, diagnostics)),
      });
    }
  }

  if (sections.every((section) => section.slides.length === 0)) {
    diagnostics.push({
      severity: "error",
      code: "no-slides",
      message: `No level-${metadata.frameLevel} slide headlines were found.`,
    });
  }

  return { metadata, sections, diagnostics };
}

const latexUnicodeReplacements: Record<string, string> = {
  "←": "\\ensuremath{\\leftarrow}",
  "→": "\\ensuremath{\\rightarrow}",
  "↔": "\\ensuremath{\\leftrightarrow}",
  "↑": "\\ensuremath{\\uparrow}",
  "↓": "\\ensuremath{\\downarrow}",
  "↖": "\\ensuremath{\\nwarrow}",
  "↗": "\\ensuremath{\\nearrow}",
  "↘": "\\ensuremath{\\searrow}",
  "↙": "\\ensuremath{\\swarrow}",
  "⇐": "\\ensuremath{\\Leftarrow}",
  "⇒": "\\ensuremath{\\Rightarrow}",
  "⇔": "\\ensuremath{\\Leftrightarrow}",
  "≤": "\\ensuremath{\\leq}",
  "≥": "\\ensuremath{\\geq}",
  "≠": "\\ensuremath{\\neq}",
  "≈": "\\ensuremath{\\approx}",
  "±": "\\ensuremath{\\pm}",
  "×": "\\ensuremath{\\times}",
  "÷": "\\ensuremath{\\div}",
  "∞": "\\ensuremath{\\infty}",
  "∅": "\\ensuremath{\\varnothing}",
  "∈": "\\ensuremath{\\in}",
  "∉": "\\ensuremath{\\notin}",
  "✓": "\\ensuremath{\\checkmark}",
  "✔": "\\ensuremath{\\checkmark}",
  "✗": "\\ensuremath{\\times}",
  "✘": "\\ensuremath{\\times}",
  "•": "\\textbullet{}",
  "…": "\\ldots{}",
  "–": "\\textendash{}",
  "—": "\\textemdash{}",
  "−": "\\ensuremath{-}",
};

function replaceLatexUnicode(value: string): string {
  return Array.from(value)
    .map((character) => latexUnicodeReplacements[character] || character)
    .join("");
}

function escapeLatexText(value: string): string {
  const specialCharacterReplacements: Record<string, string> = {
    "\\": "\\textbackslash{}",
    "{": "\\{",
    "}": "\\}",
    "$": "\\$",
    "&": "\\&",
    "#": "\\#",
    "_": "\\_",
    "%": "\\%",
    "~": "\\textasciitilde{}",
    "^": "\\textasciicircum{}",
  };
  return Array.from(value)
    .map((character) =>
      latexUnicodeReplacements[character] ||
      specialCharacterReplacements[character] ||
      character,
    )
    .join("");
}

function renderText(value: string): string {
  const mathPattern = /(\$[^$\n]+\$|\\\([^]*?\\\)|\\\[[^]*?\\\])/g;
  return value
    .split(mathPattern)
    .map((part) => {
      if (!part) return "";
      if (
        (part.startsWith("$") && part.endsWith("$")) ||
        (part.startsWith("\\(") && part.endsWith("\\)")) ||
        (part.startsWith("\\[") && part.endsWith("\\]"))
      ) {
        return replaceLatexUnicode(part);
      }
      return escapeLatexText(part);
    })
    .join("");
}

function escapeLatexUrl(value: string): string {
  return value
    .replace(/\\/g, "/")
    .replace(/%/g, "\\%")
    .replace(/#/g, "\\#")
    .replace(/\{/g, "\\{")
    .replace(/\}/g, "\\}");
}

function renderInline(node: InlineNode): string {
  if (node.type === "Text") return renderText(node.value);
  if (node.type === "Timestamp") return renderText(node.raw);
  if (node.type === "TimestampRange") return `${renderText(node.start.raw)}--${renderText(node.end.raw)}`;
  if (node.type === "ProgressCookie") return renderText(node.raw);
  if (node.type === "Emphasis") {
    const body = node.kind === "code" || node.kind === "verbatim"
      ? escapeLatexText(node.content)
      : renderText(node.content);
    if (node.kind === "bold") return `\\textbf{${body}}`;
    if (node.kind === "italic") return `\\emph{${body}}`;
    if (node.kind === "underline") return `\\uline{${body}}`;
    if (node.kind === "strike") return `\\sout{${body}}`;
    return `\\texttt{${body}}`;
  }

  const target = node.targetRaw.replace(/^file:/i, "");
  const url = escapeLatexUrl(target);
  if (node.descriptionRaw !== undefined) {
    return `\\href{${url}}{${renderInlines(parseInlinesFromText(node.descriptionRaw))}}`;
  }
  if (/^(?:https?|mailto):/i.test(target)) return `\\url{${url}}`;
  return `\\path{${escapeLatexUrl(target)}}`;
}

function renderInlines(nodes: InlineNode[]): string {
  return nodes.map(renderInline).join("");
}

function isImageTarget(targetRaw: string): boolean {
  const withoutQuery = targetRaw.replace(/^file:/i, "").split(/[?#]/, 1)[0] || "";
  return /\.(?:png|jpe?g|gif|svg|pdf|webp)$/i.test(withoutQuery);
}

function imageOnlyLink(paragraph: ParagraphNode): InlineNode & { type: "Link" } | null {
  const meaningful = paragraph.children.filter((node) => node.type !== "Text" || node.value.trim().length > 0);
  if (meaningful.length !== 1 || meaningful[0]?.type !== "Link") return null;
  return isImageTarget(meaningful[0].targetRaw) ? meaningful[0] : null;
}

function parseLatexImageOptions(raw: string | undefined): string {
  const value = String(raw || "").trim();
  const options: string[] = [];
  for (const key of ["width", "height", "scale"]) {
    const match = new RegExp(`(?:^|\\s):${key}\\s+([^\\s]+)`, "i").exec(value);
    if (match) options.push(`${key}=${match[1]}`);
  }
  return options.length > 0 ? options.join(",") : "width=.9\\linewidth";
}

function renderParagraph(node: ParagraphNode, latexAttributes?: string): string {
  const imageLink = imageOnlyLink(node);
  if (imageLink) {
    const target = imageLink.targetRaw.replace(/^file:/i, "");
    const options = parseLatexImageOptions(latexAttributes);
    return [
      "\\begin{center}",
      `\\includegraphics[${options}]{\\detokenize{${target}}}`,
      "\\end{center}",
    ].join("\n");
  }
  return renderInlines(node.children);
}

function renderListItem(item: ListItemNode): string {
  const checkbox = item.checkbox === "checked" ? "[x] " : item.checkbox === "unchecked" ? "[ ] " : "";
  const body = renderAstNodes(item.children).trim();
  return `\\item ${escapeLatexText(checkbox)}${body}`;
}

function renderList(node: ListNode): string {
  const environment = node.ordered ? "enumerate" : "itemize";
  return [
    `\\begin{${environment}}`,
    ...node.items.map(renderListItem),
    `\\end{${environment}}`,
  ].join("\n");
}

function renderTable(node: TableNode): string {
  const rows = node.rows.filter((row) => row.type === "TableRow");
  const columnCount = Math.max(1, ...rows.map((row) => row.cells.length));
  const renderedRows: string[] = [];
  for (const row of node.rows) {
    if (row.type === "TableHline") {
      renderedRows.push("\\hline");
      continue;
    }
    const cells = Array.from({ length: columnCount }, (_, index) =>
      renderInlines(parseInlinesFromText(row.cells[index] || "")),
    );
    renderedRows.push(`${cells.join(" & ")}\\\\[0pt]`);
  }
  return [
    "\\begin{center}",
    `\\begin{tabular}{${"l".repeat(columnCount)}}`,
    ...renderedRows,
    "\\end{tabular}",
    "\\end{center}",
  ].join("\n");
}

function stripCommonIndent(value: string): string {
  const lines = value.replace(/\r\n/g, "\n").split("\n");
  const indents = lines
    .filter((line) => line.trim().length > 0)
    .map((line) => /^ */.exec(line)?.[0].length || 0);
  const commonIndent = indents.length > 0 ? Math.min(...indents) : 0;
  return lines.map((line) => line.slice(Math.min(commonIndent, line.length))).join("\n").replace(/\n+$/, "");
}

function renderLiteralBlock(value: string): string {
  const body = stripCommonIndent(value);
  const mappedCharacters = Array.from(new Set(Array.from(body)))
    .filter((character) => Boolean(latexUnicodeReplacements[character]));
  if (mappedCharacters.length === 0) {
    return `\\begin{verbatim}\n${body}\n\\end{verbatim}`;
  }

  const literate = mappedCharacters
    .map((character) => `{${character}}{{${latexUnicodeReplacements[character]}}}1`)
    .join("");
  return [
    `\\begin{lstlisting}[basicstyle=\\ttfamily,columns=fullflexible,keepspaces=true,showstringspaces=false,literate=${literate}]`,
    body,
    "\\end{lstlisting}",
  ].join("\n");
}

function renderSourceBlock(node: SrcBlockNode): string {
  return renderLiteralBlock(node.bodyRaw);
}

function renderBlock(node: BlockNode): string {
  if (node.kind === "comment") return "";
  if (node.kind === "export") {
    const backend = node.begin.afterKeywordRaw.trim().toLowerCase();
    return backend === "beamer" || backend === "latex" ? node.bodyRaw.trim() : "";
  }
  if (node.kind === "example" || node.kind === "verse") {
    return renderLiteralBlock(node.bodyRaw);
  }
  const innerDoc = parseOrgToCanonicalAst(node.bodyRaw);
  const body = renderAstNodes(innerDoc.children).trim();
  const environment = node.kind === "quote" ? "quote" : node.kind === "center" ? "center" : undefined;
  if (!environment) return body;
  return `\\begin{${environment}}\n${body}\n\\end{${environment}}`;
}

function renderKeyword(node: KeywordLineNode): string {
  const key = node.keyRaw.trim().toUpperCase();
  if (key === "LATEX" || key === "BEAMER") return node.valueRaw.trim();
  return "";
}

function renderAstNode(node: Node, latexAttributes?: string): string {
  if (node.type === "Paragraph") return renderParagraph(node, latexAttributes);
  if (node.type === "List") return renderList(node);
  if (node.type === "ListItem") return renderListItem(node);
  if (node.type === "SrcBlock") return renderSourceBlock(node);
  if (node.type === "Block") return renderBlock(node);
  if (node.type === "Table") return renderTable(node);
  if (node.type === "KeywordLine") return renderKeyword(node);
  if (node.type === "Text") return renderText(node.value);
  if (node.type === "Headline") return renderAstNodes(node.children);
  return "";
}

function renderAstNodes(nodes: Node[]): string {
  const rendered: string[] = [];
  let latexAttributes: string | undefined;
  let suppressNextResult = false;

  for (const node of nodes) {
    if (node.type === "KeywordLine") {
      const key = node.keyRaw.trim().toUpperCase();
      if (key === "ATTR_LATEX") {
        latexAttributes = node.valueRaw.trim();
        continue;
      }
      if (key === "RESULTS") {
        suppressNextResult = true;
        continue;
      }
    }

    if (suppressNextResult && node.type === "Paragraph" && imageOnlyLink(node)) {
      suppressNextResult = false;
      latexAttributes = undefined;
      continue;
    }
    suppressNextResult = false;

    const value = renderAstNode(node, latexAttributes).trim();
    latexAttributes = undefined;
    if (value) rendered.push(value);
  }
  return rendered.join("\n\n");
}

function renderGroup(
  group: PresentationGroupElement,
  diagnostics: PresentationDiagnostic[],
  hideHeading = false,
): string {
  if (group.environment === "note") {
    const noteBody = renderPresentationElements(group.children, diagnostics).trim();
    const title = renderInlines(group.title);
    const body = [title, noteBody].filter(Boolean).join("\n\n");
    return `\\note{${body}}`;
  }

  if (group.environment === "ignoreheading") {
    return renderPresentationElements(group.children, diagnostics, true);
  }

  const body = renderPresentationElements(group.children, diagnostics).trim();
  if (group.environment === "plain" || hideHeading) return body;
  const overlay = group.overlay || "";
  return `\\begin{block}${overlay}{${renderInlines(group.title)}}\n${body}\n\\end{block}`;
}

function renderPresentationElements(
  elements: PresentationElement[],
  diagnostics: PresentationDiagnostic[],
  hideGroupHeadings = false,
): string {
  const rendered: string[] = [];
  let index = 0;

  while (index < elements.length) {
    const element = elements[index]!;
    if (element.kind === "ast") {
      const nodes: Node[] = [];
      while (index < elements.length) {
        const candidate = elements[index]!;
        if (candidate.kind !== "ast") break;
        nodes.push(candidate.node);
        index += 1;
      }
      const value = renderAstNodes(nodes).trim();
      if (value) rendered.push(value);
      continue;
    }

    if (element.kind === "group" && element.columnWidth) {
      const columns: PresentationGroupElement[] = [];
      while (index < elements.length) {
        const candidate = elements[index]!;
        if (candidate.kind !== "group" || !candidate.columnWidth) break;
        columns.push(candidate);
        index += 1;
      }
      rendered.push([
        "\\begin{columns}",
        ...columns.flatMap((column) => [
          `\\begin{column}{${column.columnWidth}\\columnwidth}`,
          renderGroup(column, diagnostics, hideGroupHeadings),
          "\\end{column}",
        ]),
        "\\end{columns}",
      ].join("\n"));
      continue;
    }

    rendered.push(renderGroup(element, diagnostics, hideGroupHeadings));
    index += 1;
  }

  return rendered.filter(Boolean).join("\n\n");
}

function slugify(value: string): string {
  const slug = value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug || "slide";
}

function renderSlide(
  slide: PresentationSlide,
  diagnostics: PresentationDiagnostic[],
  index: number,
): string {
  const title = renderInlines(slide.title);
  const label = `org2:${index + 1}-${slugify(inlinePlainText(slide.title))}`;
  const options = [`label={${label}}`, ...slide.options];
  if (slide.fragile && !options.some((option) => option.toLowerCase() === "fragile")) options.push("fragile");
  const optionText = options.length > 0 ? `[${options.join(",")}]` : "";
  const overlay = slide.overlay || "";
  const body = renderPresentationElements(slide.elements, diagnostics).trim();
  const sourceLine = slide.sourceRange?.startLine;
  const sourceMarker = sourceLine
    ? `\\makebox[0pt][l]{\\href{org2-source-line://${sourceLine}}{\\phantom{\\rule{1pt}{1pt}}}}`
    : "";
  return `\\begin{frame}${overlay}${optionText}{${title}}\n${sourceMarker}\n${body}\n\\end{frame}`;
}

function renderThemeCommand(command: string, value: string | undefined): string {
  return value ? `\\${command}{${escapeLatexText(value)}}` : "";
}

export function renderPresentationToBeamer(doc: DocumentNode): BeamerRenderResult {
  const presentation = compilePresentation(doc);
  const diagnostics = presentation.diagnostics;
  const metadata = presentation.metadata;
  const classOptions = metadata.classOptions.length > 0 ? `[${metadata.classOptions.join(",")}]` : "";
  const author = metadata.author ? renderText(metadata.author) : "";
  const title = renderInlines(parseInlinesFromText(metadata.title));
  let slideIndex = 0;
  const documentBody: string[] = [];

  for (const section of presentation.sections) {
    if (section.title.length > 0) {
      documentBody.push(`\\section{${renderInlines(section.title)}}`);
    }
    for (const slide of section.slides) {
      documentBody.push(renderSlide(slide, diagnostics, slideIndex));
      slideIndex += 1;
    }
  }

  const preamble = [
    "% Generated by Org2. Edit the Org/Org2 source, not this file.",
    `\\documentclass${classOptions}{beamer}`,
    "\\usepackage[utf8]{inputenc}",
    "\\usepackage[T1]{fontenc}",
    "\\usepackage{graphicx}",
    "\\usepackage[normalem]{ulem}",
    "\\usepackage{amsmath}",
    "\\usepackage{amssymb}",
    "\\usepackage{hyperref}",
    "\\usepackage{listings}",
    ...metadata.latexHeaders,
    renderThemeCommand("usetheme", metadata.theme),
    renderThemeCommand("usecolortheme", metadata.colorTheme),
    renderThemeCommand("usefonttheme", metadata.fontTheme),
    renderThemeCommand("useinnertheme", metadata.innerTheme),
    renderThemeCommand("useoutertheme", metadata.outerTheme),
    `\\author{${author}}`,
    `\\date{${metadata.date ? renderText(metadata.date) : "\\today"}}`,
    `\\title{${title}}`,
  ].filter(Boolean);

  const frontMatter = [
    "\\maketitle",
    metadata.toc
      ? "\\begin{frame}{Outline}\n\\tableofcontents\n\\end{frame}"
      : "",
  ].filter(Boolean);

  const tex = [
    ...preamble,
    "\\begin{document}",
    ...frontMatter,
    ...documentBody,
    "\\end{document}",
    "",
  ].join("\n");

  return { tex, presentation, diagnostics };
}
