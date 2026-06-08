import { parseOrgWithDiagnostics } from "./parser.js";

export interface Position {
  line: number;
  character: number;
}

export interface Range {
  start: Position;
  end: Position;
}

export interface Diagnostic {
  range: Range;
  severity: number;
  message: string;
  code?: string;
}

export interface PublishDiagnosticsParams {
  uri: string;
  diagnostics: Diagnostic[];
}

const DiagnosticSeverity = {
  Error: 1,
} as const;

class DiagnosticLineTracker {
  private lines: string[];

  constructor(text: string) {
    this.lines = text.split("\n");
  }

  getLineLength(lineNum: number): number {
    return this.lines[lineNum]?.length || 0;
  }
}

/**
 * Build the LSP publishDiagnostics payload for org parser diagnostics.
 *
 * LSP positions are 0-based, while parser errors are 1-based.
 */
export function buildPublishDiagnosticsParams(uri: string, text: string): PublishDiagnosticsParams {
  const result = parseOrgWithDiagnostics(text);
  const tracker = new DiagnosticLineTracker(text);

  const diagnostics: Diagnostic[] = result.diagnostics.map((parseErr) => {
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

  return { uri, diagnostics };
}
