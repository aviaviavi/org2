import type {
  DocumentNode,
  HeadlineNode,
  InlineNode,
  ParagraphNode,
  TextNode,
  TimestampNode,
  TimestampRangeNode,
} from "./ast.js";

function printText(node: TextNode): string {
  return node.value;
}

function printTimestamp(node: TimestampNode): string {
  return node.raw;
}

function printTimestampRange(node: TimestampRangeNode): string {
  return `${printTimestamp(node.start)}${node.separatorRaw}${printTimestamp(node.end)}`;
}

function printInline(node: InlineNode): string {
  switch (node.type) {
    case "Text":
      return printText(node);
    case "Timestamp":
      return printTimestamp(node);
    case "TimestampRange":
      return printTimestampRange(node);
    default: {
      const _exhaustive: never = node;
      return _exhaustive;
    }
  }
}

function printParagraph(node: ParagraphNode): string {
  return node.children.map(printInline).join("");
}

function printHeadline(node: HeadlineNode): string {
  const stars = "*".repeat(node.level);

  const todo = node.todo ? `${node.todo} ` : "";
  const title = node.title.map(printInline).join("");

  const tags =
    node.tags && node.tags.length > 0
      ? ` :${node.tags.map((t) => `${t}:`).join("")}`
      : "";

  return `${stars} ${todo}${title}${tags}`;
}

export function printCanonicalAstToOrg(doc: DocumentNode): string {
  if (doc.type !== "Document" || doc.version !== "0") {
    throw new Error("Unsupported AST: expected Document v0");
  }

  const lines: string[] = [];

  for (const child of doc.children) {
    switch (child.type) {
      case "Paragraph":
        lines.push(printParagraph(child));
        break;
      case "Headline":
        lines.push(printHeadline(child));
        break;
      default:
        throw new Error(`Unsupported node in printer v0: ${child.type}`);
    }
  }

  // v0 fixtures generally include a trailing newline.
  return `${lines.join("\n\n")}\n`;
}
