import type {
  BlockKind,
  BlockNode,
  CommentLineNode,
  DocumentNode,
  EmphasisKind,
  EmphasisNode,
  HeadlineNode,
  InlineNode,
  KeywordLineNode,
  LinkNode,
  ProgressCookieNode,
  ListItemNode,
  ListNode,
  Node,
  ParagraphNode,
  PlanningKind,
  PlanningNode,
  ClockNode,
  PropertyDrawerNode,
  DrawerNode,
  SrcBlockLine,
  SrcBlockNode,
  TableNode,
  TextNode,
  TimestampNode,
  TimestampRangeNode,
  TimestampRepeater,
  TimestampWarning,
} from "./ast.js";

export type ParseError = {
  message: string;
  line: number;
  column: number;
};

export type ParseOptions = {
  sourceRanges?: boolean;
  sourceLineOffset?: number;
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

function parseTimestampRepeater(raw: string): TimestampRepeater | undefined {
  const match = raw.match(/(?:^|\s)(\+\+|\.\+|\+)(\d+)([dwmy])(?=[^A-Za-z0-9]|$)/i);
  if (!match) return undefined;

  const mode = match[1] as TimestampRepeater["mode"];
  const value = Number.parseInt(match[2] ?? "", 10);
  const unit = (match[3] ?? "").toLowerCase() as TimestampRepeater["unit"];
  if (!Number.isFinite(value) || value <= 0) return undefined;
  if (unit !== "d" && unit !== "w" && unit !== "m" && unit !== "y") return undefined;

  return { mode, value, unit, raw: match[0].trim() };
}

function parseTimestampWarning(raw: string): TimestampWarning | undefined {
  const match = raw.match(/(?:^|\s)(--|-)(\d+)([dwmy])(?=[^A-Za-z0-9]|$)/i);
  if (!match) return undefined;

  const mode = match[1] as TimestampWarning["mode"];
  const value = Number.parseInt(match[2] ?? "", 10);
  const unit = (match[3] ?? "").toLowerCase() as TimestampWarning["unit"];
  if (!Number.isFinite(value) || value <= 0) return undefined;
  if (unit !== "d" && unit !== "w" && unit !== "m" && unit !== "y") return undefined;

  return { mode, value, unit, raw: match[0].trim() };
}

function timestamp(active: boolean, raw: string): TimestampNode {
  const repeater = parseTimestampRepeater(raw);
  const warning = parseTimestampWarning(raw);
  return { type: "Timestamp", active, raw, ...(repeater ? { repeater } : {}), ...(warning ? { warning } : {}) };
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

function progressCookie(node: Omit<ProgressCookieNode, "type">): ProgressCookieNode {
  return { type: "ProgressCookie", ...node };
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

function isHeadlineStart(line: string): boolean {
  return /^\*+\s/.test(line);
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

type ParsedProgressCookieAt = { node: ProgressCookieNode; endIndex: number };

function parseProgressCookieAt(value: string, startIndex: number): ParsedProgressCookieAt | null {
  const rest = value.slice(startIndex);
  const fraction = /^\[(\d+)\/(\d+)\]/.exec(rest);
  if (fraction) {
    const done = Number.parseInt(fraction[1] || "0", 10);
    const total = Number.parseInt(fraction[2] || "0", 10);
    return { node: progressCookie({ raw: fraction[0], format: "fraction", done, total, percent: total > 0 ? Math.round((done / total) * 100) : 0 }), endIndex: startIndex + fraction[0].length };
  }
  const percent = /^\[(\d{1,3})%\]/.exec(rest);
  if (percent) {
    const valueNum = Number.parseInt(percent[1] || "0", 10);
    return { node: progressCookie({ raw: percent[0], format: "percent", percent: Math.max(0, Math.min(100, valueNum)) }), endIndex: startIndex + percent[0].length };
  }
  return null;
}

export function parseInlinesFromText(value: string): InlineNode[] {
  const out: InlineNode[] = [];

  let i = 0;
  let lastTextStart = 0;

  while (i < value.length) {
    const parsedProgressCookie = parseProgressCookieAt(value, i);
    if (parsedProgressCookie) {
      if (lastTextStart < i) {
        out.push(text(value.slice(lastTextStart, i)));
      }

      out.push(parsedProgressCookie.node);
      i = parsedProgressCookie.endIndex;
      lastTextStart = i;
      continue;
    }

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

export function isAffiliatedKeyword(node: KeywordLineNode): boolean {
  const key = node.keyRaw.toUpperCase();
  return (
    key === "NAME" ||
    key === "CAPTION" ||
    key === "HEADER" ||
    key === "HEADERS" ||
    key === "RESULTS" ||
    key === "PLOT" ||
    key === "CHART" ||
    key === "DATASET" ||
    key === "VIEW" ||
    key.startsWith("ATTR_")
  );
}

function parseCommentLine(line: string, lineNumber: number): CommentLineNode | null {
  const match = /^(\s*)#(?!\+)(.*)$/.exec(line);
  if (!match) return null;

  const indent = match[1] ?? "";
  const bodyRaw = match[2] ?? "";

  if (indent.includes("\t") || bodyRaw.includes("\t")) {
    fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
  }

  return {
    type: "CommentLine",
    raw: line,
    indent,
    bodyRaw,
  };
}

function parseClockLine(line: string, lineNumber: number): ClockNode | null {
  const match = /^(\s*)CLOCK:\s*(.*)$/.exec(line);
  if (!match) return null;
  const indent = match[1] ?? "";
  if (indent.includes("\t") || line.includes("\t")) {
    fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
  }

  const rangeMatch = /(\[[^\]]+\]|<[^>]+>)--(\[[^\]]+\]|<[^>]+>)/.exec(match[2] ?? "");
  const start = rangeMatch ? parseTimestampAt(rangeMatch[1] || "", 0)?.node : undefined;
  const end = rangeMatch ? parseTimestampAt(rangeMatch[2] || "", 0)?.node : undefined;
  return { type: "Clock", raw: line, ...(start ? { start } : {}), ...(end ? { end } : {}) };
}

function parsePlanningLine(line: string, lineNumber: number): PlanningNode[] | null {
  // Check if line starts with optional indentation followed by a planning keyword
  const initialMatch = /^(\s*)(SCHEDULED|DEADLINE|CLOSED):/.exec(line);
  if (!initialMatch) return null;

  const indent = initialMatch[1] ?? "";

  if (indent.includes("\t")) {
    fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
  }

  // Parse all planning keywords from the line
  const planningNodes: PlanningNode[] = [];
  
  // Find all occurrences of SCHEDULED:, DEADLINE:, or CLOSED: in the line
  let pos = 0;
  while (true) {
    const keywordMatch = /(SCHEDULED|DEADLINE|CLOSED):/.exec(line.slice(pos));
    if (!keywordMatch) break;
    
    const kind = keywordMatch[1] as PlanningKind;
    const startPos = pos + keywordMatch.index;
    const afterKeywordPos = startPos + keywordMatch[0].length;
    
    // Extract the portion from this keyword to the start of the next keyword or end of line
    let endPos = line.length;
    const nextKeywordMatch = /(SCHEDULED|DEADLINE|CLOSED):/.exec(line.slice(afterKeywordPos));
    if (nextKeywordMatch) {
      endPos = afterKeywordPos + nextKeywordMatch.index;
    }
    
    const after = line.slice(afterKeywordPos, endPos).trim();

    // Find the first timestamp/range in the remainder, if any.
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

    planningNodes.push({
      type: "Planning",
      kind,
      raw: line,
      ...(ts ? { timestamp: ts } : {}),
    });
    
    // Move position to after this keyword for next iteration
    pos = afterKeywordPos;
  }

  return planningNodes.length > 0 ? planningNodes : null;
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

  // Todo keyword (Org2 supports a small set).
  for (const kw of ["TODO", "IN_PROGRESS", "DONE", "CANCELED", "CANCELLED"] as const) {
    const prefix = `${kw} `;
    if (rest.startsWith(prefix)) {
      todo = kw;
      rest = rest.slice(prefix.length);
      break;
    }
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
  checkbox?: "unchecked" | "checked";
  progressCookie?: ProgressCookieNode;
};

type ParsePropertyDrawerResult = {
  drawer: PropertyDrawerNode;
  nextLineIndex: number;
};

type ParseDrawerResult = {
  drawer: DrawerNode;
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

    if (ws.includes("\t")) {
      fail(makeError("Unsupported construct: tab character", lineNumber, key.length + 3));
    }

    properties.push({ key, value: rawValue });
  }

  fail(makeError("Invalid property drawer; missing :END:", startLineNumber, 1));
}

function parseDrawer(lines: string[], startLineIndex: number): ParseDrawerResult {
  const startLineNumber = startLineIndex + 1;
  const start = lines[startLineIndex] ?? "";

  const match = /^(\s*):([^:\s]+):$/.exec(start);
  if (!match) {
    fail(makeError("Invalid drawer; expected :NAME:", startLineNumber, 1));
  }

  const indent = match[1] ?? "";
  const nameRaw = match[2] ?? "";

  if (indent.includes("\t")) {
    fail(makeError("Unsupported construct: tab character", startLineNumber, start.indexOf("\t") + 1));
  }

  for (let i = startLineIndex + 1; i < lines.length; i += 1) {
    const lineNumber = i + 1;
    const line = lines[i] ?? "";

    if (line === ":END:") {
      const bodyLines = lines.slice(startLineIndex + 1, i);
      return {
        drawer: {
          type: "Drawer",
          nameRaw,
          indent,
          terminated: true,
          bodyRaw: bodyLines.join("\n"),
          endRaw: line,
        },
        nextLineIndex: i + 1,
      };
    }

    if (line.includes("\t")) {
      fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
    }
  }

  const bodyLines = lines.slice(startLineIndex + 1);
  return {
    drawer: {
      type: "Drawer",
      nameRaw,
      indent,
      terminated: false,
      bodyRaw: bodyLines.join("\n"),
    },
    nextLineIndex: lines.length,
  };
}

function parseListItemLine(line: string): ParsedListItem | null {
  const unordered = /^([+-])(\s+)(.*)$/.exec(line);
  if (unordered) {
    const ws = unordered[2];
    if (ws !== " ") return null;
    let content = unordered[3];
    if (content.length === 0) return null;

    // Check for checkbox syntax: [ ] or [X] or [x]
    let checkbox: "unchecked" | "checked" | undefined;
    const checkboxMatch = /^\[([ Xx])\]\s+(.*)$/.exec(content);
    if (checkboxMatch) {
      checkbox = checkboxMatch[1] === " " ? "unchecked" : "checked";
      content = checkboxMatch[2];
    }
    const progressCookie = parseProgressCookieAt(content, 0)?.node;

    return { ordered: false, content, indentColumn: unordered[1].length + ws.length, checkbox, ...(progressCookie ? { progressCookie } : {}) };
  }

  const ordered = /^(\d+)([.)])(\s+)(.*)$/.exec(line);
  if (ordered) {
    const ws = ordered[3];
    if (ws !== " ") return null;
    let content = ordered[4];
    if (content.length === 0) return null;

    // Check for checkbox syntax: [ ] or [X] or [x]
    let checkbox: "unchecked" | "checked" | undefined;
    const checkboxMatch = /^\[([ Xx])\]\s+(.*)$/.exec(content);
    if (checkboxMatch) {
      checkbox = checkboxMatch[1] === " " ? "unchecked" : "checked";
      content = checkboxMatch[2];
    }
    const progressCookie = parseProgressCookieAt(content, 0)?.node;

    return {
      ordered: true,
      content,
      indentColumn: ordered[1].length + ordered[2].length + ws.length,
      checkbox,
      ...(progressCookie ? { progressCookie } : {}),
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
  const directiveMatch = /^(\s*)#\+([^\s]+)(.*)$/.exec(line);
  if (directiveMatch) {
    const indent = directiveMatch[1];
    const keywordRaw = directiveMatch[2];
    const afterKeywordRaw = directiveMatch[3];

    if (indent.includes("\t") || afterKeywordRaw.includes("\t")) {
      fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
    }

    return { indent, keywordRaw, afterKeywordRaw };
  }

  // Additive syntax sugar: fenced source blocks (```lang ... ```)
  // Stored in the same SrcBlockLine shape for round-tripping.
  const fenceMatch = /^(\s*)```(.*)$/.exec(line);
  if (fenceMatch) {
    const indent = fenceMatch[1] || "";
    const afterKeywordRaw = fenceMatch[2] || "";
    if (indent.includes("\t") || afterKeywordRaw.includes("\t")) {
      fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
    }
    return { indent, keywordRaw: "```", afterKeywordRaw };
  }

  return null;
}

function isBeginSrc(line: SrcBlockLine): boolean {
  const key = line.keywordRaw.toLowerCase();
  return key === "begin_src" || key === "begin_org2" || key === "```";
}

function isEndSrc(line: SrcBlockLine): boolean {
  const key = line.keywordRaw.toLowerCase();
  return key === "end_src" || key === "end_org2" || key === "```";
}

function getBlockKindFromBegin(line: SrcBlockLine): BlockKind | null {
  const key = line.keywordRaw.toLowerCase();
  if (key === "begin_example") return "example";
  if (key === "begin_quote") return "quote";
  if (key === "begin_verse") return "verse";
  if (key === "begin_center") return "center";
  if (key === "begin_comment") return "comment";
  if (key === "begin_export") return "export";
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
    fail(makeError("Invalid source block; expected #+begin_src, #+begin_org2, or ```", startLineNumber, 1));
  }

  const beginKey = begin.keywordRaw.toLowerCase();
  const beginIsFence = beginKey === "```";

  for (let i = startLineIndex + 1; i < lines.length; i += 1) {
    const lineNumber = i + 1;
    const line = lines[i] ?? "";

    const parsed = parseSrcBlockLine(line, lineNumber);
    if (!parsed) continue;

    if (beginIsFence) {
      // Fenced opener must close with a bare triple-backtick fence line.
      if (parsed.keywordRaw === "```" && String(parsed.afterKeywordRaw || "").trim().length === 0) {
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
      continue;
    }

    if (isEndSrc(parsed) && parsed.keywordRaw !== "```") {
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
  // Org mode effectively treats leading/trailing whitespace in cells as insignificant.
  // Store cells in canonical form with whitespace stripped so formatting/alignment isn't
  // prevented by stray spaces.
  return core.split("|").map((c) => c.trim());
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
    const lineIndent = " ".repeat(matched.indentLen);

    if (isTableHlineRow(rest)) {
      rows.push({ type: "TableHline", indent: lineIndent, raw: rest });
      continue;
    }

    rows.push({ type: "TableRow", indent: lineIndent, cells: parseTableRowCells(rest) });
  }

  return { table: { type: "Table", rows }, nextLineIndex: lines.length };
}

export function parseOrgToCanonicalAst(input: string, options: ParseOptions = {}): DocumentNode {
  if (input.includes("\r\n")) {
    fail(makeError("Unsupported line endings: CRLF", 1, 1));
  }

  const doc: DocumentNode = { type: "Document", version: "0", children: [] };

  const headlineStack: HeadlineNode[] = [];

  let paragraphLines: string[] = [];
  let paragraphStartLine: number | null = null;
  let currentList: ListNode | null = null;
  let pendingBlankLinesBeforeNextNode = 0;
  let pendingAffiliatedKeywords: KeywordLineNode[] = [];

  const sourceLineOffset = options.sourceLineOffset ?? 0;

  function setSourceRange<T extends object>(node: T, startLine: number, endLine: number): T {
    if (options.sourceRanges) {
      const absoluteStartLine = startLine + sourceLineOffset;
      const absoluteEndLine = Math.max(startLine, endLine) + sourceLineOffset;
      (node as T & { sourceRange: { startLine: number; endLine: number } }).sourceRange = {
        startLine: absoluteStartLine,
        endLine: absoluteEndLine,
      };
    }
    return node;
  }

  function sourceRangeStart(node: object): number | undefined {
    const startLine = (node as { sourceRange?: { startLine: number; endLine: number } }).sourceRange?.startLine;
    return startLine === undefined ? undefined : startLine - sourceLineOffset;
  }

  function finalizeHeadline(headline: HeadlineNode, endLine: number): void {
    if (!options.sourceRanges) return;
    const startLine = sourceRangeStart(headline);
    if (startLine !== undefined) setSourceRange(headline, startLine, endLine);
  }

  function currentContainer(): DocumentNode | HeadlineNode {
    return headlineStack.length > 0 ? headlineStack[headlineStack.length - 1] : doc;
  }

  function attachBlankLinesBefore<T extends Node>(node: T): T {
    if (pendingBlankLinesBeforeNextNode > 0) {
      Object.defineProperty(node, "blankLinesBefore", {
        value: pendingBlankLinesBeforeNextNode,
        enumerable: false,
        configurable: true,
      });
      pendingBlankLinesBeforeNextNode = 0;
    }
    return node;
  }

  function pushCurrent(node: Node, startLine?: number, endLine?: number): void {
    if (startLine !== undefined) {
      setSourceRange(node, startLine, endLine ?? startLine);
    }
    getChildrenArray(currentContainer()).push(attachBlankLinesBefore(node));
  }

  function flushAffiliatedKeywords(): void {
    if (pendingAffiliatedKeywords.length === 0) return;
    for (const keyword of pendingAffiliatedKeywords) pushCurrent(keyword);
    pendingAffiliatedKeywords = [];
  }

  function takeAffiliatedKeywords(): KeywordLineNode[] | undefined {
    if (pendingAffiliatedKeywords.length === 0) return undefined;
    const keywords = pendingAffiliatedKeywords;
    pendingAffiliatedKeywords = [];
    return keywords;
  }

  function attachAffiliatedKeywords<T extends SrcBlockNode | BlockNode | TableNode>(node: T): T {
    const affiliatedKeywords = takeAffiliatedKeywords();
    if (!affiliatedKeywords) return node;
    return { ...node, affiliatedKeywords };
  }

  function flushParagraph(): void {
    if (paragraphLines.length === 0) return;

    const node = paragraphFromLines(paragraphLines);
    if (paragraphStartLine !== null) {
      setSourceRange(node, paragraphStartLine, paragraphStartLine + paragraphLines.length - 1);
    }
    pushCurrent(node);
    paragraphLines = [];
    paragraphStartLine = null;
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

    pushCurrent(list);
    currentList = list;
    return list;
  }

  function addListItem(ordered: boolean, content: string, checkbox?: "unchecked" | "checked", itemProgressCookie?: ProgressCookieNode): ListItemNode {
    const list = ensureList(ordered);
    const item: ListItemNode = {
      type: "ListItem",
      ...(checkbox && { checkbox }),
      ...(itemProgressCookie ? { progressCookie: itemProgressCookie } : {}),
      children: [paragraphFromText(content)],
    };
    list.items.push(item);
    return item;
  }

  const lines = input.split("\n");
  const documentEndLine = input.endsWith("\n") ? Math.max(1, lines.length - 1) : lines.length;

  for (let i = 0; i < lines.length; ) {
    const lineNumber = i + 1;
    const line = lines[i];

    {
      const keyword = parseKeywordLine(line, lineNumber);
      if (keyword) {
        flushParagraph();
        endList();
        if (isAffiliatedKeyword(keyword)) {
          setSourceRange(keyword, lineNumber, lineNumber);
          pendingAffiliatedKeywords.push(keyword);
          i += 1;
          continue;
        }
        flushAffiliatedKeywords();
        pushCurrent(keyword, lineNumber);
        i += 1;
        continue;
      }

      const planning = parsePlanningLine(line, lineNumber);
      if (planning) {
        flushParagraph();
        endList();
        flushAffiliatedKeywords();
        for (const node of planning) pushCurrent(node, lineNumber);
        i += 1;
        continue;
      }

      const clock = parseClockLine(line, lineNumber);
      if (clock) {
        flushParagraph();
        endList();
        flushAffiliatedKeywords();
        pushCurrent(clock, lineNumber);
        i += 1;
        continue;
      }

      const comment = parseCommentLine(line, lineNumber);
      if (comment) {
        flushParagraph();
        endList();
        flushAffiliatedKeywords();
        pushCurrent(comment, lineNumber);
        i += 1;
        continue;
      }

      const directive = parseSrcBlockLine(line, lineNumber);
      if (directive) {
        if (isBeginSrc(directive)) {
          flushParagraph();
          endList();

          const { block, nextLineIndex } = parseSrcBlock(lines, i);
          pushCurrent(attachAffiliatedKeywords(block), lineNumber, nextLineIndex);
          i = nextLineIndex;
          continue;
        }

        const kind = getBlockKindFromBegin(directive);
        if (kind) {
          flushParagraph();
          endList();

          const { block, nextLineIndex } = parseBlock(lines, i, kind);
          pushCurrent(attachAffiliatedKeywords(block), lineNumber, nextLineIndex);
          i = nextLineIndex;
          continue;
        }

        flushParagraph();
        endList();
        flushAffiliatedKeywords();
        pushCurrent({
          type: "DirectiveLine",
          raw: line,
          indent: directive.indent,
          keywordRaw: directive.keywordRaw,
          afterKeywordRaw: directive.afterKeywordRaw,
        }, lineNumber);
        i += 1;
        continue;
      }
    }

    if (matchTableLine(line, "")) {
      flushParagraph();
      endList();

      const { table, nextLineIndex } = parseTable(lines, i, "");
      pushCurrent(attachAffiliatedKeywords(table), lineNumber, nextLineIndex);
      i = nextLineIndex;
      continue;
    }

    if (isHeadlineStart(line)) {
      flushParagraph();
      endList();
      flushAffiliatedKeywords();

      const { level, title, todo, tags } = parseHeadline(line, lineNumber);

      while (headlineStack.length > 0 && headlineStack[headlineStack.length - 1].level >= level) {
        const popped = headlineStack.pop();
        if (popped) finalizeHeadline(popped, lineNumber - 1);
      }

      const node: HeadlineNode = {
        type: "Headline",
        level,
        ...(todo ? { todo } : {}),
        ...(tags ? { tags } : {}),
        title: parseInlinesFromText(title),
        children: [],
      };

      pushCurrent(node, lineNumber);
      headlineStack.push(node);
      i += 1;
      continue;
    }

    if (line === ":PROPERTIES:") {
      flushParagraph();
      endList();
      flushAffiliatedKeywords();

      const { drawer, nextLineIndex } = parsePropertyDrawer(lines, i);
      pushCurrent(drawer, lineNumber, nextLineIndex);
      i = nextLineIndex;
      continue;
    }

    {
      const matchDrawerStart = /^(\s*):([^:\s]+):$/.exec(line);
      const isDrawerStart = matchDrawerStart && matchDrawerStart[2] !== "END";

      if (isDrawerStart) {
        flushParagraph();
        endList();
        flushAffiliatedKeywords();

        const { drawer, nextLineIndex } = parseDrawer(lines, i);
        pushCurrent(drawer, lineNumber, nextLineIndex);
        i = nextLineIndex;
        continue;
      }
    }

    if (isBlank(line)) {
      flushParagraph();
      endList();
      flushAffiliatedKeywords();
      pendingBlankLinesBeforeNextNode += 1;
      i += 1;
      continue;
    }

    if (line.includes("\t")) {
      fail(makeError("Unsupported construct: tab character", lineNumber, line.indexOf("\t") + 1));
    }

    const listItem = parseListItemLine(line) ?? (() => {
      const trimmed = line.trimStart();
      if (trimmed === line) return null;
      const parsed = parseListItemLine(trimmed);
      if (!parsed) return null;
      const leadingSpaces = line.length - trimmed.length;
      return { ...parsed, indentColumn: parsed.indentColumn + leadingSpaces };
    })();

    if (listItem) {
      flushParagraph();
      flushAffiliatedKeywords();
      const item = addListItem(listItem.ordered, listItem.content, listItem.checkbox, listItem.progressCookie);
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

        if (isHeadlineStart(contLine)) {
          flushItemParagraph();
          break;
        }

        const maybeNextItem = parseListItemLine(contLine);
        if (maybeNextItem) {
          // Same or less indented list item, end current item
          flushItemParagraph();
          break;
        }
        
        // Check if this is a nested list item by stripping indentation
        const leadingSpaces = contLine.match(/^(\s*)/)?.[1]?.length ?? 0;
        if (leadingSpaces > 0) {
          const unindentedLine = contLine.slice(leadingSpaces);
          const maybeNestedItem = parseListItemLine(unindentedLine);
          
          if (maybeNestedItem) {
            // Check if this is a nested list item (more indented than current)
            const nestedIndentColumn = leadingSpaces + maybeNestedItem.indentColumn;
            if (nestedIndentColumn > listItem.indentColumn) {
              flushItemParagraph();
              // Parse nested list items
              let nestedList: ListNode | null = null;
              let nestedItemParaLines: string[] = [];
              
              while (i < lines.length) {
                const nestedLineNumber = i + 1;
                const nestedLine = lines[i] ?? "";
                
                if (isBlank(nestedLine)) {
                  if (nestedItemParaLines.length > 0) {
                    // This shouldn't happen in normal flow, but handle it
                    nestedItemParaLines = [];
                  }
                  break;
                }
                
                if (isHeadlineStart(nestedLine)) {
                  break;
                }
                
                const nestedLeadingSpaces = nestedLine.match(/^(\s*)/)?.[1]?.length ?? 0;
                if (nestedLeadingSpaces === 0) {
                  // Not indented, so not a nested item
                  break;
                }
                
                const nestedUnindentedLine = nestedLine.slice(nestedLeadingSpaces);
                const nestedItem = parseListItemLine(nestedUnindentedLine);
                
                if (!nestedItem) {
                  // Not a list item
                  if (nestedLeadingSpaces >= listItem.indentColumn) {
                    // Still within indentation, treat as continuation
                    nestedItemParaLines.push(nestedLine.slice(listItem.indentColumn));
                    i += 1;
                    continue;
                  } else {
                    break;
                  }
                }
                
                const nestedItemIndentColumn = nestedLeadingSpaces + nestedItem.indentColumn;
                
                // Check nesting consistency
                if (!nestedList) {
                  nestedList = {
                    type: "List",
                    ordered: nestedItem.ordered,
                    items: [],
                  };
                  item.children.push(nestedList);
                }
                
                if (nestedList.ordered !== nestedItem.ordered) {
                  break;
                }
                
                // Flush any accumulated para lines before adding new item
                if (nestedItemParaLines.length > 0) {
                  // This shouldn't normally happen, but handle it
                  nestedItemParaLines = [];
                }
                
                // Add nested item
                const nestedListItem: ListItemNode = {
                  type: "ListItem",
                  ...(nestedItem.checkbox && { checkbox: nestedItem.checkbox }),
                  children: [paragraphFromText(nestedItem.content)],
                };
                nestedList.items.push(nestedListItem);
                i += 1;
                
                // Process nested item's continuation lines
                while (i < lines.length) {
                  const contNestedLineNumber = i + 1;
                  const contNestedLine = lines[i] ?? "";
                  
                  if (isBlank(contNestedLine)) {
                    if (nestedItemParaLines.length > 0) {
                      nestedListItem.children.push(paragraphFromLines(nestedItemParaLines));
                      nestedItemParaLines = [];
                    }
                    break;
                  }
                  
                  if (isHeadlineStart(contNestedLine)) {
                    if (nestedItemParaLines.length > 0) {
                      nestedListItem.children.push(paragraphFromLines(nestedItemParaLines));
                      nestedItemParaLines = [];
                    }
                    break;
                  }
                  
                  const nextNestedLeadingSpaces = contNestedLine.match(/^(\s*)/)?.[1]?.length ?? 0;
                  if (nextNestedLeadingSpaces > 0) {
                    const nextNestedUnindentedLine = contNestedLine.slice(nextNestedLeadingSpaces);
                    const nextNestedItem = parseListItemLine(nextNestedUnindentedLine);
                    if (nextNestedItem) {
                      const nextNestedItemIndentColumn = nextNestedLeadingSpaces + nextNestedItem.indentColumn;

                      // Deeper nesting (nested list under this nested list item)
                      if (nextNestedItemIndentColumn > nestedItemIndentColumn) {
                        if (nestedItemParaLines.length > 0) {
                          nestedListItem.children.push(paragraphFromLines(nestedItemParaLines));
                          nestedItemParaLines = [];
                        }

                        const deeperList: ListNode = {
                          type: "List",
                          ordered: nextNestedItem.ordered,
                          items: [],
                        };
                        nestedListItem.children.push(deeperList);

                        while (i < lines.length) {
                          const deeperLine = lines[i] ?? "";
                          if (isBlank(deeperLine) || isHeadlineStart(deeperLine)) break;

                          const deeperLeadingSpaces = deeperLine.match(/^(\s*)/)?.[1]?.length ?? 0;
                          const deeperUnindentedLine = deeperLine.slice(deeperLeadingSpaces);
                          const deeperItem = parseListItemLine(deeperUnindentedLine);
                          if (!deeperItem) break;

                          const deeperItemIndentColumn = deeperLeadingSpaces + deeperItem.indentColumn;
                          if (deeperItemIndentColumn < nextNestedItemIndentColumn) break;
                          if (deeperList.ordered != deeperItem.ordered) break;

                          const deeperListItem: ListItemNode = {
                            type: "ListItem",
                            children: [paragraphFromText(deeperItem.content)],
                          };
                          deeperList.items.push(deeperListItem);
                          i += 1;
                        }

                        continue;
                      }

                      // Same-level nested item; end current nested item
                      if (nestedItemParaLines.length > 0) {
                        nestedListItem.children.push(paragraphFromLines(nestedItemParaLines));
                        nestedItemParaLines = [];
                      }
                      break;
                    }
                  }
                  
                  if (!contNestedLine.startsWith(" ".repeat(nestedItemIndentColumn))) {
                    if (nestedItemParaLines.length > 0) {
                      nestedListItem.children.push(paragraphFromLines(nestedItemParaLines));
                      nestedItemParaLines = [];
                    }
                    break;
                  }
                  
                  nestedItemParaLines.push(contNestedLine.slice(nestedItemIndentColumn));
                  i += 1;
                }
              }
              continue;
            }
          }
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
    flushAffiliatedKeywords();
    if (paragraphStartLine === null) paragraphStartLine = lineNumber;
    paragraphLines.push(line);
    i += 1;
  }

  flushAffiliatedKeywords();
  flushParagraph();
  while (headlineStack.length > 0) {
    const popped = headlineStack.pop();
    if (popped) finalizeHeadline(popped, documentEndLine);
  }
  return doc;
}

/**
 * Result of parsing with diagnostics collection
 */
export interface ParseResult {
  ast: DocumentNode;
  diagnostics: ParseError[];
}

/**
 * Parse org content and collect errors as diagnostics instead of throwing
 * Useful for LSP and editor integrations that need to report errors without failing
 */
export function parseOrgWithDiagnostics(input: string, options: ParseOptions = {}): ParseResult {
  const diagnostics: ParseError[] = [];

  try {
    const ast = parseOrgToCanonicalAst(input, options);
    return { ast, diagnostics };
  } catch (error: any) {
    // Extract line:column from error message format: "LINE:COL MESSAGE"
    const message = error.message || String(error);
    const match = message.match(/^(\d+):(\d+)\s+(.*)/);

    if (match) {
      const line = parseInt(match[1], 10);
      const column = parseInt(match[2], 10);
      const msg = match[3];
      diagnostics.push({ message: msg, line, column });
    } else {
      // Fallback if error format doesn't match expected pattern
      diagnostics.push({ message, line: 1, column: 1 });
    }

    // Return empty document when parsing fails
    return { ast: { type: "Document", version: "0", children: [] }, diagnostics };
  }
}

// Re-export AST types for LSP and other modules
export type {
  DocumentNode,
  HeadlineNode,
  Node,
  ListNode,
  BlockNode,
  SrcBlockNode,
  TableNode,
  KeywordLineNode,
  ListItemNode,
  InlineNode,
} from "./ast.js";
