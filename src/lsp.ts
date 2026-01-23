#!/usr/bin/env node

import * as fs from "node:fs";
import * as readline from "node:readline";
import {
  parseOrgToCanonicalAst,
  DocumentNode,
  HeadlineNode,
  Node,
  ListNode,
  BlockNode,
  SrcBlockNode,
  ListItemNode,
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
  kind: number; // SymbolKind
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
  File: 1,
  Module: 2,
  Namespace: 3,
  Package: 4,
  Class: 5,
  Method: 6,
  Property: 7,
  Field: 8,
  Constructor: 9,
  Enum: 10,
  Interface: 11,
  Function: 12,
  Variable: 13,
  Constant: 14,
  String: 15,
  Number: 16,
  Boolean: 17,
  Array: 18,
  Object: 19,
  Key: 20,
  Null: 21,
  EnumMember: 22,
  Struct: 23,
  Event: 24,
  Operator: 25,
  TypeParameter: 26,
};

const DiagnosticSeverity = {
  Error: 1,
  Warning: 2,
  Information: 3,
  Hint: 4,
};

// ============================================================================
// Line Tracking Helper
// ============================================================================

class LineTracker {
  private lines: string[];
  private lineOffsets: number[] = [];

  constructor(text: string) {
    this.lines = text.split("\n");
    let offset = 0;
    for (const line of this.lines) {
      this.lineOffsets.push(offset);
      offset += line.length + 1; // +1 for newline
    }
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

  findLineWithContent(pattern: string | RegExp, startLine = 0): number {
    for (let i = startLine; i < this.lines.length; i++) {
      const line = this.lines[i];
      if (typeof pattern === "string") {
        if (line.includes(pattern)) return i;
      } else {
        if (pattern.test(line)) return i;
      }
    }
    return -1;
  }
}

// ============================================================================
// LSP Server
// ============================================================================

class LSPServer {
  private documents: Map<string, TextDocument> = new Map();
  private messageId = 0;
  private initialized = false;

  async start(): Promise<void> {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
      terminal: false,
    });

    let buffer = "";

    const processData = () => {
      while (buffer.includes("\r\n\r\n")) {
        const headerEnd = buffer.indexOf("\r\n\r\n");
        const headers = buffer.substring(0, headerEnd);
        buffer = buffer.substring(headerEnd + 4);

        const lengthMatch = headers.match(/Content-Length: (\d+)/);
        if (!lengthMatch) continue;

        const contentLength = parseInt(lengthMatch[1], 10);
        if (buffer.length < contentLength) {
          // Put data back
          buffer = headers + "\r\n\r\n" + buffer;
          break;
        }

        const content = buffer.substring(0, contentLength);
        buffer = buffer.substring(contentLength);

        try {
          const message = JSON.parse(content);
          this.handleMessage(message);
        } catch (e) {
          this.sendError(0, -32700, "Parse error");
        }
      }
    };

    rl.on("line", (line: string) => {
      buffer += line + "\n";
      processData();
    });

    rl.on("close", () => {
      process.exit(0);
    });
  }

  private handleMessage(message: any): void {
    const { id, method, params } = message;

    try {
      if (method === "initialize") {
        this.initialized = true;
        this.sendResponse(id, {
          capabilities: {
            textDocumentSync: 1, // Full
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
              // Incremental change
              const { start, end } = change.range;
              const lines = doc.text.split("\n");
              const startOffset = this.positionToOffset(doc.text, start);
              const endOffset = this.positionToOffset(doc.text, end);
              doc.text = doc.text.substring(0, startOffset) + change.text + doc.text.substring(endOffset);
            } else {
              // Full document change
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
          try {
            const ast = parseOrgToCanonicalAst(doc.text);
            const symbols = this.extractSymbols(ast, doc.text);
            this.sendResponse(id, symbols);
          } catch (e) {
            this.sendResponse(id, []);
          }
        } else {
          this.sendResponse(id, []);
        }
      } else if (method === "textDocument/foldingRange") {
        const { textDocument } = params;
        const doc = this.documents.get(textDocument.uri);
        if (doc) {
          try {
            const ast = parseOrgToCanonicalAst(doc.text);
            const ranges = this.extractFoldingRanges(ast, doc.text);
            this.sendResponse(id, ranges);
          } catch (e) {
            this.sendResponse(id, []);
          }
        } else {
          this.sendResponse(id, []);
        }
      } else {
        // Unknown method
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

      // Find the line this headline starts on by searching for the title text
      // This is a heuristic since AST doesn't store line info
      const headlineMarker = "*".repeat(headline.level) + " ";
      const searchText = headlineMarker + titleText;

      // Find first line that matches headline pattern
      let headlineLine = 0;
      for (let i = 0; i < tracker.getLinesCount(); i++) {
        const line = tracker.getLine(i);
        if (line.includes(headlineMarker) && (titleText === "" || line.includes(titleText))) {
          headlineLine = i;
          break;
        }
      }

      // Find the end line (where this section ends)
      let endLine = headlineLine;
      let nextHeadlineFound = false;

      // Look for next headline at same or lower level
      for (let i = headlineLine + 1; i < tracker.getLinesCount(); i++) {
        const line = tracker.getLine(i);
        const match = line.match(/^(\*+) /);
        if (match) {
          const nextLevel = match[1].length;
          if (nextLevel <= headline.level) {
            endLine = i - 1;
            nextHeadlineFound = true;
            break;
          }
        }
      }

      if (!nextHeadlineFound) {
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

      // Extract child headlines
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
      for (const child of node.children || []) {
        this.extractFoldingRanges(child, text, ranges, tracker);
      }
    } else if (node.type === "Headline") {
      const headline = node as HeadlineNode;
      const titleText = this.inlineNodesToText(headline.title);
      const headlineMarker = "*".repeat(headline.level) + " ";

      // Find the line this headline starts on
      let headlineLine = 0;
      for (let i = 0; i < tracker.getLinesCount(); i++) {
        const line = tracker.getLine(i);
        if (line.includes(headlineMarker) && (titleText === "" || line.includes(titleText))) {
          headlineLine = i;
          break;
        }
      }

      // Find the end line
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
        // Check if there are non-headline children
        for (let i = headlineLine + 1; i < tracker.getLinesCount(); i++) {
          const line = tracker.getLine(i);
          if (line.match(/^(\*+) /)) {
            endLine = i - 1;
            break;
          }
        }
        if (endLine === headlineLine) {
          endLine = tracker.getLinesCount() - 1;
        }
      }

      if (endLine > headlineLine) {
        ranges.push({
          startLine: headlineLine,
          endLine,
          kind: "region",
        });
      }

      // Process children
      for (const child of headline.children || []) {
        this.extractFoldingRanges(child, text, ranges, tracker);
      }
    } else if (node.type === "SrcBlock" || node.type === "Block") {
      const block = node as any;
      if (block.terminated) {
        // Find begin and end lines
        const beginKeyword = node.type === "SrcBlock" ? "BEGIN_SRC" : `BEGIN_${block.kind.toUpperCase()}`;
        const endKeyword = node.type === "SrcBlock" ? "END_SRC" : `END_${block.kind.toUpperCase()}`;

        const beginLine = tracker.findLineWithContent(beginKeyword);
        const endLine = tracker.findLineWithContent(endKeyword, beginLine + 1);

        if (beginLine >= 0 && endLine > beginLine) {
          ranges.push({
            startLine: beginLine,
            endLine,
            kind: "region",
          });
        }
      }
    } else if (node.type === "List") {
      // Find the first and last list item lines
      const list = node as ListNode;
      // Since we don't have precise line tracking, we'll estimate
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

    // Process children for other node types
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

    const diagnostics: Diagnostic[] = [];

    try {
      parseOrgToCanonicalAst(doc.text);
    } catch (e: any) {
      // Parser errors - would create diagnostics here
      // For now, best-effort parsing
    }

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
      offset += (lines[i]?.length || 0) + 1; // +1 for newline
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
    if (id !== null) {
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
    const headers = `Content-Length: ${Buffer.byteLength(content, "utf8")}\r\n\r\n`;
    process.stdout.write(headers + content);
  }
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  const server = new LSPServer();
  await server.start();
}

main().catch((e) => {
  console.error("Fatal error:", e);
  process.exit(1);
});
