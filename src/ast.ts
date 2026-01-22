export type TextNode = {
  type: "Text";
  value: string;
};

export type TimestampNode = {
  type: "Timestamp";
  active: boolean;
  raw: string;
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
  format: "bracket" | "plain";
  raw: string;
  targetRaw: string;
  descriptionRaw?: string;
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
  terminated: boolean;
  begin: SrcBlockLine;
  bodyRaw: string;
  end?: SrcBlockLine;
};

export type BlockKind = "example" | "quote" | "verse" | "center" | "comment";

export type BlockNode = {
  type: "Block";
  kind: BlockKind;
  terminated: boolean;
  begin: SrcBlockLine;
  bodyRaw: string;
  end?: SrcBlockLine;
};

export type TableRowNode = {
  type: "TableRow";
  indent: string;
  cells: string[];
};

export type TableHlineNode = {
  type: "TableHline";
  indent: string;
  raw: string;
};

export type TableNode = {
  type: "Table";
  rows: (TableRowNode | TableHlineNode)[];
};

export type ListItemNode = {
  type: "ListItem";
  checkbox?: "unchecked" | "checked";
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
  tags?: string[];
  title: InlineNode[];
  children: Node[];
};

export type InlineNode = TextNode | TimestampNode | TimestampRangeNode | EmphasisNode | LinkNode;

export type Node =
  | HeadlineNode
  | ParagraphNode
  | ListNode
  | ListItemNode
  | KeywordLineNode
  | DirectiveLineNode
  | CommentLineNode
  | PlanningNode
  | PropertyDrawerNode
  | DrawerNode
  | SrcBlockNode
  | BlockNode
  | TableNode
  | TextNode;

export type DocumentNode = {
  type: "Document";
  version: "0";
  children: Node[];
};
