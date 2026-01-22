import type {
  BlockNode,
  CommentLineNode,
  DocumentNode,
  DrawerNode,
  EmphasisNode,
  HeadlineNode,
  InlineNode,
  DirectiveLineNode,
  KeywordLineNode,
  LinkNode,
  ListItemNode,
  ListNode,
  Node,
  ParagraphNode,
  PlanningNode,
  PropertyDrawerNode,
  SrcBlockNode,
  TableNode,
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

function printCommentLine(node: CommentLineNode): string {
  return node.raw;
}

function printPropertyDrawer(node: PropertyDrawerNode): string {
  const lines: string[] = [":PROPERTIES:"];
  for (const prop of node.properties) {
    const propLine = `:${prop.key}: ${prop.value}`;
    lines.push(propLine);
  }
  lines.push(":END:");
  return lines.join("\n");
}

function printDrawer(node: DrawerNode): string {
  const begin = `${node.indent}:${node.nameRaw}:`;
  if (!node.terminated) {
    return [begin, node.bodyRaw].filter((l) => l.length > 0).join("\n");
  }
  const end = `${node.indent}:END:`;
  if (node.bodyRaw.length === 0) {
    return `${begin}\n${end}`;
  }
  return `${begin}\n${node.bodyRaw}\n${end}`;
}

function printSrcBlock(node: SrcBlockNode): string {
  const directiveLineToRaw = (indent: string, keywordRaw: string, afterKeywordRaw: string): string => {
    return `${indent}#+${keywordRaw}${afterKeywordRaw}`;
  };

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

function printTable(node: TableNode): string {
  return node.rows.map((row) => {
    if (row.type === "TableHline") {
      return `${row.indent}${row.raw}`;
    }
    // TableRow
    return `${row.indent}|${row.cells.join("|")}|`;
  }).join("\n");
}

function printListItem(node: ListItemNode): string {
  const childLines = node.children.map((child) => printNode(child));
  return childLines.join("\n");
}

function printList(node: ListNode): string {
  const items = node.items.map((item, index) => {
    const marker = node.ordered ? `${index + 1}.` : "-";
    const content = printListItem(item);
    // For list items with multiple lines, indent continuation lines
    const lines = content.split("\n");
    const firstLine = `${marker} ${lines[0]}`;
    // For continuation lines, preserve their indentation as-is from the AST
    const restLines = lines.slice(1);
    return [firstLine, ...restLines].join("\n");
  });
  return items.join("\n");
}

function printNode(node: any): string {
  switch (node.type) {
    case "Paragraph":
      return printParagraph(node);
    case "Headline":
      return printHeadline(node);
    case "KeywordLine":
      return printKeywordLine(node);
    case "DirectiveLine":
      return printDirectiveLine(node);
    case "Planning":
      return printPlanning(node);
    case "Block":
      return printBlock(node);
    case "CommentLine":
      return printCommentLine(node);
    case "PropertyDrawer":
      return printPropertyDrawer(node);
    case "Drawer":
      return printDrawer(node);
    case "SrcBlock":
      return printSrcBlock(node);
    case "Table":
      return printTable(node);
    case "List":
      return printList(node);
    case "ListItem":
      return printListItem(node);
    case "Text":
      return printText(node);
    default:
      throw new Error(`Unsupported node in printer: ${node.type}`);
  }
}

function printHeadline(node: HeadlineNode): string {
  const stars = "*".repeat(node.level);

  const todo = node.todo ? `${node.todo} ` : "";
  const title = node.title.map(printInline).join("");

  const tags =
    node.tags && node.tags.length > 0
      ? ` :${node.tags.map((t) => `${t}:`).join("")}`
      : "";

  const headlineLine = `${stars} ${todo}${title}${tags}`;
  
  // Print children if any
  if (!node.children || node.children.length === 0) {
    return headlineLine;
  }

  const childLines: string[] = [];
  let lastRaw: string | undefined;
  
  for (let i = 0; i < node.children.length; i++) {
    const child = node.children[i];
    
    // Deduplicate consecutive Planning nodes with the same raw value
    if (child.type === "Planning" && child.raw === lastRaw) {
      // Skip this node since it's a duplicate of the previous planning line
      continue;
    }
    
    if (child.type === "Planning") {
      lastRaw = child.raw;
    } else {
      lastRaw = undefined;
    }
    
    // Determine if we should add a blank line before this child
    let addBlankLineBefore = false;
    
    if (childLines.length === 0) {
      // First child: add blank line only if it's not metadata (Headline/Planning/PropertyDrawer/Drawer)
      const isMetadata = child.type === "Headline" || child.type === "Planning" || 
                        child.type === "PropertyDrawer" || child.type === "Drawer";
      addBlankLineBefore = !isMetadata;
    } else {
      // Subsequent child: add blank line if previous was PropertyDrawer and this is not metadata
      const prevChild = node.children[i - 1];
      if (prevChild && prevChild.type === "PropertyDrawer") {
        const isMetadata = child.type === "Headline" || child.type === "Planning" || 
                          child.type === "PropertyDrawer" || child.type === "Drawer";
        addBlankLineBefore = !isMetadata;
      }
    }
    
    if (addBlankLineBefore) {
      childLines.push("");
    }
    
    childLines.push(printNode(child));
  }

  return [headlineLine, ...childLines].join("\n");
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
    lines.push(printNode(child));
  }

  const output = lines.join("\n\n");
  
  // Check if the last child is an unterminated block that ends at EOF (no newline)
  const lastChild = doc.children[doc.children.length - 1];
  const endsWithNewline = !lastChild || lastChild.type !== "SrcBlock" || (lastChild as SrcBlockNode).terminated;
  
  // v0 fixtures generally include a trailing newline, except for unterminated blocks at EOF.
  return endsWithNewline ? `${output}\n` : output;
}
