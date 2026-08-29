import type {
  BlockNode,
  CommentLineNode,
  DocumentNode,
  DrawerNode,
  DynamicBlockNode,
  EmphasisNode,
  HeadlineNode,
  InlineNode,
  DirectiveLineNode,
  KeywordLineNode,
  LinkNode,
  ProgressCookieNode,
  ListItemNode,
  ListNode,
  Node,
  ParagraphNode,
  PlanningNode,
  ClockNode,
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

function printProgressCookie(node: ProgressCookieNode): string {
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
    case "ProgressCookie":
      return printProgressCookie(node);
    case "Entity":
    case "LatexFragment":
    case "ExportSnippet":
    case "FootnoteReference":
    case "Citation":
    case "Target":
    case "Script":
    case "LineBreak":
      return node.raw;
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

function printAffiliatedKeywords(node: SrcBlockNode | BlockNode | DynamicBlockNode | TableNode): string[] {
  return (node.affiliatedKeywords ?? []).map(printKeywordLine);
}

function printSrcBlock(node: SrcBlockNode): string {
  const directiveLineToRaw = (indent: string, keywordRaw: string, afterKeywordRaw: string): string => {
    if (keywordRaw === "```") return `${indent}\`\`\`${afterKeywordRaw}`;
    return `${indent}#+${keywordRaw}${afterKeywordRaw}`;
  };

  const begin = directiveLineToRaw(node.begin.indent, node.begin.keywordRaw, node.begin.afterKeywordRaw);

  const affiliated = printAffiliatedKeywords(node);

  if (!node.terminated || !node.end) {
    return [...affiliated, begin, node.bodyRaw].filter((l) => l.length > 0).join("\n");
  }

  const end = directiveLineToRaw(node.end.indent, node.end.keywordRaw, node.end.afterKeywordRaw);

  if (node.bodyRaw.length === 0) {
    return [...affiliated, begin, end].join("\n");
  }

  return [...affiliated, begin, node.bodyRaw, end].join("\n");
}


function printTable(node: TableNode): string {
  const tableRows = node.rows.filter((r) => r.type === "TableRow") as Array<Extract<TableNode["rows"][number], { type: "TableRow" }>>;

  const colCount = tableRows.reduce((max, r) => Math.max(max, r.cells.length), 0);
  const widths: number[] = Array.from({ length: colCount }, () => 0);

  for (const r of tableRows) {
    for (let i = 0; i < colCount; i += 1) {
      const cell = (r.cells[i] ?? "");
      widths[i] = Math.max(widths[i] ?? 0, cell.length);
    }
  }

  const printRow = (indent: string, cells: string[]): string => {
    const parts: string[] = [];
    for (let i = 0; i < colCount; i += 1) {
      const cell = cells[i] ?? "";
      parts.push(` ${cell.padEnd(widths[i] ?? 0, " ")} `);
    }
    return `${indent}|${parts.join("|")}|`;
  };

  const printHline = (indent: string): string => {
    // Each column gets 2 extra chars for the surrounding spaces.
    const segments = widths.map((w) => "-".repeat(w + 2));
    return `${indent}|${segments.join("+")}|`;
  };

  const table = node.rows
    .map((row) => {
      if (row.type === "TableHline") {
        // Re-generate hlines deterministically based on observed column widths.
        return printHline(row.indent);
      }
      return printRow(row.indent, row.cells);
    })
    .join("\n");

  return [...printAffiliatedKeywords(node), table].filter((l) => l.length > 0).join("\n");
}

function printListItem(node: ListItemNode, continuationIndent: string, nestedListIndent: string): string {
  const out: string[] = [];

  for (let childIndex = 0; childIndex < node.children.length; childIndex += 1) {
    const child = node.children[childIndex]!;

    if (child.type === "List") {
      out.push(printList(child, nestedListIndent));
      continue;
    }

    const printed = printNode(child);
    const lines = printed.split("\n");

    for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
      const line = lines[lineIndex]!;
      const isFirstLineOfFirstChild = childIndex === 0 && lineIndex === 0;

      if (isFirstLineOfFirstChild) {
        out.push(line);
      } else if (line.startsWith(continuationIndent)) {
        out.push(line);
      } else {
        out.push(continuationIndent + line);
      }
    }
  }

  return out.join("\n");
}

function printList(node: ListNode, indent: string = ""): string {
  const items = node.items.map((item, index) => {
    const marker = node.ordered ? `${item.ordinal ?? index + 1}.` : "-";

    let checkboxStr = "";
    if (item.checkbox === "unchecked") checkboxStr = " [ ]";
    if (item.checkbox === "checked") checkboxStr = " [X]";
    if (item.checkbox === "indeterminate") checkboxStr = " [-]";
    const counterStr = item.counter !== undefined ? ` [@${item.counter}]` : "";
    const descriptionStr = item.descriptionTag ? ` ${item.descriptionTag.map(printInline).join("")} ::` : "";

    const nestedListIndent = indent + " ".repeat(marker.length + 1);
    const continuationIndent = indent + " ".repeat(marker.length + counterStr.length + checkboxStr.length + descriptionStr.length + 1);
    const content = printListItem(item, continuationIndent, nestedListIndent);

    const lines = content.split("\n");
    const firstLine = `${indent}${marker}${counterStr}${checkboxStr}${descriptionStr} ${lines[0]}`;
    const restLines = lines.slice(1).map((line) => {
      if (line.startsWith(nestedListIndent)) return line;
      if (line.startsWith(continuationIndent)) return line;
      return continuationIndent + line;
    });

    return [firstLine, ...restLines].join("\n");
  });

  return items.join("\n");
}

function printNode(node: Node): string {
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
    case "Clock":
      return printClock(node);
    case "Block":
      return printBlock(node);
    case "DynamicBlock": {
      const body = node.bodyRaw.length > 0 ? `\n${node.bodyRaw}` : "";
      const end = node.terminated && node.endRaw ? `\n${node.endRaw}` : "";
      return [...printAffiliatedKeywords(node), `${node.beginRaw}${body}${end}`].join("\n");
    }
    case "FixedWidth":
      return node.lines.map((line) => line.raw).join("\n");
    case "HorizontalRule":
    case "DiarySexp":
      return node.raw;
    case "LatexEnvironment":
      return [node.beginRaw, node.bodyRaw, node.terminated ? node.endRaw : undefined].filter((line) => line !== undefined && line.length > 0).join("\n");
    case "FootnoteDefinition":
      return `[fn:${node.labelRaw}]${node.children.length > 0 ? ` ${node.children.map(printInline).join("")}` : ""}`;
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
      return printListItem(node, "", "");
    case "Text":
      return printText(node);
    default: {
      const _exhaustive: never = node;
      return _exhaustive;
    }
  }
}

type NodeWithSpacing = Node & { blankLinesBefore?: unknown };

function blankLinesBefore(node: Node): number | undefined {
  const value = (node as NodeWithSpacing).blankLinesBefore;
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}

function separatorForBlankLines(blankLines: number): string {
  return "\n".repeat(blankLines + 1);
}

function printHeadline(node: HeadlineNode): string {
  const stars = "*".repeat(node.level);

  const todo = node.todo ? `${node.todo} ` : "";
  const priority = node.priority ? `[#${node.priority}] ` : "";
  const comment = node.commented ? "COMMENT " : "";
  const title = node.title.map(printInline).join("");

  const tags =
    node.tags && node.tags.length > 0
      ? ` :${node.tags.map((t) => `${t}:`).join("")}`
      : "";

  const headlineLine = `${stars} ${todo}${priority}${comment}${title}${tags}`;
  
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
    
    const explicitBlankLinesBefore = blankLinesBefore(child);

    if (explicitBlankLinesBefore !== undefined) {
      childLines.push(...Array.from({ length: explicitBlankLinesBefore }, () => ""));
      childLines.push(printNode(child));
      continue;
    }

    // Determine if we should add a blank line before this child when printing
    // canonical AST fixtures that do not carry source spacing metadata.
    let addBlankLineBefore = false;
    
    if (childLines.length === 0) {
      // First child: add blank line only if it's not metadata (Headline/Planning/PropertyDrawer/Drawer)
      const isMetadata = child.type === "Headline" || child.type === "Planning" || child.type === "Clock" ||
                        child.type === "PropertyDrawer" || child.type === "Drawer";
      addBlankLineBefore = !isMetadata;
    } else {
      // Subsequent child: add blank line if previous was PropertyDrawer and this is not metadata
      const prevChild = node.children[i - 1];
      if (prevChild && prevChild.type === "PropertyDrawer") {
        const isMetadata = child.type === "Headline" || child.type === "Planning" || child.type === "Clock" ||
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

function printClock(node: ClockNode): string {
  return node.raw;
}

function directiveLineToRaw(indent: string, keywordRaw: string, afterKeywordRaw: string): string {
  return `${indent}#+${keywordRaw}${afterKeywordRaw}`;
}

function printBlock(node: BlockNode): string {
  const begin = directiveLineToRaw(node.begin.indent, node.begin.keywordRaw, node.begin.afterKeywordRaw);
  const affiliated = printAffiliatedKeywords(node);

  if (!node.terminated || !node.end) {
    return [...affiliated, begin, node.bodyRaw].filter((l) => l.length > 0).join("\n");
  }

  const end = directiveLineToRaw(node.end.indent, node.end.keywordRaw, node.end.afterKeywordRaw);

  if (node.bodyRaw.length === 0) {
    return [...affiliated, begin, end].join("\n");
  }

  return [...affiliated, begin, node.bodyRaw, end].join("\n");
}

export function printCanonicalAstToOrg(doc: DocumentNode): string {
  if (doc.type !== "Document" || doc.version !== "0") {
    throw new Error("Unsupported AST: expected Document v0");
  }

  const isKeywordLike = (node: Node): boolean => node.type === "KeywordLine" || node.type === "DirectiveLine";

  const chunks: string[] = [];
  let prevChild: Node | undefined;
  for (const child of doc.children) {
    if (prevChild) {
      const explicitBlankLinesBefore = blankLinesBefore(child);
      if (explicitBlankLinesBefore !== undefined) {
        chunks.push(separatorForBlankLines(explicitBlankLinesBefore));
      } else {
        const needsBlankLine = !(isKeywordLike(prevChild) && isKeywordLike(child));
        chunks.push(needsBlankLine ? "\n\n" : "\n");
      }
    }
    chunks.push(printNode(child));
    prevChild = child;
  }

  const output = chunks.join("");

  // Check if the last child is an unterminated block that ends at EOF (no newline)
  const lastChild = doc.children[doc.children.length - 1];
  const endsWithNewline = !lastChild || lastChild.type !== "SrcBlock" || (lastChild as SrcBlockNode).terminated;

  // v0 fixtures generally include a trailing newline, except for unterminated blocks at EOF.
  return endsWithNewline ? `${output}\n` : output;
}
