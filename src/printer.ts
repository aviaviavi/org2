import type {
  BlockNode,
  DocumentNode,
  EmphasisNode,
  HeadlineNode,
  InlineNode,
  DirectiveLineNode,
  KeywordLineNode,
  LinkNode,
  ParagraphNode,
  PlanningNode,
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

function printEmphasis(node: EmphasisNode): string {
  return `${node.marker}${node.content}${node.marker}`;
}

function printLink(node: LinkNode): string {
  return node.raw;
}

function printInline(node: InlineNode): string {
  switch (node.type) {
    case "Text":
      return printText(node);
    case "Timestamp":
      return printTimestamp(node);
    case "TimestampRange":
      return printTimestampRange(node);
    case "Emphasis":
      return printEmphasis(node);
    case "Link":
      return printLink(node);
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

function printKeywordLine(node: KeywordLineNode): string {
  return node.raw;
}

function printDirectiveLine(node: DirectiveLineNode): string {
  return node.raw;
}

function printPlanning(node: PlanningNode): string {
  return node.raw;
}

function directiveLineToRaw(indent: string, keywordRaw: string, afterKeywordRaw: string): string {
  return `${indent}#+${keywordRaw}${afterKeywordRaw}`;
}

function printBlock(node: BlockNode): string {
  const begin = directiveLineToRaw(node.begin.indent, node.begin.keywordRaw, node.begin.afterKeywordRaw);

  if (!node.terminated || !node.end) {
    return [begin, node.bodyRaw].filter((l) => l.length > 0).join("\n");
  }

  const end = directiveLineToRaw(node.end.indent, node.end.keywordRaw, node.end.afterKeywordRaw);

  if (node.bodyRaw.length === 0) {
    return `${begin}\n${end}`;
  }

  return `${begin}\n${node.bodyRaw}\n${end}`;
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
      case "KeywordLine":
        lines.push(printKeywordLine(child));
        break;
      case "DirectiveLine":
        lines.push(printDirectiveLine(child));
        break;
      case "Planning":
        lines.push(printPlanning(child));
        break;
      case "Block":
        lines.push(printBlock(child));
        break;
      default:
        throw new Error(`Unsupported node in printer v0: ${child.type}`);
    }
  }

  // v0 fixtures generally include a trailing newline.
  return `${lines.join("\n\n")}\n`;
}
