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

export type ParagraphNode = {
  type: "Paragraph";
  children: InlineNode[];
};

export type PropertyNode = {
  key: string;
  value: string;
};

export type PropertyDrawerNode = {
  type: "PropertyDrawer";
  properties: PropertyNode[];
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

export type TableRowNode = {
  type: "TableRow";
  cells: string[];
};

export type TableHlineNode = {
  type: "TableHline";
};

export type TableNode = {
  type: "Table";
  rows: (TableRowNode | TableHlineNode)[];
};

export type ListItemNode = {
  type: "ListItem";
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

export type InlineNode = TextNode | TimestampNode | TimestampRangeNode;

export type Node =
  | HeadlineNode
  | ParagraphNode
  | ListNode
  | ListItemNode
  | PropertyDrawerNode
  | SrcBlockNode
  | TableNode
  | TextNode;

export type DocumentNode = {
  type: "Document";
  version: "0";
  children: Node[];
};
