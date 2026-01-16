import type {
  DocumentNode,
  HeadlineNode,
  ListItemNode,
  ListNode,
  Node,
  ParagraphNode,
  PropertyDrawerNode,
  SrcBlockLine,
  SrcBlockNode,
  TextNode,
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

function paragraphFromLines(lines: string[]): ParagraphNode {
  const joined = lines.join("\n");
  return { type: "Paragraph", children: [text(joined)] };
}

function paragraphFromText(value: string): ParagraphNode {
  return { type: "Paragraph", children: [text(value)] };
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
        title: [text(title)],
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
