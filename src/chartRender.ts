import { parseOrgToCanonicalAst } from "./parser.js";
import { isOrgTableDataLine, isOrgTableHline, parseOrgTableDataLine } from "./orgTableData.js";

export type ChartRenderFormat = "svg";

export type ChartRenderSource = {
  file?: string;
  line: number;
  endLine?: number;
  blockId?: string;
  dataBlockId?: string;
  chartLine?: number;
  chartEndLine?: number;
  kind: "table";
};

export type ChartRenderDiagnostic = {
  severity: "error" | "warning";
  message: string;
  source?: {
    line?: number;
    blockId?: string;
  };
};

export type ChartRenderResult = {
  ok: boolean;
  format: ChartRenderFormat;
  artifact?: string;
  svg?: string;
  presentation?: ChartPresentation;
  source?: ChartRenderSource;
  diagnostics: ChartRenderDiagnostic[];
};

export type ChartTableData = {
  headers: string[];
  rows: string[][];
};

type Keyword = {
  key: string;
  value: string;
  line: number;
};

type ChartType = "bar" | "line" | "histogram";
type ChartSort = "none" | "x-asc" | "x-desc" | "y-asc" | "y-desc";
export type ChartSize = "compact" | "medium" | "wide";

export type ChartPresentation = {
  size: ChartSize;
  height: number;
  interactive: boolean;
};

type ChartSpec = {
  type: ChartType;
  x: string;
  y: string;
  title?: string;
  sort: ChartSort;
  presentation: ChartPresentation;
};

type ChartDataSource =
  | { kind: "previous-table" }
  | { kind: "named-table"; blockId: string };

type ChartCandidate = {
  source: ChartRenderSource;
  spec: ChartSpec;
  headers: string[];
  rows: string[][];
  diagnostics: ChartRenderDiagnostic[];
};

export type RenderChartOptions = {
  file?: string;
  line?: number;
  blockId?: string;
  outputPath?: string;
  sourceLineOffset?: number;
  tableDataByLine?: ReadonlyMap<number, ChartTableData>;
};

const AFFILIATED_KEYS = new Set(["NAME", "CAPTION", "PLOT", "CHART", "DATASET", "VIEW", "RESULTS", "HEADER", "HEADERS"]);

function diagnostic(message: string, source?: { line?: number; blockId?: string }, severity: "error" | "warning" = "error"): ChartRenderDiagnostic {
  return { severity, message, ...(source ? { source } : {}) };
}

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function parseKeyword(line: string, lineNumber: number): Keyword | null {
  const match = /^(\s*)#\+([A-Za-z0-9_]+):[ \t]*(.*)$/.exec(line);
  if (!match) return null;
  const key = String(match[2] || "").toUpperCase();
  if (!AFFILIATED_KEYS.has(key) && !key.startsWith("ATTR_")) return null;
  return {
    key,
    value: String(match[3] || "").trim(),
    line: lineNumber,
  };
}

function parseTable(lines: string[]): { headers: string[]; rows: string[][]; diagnostics: ChartRenderDiagnostic[] } {
  const parsed = lines.map(parseOrgTableDataLine).filter((row): row is string[] => Array.isArray(row));
  const diagnostics: ChartRenderDiagnostic[] = [];
  const firstDataRow = parsed.find((row) => !isOrgTableHline(row));
  if (!firstDataRow) {
    return { headers: [], rows: [], diagnostics: [diagnostic("Chart table has no header row")] };
  }

  const headerIndex = parsed.indexOf(firstDataRow);
  const rows = parsed.slice(headerIndex + 1).filter((row) => !isOrgTableHline(row));
  if (rows.length === 0) diagnostics.push(diagnostic("Chart table has no data rows"));
  return { headers: firstDataRow, rows, diagnostics };
}

function parseChartSpec(raw: string, title?: string): { spec?: ChartSpec; diagnostics: ChartRenderDiagnostic[] } {
  const tokens = raw.split(/\s+/).filter(Boolean);
  const diagnostics: ChartRenderDiagnostic[] = [];
  const rawType = String(tokens.shift() || "bar").toLowerCase();
  const type = rawType === "line" ? "line" : rawType === "bar" ? "bar" : rawType === "histogram" ? "histogram" : undefined;
  if (!type) diagnostics.push(diagnostic(`Unsupported chart type "${rawType}". Supported types: bar, line, histogram`));

  const params = new Map<string, string>();
  for (const token of tokens) {
    const match = /^([A-Za-z0-9_-]+)=(.+)$/.exec(token);
    if (match) params.set(String(match[1] || "").toLowerCase(), String(match[2] || ""));
  }

  const x = params.get("x") || "";
  const y = params.get("y") || "";
  const sortRaw = (params.get("sort") || "none").toLowerCase();
  const sort = parseChartSort(sortRaw);
  const sizeRaw = (params.get("size") || "medium").toLowerCase();
  const size = parseChartSize(sizeRaw);
  const defaultHeight = size === "compact" ? 300 : size === "wide" ? 420 : 360;
  const rawHeight = params.get("height");
  const parsedHeight = rawHeight ? Number.parseInt(rawHeight, 10) : defaultHeight;
  const height = Number.isFinite(parsedHeight) && parsedHeight >= 220 && parsedHeight <= 720
    ? parsedHeight
    : undefined;
  const interactiveRaw = (params.get("interactive") || "true").toLowerCase();
  const interactive = parseBoolean(interactiveRaw);
  if (!x) diagnostics.push(diagnostic("Chart spec requires x=column"));
  if (!y) diagnostics.push(diagnostic("Chart spec requires y=column"));
  if (!sort) diagnostics.push(diagnostic(`Unsupported chart sort "${sortRaw}". Supported sorts: none, x-asc, x-desc, y-asc, y-desc`));
  if (!size) diagnostics.push(diagnostic(`Unsupported chart size "${sizeRaw}". Supported sizes: compact, medium, wide`));
  if (!height) diagnostics.push(diagnostic("Chart height must be an integer from 220 to 720 pixels"));
  if (interactive === undefined) diagnostics.push(diagnostic("Chart interactive must be true or false"));
  if (!type || !x || !y || !sort || !size || !height || interactive === undefined) return { diagnostics };
  return {
    spec: {
      type,
      x,
      y,
      sort,
      presentation: { size, height, interactive },
      ...(title ? { title } : {}),
    },
    diagnostics,
  };
}

function parseChartSize(raw: string): ChartSize | undefined {
  if (raw === "compact" || raw === "small") return "compact";
  if (raw === "medium" || raw === "default") return "medium";
  if (raw === "wide" || raw === "large" || raw === "full") return "wide";
  return undefined;
}

function parseBoolean(raw: string): boolean | undefined {
  if (raw === "true" || raw === "yes" || raw === "on" || raw === "1") return true;
  if (raw === "false" || raw === "no" || raw === "off" || raw === "0") return false;
  return undefined;
}

function parseChartSort(raw: string): ChartSort | undefined {
  const normalized = raw.toLowerCase();
  if (normalized === "" || normalized === "none" || normalized === "source" || normalized === "input") return "none";
  if (normalized === "x" || normalized === "x-asc" || normalized === "label" || normalized === "label-asc") return "x-asc";
  if (normalized === "x-desc" || normalized === "label-desc") return "x-desc";
  if (normalized === "y" || normalized === "y-asc" || normalized === "value" || normalized === "value-asc") return "y-asc";
  if (normalized === "y-desc" || normalized === "value-desc") return "y-desc";
  return undefined;
}

function keywordValue(keywords: Keyword[], key: string): string | undefined {
  return keywords.find((keyword) => keyword.key === key)?.value;
}

type ChartBlockOpener = {
  afterOpener: string;
  isEnd(line: string): boolean;
};

function parseChartBlockOpener(line: string): ChartBlockOpener | null {
  const match = /^\s*```($|[^`].*)$/.exec(line);
  if (match) {
    const afterFence = String(match[1] || "").trim();
    if (!/^(chart|plot)(?:\s|$)/i.test(afterFence)) return null;
    return {
      afterOpener: afterFence,
      isEnd: (candidate) => /^\s*```\s*$/.test(candidate),
    };
  }

  const source = /^\s*#\+begin_src\s+(chart|plot)(?:\s+(.*?))?\s*$/i.exec(line);
  if (source) {
    const kind = String(source[1] || "chart").toLowerCase();
    const args = String(source[2] || "").trim();
    return {
      afterOpener: [kind, args].filter(Boolean).join(" "),
      isEnd: (candidate) => /^\s*#\+end_src\s*$/i.test(candidate),
    };
  }

  const special = /^\s*#\+begin_(chart|plot)\b(.*?)\s*$/i.exec(line);
  if (special) {
    const kind = String(special[1] || "chart").toLowerCase();
    const args = String(special[2] || "").trim();
    return {
      afterOpener: [kind, args].filter(Boolean).join(" "),
      isEnd: (candidate) => new RegExp(`^\\s*#\\+end_${kind}\\s*$`, "i").test(candidate),
    };
  }

  return null;
}

type FencedChartBlock = {
  raw: string;
  title?: string;
  source?: string;
  startLine: number;
  endLine: number;
};

type ParsedFencedChartSpec = {
  raw: string;
  title?: string;
  source?: string;
};

function parseFencedChartBlock(lines: string[], startIndex: number): FencedChartBlock | null {
  const opener = lines[startIndex] || "";
  const parsedOpener = parseChartBlockOpener(opener);
  if (!parsedOpener) return null;

  const openerRest = parsedOpener.afterOpener;
  const bodyLines: string[] = [];
  let i = startIndex + 1;
  while (i < lines.length) {
    const line = lines[i] || "";
    if (parsedOpener.isEnd(line)) {
      const parsed = parseFencedChartSpec(openerRest, bodyLines);
      return { raw: parsed.raw.trim(), ...(parsed.title ? { title: parsed.title } : {}), ...(parsed.source ? { source: parsed.source } : {}), startLine: startIndex + 1, endLine: i + 1 };
    }
    bodyLines.push(line);
    i++;
  }

  const parsed = parseFencedChartSpec(openerRest, bodyLines);
  return { raw: parsed.raw.trim(), ...(parsed.title ? { title: parsed.title } : {}), ...(parsed.source ? { source: parsed.source } : {}), startLine: startIndex + 1, endLine: lines.length };
}

function parseFencedChartSpec(openerRest: string, bodyLines: string[]): ParsedFencedChartSpec {
  const openerTokens = openerRest.split(/\s+/).filter(Boolean);
  const kind = openerTokens.shift()?.toLowerCase();
  const openerArgs = kind === "chart" || kind === "plot" ? openerTokens : [];
  const firstArg = String(openerArgs[0] || "").trim();
  const bodyParams = new Map<string, string>();

  for (const line of bodyLines) {
    const match = /^\s*([A-Za-z0-9_-]+)\s*[:=]\s*(.*?)\s*$/.exec(line);
    if (!match) continue;
    bodyParams.set(String(match[1] || "").toLowerCase(), String(match[2] || ""));
  }

  const type = firstArg && !firstArg.includes("=") ? firstArg : bodyParams.get("type") || bodyParams.get("chart") || "bar";
  const tokens = [type];
  const x = bodyParams.get("x");
  const y = bodyParams.get("y");
  const sort = bodyParams.get("sort");
  const title = bodyParams.get("title");
  const source = bodyParams.get("source");
  const size = bodyParams.get("size");
  const height = bodyParams.get("height");
  const interactive = bodyParams.get("interactive");

  if (x) tokens.push(`x=${x}`);
  if (y) tokens.push(`y=${y}`);
  if (sort) tokens.push(`sort=${sort}`);
  if (size) tokens.push(`size=${size}`);
  if (height) tokens.push(`height=${height}`);
  if (interactive) tokens.push(`interactive=${interactive}`);

  for (const arg of openerArgs.slice(firstArg && !firstArg.includes("=") ? 1 : 0)) {
    if (!/^source=/i.test(arg)) tokens.push(arg);
  }

  const argSource = openerArgs.map((arg) => /^source=(.+)$/i.exec(arg)?.[1]).find((value): value is string => Boolean(value));
  return { raw: tokens.join(" "), ...(title ? { title } : {}), ...(source || argSource ? { source: source || argSource } : {}) };
}

function parseChartSource(rawSource: string | undefined): { source: ChartDataSource; diagnostics: ChartRenderDiagnostic[] } {
  if (!rawSource) return { source: { kind: "previous-table" }, diagnostics: [] };

  const source = rawSource.trim();
  const normalized = source.toLowerCase();
  if (normalized === "previous-table" || normalized === "prev-table" || normalized === "table" || normalized === "this-table" || normalized === "above") {
    return { source: { kind: "previous-table" }, diagnostics: [] };
  }

  const named = /^(?:table|block|result|results):(.+)$/i.exec(source)?.[1] || /^#(.+)$/.exec(source)?.[1] || source;
  const blockId = named.trim();
  if (!blockId) {
    return { source: { kind: "previous-table" }, diagnostics: [diagnostic("Chart source cannot be empty")] };
  }
  return { source: { kind: "named-table", blockId }, diagnostics: [] };
}

function parseChartSpecWithFencedSource(raw: string, rawSource?: string, title?: string): { spec?: ChartSpec; source: ChartDataSource; diagnostics: ChartRenderDiagnostic[] } {
  const tokens = raw.split(/\s+/).filter(Boolean);
  const filteredTokens: string[] = [];
  const diagnostics: ChartRenderDiagnostic[] = [];
  let sourceValue = rawSource;

  for (const token of tokens) {
    const match = /^source=(.+)$/i.exec(token);
    if (!match) {
      filteredTokens.push(token);
      continue;
    }

    sourceValue = String(match[1] || "");
  }

  const parsedSource = parseChartSource(sourceValue);
  const parsed = parseChartSpec(filteredTokens.join(" "), title);
  return { spec: parsed.spec, source: parsedSource.source, diagnostics: [...diagnostics, ...parsedSource.diagnostics, ...parsed.diagnostics] };
}

type ParsedTableBlock = {
  source: ChartRenderSource;
  headers: string[];
  rows: string[][];
  diagnostics: ChartRenderDiagnostic[];
};

function candidateFromTable(table: ParsedTableBlock, spec: ChartSpec | undefined, diagnostics: ChartRenderDiagnostic[], source?: Partial<ChartRenderSource>): ChartCandidate {
  return {
    source: { ...table.source, ...source },
    spec: spec || { type: "bar", x: "", y: "", sort: "none", presentation: { size: "medium", height: 360, interactive: true } },
    headers: table.headers,
    rows: table.rows,
    diagnostics: [...diagnostics, ...table.diagnostics],
  };
}

function tableDataOverride(
  tableStartLine: number,
  tableLines: string[],
  tableDataByLine?: ReadonlyMap<number, ChartTableData>,
): { headers: string[]; rows: string[][]; diagnostics: ChartRenderDiagnostic[] } | undefined {
  if (!tableDataByLine) return parseTable(tableLines);
  const table = tableDataByLine.get(tableStartLine);
  if (!table) return undefined;
  return {
    headers: table.headers,
    rows: table.rows,
    diagnostics: table.rows.length > 0 ? [] : [diagnostic("Chart table has no data rows")],
  };
}

function collectNamedTables(
  lines: string[],
  file?: string,
  tableDataByLine?: ReadonlyMap<number, ChartTableData>,
): Map<string, ParsedTableBlock> {
  const tables = new Map<string, ParsedTableBlock>();
  let pending: Keyword[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] || "";
    const keyword = parseKeyword(line, i + 1);
    if (keyword) {
      pending.push(keyword);
      i++;
      continue;
    }

    if (isOrgTableDataLine(line)) {
      const tableStartLine = i + 1;
      const tableLines: string[] = [];
      while (i < lines.length && isOrgTableDataLine(lines[i] || "")) {
        tableLines.push(lines[i] || "");
        i++;
      }

      const name = keywordValue(pending, "NAME");
      if (name) {
        const parsedTable = tableDataOverride(tableStartLine, tableLines, tableDataByLine);
        if (parsedTable) {
          tables.set(name, {
            source: { ...(file ? { file } : {}), line: tableStartLine, endLine: i, blockId: name, kind: "table" },
            headers: parsedTable.headers,
            rows: parsedTable.rows,
            diagnostics: parsedTable.diagnostics,
          });
        }
      }
      pending = [];
      continue;
    }

    if (line.trim() !== "") pending = [];
    i++;
  }

  return tables;
}

function collectChartCandidates(
  raw: string,
  file?: string,
  tableDataByLine?: ReadonlyMap<number, ChartTableData>,
): ChartCandidate[] {
  // Parse first so malformed syntax still goes through the canonical parser in this API path.
  parseOrgToCanonicalAst(raw);

  const lines = raw.replace(/\r\n/g, "\n").split("\n");
  const candidates: ChartCandidate[] = [];
  const namedTables = collectNamedTables(lines, file, tableDataByLine);
  let previousTable: ParsedTableBlock | undefined;
  let pending: Keyword[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] || "";
    const keyword = parseKeyword(line, i + 1);
    if (keyword) {
      pending.push(keyword);
      i++;
      continue;
    }

    if (isOrgTableDataLine(line)) {
      const tableStartLine = i + 1;
      const tableLines: string[] = [];
      while (i < lines.length && isOrgTableDataLine(lines[i] || "")) {
        tableLines.push(lines[i] || "");
        i++;
      }
      const tableEndLine = i;

      const chartRaw = keywordValue(pending, "CHART") || keywordValue(pending, "PLOT");
      const name = keywordValue(pending, "NAME");
      const caption = keywordValue(pending, "CAPTION");
      const parsedTable = tableDataOverride(tableStartLine, tableLines, tableDataByLine);
      if (!parsedTable) {
        previousTable = undefined;
        pending = [];
        continue;
      }
      const table: ParsedTableBlock = {
        source: { ...(file ? { file } : {}), line: tableStartLine, endLine: tableEndLine, ...(name ? { blockId: name } : {}), kind: "table" },
        headers: parsedTable.headers,
        rows: parsedTable.rows,
        diagnostics: parsedTable.diagnostics,
      };
      previousTable = table;
      if (name) namedTables.set(name, table);
      let chartEndLine = tableEndLine;
      let fencedChart: FencedChartBlock | null = null;
      if (!chartRaw) {
        let nextIndex = i;
        while (nextIndex < lines.length && String(lines[nextIndex] || "").trim() === "") nextIndex++;
        fencedChart = parseFencedChartBlock(lines, nextIndex);
        if (fencedChart) {
          chartEndLine = fencedChart.endLine;
          i = nextIndex + (fencedChart.endLine - fencedChart.startLine + 1);
        }
      }
      const effectiveChartRaw = chartRaw || fencedChart?.raw;
      if (chartRaw) {
        const parsedSpec = parseChartSpec(chartRaw, caption);
        candidates.push(candidateFromTable(table, parsedSpec.spec, parsedSpec.diagnostics));
      } else if (effectiveChartRaw) {
        const parsedSpec = parseChartSpecWithFencedSource(effectiveChartRaw, fencedChart?.source, caption || fencedChart?.title);
        if (parsedSpec.source.kind === "named-table") {
          const sourcedTable = namedTables.get(parsedSpec.source.blockId);
          if (sourcedTable) {
            candidates.push(candidateFromTable(sourcedTable, parsedSpec.spec, parsedSpec.diagnostics, {
              ...(name ? { blockId: name, dataBlockId: sourcedTable.source.blockId } : {}),
              chartLine: fencedChart?.startLine,
              chartEndLine: fencedChart?.endLine,
            }));
          } else {
            candidates.push({
              source: { ...(file ? { file } : {}), line: fencedChart?.startLine || tableStartLine, endLine: fencedChart?.endLine || chartEndLine, ...(name ? { blockId: name } : {}), kind: "table" },
              spec: parsedSpec.spec || { type: "bar", x: "", y: "", sort: "none", presentation: { size: "medium", height: 360, interactive: true } },
              headers: [],
              rows: [],
              diagnostics: [
                ...parsedSpec.diagnostics,
                diagnostic(`No table found for chart source "${parsedSpec.source.blockId}"`, { line: fencedChart?.startLine, ...(name ? { blockId: name } : {}) }),
              ],
            });
          }
        } else {
          candidates.push(candidateFromTable(table, parsedSpec.spec, parsedSpec.diagnostics, { endLine: chartEndLine, ...(fencedChart ? { chartLine: fencedChart.startLine, chartEndLine: fencedChart.endLine } : {}) }));
        }
      }

      pending = [];
      continue;
    }

    const fencedChart = parseFencedChartBlock(lines, i);
    if (fencedChart) {
      const name = keywordValue(pending, "NAME");
      const caption = keywordValue(pending, "CAPTION") || fencedChart.title;
      const parsedSpec = parseChartSpecWithFencedSource(fencedChart.raw, fencedChart.source, caption);
      const table = parsedSpec.source.kind === "named-table" ? namedTables.get(parsedSpec.source.blockId) : previousTable;
      const diagnostics = [...parsedSpec.diagnostics];
      if (!table) {
        diagnostics.push(diagnostic(
          parsedSpec.source.kind === "named-table"
            ? `No table found for chart source "${parsedSpec.source.blockId}"`
            : "No previous table found for chart source",
          { line: fencedChart.startLine, ...(name ? { blockId: name } : {}) },
        ));
        candidates.push({
          source: { ...(file ? { file } : {}), line: fencedChart.startLine, endLine: fencedChart.endLine, ...(name ? { blockId: name } : {}), kind: "table" },
          spec: parsedSpec.spec || { type: "bar", x: "", y: "", sort: "none", presentation: { size: "medium", height: 360, interactive: true } },
          headers: [],
          rows: [],
          diagnostics,
        });
      } else {
        candidates.push(candidateFromTable(table, parsedSpec.spec, diagnostics, {
          ...(name ? { blockId: name, dataBlockId: table.source.blockId } : {}),
          chartLine: fencedChart.startLine,
          chartEndLine: fencedChart.endLine,
        }));
      }
      pending = [];
      i = fencedChart.endLine;
      continue;
    }

    if (line.trim() !== "") pending = [];
    i++;
  }

  return candidates;
}

function selectCandidate(candidates: ChartCandidate[], opts: RenderChartOptions): ChartCandidate | undefined {
  if (opts.blockId) {
    return candidates.find((candidate) => candidate.source.blockId === opts.blockId);
  }
  if (opts.line && opts.line > 0) {
    const line = opts.line;
    return candidates.find((candidate) => line >= candidate.source.line && line <= (candidate.source.endLine || candidate.source.line))
      || candidates.find((candidate) => candidate.source.chartLine && line >= candidate.source.chartLine && line <= (candidate.source.chartEndLine || candidate.source.chartLine))
      || candidates.find((candidate) => (candidate.source.chartLine || candidate.source.line) >= line);
  }
  return candidates[0];
}

function offsetChartSource(source: ChartRenderSource, offset: number): ChartRenderSource {
  if (offset <= 0) return source;
  return {
    ...source,
    line: source.line + offset,
    ...(source.endLine ? { endLine: source.endLine + offset } : {}),
    ...(source.chartLine ? { chartLine: source.chartLine + offset } : {}),
    ...(source.chartEndLine ? { chartEndLine: source.chartEndLine + offset } : {}),
  };
}

function columnIndex(headers: string[], column: string): number {
  const lower = column.toLowerCase();
  return headers.findIndex((header) => header.toLowerCase() === lower);
}

function niceTickStep(span: number, targetTicks = 4): number {
  const rough = Math.max(Number.EPSILON, span / Math.max(1, targetTicks));
  const magnitude = 10 ** Math.floor(Math.log10(rough));
  const normalized = rough / magnitude;
  const factor = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10;
  return factor * magnitude;
}

function formatTick(value: number, step: number): string {
  if (Number.isInteger(value)) return value.toFixed(0);
  const digits = step >= 1 ? 1 : Math.min(3, Math.max(1, Math.ceil(-Math.log10(step))));
  return value.toFixed(digits).replace(/\.0+$/, "");
}

function renderSvg(candidate: ChartCandidate): { svg?: string; diagnostics: ChartRenderDiagnostic[] } {
  const diagnostics = [...candidate.diagnostics];
  const xIndex = columnIndex(candidate.headers, candidate.spec.x);
  const yIndex = columnIndex(candidate.headers, candidate.spec.y);
  if (xIndex < 0) diagnostics.push(diagnostic(`Unknown x column "${candidate.spec.x}"`, { line: candidate.source.line, blockId: candidate.source.blockId }));
  if (yIndex < 0) diagnostics.push(diagnostic(`Unknown y column "${candidate.spec.y}"`, { line: candidate.source.line, blockId: candidate.source.blockId }));
  if (xIndex < 0 || yIndex < 0) return { diagnostics };

  const points = candidate.rows.map((row) => ({
    label: String(row[xIndex] || ""),
    rawValue: String(row[yIndex] || ""),
    value: Number.parseFloat(String(row[yIndex] || "").replace(/,/g, "")),
  }));
  const invalid = points.find((point) => !Number.isFinite(point.value));
  if (invalid) {
    diagnostics.push(diagnostic(`Non-numeric y value "${invalid.rawValue}" in column "${candidate.spec.y}"`, { line: candidate.source.line, blockId: candidate.source.blockId }));
    return { diagnostics };
  }
  if (points.length === 0) return { diagnostics };

  const sortedPoints = [...points];
  const compareLabels = (a: string, b: string): number => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
  if (candidate.spec.sort === "x-asc") {
    sortedPoints.sort((a, b) => compareLabels(a.label, b.label));
  } else if (candidate.spec.sort === "x-desc") {
    sortedPoints.sort((a, b) => compareLabels(b.label, a.label));
  } else if (candidate.spec.sort === "y-asc") {
    sortedPoints.sort((a, b) => a.value - b.value || compareLabels(a.label, b.label));
  } else if (candidate.spec.sort === "y-desc") {
    sortedPoints.sort((a, b) => b.value - a.value || compareLabels(a.label, b.label));
  }

  const width = 720;
  const height = candidate.spec.presentation.height;
  const margin = { top: candidate.spec.title ? 48 : 20, right: 22, bottom: 72, left: 58 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const rawMaxValue = Math.max(0, ...sortedPoints.map((point) => point.value));
  const rawMinValue = Math.min(0, ...sortedPoints.map((point) => point.value));
  const rawSpan = Math.max(1, rawMaxValue - rawMinValue);
  const tickStep = niceTickStep(rawSpan);
  const minValue = Math.floor(rawMinValue / tickStep) * tickStep;
  const maxValue = Math.max(tickStep, Math.ceil(rawMaxValue / tickStep) * tickStep);
  const span = maxValue - minValue;
  const yFor = (value: number): number => margin.top + plotHeight - ((value - minValue) / span) * plotHeight;
  const zeroY = yFor(0);
  const axisColor = "var(--org2-chart-axis, #334155)";
  const gridColor = "var(--org2-chart-grid, #d7dee8)";
  const markColor = "var(--org2-chart-mark, #2563eb)";
  const labelColor = "var(--org2-chart-label, #475569)";

  const labelEvery = Math.max(1, Math.ceil(sortedPoints.length / 7));
  const labels = sortedPoints.map((point, index) => {
    if (index % labelEvery !== 0 && index !== sortedPoints.length - 1) return "";
    const x = margin.left + (sortedPoints.length === 1 ? plotWidth / 2 : (plotWidth * index) / (sortedPoints.length - 1));
    return `<text x="${x.toFixed(1)}" y="${height - 38}" font-size="11" fill="${labelColor}" text-anchor="end" transform="rotate(-28 ${x.toFixed(1)} ${height - 38})">${escapeXml(point.label)}</text>`;
  }).filter(Boolean);

  const tickValues: number[] = [];
  for (let value = minValue; value <= maxValue + tickStep / 2 && tickValues.length < 12; value += tickStep) {
    tickValues.push(value);
  }
  const yTicks = tickValues.map((value) => {
    const y = yFor(value);
    return `<line x1="${margin.left}" y1="${y.toFixed(1)}" x2="${width - margin.right}" y2="${y.toFixed(1)}" stroke="${gridColor}" stroke-width="1" vector-effect="non-scaling-stroke"/><text x="${margin.left - 10}" y="${(y + 4).toFixed(1)}" font-size="11" fill="${labelColor}" text-anchor="end">${formatTick(value, tickStep)}</text>`;
  });

  const markAttributes = (point: { label: string; value: number }, x: number): string => {
    const label = `${point.label}: ${point.value}`;
    return `class="org2-chart-mark" data-org2-chart-mark="true" data-label="${escapeXml(point.label)}" data-value="${point.value}" data-chart-x="${x.toFixed(1)}" role="graphics-symbol" aria-label="${escapeXml(label)}" tabindex="0"`;
  };

  const marks = candidate.spec.type === "bar" || candidate.spec.type === "histogram"
    ? sortedPoints.map((point, index) => {
        const band = plotWidth / Math.max(1, sortedPoints.length);
        const barWidth = Math.max(8, band * 0.62);
        const x = margin.left + band * index + (band - barWidth) / 2;
        const y = yFor(Math.max(0, point.value));
        const h = Math.abs(zeroY - yFor(point.value));
        return `<rect ${markAttributes(point, x + barWidth / 2)} x="${x.toFixed(1)}" y="${Math.min(y, zeroY).toFixed(1)}" width="${barWidth.toFixed(1)}" height="${h.toFixed(1)}" rx="3" fill="${markColor}"><title>${escapeXml(point.label)}: ${point.value}</title></rect>`;
      })
    : [
        `<polyline class="org2-chart-line" fill="none" stroke="${markColor}" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" points="${sortedPoints.map((point, index) => {
          const x = margin.left + (sortedPoints.length === 1 ? plotWidth / 2 : (plotWidth * index) / (sortedPoints.length - 1));
          return `${x.toFixed(1)},${yFor(point.value).toFixed(1)}`;
        }).join(" ")}"/>`,
        ...sortedPoints.map((point, index) => {
          const x = margin.left + (sortedPoints.length === 1 ? plotWidth / 2 : (plotWidth * index) / (sortedPoints.length - 1));
          return `<circle ${markAttributes(point, x)} cx="${x.toFixed(1)}" cy="${yFor(point.value).toFixed(1)}" r="3.4" fill="${markColor}" stroke="var(--org2-chart-surface, #ffffff)" stroke-width="1.5" vector-effect="non-scaling-stroke"><title>${escapeXml(point.label)}: ${point.value}</title></circle>`;
        }),
      ];

  const title = candidate.spec.title
    ? `<text x="${margin.left}" y="27" font-size="16" font-weight="600" fill="var(--org2-chart-title, #0f172a)">${escapeXml(candidate.spec.title)}</text>`
    : "";
  const svg = [
    `<svg xmlns="http://www.w3.org/2000/svg" class="org2-chart-svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="${escapeXml(candidate.spec.title || `${candidate.spec.y} by ${candidate.spec.x}`)}" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" data-org2-chart-size="${candidate.spec.presentation.size}" data-org2-chart-interactive="${candidate.spec.presentation.interactive}" data-org2-chart-y-label="${escapeXml(candidate.spec.y)}" data-org2-plot-top="${margin.top}" data-org2-plot-bottom="${height - margin.bottom}">`,
    `<title>${escapeXml(candidate.spec.title || `${candidate.spec.y} by ${candidate.spec.x}`)}</title>`,
    `<desc>Org2 ${candidate.spec.type} chart for ${escapeXml(candidate.spec.y)} by ${escapeXml(candidate.spec.x)}</desc>`,
    title,
    ...yTicks,
    `<line x1="${margin.left}" y1="${margin.top}" x2="${margin.left}" y2="${height - margin.bottom}" stroke="${axisColor}" stroke-width="1" vector-effect="non-scaling-stroke"/>`,
    `<line x1="${margin.left}" y1="${zeroY.toFixed(1)}" x2="${width - margin.right}" y2="${zeroY.toFixed(1)}" stroke="${axisColor}" stroke-width="1" vector-effect="non-scaling-stroke"/>`,
    candidate.spec.presentation.interactive
      ? `<line class="org2-chart-crosshair" x1="${margin.left}" y1="${margin.top}" x2="${margin.left}" y2="${height - margin.bottom}" stroke="${labelColor}" stroke-width="1" vector-effect="non-scaling-stroke" visibility="hidden" pointer-events="none"/>`
      : "",
    ...marks,
    ...labels,
    `<text x="${(margin.left + plotWidth / 2).toFixed(1)}" y="${height - 7}" font-size="11" fill="${labelColor}" text-anchor="middle">${escapeXml(candidate.spec.x)}</text>`,
    `<text x="16" y="${(margin.top + plotHeight / 2).toFixed(1)}" font-size="11" fill="${labelColor}" text-anchor="middle" transform="rotate(-90 16 ${(margin.top + plotHeight / 2).toFixed(1)})">${escapeXml(candidate.spec.y)}</text>`,
    `</svg>`,
  ].filter(Boolean).join("\n");

  return { svg: `${svg}\n`, diagnostics };
}

export function renderOrgChart(raw: string, opts: RenderChartOptions = {}): ChartRenderResult {
  const candidates = collectChartCandidates(raw, opts.file);
  if (candidates.length === 0) {
    return {
      ok: false,
      format: "svg",
      diagnostics: [diagnostic("No chart-affiliated table found")],
    };
  }

  const selected = selectCandidate(candidates, opts);
  if (!selected) {
    return {
      ok: false,
      format: "svg",
      diagnostics: [diagnostic(opts.blockId ? `No chart found for block id "${opts.blockId}"` : `No chart found at or after line ${opts.line}`)],
    };
  }

  const rendered = renderSvg(selected);
  const errors = rendered.diagnostics.filter((item) => item.severity === "error");
  const offset = Math.max(0, opts.sourceLineOffset || 0);
  const source = offsetChartSource(selected.source, offset);
  return {
    ok: errors.length === 0 && Boolean(rendered.svg),
    format: "svg",
    ...(opts.outputPath ? { artifact: opts.outputPath } : {}),
    ...(rendered.svg ? { svg: rendered.svg } : {}),
    presentation: selected.spec.presentation,
    source,
    diagnostics: rendered.diagnostics,
  };
}

export function renderOrgCharts(
  raw: string,
  opts: Pick<RenderChartOptions, "file" | "sourceLineOffset" | "tableDataByLine"> = {},
): ChartRenderResult[] {
  const candidates = collectChartCandidates(raw, opts.file, opts.tableDataByLine);
  const offset = Math.max(0, opts.sourceLineOffset || 0);
  return candidates.map((candidate) => {
    const rendered = renderSvg(candidate);
    const source = offsetChartSource(candidate.source, offset);
    return {
      ok: rendered.diagnostics.every((item) => item.severity !== "error") && Boolean(rendered.svg),
      format: "svg",
      ...(rendered.svg ? { svg: rendered.svg } : {}),
      presentation: candidate.spec.presentation,
      source,
      diagnostics: rendered.diagnostics,
    };
  });
}
