import type { DocumentNode, HeadlineNode, Node, ParagraphNode, TextNode } from "./ast.js";

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

function isBlank(line: string): boolean {
  return line.trim().length === 0;
}

function parseHeadline(line: string, lineNumber: number): { level: number; title: string } {
  const match = /^(\*+)(\s+)(.*)$/.exec(line);
  if (!match) {
    fail(makeError("Invalid headline; expected one or more '*' followed by a space", lineNumber, 1));
  }

  const stars = match[1];
  const ws = match[2];
  const title = match[3];

  if (ws !== " ") {
    fail(makeError("Invalid headline; only a single space is allowed after '*'", lineNumber, stars.length + 1));
  }

  if (title.length === 0) {
    fail(makeError("Invalid headline; title cannot be empty", lineNumber, stars.length + 2));
  }

  return { level: stars.length, title };
}

function getChildrenArray(node: DocumentNode | HeadlineNode): Node[] {
  return node.children;
}

export function parseOrgToCanonicalAst(input: string): DocumentNode {
  if (input.includes("\r\n")) {
    fail(makeError("Unsupported line endings: CRLF", 1, 1));
  }

  const doc: DocumentNode = { type: "Document", version: "0", children: [] };

  const headlineStack: HeadlineNode[] = [];

  let paragraphLines: string[] = [];

  function currentContainer(): DocumentNode | HeadlineNode {
    return headlineStack.length > 0 ? headlineStack[headlineStack.length - 1] : doc;
  }

  function flushParagraph(): void {
    if (paragraphLines.length === 0) return;

    const node = paragraphFromLines(paragraphLines);
    getChildrenArray(currentContainer()).push(node);
    paragraphLines = [];
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

      const { level, title } = parseHeadline(line, lineNumber);

      while (headlineStack.length > 0 && headlineStack[headlineStack.length - 1].level >= level) {
        headlineStack.pop();
      }

      const node: HeadlineNode = {
        type: "Headline",
        level,
        title: [text(title)],
        children: [],
      };

      getChildrenArray(currentContainer()).push(node);
      headlineStack.push(node);
      continue;
    }

    if (isBlank(line)) {
      flushParagraph();
      continue;
    }

    if (line.includes("\t")) {
      fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
    }

    paragraphLines.push(line);
  }

  flushParagraph();
  return doc;
}
