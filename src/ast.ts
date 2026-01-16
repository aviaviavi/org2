export type TextNode = {
  type: "Text";
  value: string;
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

export type InlineNode = TextNode;

export type Node =
  | HeadlineNode
  | ParagraphNode
  | ListNode
  | ListItemNode
  | PropertyDrawerNode
  | SrcBlockNode
  | TextNode;

export type DocumentNode = {
  type: "Document";
  version: "0";
  children: Node[];
};
