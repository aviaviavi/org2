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

// Symbol kinds
const SymbolKind = {
  Struct: 23,
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
        this.sendResponse(id, {
          capabilities: {
            textDocumentSync: 1,
            documentSymbolProvider: true,
            foldingRangeProvider: true,
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
