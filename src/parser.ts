import type { DocumentNode, HeadlineNode, ListItemNode, ListNode, Node, ParagraphNode, TextNode } from "./ast.js";

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
};

function parseListItemLine(line: string): ParsedListItem | null {
  const unordered = /^([+-])(\s+)(.*)$/.exec(line);
  if (unordered) {
    const ws = unordered[2];
    if (ws !== " ") return null;
    const content = unordered[3];
    if (content.length === 0) return null;
    return { ordered: false, content };
  }

  const ordered = /^(\d+)([.)])(\s+)(.*)$/.exec(line);
  if (ordered) {
    const ws = ordered[3];
    if (ws !== " ") return null;
    const content = ordered[4];
    if (content.length === 0) return null;
    return { ordered: true, content };
  }

  return null;
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

  function addListItem(ordered: boolean, content: string): void {
    const list = ensureList(ordered);
    const item: ListItemNode = {
      type: "ListItem",
      children: [paragraphFromText(content)],
    };
    list.items.push(item);
  }

  const lines = input.split("\n");

  for (let i = 0; i < lines.length; i += 1) {
    const lineNumber = i + 1;
    const line = lines[i];

    if (line.startsWith("#+")) {
      fail(makeError("Unsupported construct: directive", lineNumber, 1));
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
      continue;
    }

    if (isBlank(line)) {
      flushParagraph();
      endList();
      continue;
    }

    if (line.includes("\t")) {
      fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
    }

    const listItem = parseListItemLine(line);
    if (listItem) {
      flushParagraph();
      addListItem(listItem.ordered, listItem.content);
      continue;
    }

    endList();
    paragraphLines.push(line);
  }

  flushParagraph();
  return doc;
}
