import type {
  BlockKind,
  BlockNode,
  DocumentNode,
  EmphasisKind,
  EmphasisNode,
  HeadlineNode,
  InlineNode,
  KeywordLineNode,
  LinkNode,
  ListItemNode,
  ListNode,
  Node,
  ParagraphNode,
  PlanningKind,
  PlanningNode,
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

function link(node: Omit<LinkNode, "type">): LinkNode {
  return { type: "Link", ...node };
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

type ParsedLinkAt = {
  node: LinkNode;
  endIndex: number;
};

function parseBracketLinkAt(value: string, startIndex: number): ParsedLinkAt | null {
  if (value.slice(startIndex, startIndex + 2) !== "[[") return null;

  const closeIndex = value.indexOf("]]", startIndex + 2);
  if (closeIndex === -1) return null;

  const raw = value.slice(startIndex, closeIndex + 2);
  const inner = value.slice(startIndex + 2, closeIndex);

  const splitIndex = inner.indexOf("][");
  if (splitIndex === -1) {
    return {
      node: link({
        format: "bracket",
        raw,
        targetRaw: inner,
      }),
      endIndex: closeIndex + 2,
    };
  }

  return {
    node: link({
      format: "bracket",
      raw,
      targetRaw: inner.slice(0, splitIndex),
      descriptionRaw: inner.slice(splitIndex + 2),
    }),
    endIndex: closeIndex + 2,
  };
}

function parsePlainUrlAt(value: string, startIndex: number): ParsedLinkAt | null {
  const rest = value.slice(startIndex);
  const match = /^(https?:\/\/[^\s]+)/.exec(rest);
  if (!match) return null;

  let url = match[1] ?? "";

  // Avoid swallowing common trailing punctuation.
  while (/[),.!?;:]$/.test(url)) {
    url = url.slice(0, -1);
  }

  if (url.length === 0) return null;

  return {
    node: link({
      format: "plain",
      raw: url,
      targetRaw: url,
    }),
    endIndex: startIndex + url.length,
  };
}

function parseLinkAt(value: string, startIndex: number): ParsedLinkAt | null {
  return parseBracketLinkAt(value, startIndex) ?? parsePlainUrlAt(value, startIndex);
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

    const parsedLink = parseLinkAt(value, i);
    if (parsedLink) {
      if (lastTextStart < i) {
        out.push(text(value.slice(lastTextStart, i)));
      }

      out.push(parsedLink.node);
      i = parsedLink.endIndex;
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

function parseKeywordLine(line: string, lineNumber: number): KeywordLineNode | null {
  const match = /^(\s*)#\+([^:\s]+):(.*)$/.exec(line);
  if (!match) return null;

  const indent = match[1] ?? "";
  const keyRaw = match[2] ?? "";
  const valueRaw = match[3] ?? "";

  if (indent.includes("\t") || valueRaw.includes("\t")) {
    fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
  }

  return {
    type: "KeywordLine",
    raw: line,
    indent,
    keyRaw,
    valueRaw,
  };
}

function parsePlanningLine(line: string): PlanningNode | null {
  const match = /^(SCHEDULED|DEADLINE):(.*)$/.exec(line);
  if (!match) return null;

  const kind = match[1] as PlanningKind;

  // Find the first timestamp/range in the remainder, if any.
  const after = match[2] ?? "";
  let ts;

  for (let i = 0; i < after.length; i += 1) {
    const ch = after[i];
    if (ch !== "<" && ch !== "[") continue;
    const parsed = parseTimestampOrRangeAt(after, i);
    if (parsed) {
      ts = parsed.node;
      break;
    }
  }

  return {
    type: "Planning",
    kind,
    raw: line,
    ...(ts ? { timestamp: ts } : {}),
  };
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

function getBlockKindFromBegin(line: SrcBlockLine): BlockKind | null {
  const key = line.keywordRaw.toLowerCase();
  if (key === "begin_example") return "example";
  if (key === "begin_quote") return "quote";
  if (key === "begin_verse") return "verse";
  if (key === "begin_center") return "center";
  return null;
}

function isEndBlockForKind(line: SrcBlockLine, kind: BlockKind): boolean {
  const key = line.keywordRaw.toLowerCase();
  return key === `end_${kind}`;
}

type ParseBlockResult = {
  block: BlockNode;
  nextLineIndex: number;
};

function parseBlock(lines: string[], startLineIndex: number, kind: BlockKind): ParseBlockResult {
  const beginLineNumber = startLineIndex + 1;
  const begin = parseSrcBlockLine(lines[startLineIndex] ?? "", beginLineNumber);
  if (!begin) {
    fail(makeError("Invalid block; expected #+begin_...", beginLineNumber, 1));
  }

  for (let i = startLineIndex + 1; i < lines.length; i += 1) {
    const lineNumber = i + 1;
    const line = lines[i] ?? "";

    const parsed = parseSrcBlockLine(line, lineNumber);
    if (parsed && isEndBlockForKind(parsed, kind)) {
      const bodyLines = lines.slice(startLineIndex + 1, i);
      return {
        block: {
          type: "Block",
          kind,
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
      type: "Block",
      kind,
      terminated: false,
      begin,
      bodyRaw: bodyLines.join("\n"),
    },
    nextLineIndex: lines.length,
  };
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

type TableLineMatch = {
  rest: string;
  indentLen: number;
};

function matchTableLine(line: string, indent: string): TableLineMatch | null {
  if (indent.length > 0) {
    if (!line.startsWith(indent)) return null;
    const rest = line.slice(indent.length);
    if (!rest.startsWith("|")) return null;
    const trimmedEnd = rest.trimEnd();
    if (!trimmedEnd.endsWith("|")) return null;
    return { rest, indentLen: indent.length };
  }

  // At document level, tables may be preceded by indentation spaces.
  const match = /^( *)(\|.*)$/.exec(line);
  if (!match) return null;

  const rest = match[2] ?? "";
  const trimmedEnd = rest.trimEnd();
  if (!trimmedEnd.endsWith("|")) return null;

  return { rest, indentLen: (match[1] ?? "").length };
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

    const matched = matchTableLine(line, indent);
    if (!matched) {
      return { table: { type: "Table", rows }, nextLineIndex: i };
    }

    const rest = matched.rest;

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
      const keyword = parseKeywordLine(line, lineNumber);
      if (keyword) {
        flushParagraph();
        endList();
        getChildrenArray(currentContainer()).push(keyword);
        i += 1;
        continue;
      }

      const planning = parsePlanningLine(line);
      if (planning) {
        flushParagraph();
        endList();
        getChildrenArray(currentContainer()).push(planning);
        i += 1;
        continue;
      }

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

        const kind = getBlockKindFromBegin(directive);
        if (kind) {
          flushParagraph();
          endList();

          const { block, nextLineIndex } = parseBlock(lines, i, kind);
          getChildrenArray(currentContainer()).push(block);
          i = nextLineIndex;
          continue;
        }

        flushParagraph();
        endList();
        getChildrenArray(currentContainer()).push({
          type: "DirectiveLine",
          raw: line,
          indent: directive.indent,
          keywordRaw: directive.keywordRaw,
          afterKeywordRaw: directive.afterKeywordRaw,
        });
        i += 1;
        continue;
      }
    }

    if (matchTableLine(line, "")) {
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

        if (directive) {
          if (isBeginSrc(directive)) {
            flushItemParagraph();
            const { block, nextLineIndex } = parseSrcBlock(lines, i);
            item.children.push(block);
            i = nextLineIndex;
            continue;
          }

          const kind = getBlockKindFromBegin(directive);
          if (kind) {
            flushItemParagraph();
            const { block, nextLineIndex } = parseBlock(lines, i, kind);
            item.children.push(block);
            i = nextLineIndex;
            continue;
          }

          flushItemParagraph();
          item.children.push({
            type: "DirectiveLine",
            raw: contLine,
            indent: directive.indent,
            keywordRaw: directive.keywordRaw,
            afterKeywordRaw: directive.afterKeywordRaw,
          });
          i += 1;
          continue;
        }

        if (matchTableLine(contLine, " ".repeat(listItem.indentColumn))) {
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
