#!/usr/bin/env node

import {
  parseOrgToCanonicalAst,
  parseOrgWithDiagnostics,
  DocumentNode,
  HeadlineNode,
  Node,
  ListNode,
  BlockNode,
  SrcBlockNode,
  ListItemNode,
  type ParseError,
} from "./parser.js";
import { printCanonicalAstToOrg } from "./printer.js";

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// ============================================================================
// LSP Types (minimal subset)
// ============================================================================

interface Position {
  line: number;
  character: number;
}

interface Range {
  start: Position;
  end: Position;
}

interface TextDocument {
  uri: string;
  version: number;
  text: string;
}

interface DocumentSymbol {
  name: string;
  detail?: string;
  kind: number;
  range: Range;
  selectionRange: Range;
  children?: DocumentSymbol[];
}

interface SymbolInformation {
  name: string;
  kind: number;
  location: Location;
  containerName?: string;
}

interface FoldingRange {
  startLine: number;
  endLine: number;
  kind?: string;
}

interface Diagnostic {
  range: Range;
  severity: number;
  message: string;
  code?: string;
}

interface Location {
  uri: string;
  range: Range;
}

interface DocumentHighlight {
  range: Range;
  kind?: number;
}

interface DocumentLink {
  range: Range;
  target?: string;
  tooltip?: string;
}

interface CompletionItem {
  label: string;
  kind?: number;
  detail?: string;
  insertText?: string;
  sortText?: string;
}

interface MarkupContent {
  kind: "markdown" | "plaintext";
  value: string;
}

interface Hover {
  contents: MarkupContent;
  range?: Range;
}

interface SignatureInformation {
  label: string;
  documentation?: string | MarkupContent;
}

interface SignatureHelp {
  signatures: SignatureInformation[];
  activeSignature?: number;
  activeParameter?: number;
}

interface TextEdit {
  range: Range;
  newText: string;
}

interface WorkspaceEdit {
  changes?: Record<string, TextEdit[]>;
}

interface SelectionRange {
  range: Range;
  parent?: SelectionRange;
}

interface SemanticToken {
  line: number;
  startChar: number;
  length: number;
  tokenType: number;
  tokenModifiers: number;
}

interface SemanticTokens {
  data: number[];
}

interface CodeAction {
  title: string;
  kind?: string;
  diagnostics?: Diagnostic[];
  isPreferred?: boolean;
  edit?: WorkspaceEdit;
}

interface Command {
  title: string;
  command: string;
  arguments?: any[];
}

interface CodeLens {
  range: Range;
  command?: Command;
  data?: any;
}

interface LinkedEditingRanges {
  ranges: Range[];
  wordPattern?: string;
}

interface Color {
  red: number;
  green: number;
  blue: number;
  alpha: number;
}

interface ColorInformation {
  range: Range;
  color: Color;
}

interface ColorPresentation {
  label: string;
  textEdit?: TextEdit;
}

interface RenameTarget {
  kind: "id";
  targetId: string;
  range: Range;
  placeholder: string;
}

type ReferenceQuery =
  | {
      kind: "id";
      targetId: string;
    }
  | {
      kind: "file";
      targetPath: string;
    };

// Symbol kinds
const SymbolKind = {
  Struct: 23,
};

const CompletionItemKind = {
  Keyword: 14,
  Value: 12,
  File: 17,
};

const DocumentHighlightKind = {
  Text: 1,
  Read: 2,
  Write: 3,
};

const CodeActionKind = {
  QuickFix: "quickfix",
};

const SemanticTokenType = {
  Keyword: 0,
  Property: 1,
  String: 2,
};

const SEMANTIC_TOKEN_LEGEND = {
  tokenTypes: ["keyword", "property", "string"],
  tokenModifiers: [] as string[],
};

const DiagnosticSeverity = {
  Error: 1,
};

// ============================================================================
// Line Tracking Helper
// ============================================================================

class LineTracker {
  private lines: string[];

  constructor(text: string) {
    this.lines = text.split("\n");
  }

  getLinesCount(): number {
    return this.lines.length;
  }

  getLine(lineNum: number): string {
    return this.lines[lineNum] || "";
  }

  getLineLength(lineNum: number): number {
    return this.lines[lineNum]?.length || 0;
  }
}

// ============================================================================
// LSP Server
// ============================================================================

class LSPServer {
  private documents: Map<string, TextDocument> = new Map();
  private initialized = false;
  private workspaceRoots: string[] = [];

  async start(): Promise<void> {
    let buffer = "";

    process.stdin.setEncoding("utf-8");

    const processData = () => {
      while (buffer.includes("\r\n\r\n")) {
        const headerEnd = buffer.indexOf("\r\n\r\n");
        const headers = buffer.substring(0, headerEnd);
        buffer = buffer.substring(headerEnd + 4);

        const lengthMatch = headers.match(/Content-Length: (\d+)/);
        if (!lengthMatch) continue;

        const contentLength = parseInt(lengthMatch[1], 10);
        if (buffer.length < contentLength) {
          buffer = headers + "\r\n\r\n" + buffer;
          break;
        }

        const content = buffer.substring(0, contentLength);
        buffer = buffer.substring(contentLength);

        try {
          const message = JSON.parse(content);
          this.handleMessage(message);
        } catch (e) {
          this.sendError(null, -32700, "Parse error");
        }
      }
    };

    process.stdin.on("data", (chunk: string) => {
      buffer += chunk;
      processData();
    });

    process.stdin.on("end", () => {
      process.exit(0);
    });

    process.stdin.on("error", (err) => {
      process.stderr.write(`stdin error: ${err}\n`);
      process.exit(1);
    });
  }

  private handleMessage(message: any): void {
    const { id, method, params } = message;

    try {
      if (method === "initialize") {
        this.initialized = true;
        this.workspaceRoots = this.extractWorkspaceRoots(params);
        this.sendResponse(id, {
          capabilities: {
            textDocumentSync: 1,
            documentSymbolProvider: true,
            foldingRangeProvider: true,
            definitionProvider: true,
            declarationProvider: true,
            typeDefinitionProvider: true,
            implementationProvider: true,
            referencesProvider: true,
            workspaceSymbolProvider: true,
            documentLinkProvider: true,
            documentHighlightProvider: true,
            hoverProvider: true,
            renameProvider: {
              prepareProvider: true,
            },
            linkedEditingRangeProvider: true,
            completionProvider: {
              triggerCharacters: [" ", ":", "<"],
            },
            signatureHelpProvider: {
              triggerCharacters: [":", "<", "[", " "],
              retriggerCharacters: ["<", "[", " "],
            },
            codeActionProvider: {
              codeActionKinds: [CodeActionKind.QuickFix],
            },
            documentFormattingProvider: true,
            documentRangeFormattingProvider: true,
            documentOnTypeFormattingProvider: {
              firstTriggerCharacter: "|",
              moreTriggerCharacter: ["\n"],
            },
            selectionRangeProvider: true,
            semanticTokensProvider: {
              legend: SEMANTIC_TOKEN_LEGEND,
              full: true,
            },
            codeLensProvider: {
              resolveProvider: false,
            },
            colorProvider: true,
          },
          serverInfo: {
            name: "org2-lsp",
            version: "0.1.0",
          },
        });
      } else if (method === "initialized") {
        // No response needed
      } else if (method === "shutdown") {
        this.sendResponse(id, null);
        process.exit(0);
      } else if (method === "exit") {
        process.exit(0);
      } else if (method === "textDocument/didOpen") {
        const { textDocument } = params;
        this.documents.set(textDocument.uri, {
          uri: textDocument.uri,
          version: textDocument.version,
          text: textDocument.text,
        });
        this.publishDiagnostics(textDocument.uri);
      } else if (method === "textDocument/didChange") {
        const { textDocument, contentChanges } = params;
        const doc = this.documents.get(textDocument.uri);
        if (doc) {
          for (const change of contentChanges) {
            if (change.range) {
              const { start, end } = change.range;
              const startOffset = this.positionToOffset(doc.text, start);
              const endOffset = this.positionToOffset(doc.text, end);
              doc.text = doc.text.substring(0, startOffset) + change.text + doc.text.substring(endOffset);
            } else {
              doc.text = change.text;
            }
          }
          doc.version = textDocument.version;
          this.publishDiagnostics(textDocument.uri);
        }
      } else if (method === "textDocument/didClose") {
        const { textDocument } = params;
        this.documents.delete(textDocument.uri);
      } else if (method === "textDocument/documentLink") {
        const { textDocument } = params;
        const doc = this.documents.get(textDocument.uri);
        if (doc) {
          const links = this.extractDocumentLinks(doc.uri, doc.text);
          this.sendResponse(id, links);
        } else {
          this.sendResponse(id, []);
        }
      } else if (method === "textDocument/documentSymbol") {
        const { textDocument } = params;
        const doc = this.documents.get(textDocument.uri);
        if (doc) {
          const result = parseOrgWithDiagnostics(doc.text);
          const symbols = this.extractSymbols(result.ast, doc.text);
          this.sendResponse(id, symbols);
        } else {
          this.sendResponse(id, []);
        }
      } else if (method === "textDocument/foldingRange") {
        const { textDocument } = params;
        const doc = this.documents.get(textDocument.uri);
        if (doc) {
          const result = parseOrgWithDiagnostics(doc.text);
          const ranges = this.extractFoldingRanges(result.ast, doc.text);
          this.sendResponse(id, ranges);
        } else {
          this.sendResponse(id, []);
        }
      } else if (
        method === "textDocument/definition" ||
        method === "textDocument/declaration" ||
        method === "textDocument/typeDefinition" ||
        method === "textDocument/implementation"
      ) {
        const { textDocument, position } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, null);
          return;
        }

        const target = this.extractLinkTargetAtPosition(doc.text, position);
        if (!target) {
          this.sendResponse(id, null);
          return;
        }

        const location = this.resolveDefinitionLocation(doc.uri, target);
        this.sendResponse(id, location ? [location] : null);
      } else if (method === "textDocument/references") {
        const { textDocument, position, context } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, []);
          return;
        }

        const query = this.extractReferenceQuery(doc.uri, doc.text, position);
        if (!query) {
          this.sendResponse(id, []);
          return;
        }

        const includeDeclaration = Boolean(context?.includeDeclaration);
        const references = this.findReferenceLocations(doc.uri, query, includeDeclaration);
        this.sendResponse(id, references);
      } else if (method === "textDocument/documentHighlight") {
        const { textDocument, position } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, []);
          return;
        }

        const highlights = this.getDocumentHighlights(doc.uri, doc.text, position);
        this.sendResponse(id, highlights);
      } else if (method === "textDocument/hover") {
        const { textDocument, position } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, null);
          return;
        }

        const hover = this.getHover(doc.uri, doc.text, position);
        this.sendResponse(id, hover);
      } else if (method === "textDocument/prepareRename") {
        const { textDocument, position } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, null);
          return;
        }

        const target = this.extractRenameTarget(doc.uri, doc.text, position);
        if (!target) {
          this.sendResponse(id, null);
          return;
        }

        this.sendResponse(id, {
          range: target.range,
          placeholder: target.placeholder,
        });
      } else if (method === "textDocument/rename") {
        const { textDocument, position, newName } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, null);
          return;
        }

        const target = this.extractRenameTarget(doc.uri, doc.text, position);
        if (!target) {
          this.sendResponse(id, null);
          return;
        }

        const normalizedNewId = this.normalizeRenameIdInput(String(newName ?? ""));
        if (!normalizedNewId) {
          this.sendError(id, -32602, "Rename target must be a non-empty ID without spaces");
          return;
        }

        const edit = this.buildRenameWorkspaceEdit(doc.uri, target, normalizedNewId);
        this.sendResponse(id, edit);
      } else if (method === "textDocument/linkedEditingRange") {
        const { textDocument, position } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, null);
          return;
        }

        const linkedRanges = this.getLinkedEditingRanges(doc.uri, doc.text, position);
        this.sendResponse(id, linkedRanges);
      } else if (method === "textDocument/completion") {
        const { textDocument, position } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, []);
          return;
        }

        const completions = this.getCompletions(textDocument.uri, doc.text, position);
        this.sendResponse(id, completions);
      } else if (method === "textDocument/signatureHelp") {
        const { textDocument, position } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, null);
          return;
        }

        const signatureHelp = this.getSignatureHelp(doc.text, position);
        this.sendResponse(id, signatureHelp);
      } else if (method === "textDocument/codeAction") {
        const { textDocument, context } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, []);
          return;
        }

        const actions = this.getCodeActions(doc.uri, doc.text, context);
        this.sendResponse(id, actions);
      } else if (method === "textDocument/formatting") {
        const { textDocument } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, []);
          return;
        }

        const edits = this.getDocumentFormattingEdits(doc.text);
        this.sendResponse(id, edits);
      } else if (method === "textDocument/rangeFormatting") {
        const { textDocument, range } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, []);
          return;
        }

        const edits = this.getRangeFormattingEdits(doc.text, range);
        this.sendResponse(id, edits);
      } else if (method === "textDocument/onTypeFormatting") {
        const { textDocument, position, ch } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, []);
          return;
        }

        const edits = this.getOnTypeFormattingEdits(doc.text, position, String(ch || ""));
        this.sendResponse(id, edits);
      } else if (method === "textDocument/selectionRange") {
        const { textDocument, positions } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, []);
          return;
        }

        const selectionRanges = this.getSelectionRanges(doc.text, Array.isArray(positions) ? positions : []);
        this.sendResponse(id, selectionRanges);
      } else if (method === "textDocument/semanticTokens/full") {
        const { textDocument } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, { data: [] });
          return;
        }

        const semanticTokens = this.getSemanticTokens(doc.text);
        this.sendResponse(id, semanticTokens);
      } else if (method === "textDocument/codeLens") {
        const { textDocument } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, []);
          return;
        }

        const codeLenses = this.getCodeLenses(doc.uri, doc.text);
        this.sendResponse(id, codeLenses);
      } else if (method === "textDocument/documentColor") {
        const { textDocument } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, []);
          return;
        }

        const colors = this.getDocumentColors(doc.text);
        this.sendResponse(id, colors);
      } else if (method === "textDocument/colorPresentation") {
        const { textDocument, color, range } = params;
        const doc = this.documents.get(textDocument.uri);
        if (!doc) {
          this.sendResponse(id, []);
          return;
        }

        const presentations = this.getColorPresentations(doc.text, color, range);
        this.sendResponse(id, presentations);
      } else if (method === "workspace/symbol") {
        const query = String(params?.query || "").trim();
        const symbols = this.findWorkspaceSymbols(query);
        this.sendResponse(id, symbols);
      } else {
        this.sendError(id, -32601, "Method not found");
      }
    } catch (e: any) {
      this.sendError(id, -32603, `Internal error: ${e.message}`);
    }
  }

  private extractSymbols(node: any, text: string, symbols: DocumentSymbol[] = [], tracker?: LineTracker): DocumentSymbol[] {
    if (!tracker) {
      tracker = new LineTracker(text);
    }

    if (!node) return symbols;

    if (node.type === "Document") {
      for (const child of node.children || []) {
        this.extractSymbols(child, text, symbols, tracker);
      }
    } else if (node.type === "Headline") {
      const headline = node as HeadlineNode;
      const titleText = this.inlineNodesToText(headline.title);
      const headlineMarker = "*".repeat(headline.level) + " ";

      let headlineLine = -1;
      for (let i = 0; i < tracker.getLinesCount(); i++) {
        const line = tracker.getLine(i);
        if (line.includes(headlineMarker) && (titleText === "" || line.includes(titleText))) {
          headlineLine = i;
          break;
        }
      }

      if (headlineLine < 0) {
        // Could not map this AST node back to a stable line; skip producing a symbol.
        return symbols;
      }

      let endLine = headlineLine;
      for (let i = headlineLine + 1; i < tracker.getLinesCount(); i++) {
        const line = tracker.getLine(i);
        const match = line.match(/^(\*+) /);
        if (match) {
          const nextLevel = match[1].length;
          if (nextLevel <= headline.level) {
            endLine = i - 1;
            break;
          }
        }
      }

      if (endLine === headlineLine) {
        endLine = tracker.getLinesCount() - 1;
      }

      const range: Range = {
        start: { line: headlineLine, character: 0 },
        end: { line: endLine, character: tracker.getLineLength(endLine) },
      };

      const symbol: DocumentSymbol = {
        name: titleText || `Headline (level ${headline.level})`,
        kind: SymbolKind.Struct,
        range,
        selectionRange: {
          start: { line: headlineLine, character: 0 },
          end: { line: headlineLine, character: tracker.getLineLength(headlineLine) },
        },
        children: [],
      };

      const childSymbols: DocumentSymbol[] = [];
      for (const child of headline.children || []) {
        if (child.type === "Headline") {
          this.extractSymbols(child, text, childSymbols, tracker);
        }
      }
      if (childSymbols.length > 0) {
        symbol.children = childSymbols;
      }

      symbols.push(symbol);
    }

    return symbols;
  }

  private extractFoldingRanges(node: any, text: string, ranges: FoldingRange[] = [], tracker?: LineTracker): FoldingRange[] {
    if (!tracker) {
      tracker = new LineTracker(text);
    }

    if (!node) return ranges;

    if (node.type === "Document") {
      // Document itself does not contribute a folding range; recurse via the generic children-walk below.
    } else if (node.type === "Headline") {
      const headline = node as HeadlineNode;
      const titleText = this.inlineNodesToText(headline.title);
      const headlineMarker = "*".repeat(headline.level) + " ";

      let headlineLine = -1;
      for (let i = 0; i < tracker.getLinesCount(); i++) {
        const line = tracker.getLine(i);
        if (line.includes(headlineMarker) && (titleText === "" || line.includes(titleText))) {
          headlineLine = i;
          break;
        }
      }

      if (headlineLine < 0) {
        // Could not map this AST node back to a stable line; skip producing a folding range.
        // (Otherwise we'd accidentally fold from the top of the file.)
        return ranges;
      }

      let endLine = headlineLine;
      for (let i = headlineLine + 1; i < tracker.getLinesCount(); i++) {
        const line = tracker.getLine(i);
        const match = line.match(/^(\*+) /);
        if (match) {
          const nextLevel = match[1].length;
          if (nextLevel <= headline.level) {
            endLine = i - 1;
            break;
          }
        }
      }

      if (endLine === headlineLine) {
        endLine = tracker.getLinesCount() - 1;
      }

      if (endLine > headlineLine) {
        ranges.push({
          startLine: headlineLine,
          endLine,
          kind: "region",
        });
      }

    } else if (node.type === "SrcBlock" || node.type === "Block") {
      const block = node as any;
      if (block.terminated) {
        const beginKeyword = node.type === "SrcBlock" ? "BEGIN_SRC" : `BEGIN_${block.kind.toUpperCase()}`;
        const endKeyword = node.type === "SrcBlock" ? "END_SRC" : `END_${block.kind.toUpperCase()}`;

        let beginLine = -1;
        let endLine = -1;
        for (let i = 0; i < tracker.getLinesCount(); i++) {
          const line = tracker.getLine(i);
          if (line.includes(beginKeyword) && beginLine < 0) {
            beginLine = i;
          }
          if (line.includes(endKeyword) && beginLine >= 0) {
            endLine = i;
            break;
          }
        }

        if (beginLine >= 0 && endLine > beginLine) {
          ranges.push({
            startLine: beginLine,
            endLine,
            kind: "region",
          });
        }
      }
    } else if (node.type === "List") {
      const list = node as ListNode;
      const firstItemMarker = list.ordered ? /^\s*\d+\./ : /^\s*[-*+]/;
      let startLine = -1;
      let endLine = -1;

      for (let i = 0; i < tracker.getLinesCount(); i++) {
        const line = tracker.getLine(i);
        if (firstItemMarker.test(line)) {
          if (startLine < 0) startLine = i;
          endLine = i;
        }
      }

      if (startLine >= 0 && endLine > startLine) {
        ranges.push({
          startLine,
          endLine,
          kind: "region",
        });
      }
    }

    if (node.children) {
      for (const child of node.children) {
        this.extractFoldingRanges(child, text, ranges, tracker);
      }
    }

    return ranges;
  }

  private findWorkspaceSymbols(query: string): SymbolInformation[] {
    const normalizedQuery = query.toLowerCase();
    const allDocuments = this.collectReferenceDocuments("");
    const symbols: SymbolInformation[] = [];

    for (const doc of allDocuments) {
      const headings = this.extractHeadingSymbolsFromText(doc.uri, doc.text);
      for (const heading of headings) {
        if (normalizedQuery && !heading.name.toLowerCase().includes(normalizedQuery)) {
          continue;
        }
        symbols.push(heading);
      }
    }

    symbols.sort((a, b) => {
      if (a.name !== b.name) {
        return a.name.localeCompare(b.name);
      }
      if (a.location.uri !== b.location.uri) {
        return a.location.uri.localeCompare(b.location.uri);
      }
      if (a.location.range.start.line !== b.location.range.start.line) {
        return a.location.range.start.line - b.location.range.start.line;
      }
      return a.location.range.start.character - b.location.range.start.character;
    });

    return symbols.slice(0, 200);
  }

  private extractHeadingSymbolsFromText(uri: string, text: string): SymbolInformation[] {
    const symbols: SymbolInformation[] = [];
    const lines = text.split("\n");

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const match = line.match(/^(\*+)\s+(.*)$/);
      if (!match) {
        continue;
      }

      const level = match[1].length;
      const title = (match[2] || "").trim();
      if (!title) {
        continue;
      }

      symbols.push({
        name: title,
        kind: SymbolKind.Struct,
        containerName: level > 1 ? `Level ${level}` : undefined,
        location: {
          uri,
          range: {
            start: { line: i, character: 0 },
            end: { line: i, character: line.length },
          },
        },
      });
    }

    return symbols;
  }

  private getCompletions(sourceUri: string, text: string, position: Position): CompletionItem[] {
    const lines = text.split("\n");
    const line = lines[position.line] ?? "";
    const cursor = Math.max(0, Math.min(position.character, line.length));
    const prefix = line.slice(0, cursor);

    const completions = new Map<string, CompletionItem>();
    const addCompletion = (item: CompletionItem) => {
      const key = `${item.label}:${item.insertText || ""}`;
      if (!completions.has(key)) {
        completions.set(key, item);
      }
    };

    const todoKeywords = ["TODO", "NEXT", "WAITING", "DONE", "CANCELLED"];
    const headlineMatch = line.match(/^(\*+\s+)([A-Z]*)/);
    if (headlineMatch) {
      const keywordStart = headlineMatch[1].length;
      const typedKeyword = (headlineMatch[2] || "").toUpperCase();
      if (cursor >= keywordStart && cursor <= keywordStart + typedKeyword.length) {
        for (const keyword of todoKeywords) {
          if (typedKeyword && !keyword.startsWith(typedKeyword)) {
            continue;
          }
          addCompletion({
            label: keyword,
            kind: CompletionItemKind.Keyword,
            detail: "Org TODO keyword",
            insertText: keyword,
          });
        }
      }
    }

    const planningKeywordMatch = prefix.match(/^\s*([A-Z]*)$/);
    if (planningKeywordMatch) {
      const typed = (planningKeywordMatch[1] || "").toUpperCase();
      for (const keyword of ["SCHEDULED:", "DEADLINE:"]) {
        if (typed && !keyword.startsWith(typed)) {
          continue;
        }
        addCompletion({
          label: keyword,
          kind: CompletionItemKind.Keyword,
          detail: "Org planning keyword",
          insertText: keyword,
        });
      }
    }

    if (/^\s*(SCHEDULED|DEADLINE):\s*(<[^>]*>)?$/i.test(prefix)) {
      const activeTimestamp = this.formatOrgTimestamp(new Date(), true);
      const inactiveTimestamp = this.formatOrgTimestamp(new Date(), false);

      addCompletion({
        label: activeTimestamp,
        kind: CompletionItemKind.Value,
        detail: "Active Org timestamp",
        insertText: activeTimestamp,
        sortText: "0",
      });

      addCompletion({
        label: inactiveTimestamp,
        kind: CompletionItemKind.Value,
        detail: "Inactive Org timestamp",
        insertText: inactiveTimestamp,
        sortText: "1",
      });
    }

    const idLinkContext = this.getIdLinkCompletionContext(line, cursor);
    if (idLinkContext) {
      for (const item of this.collectIdLinkCompletionItems(sourceUri, idLinkContext.typedPrefix)) {
        addCompletion(item);
      }
    }

    const fileLinkContext = this.getFileLinkCompletionContext(line, cursor);
    if (fileLinkContext) {
      for (const item of this.collectFileLinkCompletionItems(sourceUri, fileLinkContext.typedPrefix)) {
        addCompletion(item);
      }
    }

    return Array.from(completions.values()).sort((a, b) => {
      const aSort = a.sortText ?? a.label;
      const bSort = b.sortText ?? b.label;
      return aSort.localeCompare(bSort);
    });
  }

  private getIdLinkCompletionContext(line: string, cursor: number): { typedPrefix: string } | null {
    const beforeCursor = line.slice(0, cursor);
    const linkStart = beforeCursor.toLowerCase().lastIndexOf("[[id:");
    if (linkStart < 0) {
      return null;
    }

    const targetStart = linkStart + "[[id:".length;
    const targetEnd = line.indexOf("]", targetStart);
    const effectiveTargetEnd = targetEnd >= 0 ? targetEnd : line.length;
    if (cursor < targetStart || cursor > effectiveTargetEnd) {
      return null;
    }

    const typedPrefix = line.slice(targetStart, cursor);
    if (/[\s\[\]]/.test(typedPrefix)) {
      return null;
    }

    return {
      typedPrefix,
    };
  }

  private getFileLinkCompletionContext(line: string, cursor: number): { typedPrefix: string } | null {
    const beforeCursor = line.slice(0, cursor);
    const linkStart = beforeCursor.lastIndexOf("[[");
    if (linkStart < 0) {
      return null;
    }

    const targetStart = linkStart + "[[".length;
    const targetEnd = line.indexOf("]", targetStart);
    const effectiveTargetEnd = targetEnd >= 0 ? targetEnd : line.length;
    if (cursor < targetStart || cursor > effectiveTargetEnd) {
      return null;
    }

    const typedTarget = line.slice(targetStart, cursor);
    if (!typedTarget || /[\s\[\]]/.test(typedTarget)) {
      return null;
    }

    const loweredTarget = typedTarget.toLowerCase();
    if (loweredTarget.startsWith("id:")) {
      return null;
    }

    let typedPrefix = typedTarget;
    if (loweredTarget.startsWith("file:")) {
      typedPrefix = typedTarget.slice("file:".length);
    } else if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(typedTarget)) {
      return null;
    }

    const pathPrefix = (typedPrefix.split("::")[0] || "").replace(/\\/g, "/");
    if (/[\s\[\]]/.test(pathPrefix)) {
      return null;
    }

    return {
      typedPrefix: pathPrefix,
    };
  }

  private collectIdLinkCompletionItems(sourceUri: string, typedPrefix: string): CompletionItem[] {
    const normalizedPrefix = this.normalizeIdValue(typedPrefix || "");
    const entries = new Map<string, string>();

    for (const doc of this.collectReferenceDocuments(sourceUri)) {
      const lines = doc.text.split("\n");
      let currentHeadline = "";
      const docPath = this.filePathFromUri(doc.uri);
      const locationLabel = docPath ? this.formatPathForHover(docPath) : doc.uri;

      for (const line of lines) {
        const headlineMatch = line.match(/^\*+\s+(.*)$/);
        if (headlineMatch) {
          const headlineTitle = (headlineMatch[1] || "").trim();
          currentHeadline = headlineTitle.replace(/^[A-Z][A-Z0-9_-]*\s+/, "");
        }

        const idMatch = line.match(/^\s*:ID:\s*(\S+)\s*$/i);
        if (!idMatch) {
          continue;
        }

        const normalizedId = this.normalizeIdValue(idMatch[1] || "");
        if (!normalizedId) {
          continue;
        }

        if (normalizedPrefix && !normalizedId.startsWith(normalizedPrefix)) {
          continue;
        }

        const detail = currentHeadline ? `${currentHeadline} - ${locationLabel}` : `Org ID in ${locationLabel}`;
        if (!entries.has(normalizedId) || currentHeadline) {
          entries.set(normalizedId, detail);
        }
      }
    }

    return Array.from(entries.entries())
      .sort(([a], [b]) => a.localeCompare(b))
      .slice(0, 100)
      .map(([id, detail], index) => ({
        label: id,
        kind: CompletionItemKind.Value,
        detail,
        insertText: id,
        sortText: `2-${String(index).padStart(3, "0")}-${id}`,
      }));
  }

  private collectFileLinkCompletionItems(sourceUri: string, typedPrefix: string): CompletionItem[] {
    const sourcePath = this.filePathFromUri(sourceUri);
    if (!sourcePath) {
      return [];
    }

    const sourceDir = path.dirname(sourcePath);
    const normalizedPrefix = (typedPrefix || "").toLowerCase();
    const entries = new Map<string, string>();

    for (const doc of this.collectReferenceDocuments(sourceUri)) {
      const filePath = this.filePathFromUri(doc.uri);
      if (!filePath || !this.isOrgFile(filePath)) {
        continue;
      }

      const relativePath = path.relative(sourceDir, filePath).split(path.sep).join("/");
      if (!relativePath) {
        continue;
      }

      const normalizedRelativePath = relativePath.toLowerCase();
      if (normalizedPrefix && !normalizedRelativePath.startsWith(normalizedPrefix)) {
        continue;
      }

      if (!entries.has(relativePath)) {
        entries.set(relativePath, `Org file - ${this.formatPathForHover(filePath)}`);
      }
    }

    return Array.from(entries.entries())
      .sort(([a], [b]) => a.localeCompare(b))
      .slice(0, 100)
      .map(([relativePath, detail], index) => ({
        label: relativePath,
        kind: CompletionItemKind.File,
        detail,
        insertText: relativePath,
        sortText: `3-${String(index).padStart(3, "0")}-${relativePath}`,
      }));
  }

  private getSignatureHelp(text: string, position: Position): SignatureHelp | null {
    const lines = text.split("\n");
    const line = lines[position.line] ?? "";
    const cursor = Math.max(0, Math.min(position.character, line.length));

    const planningRegex = /(SCHEDULED:|DEADLINE:)/gi;
    let match: RegExpExecArray | null;

    while ((match = planningRegex.exec(line)) !== null) {
      const keyword = (match[1] || "").toUpperCase();
      const start = match.index;
      const end = start + keyword.length;
      if (cursor < start) {
        continue;
      }

      const valuePrefix = cursor <= end ? "" : line.slice(end, cursor);
      const trimmedPrefix = valuePrefix.trimStart();
      const activeSignature = trimmedPrefix.startsWith("[") ? 1 : 0;

      return {
        signatures: [
          {
            label: `${keyword} <YYYY-MM-DD Ddd>`,
            documentation: {
              kind: "markdown",
              value:
                "Active timestamp used by default in Org agenda workflows. Example: `<2026-02-14 Sat>`.",
            },
          },
          {
            label: `${keyword} [YYYY-MM-DD Ddd]`,
            documentation: {
              kind: "markdown",
              value:
                "Inactive timestamp for planning context that should not drive agenda scheduling. Example: `[2026-02-14 Sat]`.",
            },
          },
        ],
        activeSignature,
        activeParameter: 0,
      };
    }

    return null;
  }

  private getCodeActions(sourceUri: string, text: string, context: any): CodeAction[] {
    const actions: CodeAction[] = [];
    const diagnostics = Array.isArray(context?.diagnostics) ? (context.diagnostics as Diagnostic[]) : [];

    const parserDiagnostics = diagnostics.filter((diag) => String(diag?.code || "") === "org2-parser");
    const fullRange = this.getFullDocumentRange(text);

    if (text.includes("\r\n")) {
      actions.push({
        title: "Org2: Convert CRLF line endings to LF",
        kind: CodeActionKind.QuickFix,
        diagnostics: parserDiagnostics.filter((diag) => String(diag?.message || "").includes("Unsupported line endings: CRLF")),
        isPreferred: true,
        edit: {
          changes: {
            [sourceUri]: [
              {
                range: fullRange,
                newText: text.replace(/\r\n/g, "\n"),
              },
            ],
          },
        },
      });
    }

    if (text.includes("\t")) {
      actions.push({
        title: "Org2: Replace tab characters with two spaces",
        kind: CodeActionKind.QuickFix,
        diagnostics: parserDiagnostics.filter((diag) =>
          String(diag?.message || "").includes("Unsupported construct: tab character")
        ),
        edit: {
          changes: {
            [sourceUri]: [
              {
                range: fullRange,
                newText: text.replace(/\t/g, "  "),
              },
            ],
          },
        },
      });
    }

    return actions;
  }

  private getDocumentFormattingEdits(text: string): TextEdit[] {
    const formatted = this.formatCanonicalOrgText(text);
    if (!formatted) {
      return [];
    }

    const normalizedText = text.replace(/\r\n/g, "\n");
    if (formatted === normalizedText) {
      return [];
    }

    return [
      {
        range: this.getFullDocumentRange(text),
        newText: formatted,
      },
    ];
  }

  private getRangeFormattingEdits(text: string, range: Range): TextEdit[] {
    const lines = text.split("\n");
    if (lines.length === 0) {
      return [];
    }

    const maxLine = lines.length - 1;
    const startLine = this.clampLine(range?.start?.line, maxLine);
    const rawEndLine = this.clampLine(range?.end?.line, maxLine);
    const endLineExclusiveBase = (range?.end?.character ?? 0) === 0 ? rawEndLine : rawEndLine + 1;
    const endLineExclusive = Math.min(lines.length, Math.max(startLine + 1, endLineExclusiveBase));

    const selectedText = lines.slice(startLine, endLineExclusive).join("\n");
    const formatted = this.formatCanonicalOrgText(selectedText);
    if (!formatted) {
      return [];
    }

    const normalizedSelectedText = selectedText.replace(/\r\n/g, "\n");
    const normalizedFormattedText = formatted.replace(/\r\n/g, "\n");
    if (normalizedFormattedText === normalizedSelectedText) {
      return [];
    }

    const endLine = endLineExclusive - 1;
    return [
      {
        range: {
          start: { line: startLine, character: 0 },
          end: { line: endLine, character: lines[endLine]?.length ?? 0 },
        },
        newText: normalizedFormattedText,
      },
    ];
  }

  private getOnTypeFormattingEdits(text: string, position: Position, triggerCharacter: string): TextEdit[] {
    if (triggerCharacter !== "|" && triggerCharacter !== "\n") {
      return [];
    }

    const lines = text.split("\n");
    if (lines.length === 0) {
      return [];
    }

    const maxLine = lines.length - 1;
    const rawLine = this.clampLine(position?.line, maxLine);
    const targetLine = triggerCharacter === "\n" ? Math.max(0, rawLine - 1) : rawLine;
    if (!this.isTableLikeLine(lines[targetLine] || "")) {
      return [];
    }

    let startLine = targetLine;
    while (startLine > 0 && this.isTableLikeLine(lines[startLine - 1] || "")) {
      startLine -= 1;
    }

    let endLine = targetLine;
    while (endLine + 1 < lines.length && this.isTableLikeLine(lines[endLine + 1] || "")) {
      endLine += 1;
    }

    const endCharacter = lines[endLine]?.length ?? 0;
    return this.getRangeFormattingEdits(text, {
      start: { line: startLine, character: 0 },
      end: { line: endLine, character: endCharacter },
    });
  }

  private isTableLikeLine(line: string): boolean {
    return /^\s*\|/.test(line);
  }

  private getSelectionRanges(text: string, positions: Position[]): SelectionRange[] {
    return positions.map((position) => this.getSelectionRangeAtPosition(text, position));
  }

  private getSelectionRangeAtPosition(text: string, position: Position): SelectionRange {
    const lines = text.split("\n");
    const maxLine = Math.max(0, lines.length - 1);
    const safeLine = this.clampLine(position?.line, maxLine);
    const lineText = lines[safeLine] ?? "";
    const rawCharacter = Number.isFinite(position?.character) ? Number(position.character) : 0;
    const safeCharacter = Math.max(0, Math.min(lineText.length, rawCharacter));
    const safePosition: Position = { line: safeLine, character: safeCharacter };

    const lineRange: Range = {
      start: { line: safeLine, character: 0 },
      end: { line: safeLine, character: lineText.length },
    };

    const candidateRanges: Range[] = [];

    const wordRange = this.getWordRangeAtPosition(lines, safePosition);
    if (wordRange) {
      candidateRanges.push(wordRange);
    }

    const link = this.extractLinkAtPosition(text, safePosition);
    if (link) {
      if (this.isPositionInRange(safePosition, link.targetRange)) {
        candidateRanges.push(link.targetRange);
      }
      candidateRanges.push(link.range);
    }

    candidateRanges.push(lineRange);
    for (const headlineRange of this.getEnclosingHeadlineRanges(lines, safeLine)) {
      candidateRanges.push(headlineRange);
    }

    const documentRange = this.getFullDocumentRange(text);
    candidateRanges.push(documentRange);

    const uniqueRanges: Range[] = [];
    const seen = new Set<string>();
    for (const candidate of candidateRanges) {
      const key = `${candidate.start.line}:${candidate.start.character}:${candidate.end.line}:${candidate.end.character}`;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      uniqueRanges.push(candidate);
    }

    uniqueRanges.sort((a, b) => {
      const aContainsB = this.rangeContains(a, b);
      const bContainsA = this.rangeContains(b, a);
      if (aContainsB && !bContainsA) {
        return 1;
      }
      if (bContainsA && !aContainsB) {
        return -1;
      }

      const startCompare = this.comparePositions(a.start, b.start);
      if (startCompare !== 0) {
        return startCompare;
      }
      return this.comparePositions(a.end, b.end);
    });

    const normalizedRanges: Range[] = [];
    for (const candidate of uniqueRanges) {
      if (normalizedRanges.length === 0) {
        normalizedRanges.push(candidate);
        continue;
      }

      const previous = normalizedRanges[normalizedRanges.length - 1];
      if (this.areRangesEqual(candidate, previous)) {
        continue;
      }

      if (this.rangeContains(candidate, previous)) {
        normalizedRanges.push(candidate);
      }
    }

    if (normalizedRanges.length === 0) {
      normalizedRanges.push(documentRange);
    }

    let selection: SelectionRange | undefined;
    for (let i = normalizedRanges.length - 1; i >= 0; i--) {
      selection = selection ? { range: normalizedRanges[i], parent: selection } : { range: normalizedRanges[i] };
    }

    return selection ?? { range: documentRange };
  }

  private getSemanticTokens(text: string): SemanticTokens {
    const lines = text.split("\n");
    const tokens: SemanticToken[] = [];
    const seen = new Set<string>();

    const addToken = (line: number, startChar: number, length: number, tokenType: number) => {
      if (length <= 0 || startChar < 0) {
        return;
      }
      const key = `${line}:${startChar}:${length}:${tokenType}`;
      if (seen.has(key)) {
        return;
      }
      seen.add(key);
      tokens.push({
        line,
        startChar,
        length,
        tokenType,
        tokenModifiers: 0,
      });
    };

    const todoKeywords = new Set([
      "TODO",
      "NEXT",
      "WAITING",
      "IN_PROGRESS",
      "DONE",
      "CANCELED",
      "CANCELLED",
      "OPEN",
      "BACKLOG",
      "BLOCKED",
      "STARTED",
      "DOING",
      "CLOSED",
    ]);

    for (let lineNumber = 0; lineNumber < lines.length; lineNumber++) {
      const line = lines[lineNumber] ?? "";

      const headingTodoMatch = line.match(/^(\*+\s+)([A-Z][A-Z0-9_-]*)\b/);
      if (headingTodoMatch) {
        const keyword = (headingTodoMatch[2] || "").toUpperCase();
        if (todoKeywords.has(keyword)) {
          addToken(lineNumber, headingTodoMatch[1].length, keyword.length, SemanticTokenType.Keyword);
        }
      }

      const planningKeywordRegex = /(SCHEDULED:|DEADLINE:|CLOSED:)/g;
      let planningMatch: RegExpExecArray | null;
      while ((planningMatch = planningKeywordRegex.exec(line)) !== null) {
        const keyword = planningMatch[1] || "";
        addToken(lineNumber, planningMatch.index, keyword.length, SemanticTokenType.Keyword);
      }

      const propertyMatch = line.match(/^(\s*)(:[A-Za-z0-9_@#%+.-]+:)/);
      if (propertyMatch) {
        const startChar = (propertyMatch[1] || "").length;
        const propertyKey = propertyMatch[2] || "";
        addToken(lineNumber, startChar, propertyKey.length, SemanticTokenType.Property);
      }

      const linkRegex = /\[\[([^\]\n]+?)\](?:\[[^\]\n]*\])?\]/g;
      let linkMatch: RegExpExecArray | null;
      while ((linkMatch = linkRegex.exec(line)) !== null) {
        const rawTarget = linkMatch[1] || "";
        if (!rawTarget.trim()) {
          continue;
        }

        const targetOffsetInMatch = linkMatch[0].indexOf(rawTarget);
        const targetStartChar = targetOffsetInMatch >= 0 ? linkMatch.index + targetOffsetInMatch : linkMatch.index + 2;
        addToken(lineNumber, targetStartChar, rawTarget.length, SemanticTokenType.String);
      }
    }

    return {
      data: this.encodeSemanticTokens(tokens),
    };
  }

  private getCodeLenses(sourceUri: string, text: string): CodeLens[] {
    const idDefinitions = this.findCodeLensIdDefinitions(text);
    if (idDefinitions.length === 0) {
      return [];
    }

    const backlinkCounts = new Map<string, number>();
    for (const definition of idDefinitions) {
      backlinkCounts.set(definition.id, 0);
    }

    for (const doc of this.collectReferenceDocuments(sourceUri)) {
      for (const link of this.findLinkTargets(doc.text)) {
        if (!link.target.toLowerCase().startsWith("id:")) {
          continue;
        }

        const normalizedId = this.normalizeIdValue(link.target);
        if (!normalizedId || !backlinkCounts.has(normalizedId)) {
          continue;
        }

        backlinkCounts.set(normalizedId, (backlinkCounts.get(normalizedId) ?? 0) + 1);
      }
    }

    return idDefinitions.map((definition) => {
      const count = backlinkCounts.get(definition.id) ?? 0;
      const title = count === 0 ? "Org2: no backlinks" : `Org2: ${count} backlink${count === 1 ? "" : "s"}`;

      return {
        range: definition.range,
        command: {
          title,
          command: "org2.roamShowBacklinksById",
          arguments: [`id:${definition.id}`],
        },
      };
    });
  }

  private findCodeLensIdDefinitions(text: string): Array<{ id: string; range: Range }> {
    const lines = text.split("\n");
    const definitions: Array<{ id: string; range: Range }> = [];

    for (let lineNumber = 0; lineNumber < lines.length; lineNumber++) {
      const line = lines[lineNumber] ?? "";
      const match = line.match(/^(\s*:ID:\s*)(\S+)(\s*)$/i);
      if (!match) {
        continue;
      }

      const normalizedId = this.normalizeIdValue(match[2] || "");
      if (!normalizedId) {
        continue;
      }

      const idStart = (match[1] || "").length;
      const idLength = (match[2] || "").length;
      definitions.push({
        id: normalizedId,
        range: {
          start: { line: lineNumber, character: idStart },
          end: { line: lineNumber, character: idStart + idLength },
        },
      });
    }

    return definitions;
  }

  private getDocumentColors(text: string): ColorInformation[] {
    const lines = text.split("\n");
    const colors: ColorInformation[] = [];
    const seen = new Set<string>();

    for (let lineNumber = 0; lineNumber < lines.length; lineNumber++) {
      const line = lines[lineNumber] ?? "";
      const colorRegex = /(^|[^A-Za-z0-9])(#(?:[A-Fa-f0-9]{8}|[A-Fa-f0-9]{6}|[A-Fa-f0-9]{4}|[A-Fa-f0-9]{3}))(?=$|[^A-Za-z0-9])/g;
      let match: RegExpExecArray | null;
      while ((match = colorRegex.exec(line)) !== null) {
        const rawColor = match[2] || "";
        const parsed = this.parseHexColorLiteral(rawColor);
        if (!parsed) {
          continue;
        }

        const prefix = match[1] || "";
        const startChar = match.index + prefix.length;
        const endChar = startChar + rawColor.length;
        const key = `${lineNumber}:${startChar}:${endChar}:${rawColor.toLowerCase()}`;
        if (seen.has(key)) {
          continue;
        }
        seen.add(key);

        colors.push({
          color: parsed,
          range: {
            start: { line: lineNumber, character: startChar },
            end: { line: lineNumber, character: endChar },
          },
        });
      }
    }

    return colors;
  }

  private getColorPresentations(text: string, color: Color, range?: Range): ColorPresentation[] {
    if (!color) {
      return [];
    }

    const existingLiteral = range ? this.getSingleLineRangeText(text, range) : null;
    const existingLength = existingLiteral && /^#[A-Fa-f0-9]+$/.test(existingLiteral) ? existingLiteral.length - 1 : 0;
    const includeAlpha = existingLength === 4 || existingLength === 8 || this.colorComponentToByte(color.alpha) < 255;

    const lengths = includeAlpha ? [8, 4, 6, 3] : [6, 3, 8, 4];
    const orderedLengths = existingLength > 0 ? [existingLength, ...lengths.filter((length) => length !== existingLength)] : lengths;

    const presentations: ColorPresentation[] = [];
    const seen = new Set<string>();

    for (const length of orderedLengths) {
      const label = this.formatColorAsHex(color, length);
      if (!label || seen.has(label)) {
        continue;
      }
      seen.add(label);
      presentations.push({
        label,
        textEdit: range
          ? {
              range,
              newText: label,
            }
          : undefined,
      });
    }

    return presentations;
  }

  private getSingleLineRangeText(text: string, range: Range): string | null {
    const lines = text.split("\n");
    const startLine = range?.start?.line;
    const endLine = range?.end?.line;
    if (!Number.isFinite(startLine) || !Number.isFinite(endLine) || startLine !== endLine) {
      return null;
    }

    const lineNumber = Math.trunc(Number(startLine));
    const line = lines[lineNumber] ?? "";
    const startChar = Math.max(0, Math.min(line.length, Number(range?.start?.character ?? 0)));
    const endChar = Math.max(startChar, Math.min(line.length, Number(range?.end?.character ?? startChar)));
    return line.slice(startChar, endChar);
  }

  private parseHexColorLiteral(value: string): Color | null {
    const raw = value.trim();
    if (!raw.startsWith("#")) {
      return null;
    }

    let hex = raw.slice(1);
    if (hex.length === 3 || hex.length === 4) {
      hex = hex
        .split("")
        .map((char) => char + char)
        .join("");
    }

    if (hex.length === 6) {
      hex += "ff";
    }

    if (hex.length !== 8 || /[^A-Fa-f0-9]/.test(hex)) {
      return null;
    }

    const r = parseInt(hex.slice(0, 2), 16);
    const g = parseInt(hex.slice(2, 4), 16);
    const b = parseInt(hex.slice(4, 6), 16);
    const a = parseInt(hex.slice(6, 8), 16);
    if ([r, g, b, a].some((component) => Number.isNaN(component))) {
      return null;
    }

    return {
      red: r / 255,
      green: g / 255,
      blue: b / 255,
      alpha: a / 255,
    };
  }

  private formatColorAsHex(color: Color, length: number): string | null {
    const toByteHex = (value: number) => this.colorComponentToByte(value).toString(16).padStart(2, "0").toUpperCase();

    const red = toByteHex(color.red);
    const green = toByteHex(color.green);
    const blue = toByteHex(color.blue);
    const alpha = toByteHex(color.alpha);

    if (length === 6) {
      return `#${red}${green}${blue}`;
    }

    if (length === 8) {
      return `#${red}${green}${blue}${alpha}`;
    }

    const canShorten = (component: string) => component.length === 2 && component[0] === component[1];
    if (length === 3) {
      if (!canShorten(red) || !canShorten(green) || !canShorten(blue)) {
        return null;
      }
      return `#${red[0]}${green[0]}${blue[0]}`;
    }

    if (!canShorten(red) || !canShorten(green) || !canShorten(blue) || !canShorten(alpha)) {
      return null;
    }

    return `#${red[0]}${green[0]}${blue[0]}${alpha[0]}`;
  }

  private colorComponentToByte(value: number): number {
    if (!Number.isFinite(value)) {
      return 0;
    }
    return Math.max(0, Math.min(255, Math.round(value * 255)));
  }

  private encodeSemanticTokens(tokens: SemanticToken[]): number[] {
    const sorted = [...tokens].sort((a, b) => {
      if (a.line !== b.line) {
        return a.line - b.line;
      }
      if (a.startChar !== b.startChar) {
        return a.startChar - b.startChar;
      }
      if (a.length !== b.length) {
        return a.length - b.length;
      }
      return a.tokenType - b.tokenType;
    });

    const data: number[] = [];
    let previousLine = 0;
    let previousStartChar = 0;

    for (const token of sorted) {
      const deltaLine = token.line - previousLine;
      const deltaStart = deltaLine === 0 ? token.startChar - previousStartChar : token.startChar;

      data.push(deltaLine, deltaStart, token.length, token.tokenType, token.tokenModifiers);

      previousLine = token.line;
      previousStartChar = token.startChar;
    }

    return data;
  }

  private getWordRangeAtPosition(lines: string[], position: Position): Range | null {
    const line = lines[position.line] ?? "";
    if (!line) {
      return null;
    }

    let cursor = position.character;
    if (cursor >= line.length && line.length > 0) {
      cursor = line.length - 1;
    }

    if (cursor < 0 || cursor >= line.length) {
      return null;
    }

    if (!/\S/.test(line[cursor])) {
      return null;
    }

    let start = cursor;
    while (start > 0 && /\S/.test(line[start - 1])) {
      start -= 1;
    }

    let end = cursor + 1;
    while (end < line.length && /\S/.test(line[end])) {
      end += 1;
    }

    return {
      start: { line: position.line, character: start },
      end: { line: position.line, character: end },
    };
  }

  private getEnclosingHeadlineRanges(lines: string[], lineNumber: number): Range[] {
    const ranges: Range[] = [];
    let searchFrom = lineNumber;
    let maxLevel = Number.POSITIVE_INFINITY;

    while (searchFrom >= 0) {
      let headlineLine = -1;
      let headlineLevel = 0;

      for (let i = searchFrom; i >= 0; i--) {
        const match = lines[i]?.match(/^(\*+)\s+/);
        if (!match) {
          continue;
        }

        const level = match[1].length;
        if (level >= maxLevel) {
          continue;
        }

        headlineLine = i;
        headlineLevel = level;
        break;
      }

      if (headlineLine < 0) {
        break;
      }

      const endLine = this.findHeadlineEndLine(lines, headlineLine, headlineLevel);
      if (lineNumber >= headlineLine && lineNumber <= endLine) {
        ranges.push({
          start: { line: headlineLine, character: 0 },
          end: { line: endLine, character: lines[endLine]?.length ?? 0 },
        });
      }

      maxLevel = headlineLevel;
      searchFrom = headlineLine - 1;
    }

    return ranges;
  }

  private findHeadlineEndLine(lines: string[], headlineLine: number, headlineLevel: number): number {
    for (let i = headlineLine + 1; i < lines.length; i++) {
      const match = lines[i]?.match(/^(\*+)\s+/);
      if (!match) {
        continue;
      }

      const nextLevel = match[1].length;
      if (nextLevel <= headlineLevel) {
        return i - 1;
      }
    }

    return Math.max(headlineLine, lines.length - 1);
  }

  private rangeContains(outer: Range, inner: Range): boolean {
    return this.comparePositions(outer.start, inner.start) <= 0 && this.comparePositions(outer.end, inner.end) >= 0;
  }

  private areRangesEqual(a: Range, b: Range): boolean {
    return (
      a.start.line === b.start.line &&
      a.start.character === b.start.character &&
      a.end.line === b.end.line &&
      a.end.character === b.end.character
    );
  }

  private comparePositions(a: Position, b: Position): number {
    if (a.line !== b.line) {
      return a.line - b.line;
    }
    return a.character - b.character;
  }

  private clampLine(line: number | undefined, maxLine: number): number {
    if (!Number.isFinite(line)) {
      return 0;
    }
    return Math.max(0, Math.min(maxLine, Number(line)));
  }

  private formatCanonicalOrgText(rawText: string): string | null {
    try {
      const ast = parseOrgToCanonicalAst(rawText.replace(/\r\n/g, "\n"));
      return printCanonicalAstToOrg(ast);
    } catch {
      return null;
    }
  }

  private getFullDocumentRange(text: string): Range {
    const lines = text.split("\n");
    const endLine = Math.max(0, lines.length - 1);
    const endCharacter = lines[endLine]?.length ?? 0;
    return {
      start: { line: 0, character: 0 },
      end: { line: endLine, character: endCharacter },
    };
  }

  private getDocumentHighlights(sourceUri: string, text: string, position: Position): DocumentHighlight[] {
    const query = this.extractReferenceQuery(sourceUri, text, position);
    if (!query) {
      return [];
    }

    const highlights: DocumentHighlight[] = [];
    const seen = new Set<string>();
    const addHighlight = (range: Range, kind: number) => {
      const key = `${range.start.line}:${range.start.character}:${range.end.line}:${range.end.character}:${kind}`;
      if (seen.has(key)) {
        return;
      }
      seen.add(key);
      highlights.push({ range, kind });
    };

    for (const link of this.findLinkTargets(text)) {
      if (query.kind === "id") {
        if (!link.target.toLowerCase().startsWith("id:")) {
          continue;
        }
        if (this.normalizeIdValue(link.target) !== query.targetId) {
          continue;
        }
        addHighlight(link.targetRange, DocumentHighlightKind.Read);
        continue;
      }

      const linkedPath = this.normalizeFileLinkPath(sourceUri, link.target);
      if (linkedPath && linkedPath === query.targetPath) {
        addHighlight(link.targetRange, DocumentHighlightKind.Read);
      }
    }

    if (query.kind === "id") {
      for (const range of this.findIdDefinitionValueRanges(text, query.targetId)) {
        addHighlight(range, DocumentHighlightKind.Write);
      }
    }

    return highlights.sort((a, b) => {
      if (a.range.start.line !== b.range.start.line) {
        return a.range.start.line - b.range.start.line;
      }
      if (a.range.start.character !== b.range.start.character) {
        return a.range.start.character - b.range.start.character;
      }
      return (a.kind || 0) - (b.kind || 0);
    });
  }

  private getHover(sourceUri: string, text: string, position: Position): Hover | null {
    const link = this.extractLinkAtPosition(text, position);
    if (link) {
      return this.getLinkHover(sourceUri, link.target, link.range);
    }

    const todoHover = this.getTodoKeywordHover(text, position);
    if (todoHover) {
      return todoHover;
    }

    const planningHover = this.getPlanningKeywordHover(text, position);
    if (planningHover) {
      return planningHover;
    }

    return null;
  }

  private getLinkHover(sourceUri: string, target: string, range: Range): Hover {
    const normalizedTarget = target.trim();

    if (normalizedTarget.toLowerCase().startsWith("id:")) {
      const normalizedId = this.normalizeIdValue(normalizedTarget);
      const location = this.resolveIdDefinitionLocation(sourceUri, normalizedTarget);
      const details = [`**Org ID link** \`id:${normalizedId}\``];

      if (location) {
        details.push(`Resolves to \`${this.formatLocationForHover(location)}\`.`);
      } else {
        details.push("Target ID not found in open/workspace Org files.");
      }

      return {
        range,
        contents: {
          kind: "markdown",
          value: details.join("\n\n"),
        },
      };
    }

    const resolvedPath = this.normalizeFileLinkPath(sourceUri, normalizedTarget);
    if (resolvedPath) {
      const exists = fs.existsSync(resolvedPath);
      const details = [`**Org file link** \`${normalizedTarget}\``, `Resolves to \`${this.formatPathForHover(resolvedPath)}\`.`];

      if (!exists) {
        details.push("Target file does not exist yet.");
      }

      return {
        range,
        contents: {
          kind: "markdown",
          value: details.join("\n\n"),
        },
      };
    }

    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(normalizedTarget)) {
      return {
        range,
        contents: {
          kind: "markdown",
          value: `**External link**\n\n\`${normalizedTarget}\``,
        },
      };
    }

    return {
      range,
      contents: {
        kind: "markdown",
        value: `**Org link target**\n\n\`${normalizedTarget}\``,
      },
    };
  }

  private getTodoKeywordHover(text: string, position: Position): Hover | null {
    const lines = text.split("\n");
    const line = lines[position.line] ?? "";
    const match = line.match(/^(\*+\s+)([A-Z][A-Z0-9_-]*)\b/);
    if (!match) {
      return null;
    }

    const keyword = match[2];
    const startChar = match[1].length;
    const endChar = startChar + keyword.length;
    if (position.character < startChar || position.character >= endChar) {
      return null;
    }

    return {
      range: {
        start: { line: position.line, character: startChar },
        end: { line: position.line, character: endChar },
      },
      contents: {
        kind: "markdown",
        value: `**TODO keyword** \`${keyword}\`\n\nStatus bucket: \`${this.todoKeywordBucket(keyword)}\``,
      },
    };
  }

  private getPlanningKeywordHover(text: string, position: Position): Hover | null {
    const lines = text.split("\n");
    const line = lines[position.line] ?? "";
    const planningKeywords = [
      { keyword: "SCHEDULED:", description: "Planned start date for agenda scheduling." },
      { keyword: "DEADLINE:", description: "Due date used for overdue and urgency tracking." },
    ];

    for (const item of planningKeywords) {
      const startChar = line.indexOf(item.keyword);
      if (startChar < 0) {
        continue;
      }
      const endChar = startChar + item.keyword.length;
      if (position.character < startChar || position.character >= endChar) {
        continue;
      }
      return {
        range: {
          start: { line: position.line, character: startChar },
          end: { line: position.line, character: endChar },
        },
        contents: {
          kind: "markdown",
          value: `**${item.keyword}**\n\n${item.description}`,
        },
      };
    }

    return null;
  }

  private todoKeywordBucket(keyword: string): "active" | "closed" | "custom" {
    const normalized = keyword.trim().toUpperCase();

    if (normalized === "TODO" || normalized === "NEXT" || normalized === "WAITING" || normalized === "IN_PROGRESS") {
      return "active";
    }

    if (normalized === "DONE" || normalized === "CANCELLED" || normalized === "CANCELED" || normalized === "CLOSED") {
      return "closed";
    }

    return "custom";
  }

  private formatLocationForHover(location: Location): string {
    const filePath = this.filePathFromUri(location.uri);
    if (!filePath) {
      return location.uri;
    }
    return `${this.formatPathForHover(filePath)}:${location.range.start.line + 1}`;
  }

  private formatPathForHover(filePath: string): string {
    const absolutePath = path.resolve(filePath);
    const candidateRoots = [...this.workspaceRoots]
      .map((root) => path.resolve(root))
      .sort((a, b) => b.length - a.length);

    for (const root of candidateRoots) {
      if (absolutePath === root || absolutePath.startsWith(`${root}${path.sep}`)) {
        const relative = path.relative(root, absolutePath);
        return relative || path.basename(absolutePath);
      }
    }

    return absolutePath;
  }

  private formatOrgTimestamp(date: Date, active: boolean): string {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, "0");
    const day = String(date.getDate()).padStart(2, "0");
    const weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][date.getDay()];
    const body = `${year}-${month}-${day} ${weekday}`;
    return active ? `<${body}>` : `[${body}]`;
  }

  private extractLinkTargetAtPosition(text: string, pos: Position): string | null {
    return this.extractLinkAtPosition(text, pos)?.target ?? null;
  }

  private extractLinkAtPosition(text: string, pos: Position): { target: string; range: Range; targetRange: Range } | null {
    const lines = text.split("\n");
    const line = lines[pos.line] ?? "";
    const char = Math.max(0, Math.min(pos.character, line.length));

    const linkRegex = /\[\[([^\]\n]+?)\](?:\[[^\]\n]*\])?\]/g;
    let match: RegExpExecArray | null;
    while ((match = linkRegex.exec(line)) !== null) {
      const startChar = match.index;
      const endChar = startChar + match[0].length;
      if (char < startChar || char >= endChar) {
        continue;
      }

      const rawTarget = match[1] || "";
      const target = rawTarget.trim();
      if (!target) {
        return null;
      }

      const targetOffsetInMatch = match[0].indexOf(rawTarget);
      const targetStartChar = targetOffsetInMatch >= 0 ? startChar + targetOffsetInMatch : startChar + 2;
      const targetEndChar = targetStartChar + rawTarget.length;

      return {
        target,
        range: {
          start: { line: pos.line, character: startChar },
          end: { line: pos.line, character: endChar },
        },
        targetRange: {
          start: { line: pos.line, character: targetStartChar },
          end: { line: pos.line, character: targetEndChar },
        },
      };
    }

    return null;
  }

  private extractDocumentLinks(sourceUri: string, text: string): DocumentLink[] {
    const links: DocumentLink[] = [];
    const seen = new Set<string>();

    for (const link of this.findLinkTargets(text)) {
      const resolvedTarget = this.resolveDocumentLinkTarget(sourceUri, link.target);
      if (!resolvedTarget) {
        continue;
      }

      const key = `${link.range.start.line}:${link.range.start.character}:${link.range.end.line}:${link.range.end.character}:${resolvedTarget}`;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);

      links.push({
        range: link.range,
        target: resolvedTarget,
        tooltip: `Open ${link.target}`,
      });
    }

    return links;
  }

  private resolveDocumentLinkTarget(sourceUri: string, target: string): string | null {
    const normalizedTarget = target.trim();
    if (!normalizedTarget) {
      return null;
    }

    if (normalizedTarget.toLowerCase().startsWith("id:")) {
      const location = this.resolveIdDefinitionLocation(sourceUri, normalizedTarget);
      return location?.uri ?? null;
    }

    const absPath = this.normalizeFileLinkPath(sourceUri, normalizedTarget);
    if (absPath && fs.existsSync(absPath)) {
      return pathToFileURL(absPath).toString();
    }

    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(normalizedTarget)) {
      return normalizedTarget;
    }

    return null;
  }

  private resolveDefinitionLocation(sourceUri: string, target: string): Location | null {
    const idLocation = this.resolveIdDefinitionLocation(sourceUri, target);
    if (idLocation) {
      return idLocation;
    }

    const absPath = this.normalizeFileLinkPath(sourceUri, target);
    if (!absPath || !fs.existsSync(absPath)) return null;

    const uri = pathToFileURL(absPath).toString();
    return {
      uri,
      range: {
        start: { line: 0, character: 0 },
        end: { line: 0, character: 0 },
      },
    };
  }

  private resolveIdDefinitionLocation(sourceUri: string, target: string): Location | null {
    if (!target.toLowerCase().startsWith("id:")) return null;

    const targetId = this.normalizeIdValue(target);
    if (!targetId) return null;

    for (const doc of this.documents.values()) {
      const line = this.findIdLine(doc.text, targetId);
      if (line >= 0) {
        return {
          uri: doc.uri,
          range: {
            start: { line, character: 0 },
            end: { line, character: 0 },
          },
        };
      }
    }

    for (const root of this.buildDefinitionSearchRoots(sourceUri)) {
      for (const filePath of this.walkOrgFiles(root)) {
        if (!fs.existsSync(filePath)) continue;
        let text = "";
        try {
          text = fs.readFileSync(filePath, "utf8");
        } catch {
          continue;
        }
        const line = this.findIdLine(text, targetId);
        if (line >= 0) {
          return {
            uri: pathToFileURL(filePath).toString(),
            range: {
              start: { line, character: 0 },
              end: { line, character: 0 },
            },
          };
        }
      }
    }

    return null;
  }

  private extractReferenceQuery(sourceUri: string, text: string, position: Position): ReferenceQuery | null {
    const target = this.extractLinkTargetAtPosition(text, position);
    if (target) {
      if (target.toLowerCase().startsWith("id:")) {
        const targetId = this.normalizeIdValue(target);
        if (targetId) {
          return {
            kind: "id",
            targetId,
          };
        }
      }

      const targetPath = this.normalizeFileLinkPath(sourceUri, target);
      if (targetPath) {
        return {
          kind: "file",
          targetPath,
        };
      }
    }

    const lines = text.split("\n");
    const currentLine = lines[position.line] ?? "";
    const lineId = this.extractIdFromLine(currentLine);
    if (lineId) {
      return {
        kind: "id",
        targetId: lineId,
      };
    }

    return null;
  }

  private findReferenceLocations(sourceUri: string, query: ReferenceQuery, includeDeclaration: boolean): Location[] {
    const locations: Location[] = [];

    const pushLocation = (uri: string, range: Range) => {
      locations.push({
        uri,
        range,
      });
    };

    for (const doc of this.collectReferenceDocuments(sourceUri)) {
      const { uri, text } = doc;

      for (const link of this.findLinkTargets(text)) {
        if (query.kind === "id") {
          if (!link.target.toLowerCase().startsWith("id:")) {
            continue;
          }
          if (this.normalizeIdValue(link.target) !== query.targetId) {
            continue;
          }
          pushLocation(uri, link.range);
          continue;
        }

        const linkedPath = this.normalizeFileLinkPath(uri, link.target);
        if (linkedPath && linkedPath === query.targetPath) {
          pushLocation(uri, link.range);
        }
      }

      if (query.kind === "id" && includeDeclaration) {
        const definitionLines = this.findIdDefinitionLines(text, query.targetId);
        for (const line of definitionLines) {
          pushLocation(uri, {
            start: { line, character: 0 },
            end: { line, character: 0 },
          });
        }
      }
    }

    const deduped = new Map<string, Location>();
    for (const location of locations) {
      const key = `${location.uri}:${location.range.start.line}:${location.range.start.character}:${location.range.end.line}:${location.range.end.character}`;
      deduped.set(key, location);
    }

    return Array.from(deduped.values()).sort((a, b) => {
      if (a.uri !== b.uri) {
        return a.uri.localeCompare(b.uri);
      }
      if (a.range.start.line !== b.range.start.line) {
        return a.range.start.line - b.range.start.line;
      }
      return a.range.start.character - b.range.start.character;
    });
  }

  private extractRenameTarget(sourceUri: string, text: string, position: Position): RenameTarget | null {
    const link = this.extractLinkAtPosition(text, position);
    if (link && this.isPositionInRange(position, link.targetRange) && link.target.toLowerCase().startsWith("id:")) {
      const targetId = this.normalizeIdValue(link.target);
      if (targetId) {
        return {
          kind: "id",
          targetId,
          range: link.targetRange,
          placeholder: link.target,
        };
      }
    }

    const lines = text.split("\n");
    const line = lines[position.line] ?? "";
    const cursor = Math.max(0, Math.min(position.character, line.length));
    const match = line.match(/^(\s*:ID:\s*)(\S+)(\s*)$/i);
    if (!match) {
      return null;
    }

    const prefix = match[1] || "";
    const value = match[2] || "";
    const valueStart = prefix.length;
    const valueEnd = valueStart + value.length;
    if (cursor < valueStart || cursor > valueEnd) {
      return null;
    }

    const targetId = this.normalizeIdValue(value);
    if (!targetId) {
      return null;
    }

    return {
      kind: "id",
      targetId,
      range: {
        start: { line: position.line, character: valueStart },
        end: { line: position.line, character: valueEnd },
      },
      placeholder: value,
    };
  }

  private getLinkedEditingRanges(sourceUri: string, text: string, position: Position): LinkedEditingRanges | null {
    const target = this.extractRenameTarget(sourceUri, text, position);
    if (!target || target.kind !== "id") {
      return null;
    }

    const ranges: Range[] = [];
    const seen = new Set<string>();

    const addRange = (range: Range) => {
      const key = `${range.start.line}:${range.start.character}:${range.end.line}:${range.end.character}`;
      if (seen.has(key)) {
        return;
      }
      seen.add(key);
      ranges.push(range);
    };

    for (const link of this.findLinkTargets(text)) {
      if (!link.target.toLowerCase().startsWith("id:")) {
        continue;
      }
      if (this.normalizeIdValue(link.target) !== target.targetId) {
        continue;
      }
      addRange(link.targetRange);
    }

    for (const range of this.findIdDefinitionValueRanges(text, target.targetId)) {
      addRange(range);
    }

    if (ranges.length < 2) {
      return null;
    }

    ranges.sort((a, b) => {
      if (a.start.line !== b.start.line) {
        return a.start.line - b.start.line;
      }
      if (a.start.character !== b.start.character) {
        return a.start.character - b.start.character;
      }
      if (a.end.line !== b.end.line) {
        return a.end.line - b.end.line;
      }
      return a.end.character - b.end.character;
    });

    return {
      ranges,
      wordPattern: "[A-Za-z0-9:_-]+",
    };
  }

  private normalizeRenameIdInput(value: string): string | null {
    let normalized = value.trim();
    if (!normalized) {
      return null;
    }

    if (normalized.toLowerCase().startsWith("id:")) {
      normalized = normalized.slice(3);
    }

    if (!normalized || /\s/.test(normalized) || normalized.includes("[") || normalized.includes("]")) {
      return null;
    }

    return normalized.toLowerCase();
  }

  private buildRenameWorkspaceEdit(sourceUri: string, target: RenameTarget, newId: string): WorkspaceEdit | null {
    if (target.kind !== "id") {
      return null;
    }

    if (target.targetId === newId) {
      return { changes: {} };
    }

    const editsByUri = new Map<string, TextEdit[]>();
    const seenEdits = new Set<string>();
    const addEdit = (uri: string, edit: TextEdit) => {
      const key = `${uri}:${edit.range.start.line}:${edit.range.start.character}:${edit.range.end.line}:${edit.range.end.character}:${edit.newText}`;
      if (seenEdits.has(key)) {
        return;
      }
      seenEdits.add(key);

      const existing = editsByUri.get(uri);
      if (existing) {
        existing.push(edit);
      } else {
        editsByUri.set(uri, [edit]);
      }
    };

    for (const doc of this.collectReferenceDocuments(sourceUri)) {
      for (const link of this.findLinkTargets(doc.text)) {
        if (!link.target.toLowerCase().startsWith("id:")) {
          continue;
        }
        if (this.normalizeIdValue(link.target) !== target.targetId) {
          continue;
        }

        addEdit(doc.uri, {
          range: link.targetRange,
          newText: `id:${newId}`,
        });
      }

      for (const range of this.findIdDefinitionValueRanges(doc.text, target.targetId)) {
        addEdit(doc.uri, {
          range,
          newText: newId,
        });
      }
    }

    if (editsByUri.size === 0) {
      return null;
    }

    const changes: Record<string, TextEdit[]> = {};
    for (const [uri, edits] of editsByUri.entries()) {
      changes[uri] = edits.sort((a, b) => {
        if (a.range.start.line !== b.range.start.line) {
          return a.range.start.line - b.range.start.line;
        }
        return a.range.start.character - b.range.start.character;
      });
    }

    return { changes };
  }

  private collectReferenceDocuments(sourceUri: string): Array<{ uri: string; text: string }> {
    const documents: Array<{ uri: string; text: string }> = [];
    const seenUri = new Set<string>();
    const seenPath = new Set<string>();

    const addDocument = (uri: string, text: string) => {
      if (seenUri.has(uri)) {
        return;
      }
      seenUri.add(uri);
      documents.push({ uri, text });

      const filePath = this.filePathFromUri(uri);
      if (filePath) {
        seenPath.add(filePath);
      }
    };

    for (const doc of this.documents.values()) {
      addDocument(doc.uri, doc.text);
    }

    for (const root of this.buildDefinitionSearchRoots(sourceUri)) {
      for (const filePath of this.walkOrgFiles(root)) {
        if (!fs.existsSync(filePath)) {
          continue;
        }

        const resolvedPath = path.resolve(filePath);
        if (seenPath.has(resolvedPath)) {
          continue;
        }

        let text = "";
        try {
          text = fs.readFileSync(filePath, "utf8");
        } catch {
          continue;
        }

        addDocument(pathToFileURL(filePath).toString(), text);
      }
    }

    return documents;
  }

  private findLinkTargets(text: string): Array<{ target: string; range: Range; targetRange: Range }> {
    const links: Array<{ target: string; range: Range; targetRange: Range }> = [];
    const lines = text.split("\n");

    for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      const line = lines[lineIndex];
      const linkRegex = /\[\[([^\]\n]+?)\](?:\[[^\]\n]*\])?\]/g;
      let match: RegExpExecArray | null;
      while ((match = linkRegex.exec(line)) !== null) {
        const rawTarget = match[1] || "";
        const target = rawTarget.trim();
        if (!target) {
          continue;
        }

        const startChar = match.index;
        const endChar = startChar + match[0].length;
        const targetOffsetInMatch = match[0].indexOf(rawTarget);
        const targetStartChar = targetOffsetInMatch >= 0 ? startChar + targetOffsetInMatch : startChar + 2;
        const targetEndChar = targetStartChar + rawTarget.length;

        links.push({
          target,
          range: {
            start: { line: lineIndex, character: startChar },
            end: { line: lineIndex, character: endChar },
          },
          targetRange: {
            start: { line: lineIndex, character: targetStartChar },
            end: { line: lineIndex, character: targetEndChar },
          },
        });
      }
    }

    return links;
  }

  private findIdDefinitionLines(text: string, targetId: string): number[] {
    const lines = text.split("\n");
    const result: number[] = [];
    for (let i = 0; i < lines.length; i++) {
      const lineId = this.extractIdFromLine(lines[i]);
      if (lineId && lineId === targetId) {
        result.push(i);
      }
    }
    return result;
  }

  private findIdDefinitionValueRanges(text: string, targetId: string): Range[] {
    const lines = text.split("\n");
    const ranges: Range[] = [];

    for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      const line = lines[lineIndex];
      const match = line.match(/^(\s*:ID:\s*)(\S+)(\s*)$/i);
      if (!match) {
        continue;
      }

      const value = match[2] || "";
      if (this.normalizeIdValue(value) !== targetId) {
        continue;
      }

      const startChar = (match[1] || "").length;
      const endChar = startChar + value.length;
      ranges.push({
        start: { line: lineIndex, character: startChar },
        end: { line: lineIndex, character: endChar },
      });
    }

    return ranges;
  }

  private normalizeFileLinkPath(sourceUri: string, target: string): string | null {
    if (!sourceUri.startsWith("file://")) {
      return null;
    }

    let fileTarget = target.trim();
    if (fileTarget.toLowerCase().startsWith("file:")) {
      fileTarget = fileTarget.slice("file:".length);
    }

    if (!fileTarget) {
      return null;
    }

    const targetPathOnly = fileTarget.split("::")[0]?.trim() ?? "";
    if (!targetPathOnly) {
      return null;
    }

    // Ignore non-file link types (http:, mailto:, etc).
    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(targetPathOnly)) {
      return null;
    }

    const sourcePath = fileURLToPath(sourceUri);
    const baseDir = path.dirname(sourcePath);
    return path.resolve(baseDir, targetPathOnly);
  }

  private filePathFromUri(uri: string): string | null {
    if (!uri.startsWith("file://")) {
      return null;
    }
    try {
      return path.resolve(fileURLToPath(uri));
    } catch {
      return null;
    }
  }

  private buildDefinitionSearchRoots(sourceUri: string): string[] {
    const roots = new Set<string>();

    for (const root of this.workspaceRoots) {
      roots.add(root);
    }

    if (sourceUri.startsWith("file://")) {
      const sourcePath = fileURLToPath(sourceUri);
      const sourceDir = path.dirname(sourcePath);

      // Only scan the source file directory when the source file exists on disk.
      // This avoids pathological walks from virtual/non-existent URIs like file:///test.org.
      if (fs.existsSync(sourcePath)) {
        roots.add(sourceDir);
      }
    }

    return Array.from(roots);
  }

  private findIdLine(text: string, targetId: string): number {
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
      const lineId = this.extractIdFromLine(lines[i]);
      if (lineId && lineId === targetId) {
        return i;
      }
    }
    return -1;
  }

  private extractIdFromLine(line: string): string | null {
    const match = line.match(/^\s*:ID:\s*(\S+)\s*$/i);
    if (!match) return null;
    return this.normalizeIdValue(match[1]);
  }

  private normalizeIdValue(value: string): string {
    let normalized = value.trim();
    if (normalized.toLowerCase().startsWith("id:")) {
      normalized = normalized.slice(3);
    }
    return normalized.toLowerCase();
  }

  private walkOrgFiles(rootPath: string): string[] {
    if (!rootPath || !fs.existsSync(rootPath)) {
      return [];
    }

    const files: string[] = [];
    const stack = [rootPath];

    while (stack.length > 0) {
      const current = stack.pop()!;
      let stat: fs.Stats;
      try {
        stat = fs.statSync(current);
      } catch {
        continue;
      }

      if (stat.isFile()) {
        if (this.isOrgFile(current)) {
          files.push(current);
        }
        continue;
      }

      if (!stat.isDirectory()) {
        continue;
      }

      let entries: fs.Dirent[];
      try {
        entries = fs.readdirSync(current, { withFileTypes: true });
      } catch {
        continue;
      }

      entries.sort((a, b) => a.name.localeCompare(b.name));
      for (let i = entries.length - 1; i >= 0; i--) {
        const entry = entries[i];
        if (entry.isDirectory() && this.shouldSkipDirectory(entry.name)) {
          continue;
        }
        stack.push(path.join(current, entry.name));
      }
    }

    return files;
  }

  private shouldSkipDirectory(name: string): boolean {
    return name === ".git" || name === "node_modules" || name === "dist";
  }

  private isOrgFile(filePath: string): boolean {
    return filePath.endsWith(".org") || filePath.endsWith(".org2") || filePath.endsWith(".org_archive");
  }

  private extractWorkspaceRoots(params: any): string[] {
    const roots = new Set<string>();

    const addFileUri = (uri: string | undefined) => {
      if (!uri || !uri.startsWith("file://")) {
        return;
      }
      try {
        roots.add(fileURLToPath(uri));
      } catch {
        // Ignore malformed URI values.
      }
    };

    const addPath = (rootPath: string | undefined) => {
      if (!rootPath) return;
      roots.add(path.resolve(rootPath));
    };

    if (params && Array.isArray(params.workspaceFolders)) {
      for (const folder of params.workspaceFolders) {
        addFileUri(folder?.uri);
      }
    }

    if (params?.rootUri) {
      addFileUri(params.rootUri);
    }

    if (params?.rootPath) {
      addPath(params.rootPath);
    }

    return Array.from(roots);
  }

  private publishDiagnostics(uri: string): void {
    const doc = this.documents.get(uri);
    if (!doc) return;

    // Parse and collect diagnostics
    const result = parseOrgWithDiagnostics(doc.text);
    const tracker = new LineTracker(doc.text);

    const diagnostics: Diagnostic[] = result.diagnostics.map((parseErr) => {
      // Convert ParseError to LSP Diagnostic
      // LSP uses 0-based line/column indexing
      const lspLine = Math.max(0, parseErr.line - 1);
      const lspColumn = Math.max(0, parseErr.column - 1);
      const endChar = tracker.getLineLength(lspLine);

      return {
        range: {
          start: { line: lspLine, character: lspColumn },
          // Highlight from error column to end-of-line (keeps it visible without guessing a width).
          end: { line: lspLine, character: Math.max(lspColumn, endChar) },
        },
        severity: DiagnosticSeverity.Error,
        message: parseErr.message,
        code: "org2-parser",
      };
    });

    this.sendNotification("textDocument/publishDiagnostics", {
      uri,
      diagnostics,
    });
  }

  private inlineNodesToText(nodes: any[]): string {
    if (!nodes) return "";
    return nodes
      .map((node) => {
        if (node.type === "Text") return node.value;
        if (node.type === "Emphasis") return node.content;
        return "";
      })
      .join("");
  }

  private isPositionInRange(position: Position, range: Range): boolean {
    if (position.line < range.start.line || position.line > range.end.line) {
      return false;
    }

    if (position.line === range.start.line && position.character < range.start.character) {
      return false;
    }

    if (position.line === range.end.line && position.character > range.end.character) {
      return false;
    }

    return true;
  }

  private positionToOffset(text: string, pos: Position): number {
    const lines = text.split("\n");
    let offset = 0;
    for (let i = 0; i < pos.line; i++) {
      offset += (lines[i]?.length || 0) + 1;
    }
    offset += pos.character;
    return offset;
  }

  private sendResponse(id: number | string, result: any): void {
    const response = {
      jsonrpc: "2.0",
      id,
      result,
    };
    this.sendMessage(response);
  }

  private sendError(id: number | string | null, code: number, message: string): void {
    const response: any = {
      jsonrpc: "2.0",
      error: {
        code,
        message,
      },
    };
    if (id !== null && id !== undefined) {
      response.id = id;
    }
    this.sendMessage(response);
  }

  private sendNotification(method: string, params: any): void {
    const notification = {
      jsonrpc: "2.0",
      method,
      params,
    };
    this.sendMessage(notification);
  }

  private sendMessage(message: any): void {
    const content = JSON.stringify(message);
    const contentLength = Buffer.byteLength(content, "utf8");
    const headers = `Content-Length: ${contentLength}\r\n\r\n`;
    process.stdout.write(headers + content);
  }
}

async function main() {
  const server = new LSPServer();
  await server.start();
}

main().catch((e) => {
  process.stderr.write(`Fatal error: ${e.message}\n`);
  process.exit(1);
});
