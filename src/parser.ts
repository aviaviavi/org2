import type {
  DocumentNode,
  EmphasisKind,
  EmphasisNode,
  HeadlineNode,
  InlineNode,
  ListItemNode,
  ListNode,
  Node,
  ParagraphNode,
  PropertyDrawerNode,
  SrcBlockLine,
  SrcBlockNode,
  TableNode,
  TextNode,
  TimestampNode,
  TimestampRangeNode,
} from "./ast.js";

export type ParseError = {
  message: string;
  line: number;
  column: number;
};

function makeError(message: string, line: number, column: number): ParseError {
  return { message, line, column };
}

function fail(err: ParseError): never {
  const loc = `${err.line}:${err.column}`;
  throw new Error(`${loc} ${err.message}`);
}

function text(value: string): TextNode {
  return { type: "Text", value };
}

function timestamp(active: boolean, raw: string): TimestampNode {
  return { type: "Timestamp", active, raw };
}

function timestampRange(start: TimestampNode, separatorRaw: string, end: TimestampNode): TimestampRangeNode {
  return {
    type: "TimestampRange",
    start,
    separatorRaw,
    end,
  };
}

function emphasis(kind: EmphasisKind, marker: string, content: string): EmphasisNode {
  return {
    type: "Emphasis",
    kind,
    marker,
    content,
  };
}

function isTimestampDatePrefix(value: string): boolean {
  return /^\d{4}-\d{2}-\d{2}/.test(value);
}

type ParsedTimestampAt = {
  node: TimestampNode;
  endIndex: number;
};

function parseTimestampAt(value: string, startIndex: number): ParsedTimestampAt | null {
  const opener = value[startIndex];
  if (opener !== "<" && opener !== "[") return null;

  const closer = opener === "<" ? ">" : "]";
  const closeIndex = value.indexOf(closer, startIndex + 1);
  if (closeIndex === -1) return null;

  const inner = value.slice(startIndex + 1, closeIndex);
  if (!isTimestampDatePrefix(inner)) return null;

  const raw = value.slice(startIndex, closeIndex + 1);
  return {
    node: timestamp(opener === "<", raw),
    endIndex: closeIndex + 1,
  };
}

type ParsedTimestampRangeAt = {
  node: TimestampNode | TimestampRangeNode;
  endIndex: number;
};

function parseTimestampOrRangeAt(value: string, startIndex: number): ParsedTimestampRangeAt | null {
  const first = parseTimestampAt(value, startIndex);
  if (!first) return null;

  const afterFirst = first.endIndex;

  // Try to parse `<...>--<...>` (with optional whitespace around `--`).
  let i = afterFirst;
  while (i < value.length && value[i] === " ") i += 1;

  if (value.slice(i, i + 2) !== "--") {
    return { node: first.node, endIndex: first.endIndex };
  }

  i += 2;
  while (i < value.length && value[i] === " ") i += 1;

  const secondStart = i;
  const second = parseTimestampAt(value, secondStart);
  if (!second) {
    return { node: first.node, endIndex: first.endIndex };
  }

  const sepRaw = value.slice(afterFirst, secondStart);
  return {
    node: timestampRange(first.node, sepRaw, second.node),
    endIndex: second.endIndex,
  };
}

function isWordChar(ch: string): boolean {
  return /^[A-Za-z0-9]$/.test(ch);
}

function isWhitespace(ch: string): boolean {
  return ch === " " || ch === "\n";
}

function isBoundaryChar(ch: string | undefined): boolean {
  if (ch === undefined) return true;
  if (isWhitespace(ch)) return true;
  return !isWordChar(ch);
}

type ParsedEmphasisAt = {
  node: EmphasisNode;
  endIndex: number;
};

const EMPHASIS_MARKERS: Array<{ marker: string; kind: EmphasisKind }> = [
  { marker: "*", kind: "bold" },
  { marker: "/", kind: "italic" },
  { marker: "_", kind: "underline" },
  { marker: "+", kind: "strike" },
  { marker: "=", kind: "verbatim" },
  { marker: "~", kind: "code" },
];

function parseEmphasisAt(value: string, startIndex: number): ParsedEmphasisAt | null {
  const opener = value[startIndex];
  const rule = EMPHASIS_MARKERS.find((r) => r.marker === opener);
  if (!rule) return null;

  const prev = startIndex > 0 ? value[startIndex - 1] : undefined;
  const next = startIndex + 1 < value.length ? value[startIndex + 1] : undefined;

  if (!isBoundaryChar(prev)) return null;
  if (next === undefined || isWhitespace(next)) return null;

  // Find the first matching closer that satisfies boundary rules.
  for (let closeIndex = startIndex + 1; closeIndex < value.length; closeIndex += 1) {
    if (value[closeIndex] !== opener) continue;

    const beforeClose = closeIndex > startIndex + 1 ? value[closeIndex - 1] : undefined;
    const afterClose = closeIndex + 1 < value.length ? value[closeIndex + 1] : undefined;

    if (beforeClose === undefined || isWhitespace(beforeClose)) continue;
    if (!isBoundaryChar(afterClose)) continue;

    const content = value.slice(startIndex + 1, closeIndex);
    if (content.includes("\n")) continue;

    return {
      node: emphasis(rule.kind, opener, content),
      endIndex: closeIndex + 1,
    };
  }

  return null;
}

function parseInlinesFromText(value: string): InlineNode[] {
  const out: InlineNode[] = [];

  let i = 0;
  let lastTextStart = 0;

  while (i < value.length) {
    const parsedTimestamp = parseTimestampOrRangeAt(value, i);
    if (parsedTimestamp) {
      if (lastTextStart < i) {
        out.push(text(value.slice(lastTextStart, i)));
      }

      out.push(parsedTimestamp.node);
      i = parsedTimestamp.endIndex;
      lastTextStart = i;
      continue;
    }

    const parsedEmphasis = parseEmphasisAt(value, i);
    if (parsedEmphasis) {
      if (lastTextStart < i) {
        out.push(text(value.slice(lastTextStart, i)));
      }

      out.push(parsedEmphasis.node);
      i = parsedEmphasis.endIndex;
      lastTextStart = i;
      continue;
    }

    i += 1;
  }

  if (lastTextStart < value.length) {
    out.push(text(value.slice(lastTextStart)));
  }

  if (out.length === 0) return [text(value)];
  return out;
}

function paragraphFromLines(lines: string[]): ParagraphNode {
  const joined = lines.join("\n");
  return { type: "Paragraph", children: parseInlinesFromText(joined) };
}

function paragraphFromText(value: string): ParagraphNode {
  return { type: "Paragraph", children: parseInlinesFromText(value) };
}

function isBlank(line: string): boolean {
  return line.trim().length === 0;
}

function parseHeadline(
  line: string,
  lineNumber: number,
): { level: number; title: string; todo?: string; tags?: string[] } {
  const match = /^(\*+)(\s+)(.*)$/.exec(line);
  if (!match) {
    fail(makeError("Invalid headline; expected one or more '*' followed by a space", lineNumber, 1));
  }

  const stars = match[1];
  const ws = match[2];
  const raw = match[3];

  if (ws !== " ") {
    fail(makeError("Invalid headline; only a single space is allowed after '*'", lineNumber, stars.length + 1));
  }

  if (raw.length === 0) {
    fail(makeError("Invalid headline; title cannot be empty", lineNumber, stars.length + 2));
  }

  let todo;
  let tags;
  let rest = raw;

  {
    const parts = rest.split(/\s+/);
    const last = parts[parts.length - 1] ?? "";

    if (last.startsWith(":") && /^:(?:[^\s:]+:)+$/.test(last)) {
      const parsed = last.split(":").filter((t) => t.length > 0);
      if (parsed.length > 0) {
        tags = parsed;
        rest = rest.slice(0, rest.length - last.length).trimEnd();
      }
    }
  }

  if (rest.startsWith("TODO ")) {
    todo = "TODO";
    rest = rest.slice("TODO ".length);
  }

  if (rest.length === 0) {
    fail(makeError("Invalid headline; title cannot be empty", lineNumber, stars.length + 2));
  }

  return { level: stars.length, title: rest, todo, tags };
}

function getChildrenArray(node: DocumentNode | HeadlineNode): Node[] {
  return node.children;
}

type ParsedListItem = {
  ordered: boolean;
  content: string;
  indentColumn: number;
};

type ParsePropertyDrawerResult = {
  drawer: PropertyDrawerNode;
  nextLineIndex: number;
};

function parsePropertyDrawer(lines: string[], startLineIndex: number): ParsePropertyDrawerResult {
  const startLineNumber = startLineIndex + 1;

  if (lines[startLineIndex] !== ":PROPERTIES:") {
    fail(makeError("Invalid property drawer; expected :PROPERTIES:", startLineNumber, 1));
  }

  const properties: PropertyDrawerNode["properties"] = [];

  for (let i = startLineIndex + 1; i < lines.length; i += 1) {
    const lineNumber = i + 1;
    const line = lines[i];

    if (line === ":END:") {
      return {
        drawer: { type: "PropertyDrawer", properties },
        nextLineIndex: i + 1,
      };
    }

    if (isBlank(line)) {
      fail(makeError("Invalid property drawer; blank lines are not allowed", lineNumber, 1));
    }

    const match = /^:([^:\s]+):(\s*)(.*)$/.exec(line);
    if (!match) {
      fail(makeError("Invalid property drawer line; expected :KEY: VALUE", lineNumber, 1));
    }

    const key = match[1];
    const ws = match[2];
    const rawValue = match[3];

    if (ws !== " " && ws !== "") {
      fail(makeError("Invalid property drawer line; only a single space is allowed after :KEY:", lineNumber, key.length + 3));
    }

    properties.push({ key, value: rawValue });
  }

  fail(makeError("Invalid property drawer; missing :END:", startLineNumber, 1));
}

function parseListItemLine(line: string): ParsedListItem | null {
  const unordered = /^([+-])(\s+)(.*)$/.exec(line);
  if (unordered) {
    const ws = unordered[2];
    if (ws !== " ") return null;
    const content = unordered[3];
    if (content.length === 0) return null;
    return { ordered: false, content, indentColumn: unordered[1].length + ws.length };
  }

  const ordered = /^(\d+)([.)])(\s+)(.*)$/.exec(line);
  if (ordered) {
    const ws = ordered[3];
    if (ws !== " ") return null;
    const content = ordered[4];
    if (content.length === 0) return null;
    return {
      ordered: true,
      content,
      indentColumn: ordered[1].length + ordered[2].length + ws.length,
    };
  }

  return null;
}

type ParseSrcBlockResult = {
  block: SrcBlockNode;
  nextLineIndex: number;
};

type ParseTableResult = {
  table: TableNode;
  nextLineIndex: number;
};

function parseSrcBlockLine(line: string, lineNumber: number): SrcBlockLine | null {
  const match = /^(\s*)#\+([^\s]+)(.*)$/.exec(line);
  if (!match) return null;

  const indent = match[1];
  const keywordRaw = match[2];
  const afterKeywordRaw = match[3];

  if (indent.includes("\t") || afterKeywordRaw.includes("\t")) {
    fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
  }

  return { indent, keywordRaw, afterKeywordRaw };
}

function isBeginSrc(line: SrcBlockLine): boolean {
  return line.keywordRaw.toLowerCase() === "begin_src";
}

function isEndSrc(line: SrcBlockLine): boolean {
  return line.keywordRaw.toLowerCase() === "end_src";
}

function parseSrcBlock(lines: string[], startLineIndex: number): ParseSrcBlockResult {
  const startLineNumber = startLineIndex + 1;
  const begin = parseSrcBlockLine(lines[startLineIndex] ?? "", startLineNumber);
  if (!begin || !isBeginSrc(begin)) {
    fail(makeError("Invalid source block; expected #+begin_src", startLineNumber, 1));
  }

  for (let i = startLineIndex + 1; i < lines.length; i += 1) {
    const lineNumber = i + 1;
    const line = lines[i] ?? "";

    const parsed = parseSrcBlockLine(line, lineNumber);
    if (parsed && isEndSrc(parsed)) {
      const bodyLines = lines.slice(startLineIndex + 1, i);
      return {
        block: {
          type: "SrcBlock",
          terminated: true,
          begin,
          bodyRaw: bodyLines.join("\n"),
          end: parsed,
        },
        nextLineIndex: i + 1,
      };
    }
  }

  const bodyLines = lines.slice(startLineIndex + 1);
  return {
    block: {
      type: "SrcBlock",
      terminated: false,
      begin,
      bodyRaw: bodyLines.join("\n"),
    },
    nextLineIndex: lines.length,
  };
}

function isTableLineWithIndent(line: string, indent: string): boolean {
  if (!line.startsWith(indent)) return false;
  const rest = line.slice(indent.length);
  if (!rest.startsWith("|")) return false;
  const trimmedEnd = rest.trimEnd();
  return trimmedEnd.endsWith("|");
}

function isTableHlineRow(rest: string): boolean {
  const trimmed = rest.trim();
  return /^\|[-+]+\|$/.test(trimmed);
}

function parseTableRowCells(rest: string): string[] {
  const trimmedEnd = rest.trimEnd();
  const core = trimmedEnd.slice(1, -1);
  return core.split("|");
}

function parseTable(lines: string[], startLineIndex: number, indent: string): ParseTableResult {
  const rows: TableNode["rows"] = [];

  for (let i = startLineIndex; i < lines.length; i += 1) {
    const line = lines[i] ?? "";

    if (!isTableLineWithIndent(line, indent)) {
      return { table: { type: "Table", rows }, nextLineIndex: i };
    }

    const rest = line.slice(indent.length);

    if (isTableHlineRow(rest)) {
      rows.push({ type: "TableHline" });
      continue;
    }

    rows.push({ type: "TableRow", cells: parseTableRowCells(rest) });
  }

  return { table: { type: "Table", rows }, nextLineIndex: lines.length };
}

export function parseOrgToCanonicalAst(input: string): DocumentNode {
  if (input.includes("\r\n")) {
    fail(makeError("Unsupported line endings: CRLF", 1, 1));
  }

  const doc: DocumentNode = { type: "Document", version: "0", children: [] };

  const headlineStack: HeadlineNode[] = [];

  let paragraphLines: string[] = [];
  let currentList: ListNode | null = null;

  function currentContainer(): DocumentNode | HeadlineNode {
    return headlineStack.length > 0 ? headlineStack[headlineStack.length - 1] : doc;
  }

  function flushParagraph(): void {
    if (paragraphLines.length === 0) return;

    const node = paragraphFromLines(paragraphLines);
    getChildrenArray(currentContainer()).push(node);
    paragraphLines = [];
  }

  function endList(): void {
    currentList = null;
  }

  function ensureList(ordered: boolean): ListNode {
    if (currentList && currentList.ordered === ordered) return currentList;

    const list: ListNode = {
      type: "List",
      ordered,
      items: [],
    };

    getChildrenArray(currentContainer()).push(list);
    currentList = list;
    return list;
  }

  function addListItem(ordered: boolean, content: string): ListItemNode {
    const list = ensureList(ordered);
    const item: ListItemNode = {
      type: "ListItem",
      children: [paragraphFromText(content)],
    };
    list.items.push(item);
    return item;
  }

  const lines = input.split("\n");

  for (let i = 0; i < lines.length; ) {
    const lineNumber = i + 1;
    const line = lines[i];

    {
      const directive = parseSrcBlockLine(line, lineNumber);
      if (directive) {
        if (isBeginSrc(directive)) {
          flushParagraph();
          endList();

          const { block, nextLineIndex } = parseSrcBlock(lines, i);
          getChildrenArray(currentContainer()).push(block);
          i = nextLineIndex;
          continue;
        }

        fail(makeError("Unsupported construct: directive", lineNumber, 1));
      }
    }

    if (isTableLineWithIndent(line, "")) {
      flushParagraph();
      endList();

      const { table, nextLineIndex } = parseTable(lines, i, "");
      getChildrenArray(currentContainer()).push(table);
      i = nextLineIndex;
      continue;
    }

    if (line.startsWith("*")) {
      flushParagraph();
      endList();

      const { level, title, todo, tags } = parseHeadline(line, lineNumber);

      while (headlineStack.length > 0 && headlineStack[headlineStack.length - 1].level >= level) {
        headlineStack.pop();
      }

      const node: HeadlineNode = {
        type: "Headline",
        level,
        ...(todo ? { todo } : {}),
        ...(tags ? { tags } : {}),
        title: parseInlinesFromText(title),
        children: [],
      };

      getChildrenArray(currentContainer()).push(node);
      headlineStack.push(node);
      i += 1;
      continue;
    }

    if (line === ":PROPERTIES:") {
      flushParagraph();
      endList();

      const { drawer, nextLineIndex } = parsePropertyDrawer(lines, i);
      getChildrenArray(currentContainer()).push(drawer);
      i = nextLineIndex;
      continue;
    }

    if (isBlank(line)) {
      flushParagraph();
      endList();
      i += 1;
      continue;
    }

    if (line.includes("\t")) {
      fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
    }

    const listItem = parseListItemLine(line);
    if (listItem) {
      flushParagraph();
      const item = addListItem(listItem.ordered, listItem.content);
      i += 1;

      let itemParagraphLines: string[] = [];

      function flushItemParagraph(): void {
        if (itemParagraphLines.length === 0) return;
        item.children.push(paragraphFromLines(itemParagraphLines));
        itemParagraphLines = [];
      }

      while (i < lines.length) {
        const contLineNumber = i + 1;
        const contLine = lines[i] ?? "";

        if (isBlank(contLine)) {
          flushItemParagraph();
          break;
        }

        if (contLine.startsWith("*")) {
          flushItemParagraph();
          break;
        }

        const maybeNextItem = parseListItemLine(contLine);
        if (maybeNextItem) {
          flushItemParagraph();
          break;
        }

        if (!contLine.startsWith(" ".repeat(listItem.indentColumn))) {
          flushItemParagraph();
          break;
        }

        const directive = parseSrcBlockLine(contLine, contLineNumber);
        if (directive && isBeginSrc(directive)) {
          flushItemParagraph();
          const { block, nextLineIndex } = parseSrcBlock(lines, i);
          item.children.push(block);
          i = nextLineIndex;
          continue;
        }

        if (isTableLineWithIndent(contLine, " ".repeat(listItem.indentColumn))) {
          flushItemParagraph();
          const { table, nextLineIndex } = parseTable(lines, i, " ".repeat(listItem.indentColumn));
          item.children.push(table);
          i = nextLineIndex;
          continue;
        }

        if (contLine.includes("\t")) {
          fail(
            makeError(
              "Unsupported construct: tab character",
              contLineNumber,
              contLine.indexOf("\t") + 1,
            ),
          );
        }

        itemParagraphLines.push(contLine.slice(listItem.indentColumn));
        i += 1;
      }

      continue;
    }

    endList();
    paragraphLines.push(line);
    i += 1;
  }

  flushParagraph();
  return doc;
}
