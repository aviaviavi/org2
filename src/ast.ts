export type TextNode = {
  type: "Text";
  value: string;
};

export type TimestampRepeater = {
  mode: "+" | "++" | ".+";
  value: number;
  unit: "d" | "w" | "m" | "y";
  raw: string;
};

export type TimestampWarning = {
  mode: "-" | "--";
  value: number;
  unit: "d" | "w" | "m" | "y";
  raw: string;
};

export type TimestampNode = {
  type: "Timestamp";
  active: boolean;
  raw: string;
  repeater?: TimestampRepeater;
  warning?: TimestampWarning;
};

export type TimestampRangeNode = {
  type: "TimestampRange";
  start: TimestampNode;
  separatorRaw: string;
  end: TimestampNode;
};

export type EmphasisKind = "bold" | "italic" | "underline" | "strike" | "verbatim" | "code";

export type EmphasisNode = {
  type: "Emphasis";
  kind: EmphasisKind;
  marker: string;
  content: string;
};

export type LinkNode = {
  type: "Link";
  format: "bracket" | "plain" | "angle";
  raw: string;
  targetRaw: string;
  descriptionRaw?: string;
};

export type EntityNode = {
  type: "Entity";
  raw: string;
  nameRaw: string;
};

export type LatexFragmentNode = {
  type: "LatexFragment";
  raw: string;
  display: boolean;
};

export type ExportSnippetNode = {
  type: "ExportSnippet";
  raw: string;
  backendRaw: string;
  valueRaw: string;
};

export type FootnoteReferenceNode = {
  type: "FootnoteReference";
  raw: string;
  labelRaw?: string;
  definitionRaw?: string;
};

export type CitationReference = {
  keyRaw: string;
  prefixRaw?: string;
  suffixRaw?: string;
};

export type CitationNode = {
  type: "Citation";
  raw: string;
  styleRaw?: string;
  prefixRaw?: string;
  suffixRaw?: string;
  references: CitationReference[];
};

export type TargetNode = {
  type: "Target";
  raw: string;
  valueRaw: string;
  radio: boolean;
};

export type ScriptNode = {
  type: "Script";
  raw: string;
  kind: "subscript" | "superscript";
  valueRaw: string;
};

export type LineBreakNode = {
  type: "LineBreak";
  raw: string;
};

export type ProgressCookieNode = {
  type: "ProgressCookie";
  raw: string;
  format: "fraction" | "percent";
  done?: number;
  total?: number;
  percent?: number;
};

export type ParagraphNode = {
  type: "Paragraph";
  children: InlineNode[];
};

export type KeywordLineNode = {
  type: "KeywordLine";
  raw: string;
  indent: string;
  keyRaw: string;
  valueRaw: string;
};

// A non-block `#+...` line that does not match `#+KEY: VALUE`.
// This is used for lossless preservation of unknown directives.
export type DirectiveLineNode = {
  type: "DirectiveLine";
  raw: string;
  indent: string;
  keywordRaw: string;
  afterKeywordRaw: string;
};

export type CommentLineNode = {
  type: "CommentLine";
  raw: string;
  indent: string;
  bodyRaw: string;
};

export type PlanningKind = "SCHEDULED" | "DEADLINE" | "CLOSED";

export type PlanningNode = {
  type: "Planning";
  kind: PlanningKind;
  raw: string;
  timestamp?: TimestampNode | TimestampRangeNode;
};

export type ClockNode = {
  type: "Clock";
  raw: string;
  start?: TimestampNode;
  end?: TimestampNode;
};

export type PropertyNode = {
  key: string;
  value: string;
};

export type PropertyDrawerNode = {
  type: "PropertyDrawer";
  properties: PropertyNode[];
};

export type DrawerNode = {
  type: "Drawer";
  nameRaw: string;
  indent: string;
  terminated: boolean;
  bodyRaw: string;
  endRaw?: string;
};

export type SrcBlockLine = {
  indent: string;
  keywordRaw: string;
  afterKeywordRaw: string;
};

export type SrcBlockNode = {
  type: "SrcBlock";
  affiliatedKeywords?: KeywordLineNode[];
  terminated: boolean;
  begin: SrcBlockLine;
  bodyRaw: string;
  end?: SrcBlockLine;
};

export type BlockKind = "example" | "quote" | "verse" | "center" | "comment" | "export" | (string & {});

export type BlockNode = {
  type: "Block";
  affiliatedKeywords?: KeywordLineNode[];
  kind: BlockKind;
  terminated: boolean;
  begin: SrcBlockLine;
  bodyRaw: string;
  end?: SrcBlockLine;
};

export type DynamicBlockNode = {
  type: "DynamicBlock";
  affiliatedKeywords?: KeywordLineNode[];
  nameRaw: string;
  parametersRaw: string;
  indent: string;
  beginRaw: string;
  bodyRaw: string;
  terminated: boolean;
  endRaw?: string;
};

export type FixedWidthNode = {
  type: "FixedWidth";
  lines: Array<{ raw: string; indent: string; valueRaw: string }>;
};

export type HorizontalRuleNode = {
  type: "HorizontalRule";
  raw: string;
  indent: string;
};

export type LatexEnvironmentNode = {
  type: "LatexEnvironment";
  nameRaw: string;
  beginRaw: string;
  bodyRaw: string;
  terminated: boolean;
  endRaw?: string;
};

export type DiarySexpNode = {
  type: "DiarySexp";
  raw: string;
};

export type FootnoteDefinitionNode = {
  type: "FootnoteDefinition";
  labelRaw: string;
  children: InlineNode[];
};

export type TableRowNode = {
  type: "TableRow";
  indent: string;
  cells: string[];
  /** Parsed cell objects, parallel to `cells`; raw strings remain for compatibility and printing. */
  contents?: InlineNode[][];
};

export type TableHlineNode = {
  type: "TableHline";
  indent: string;
  raw: string;
};

/** One assignment from an Org `#+TBLFM:` line. Raw fields are retained so
 * unsupported Calc/Emacs forms can still round-trip without loss. */
export type TableFormulaAssignmentNode = {
  raw: string;
  targetRaw: string;
  expressionRaw: string;
  modeRaw?: string;
};

export type TableFormulaLineNode = {
  type: "TableFormulaLine";
  raw: string;
  indent: string;
  valueRaw: string;
  assignments: TableFormulaAssignmentNode[];
};

export type TableNode = {
  type: "Table";
  affiliatedKeywords?: KeywordLineNode[];
  rows: (TableRowNode | TableHlineNode)[];
  formulas?: TableFormulaLineNode[];
};

export type ListItemNode = {
  type: "ListItem";
  /** Written ordinal when it differs from the item's implicit one-based position. */
  ordinal?: number;
  /** Org's explicit [@N] counter cookie, distinct from the written list marker. */
  counter?: number;
  checkbox?: "unchecked" | "checked" | "indeterminate";
  descriptionTag?: InlineNode[];
  progressCookie?: ProgressCookieNode;
  children: Node[];
};

export type ListNode = {
  type: "List";
  ordered: boolean;
  items: ListItemNode[];
};

export type HeadlineNode = {
  type: "Headline";
  level: number;
  todo?: string;
  priority?: string;
  commented?: boolean;
  tags?: string[];
  title: InlineNode[];
  children: Node[];
};

export type InlineNode =
  | TextNode
  | TimestampNode
  | TimestampRangeNode
  | EmphasisNode
  | LinkNode
  | ProgressCookieNode
  | EntityNode
  | LatexFragmentNode
  | ExportSnippetNode
  | FootnoteReferenceNode
  | CitationNode
  | TargetNode
  | ScriptNode
  | LineBreakNode;

export type Node =
  | HeadlineNode
  | ParagraphNode
  | ListNode
  | ListItemNode
  | KeywordLineNode
  | DirectiveLineNode
  | CommentLineNode
  | PlanningNode
  | ClockNode
  | PropertyDrawerNode
  | DrawerNode
  | SrcBlockNode
  | BlockNode
  | DynamicBlockNode
  | FixedWidthNode
  | HorizontalRuleNode
  | LatexEnvironmentNode
  | DiarySexpNode
  | FootnoteDefinitionNode
  | TableNode
  | TextNode;

export type DocumentNode = {
  type: "Document";
  version: "0";
  children: Node[];
};
