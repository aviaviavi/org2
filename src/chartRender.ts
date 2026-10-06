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
  series: string[];
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
  const rawSeries = params.get("y") || params.get("series") || "";
  const series = rawSeries.split(",").map((column) => column.trim()).filter(Boolean);
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
  if (series.length === 0) diagnostics.push(diagnostic("Chart spec requires y=column or y=column,column"));
  if (new Set(series.map((column) => column.toLowerCase())).size !== series.length) {
    diagnostics.push(diagnostic("Chart series columns must be unique"));
  }
  if (type === "histogram" && series.length > 1) {
    diagnostics.push(diagnostic("Histogram charts support exactly one y column"));
  }
  if (!sort) diagnostics.push(diagnostic(`Unsupported chart sort "${sortRaw}". Supported sorts: none, x-asc, x-desc, y-asc, y-desc`));
  if (!size) diagnostics.push(diagnostic(`Unsupported chart size "${sizeRaw}". Supported sizes: compact, medium, wide`));
  if (!height) diagnostics.push(diagnostic("Chart height must be an integer from 220 to 720 pixels"));
  if (interactive === undefined) diagnostics.push(diagnostic("Chart interactive must be true or false"));
  if (!type || !x || series.length === 0 || diagnostics.some((item) => item.severity === "error") || !sort || !size || !height || interactive === undefined) return { diagnostics };
  return {
    spec: {
      type,
      x,
      series,
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
  /** Self-contained data: table rows written inside the chart block itself. */
  inlineTable?: { lines: string[]; startLine: number };
};

function inlineChartTable(bodyLines: string[], firstBodyLine: number): FencedChartBlock["inlineTable"] {
  const start = bodyLines.findIndex((line) => isOrgTableDataLine(line));
  if (start < 0) return undefined;
  const lines: string[] = [];
  for (let index = start; index < bodyLines.length && isOrgTableDataLine(bodyLines[index] || ""); index += 1) {
    lines.push(bodyLines[index] || "");
  }
  return { lines, startLine: firstBodyLine + start };
}

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
      const inlineTable = inlineChartTable(bodyLines, startIndex + 2);
      return { raw: parsed.raw.trim(), ...(parsed.title ? { title: parsed.title } : {}), ...(parsed.source ? { source: parsed.source } : {}), startLine: startIndex + 1, endLine: i + 1, ...(inlineTable ? { inlineTable } : {}) };
    }
    bodyLines.push(line);
    i++;
  }

  const parsed = parseFencedChartSpec(openerRest, bodyLines);
  const inlineTable = inlineChartTable(bodyLines, startIndex + 2);
  return { raw: parsed.raw.trim(), ...(parsed.title ? { title: parsed.title } : {}), ...(parsed.source ? { source: parsed.source } : {}), startLine: startIndex + 1, endLine: lines.length, ...(inlineTable ? { inlineTable } : {}) };
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
  const y = bodyParams.get("y") || bodyParams.get("series");
  const sort = bodyParams.get("sort");
  const title = bodyParams.get("title");
  const source = bodyParams.get("source");
  const size = bodyParams.get("size");
  const height = bodyParams.get("height");
  const interactive = bodyParams.get("interactive");

  if (x) tokens.push(`x=${x}`);
  if (y) tokens.push(`y=${y.replace(/\s*,\s*/g, ",")}`);
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
    spec: spec || { type: "bar", x: "", series: [], sort: "none", presentation: { size: "medium", height: 360, interactive: true } },
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

function inlineParsedTable(chart: FencedChartBlock, file?: string): ParsedTableBlock | undefined {
  if (!chart.inlineTable) return undefined;
  const parsed = parseTable(chart.inlineTable.lines);
  return {
    source: { ...(file ? { file } : {}), line: chart.inlineTable.startLine, endLine: chart.inlineTable.startLine + chart.inlineTable.lines.length - 1, kind: "table" },
    headers: parsed.headers,
    rows: parsed.rows,
    diagnostics: parsed.diagnostics,
  };
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
        const inline = fencedChart && !fencedChart.source ? inlineParsedTable(fencedChart, file) : undefined;
        if (inline) {
          candidates.push(candidateFromTable(inline, parsedSpec.spec, parsedSpec.diagnostics, {
            chartLine: fencedChart!.startLine,
            chartEndLine: fencedChart!.endLine,
          }));
        } else if (parsedSpec.source.kind === "named-table") {
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
              spec: parsedSpec.spec || { type: "bar", x: "", series: [], sort: "none", presentation: { size: "medium", height: 360, interactive: true } },
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
      const inline = inlineParsedTable(fencedChart, file);
      const table = inline && !fencedChart.source
        ? inline
        : parsedSpec.source.kind === "named-table" ? namedTables.get(parsedSpec.source.blockId) : previousTable;
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
          spec: parsedSpec.spec || { type: "bar", x: "", series: [], sort: "none", presentation: { size: "medium", height: 360, interactive: true } },
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

/** How chart values are written: a currency prefix and/or percent suffix. */
export type ChartValueUnit = { prefix: string; suffix: string };

/** Parse a table cell as a chart value, accepting `1,200`, `$1,200`, and `12%`. */
export function parseChartValue(raw: string): number {
  const cleaned = raw.trim().replace(/,/g, "").replace(/^([-+]?)\$/, "$1").replace(/%$/, "");
  return /^[-+]?(\d+\.?\d*|\.\d+)(e[-+]?\d+)?$/i.test(cleaned) ? Number.parseFloat(cleaned) : Number.NaN;
}

/** Infer a display unit from the series columns and their raw cells. */
export function chartValueUnit(series: string[], rawValues: string[]): ChartValueUnit {
  const values = rawValues.map((value) => value.trim()).filter(Boolean);
  const currency = values.length > 0 && values.every((value) => /^[-+]?\$/.test(value))
    || series.every((column) => /(^|[_\s-])(usd|dollars?)($|[_\s-])|\$/i.test(column));
  const percent = values.length > 0 && values.every((value) => /%$/.test(value))
    || series.every((column) => /(^|[_\s-])(pct|percent(age)?)($|[_\s-])|%/i.test(column));
  return { prefix: currency ? "$" : "", suffix: percent && !currency ? "%" : "" };
}

function trimZeros(value: string): string {
  return value.includes(".") ? value.replace(/\.?0+$/, "") : value;
}

/**
 * Compact axis/label formatting: `950`, `1.2k`, `85k`, `24M`, `$1.1M`, `18%`.
 * `step` (the tick spacing) chooses enough precision to keep ticks distinct.
 */
export function formatChartNumber(value: number, unit: ChartValueUnit = { prefix: "", suffix: "" }, step?: number): string {
  const abs = Math.abs(value);
  const scales: Array<[number, string]> = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "k"]];
  const [divisor, symbol] = scales.find(([size]) => abs >= size) || [1, ""];
  const scaled = value / divisor;
  const scaledStep = step !== undefined ? step / divisor : undefined;
  let digits: number;
  if (scaledStep !== undefined && scaledStep > 0) {
    digits = 0;
    while (digits < 3 && Math.abs(scaledStep * 10 ** digits - Math.round(scaledStep * 10 ** digits)) > 1e-6) digits += 1;
  } else if (divisor === 1) {
    digits = Number.isInteger(scaled) ? 0 : Math.abs(scaled) >= 10 ? 1 : 2;
  } else {
    digits = Math.abs(scaled) >= 100 ? 0 : 1;
  }
  const number = trimZeros(scaled.toFixed(digits));
  const sign = number.startsWith("-") ? "-" : "";
  return `${sign}${unit.prefix}${number.replace(/^-/, "")}${symbol}${unit.suffix}`;
}

/** Full-precision tooltip formatting with grouping: `$95,880`, `12.5%`. */
export function formatChartValue(value: number, unit: ChartValueUnit = { prefix: "", suffix: "" }): string {
  const grouped = value.toLocaleString("en-US", { maximumFractionDigits: 2 });
  const sign = grouped.startsWith("-") ? "-" : "";
  return `${sign}${unit.prefix}${grouped.replace(/^-/, "")}${unit.suffix}`;
}

/** `mrr_usd` → `mrr usd`, so column names read as words in titles and legends. */
export function humanizeChartLabel(column: string): string {
  return column.replace(/[_]+/g, " ").replace(/\s+/g, " ").trim();
}

/** Approximate rendered width of 11–12px system-UI text, for layout without a DOM. */
function textWidth(text: string, fontSize = 11): number {
  let units = 0;
  for (const char of text) {
    if (/[ilI.,:;'|!]/.test(char)) units += 0.3;
    else if (/[mwMW@]/.test(char)) units += 0.85;
    else if (/[A-Z0-9$%]/.test(char)) units += 0.64;
    else if (char === " ") units += 0.3;
    else units += 0.55;
  }
  return units * fontSize;
}

function truncateToWidth(text: string, maxWidth: number, fontSize = 11): string {
  if (textWidth(text, fontSize) <= maxWidth) return text;
  let result = text;
  while (result.length > 1 && textWidth(`${result}…`, fontSize) > maxWidth) result = result.slice(0, -1);
  return `${result.trimEnd()}…`;
}

/** Monotone cubic interpolation (Fritsch–Carlson): smooth, never overshoots the data. */
function monotonePath(points: Array<[number, number]>): string {
  if (points.length === 0) return "";
  if (points.length === 1) return `M${points[0]![0].toFixed(1)},${points[0]![1].toFixed(1)}`;
  if (points.length === 2) return `M${points[0]![0].toFixed(1)},${points[0]![1].toFixed(1)}L${points[1]![0].toFixed(1)},${points[1]![1].toFixed(1)}`;
  const n = points.length;
  const dx: number[] = [];
  const slope: number[] = [];
  for (let i = 0; i < n - 1; i += 1) {
    dx.push(points[i + 1]![0] - points[i]![0]);
    slope.push((points[i + 1]![1] - points[i]![1]) / Math.max(Number.EPSILON, dx[i]!));
  }
  const tangent: number[] = [slope[0]!];
  for (let i = 1; i < n - 1; i += 1) {
    tangent.push(slope[i - 1]! * slope[i]! <= 0 ? 0 : (slope[i - 1]! + slope[i]!) / 2);
  }
  tangent.push(slope[n - 2]!);
  for (let i = 0; i < n - 1; i += 1) {
    if (slope[i] === 0) {
      tangent[i] = 0;
      tangent[i + 1] = 0;
      continue;
    }
    const a = tangent[i]! / slope[i]!;
    const b = tangent[i + 1]! / slope[i]!;
    const h = a * a + b * b;
    if (h > 9) {
      const t = 3 / Math.sqrt(h);
      tangent[i] = t * a * slope[i]!;
      tangent[i + 1] = t * b * slope[i]!;
    }
  }
  let path = `M${points[0]![0].toFixed(1)},${points[0]![1].toFixed(1)}`;
  for (let i = 0; i < n - 1; i += 1) {
    const [x0, y0] = points[i]!;
    const [x1, y1] = points[i + 1]!;
    const h = dx[i]! / 3;
    path += `C${(x0 + h).toFixed(1)},${(y0 + h * tangent[i]!).toFixed(1)} ${(x1 - h).toFixed(1)},${(y1 - h * tangent[i + 1]!).toFixed(1)} ${x1.toFixed(1)},${y1.toFixed(1)}`;
  }
  return path;
}

function hashString(value: string): string {
  let hash = 2166136261;
  for (let i = 0; i < value.length; i += 1) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(36);
}

/** Separate stacked end-of-line labels so they never overlap. */
function spreadLabels(positions: number[], minGap: number, top: number, bottom: number): number[] {
  const order = positions.map((y, index) => ({ y, index })).sort((a, b) => a.y - b.y);
  for (let i = 1; i < order.length; i += 1) {
    if (order[i]!.y - order[i - 1]!.y < minGap) order[i]!.y = order[i - 1]!.y + minGap;
  }
  const overflow = order.length ? order[order.length - 1]!.y - bottom : 0;
  if (overflow > 0) for (const item of order) item.y -= overflow;
  for (let i = 0; i < order.length; i += 1) order[i]!.y = Math.max(top + i * minGap, order[i]!.y);
  const result = [...positions];
  for (const item of order) result[item.index] = item.y;
  return result;
}

function renderSvg(candidate: ChartCandidate): { svg?: string; diagnostics: ChartRenderDiagnostic[] } {
  const diagnostics = [...candidate.diagnostics];
  const xIndex = columnIndex(candidate.headers, candidate.spec.x);
  if (xIndex < 0) diagnostics.push(diagnostic(`Unknown x column "${candidate.spec.x}"`, { line: candidate.source.line, blockId: candidate.source.blockId }));
  const seriesIndexes = candidate.spec.series.map((series) => ({ series, index: columnIndex(candidate.headers, series) }));
  for (const entry of seriesIndexes) {
    if (entry.index < 0) diagnostics.push(diagnostic(`Unknown y column "${entry.series}"`, { line: candidate.source.line, blockId: candidate.source.blockId }));
  }
  if (xIndex < 0 || seriesIndexes.length === 0 || seriesIndexes.some((entry) => entry.index < 0)) return { diagnostics };

  const categories = candidate.rows.map((row) => ({
    label: String(row[xIndex] || ""),
    points: seriesIndexes.map(({ series, index }) => {
      const rawValue = String(row[index] || "");
      return {
        label: String(row[xIndex] || ""),
        series,
        rawValue,
        value: parseChartValue(rawValue),
      };
    }),
  }));
  const invalid = categories.flatMap((category) => category.points).find((point) => !Number.isFinite(point.value));
  if (invalid) {
    diagnostics.push(diagnostic(`Non-numeric y value "${invalid.rawValue}" in column "${invalid.series}"`, { line: candidate.source.line, blockId: candidate.source.blockId }));
    return { diagnostics };
  }
  if (categories.length === 0) return { diagnostics };

  const sortedCategories = [...categories];
  const compareLabels = (a: string, b: string): number => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
  if (candidate.spec.sort === "x-asc") {
    sortedCategories.sort((a, b) => compareLabels(a.label, b.label));
  } else if (candidate.spec.sort === "x-desc") {
    sortedCategories.sort((a, b) => compareLabels(b.label, a.label));
  } else if (candidate.spec.sort === "y-asc") {
    sortedCategories.sort((a, b) => (a.points[0]?.value || 0) - (b.points[0]?.value || 0) || compareLabels(a.label, b.label));
  } else if (candidate.spec.sort === "y-desc") {
    sortedCategories.sort((a, b) => (b.points[0]?.value || 0) - (a.points[0]?.value || 0) || compareLabels(a.label, b.label));
  }

  const series = candidate.spec.series;
  const unit = chartValueUnit(series, sortedCategories.flatMap((category) => category.points.map((point) => point.rawValue)));
  const width = 720;
  const height = candidate.spec.presentation.height;
  const hasMultipleSeries = series.length > 1;
  const isBarChart = candidate.spec.type === "bar" || candidate.spec.type === "histogram";
  const isHistogram = candidate.spec.type === "histogram";
  const allPoints = sortedCategories.flatMap((category) => category.points);

  // Value domain. Bars always include zero; lines fit the data so trends stay visible.
  const rawMaxValue = Math.max(...allPoints.map((point) => point.value));
  const rawMinValue = Math.min(...allPoints.map((point) => point.value));
  let domainMin = isBarChart ? Math.min(0, rawMinValue) : rawMinValue;
  let domainMax = isBarChart ? Math.max(0, rawMaxValue) : rawMaxValue;
  if (!isBarChart) {
    const pad = Math.max((domainMax - domainMin) * 0.12, Math.abs(domainMax) * 0.02, 1e-9);
    domainMin = rawMinValue >= 0 && domainMin - pad < 0 ? 0 : domainMin - pad;
    domainMax += pad;
    // Close to zero relative to the range? Then anchor at zero, which reads more honestly.
    if (rawMinValue >= 0 && rawMinValue < (rawMaxValue - rawMinValue) * 0.5) domainMin = 0;
  }
  const showBarValues = isBarChart && !hasMultipleSeries && sortedCategories.length <= 14;
  if (showBarValues) {
    const range = Math.max(domainMax - domainMin, 1e-9);
    if (domainMax > 0) domainMax += range * 0.1;
    if (domainMin < 0) domainMin -= range * 0.14;
  }
  const rawSpan = Math.max(domainMax - domainMin, Math.abs(domainMax) * 0.1, 1e-9);
  const tickStep = niceTickStep(rawSpan, 4);
  const minValue = Math.floor(domainMin / tickStep + 1e-9) * tickStep;
  const maxValue = Math.max(minValue + tickStep, Math.ceil(domainMax / tickStep - 1e-9) * tickStep);
  const tickValues: number[] = [];
  for (let value = minValue; value <= maxValue + tickStep / 2 && tickValues.length < 12; value += tickStep) {
    tickValues.push(Math.abs(value) < tickStep * 1e-6 ? 0 : value);
  }
  const tickLabels = tickValues.map((value) => formatChartNumber(value, unit, tickStep));

  // Header: title, subtitle, and a flowing legend.
  const titleText = candidate.spec.title;
  const yLabel = series.length === 1 ? series[0]! : "value";
  const subtitleText = hasMultipleSeries
    ? `by ${humanizeChartLabel(candidate.spec.x)}`
    : `${humanizeChartLabel(yLabel)} by ${humanizeChartLabel(candidate.spec.x)}`;
  let cursorY = 0;
  const header: string[] = [];
  if (titleText) {
    cursorY += 20;
    header.push(`<text class="org2-chart-title" x="0" y="${cursorY}" font-size="15" font-weight="600" letter-spacing="-0.01em" fill="var(--org2-chart-title, #0f172a)">${escapeXml(titleText)}</text>`);
  }
  cursorY += titleText ? 19 : 14;
  header.push(`<text class="org2-chart-subtitle" x="0" y="${cursorY}" font-size="12" fill="var(--org2-chart-label, #64748b)">${escapeXml(subtitleText)}</text>`);

  const labelColor = "var(--org2-chart-label, #64748b)";
  const gridColor = "var(--org2-chart-grid, #e2e8f0)";
  const axisColor = "var(--org2-chart-axis, #94a3b8)";
  const seriesColors = [
    "var(--org2-chart-mark, #2563eb)",
    "var(--org2-chart-series-2, #dc2626)",
    "var(--org2-chart-series-3, #16a34a)",
    "var(--org2-chart-series-4, #9333ea)",
    "var(--org2-chart-series-5, #ea580c)",
    "var(--org2-chart-series-6, #0891b2)",
    "var(--org2-chart-series-7, #c026d3)",
    "var(--org2-chart-series-8, #4d7c0f)",
  ];
  const colorForSeries = (index: number): string => seriesColors[index % seriesColors.length] || seriesColors[0]!;

  const legend: string[] = [];
  if (hasMultipleSeries) {
    cursorY += 12;
    let legendX = 0;
    let legendRowY = cursorY + 9;
    series.forEach((name, index) => {
      const label = humanizeChartLabel(name);
      const itemWidth = 10 + 6 + textWidth(label, 12) + 16;
      if (legendX > 0 && legendX + itemWidth > width) {
        legendX = 0;
        legendRowY += 20;
      }
      legend.push(`<g class="org2-chart-legend-item" data-series="${escapeXml(name)}"><rect x="${legendX.toFixed(1)}" y="${(legendRowY - 5).toFixed(1)}" width="10" height="10" rx="3" fill="${colorForSeries(index)}"/><text x="${(legendX + 16).toFixed(1)}" y="${(legendRowY + 4).toFixed(1)}" font-size="12" fill="var(--org2-chart-title, #0f172a)">${escapeXml(label)}</text></g>`);
      legendX += itemWidth;
    });
    cursorY = legendRowY + 5;
  }

  // Plot geometry.
  const yLabelWidth = Math.max(...tickLabels.map((label) => textWidth(label, 11)));
  const endLabels = !isBarChart
    ? series.map((name, seriesIndex) => {
        const last = sortedCategories[sortedCategories.length - 1]!.points[seriesIndex]!;
        const value = formatChartNumber(last.value, unit);
        return hasMultipleSeries ? `${truncateToWidth(humanizeChartLabel(name), 84)} ${value}` : value;
      })
    : [];
  const endLabelWidth = endLabels.length ? Math.min(140, Math.max(...endLabels.map((label) => textWidth(label, 11)))) : 0;
  const margin = {
    top: cursorY + 18,
    right: endLabelWidth ? endLabelWidth + 14 : 8,
    bottom: 30,
    left: Math.ceil(yLabelWidth) + 12,
  };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = Math.max(80, height - margin.top - margin.bottom);
  const plotBottom = margin.top + plotHeight;
  const span = maxValue - minValue;
  const yFor = (value: number): number => margin.top + plotHeight - ((value - minValue) / span) * plotHeight;
  const zeroY = yFor(Math.min(maxValue, Math.max(minValue, 0)));
  const count = sortedCategories.length;
  const band = plotWidth / Math.max(1, count);
  const linePad = count > 1 ? 4 : 0;
  const categoryX = (index: number): number => isBarChart
    ? margin.left + band * (index + 0.5)
    : margin.left + (count === 1 ? plotWidth / 2 : linePad + ((plotWidth - linePad * 2) * index) / (count - 1));

  // Gridlines and y tick labels (no y axis line).
  const yTicks = tickValues.map((value, index) => {
    const y = yFor(value);
    const isBaseline = value === 0 || (index === 0 && minValue > 0);
    return `<line class="org2-chart-grid" x1="${margin.left}" y1="${y.toFixed(1)}" x2="${width - margin.right}" y2="${y.toFixed(1)}" stroke="${isBaseline ? axisColor : gridColor}" stroke-opacity="${isBaseline ? 0.55 : 1}" stroke-width="1" vector-effect="non-scaling-stroke"/><text x="${margin.left - 8}" y="${(y + 4).toFixed(1)}" font-size="11" fill="${labelColor}" text-anchor="end">${escapeXml(tickLabels[index]!)}</text>`;
  });

  // X labels stay horizontal: bars truncate to their band; lines thin out by width.
  const labels: string[] = [];
  const labelY = plotBottom + 19;
  const longest = Math.max(...sortedCategories.map((category) => textWidth(category.label, 11)));
  if (isBarChart && (longest <= band - 8 || band - 8 >= 72)) {
    sortedCategories.forEach((category, index) => {
      const text = truncateToWidth(category.label, band - 8);
      labels.push(`<text x="${categoryX(index).toFixed(1)}" y="${labelY}" font-size="11" fill="${labelColor}" text-anchor="middle"><title>${escapeXml(category.label)}</title>${escapeXml(text)}</text>`);
    });
  } else {
    const slotWidth = isBarChart ? band : (plotWidth - linePad * 2) / Math.max(1, count - 1);
    const labelWidth = Math.min(longest, 120);
    const every = Math.max(1, Math.ceil((labelWidth + 14) / Math.max(1, slotWidth)));
    let lastRight = -Infinity;
    sortedCategories.forEach((category, index) => {
      const isLast = index === count - 1;
      if (index % every !== 0 && !isLast) return;
      const text = truncateToWidth(category.label, 120);
      const w = textWidth(text, 11);
      const x = categoryX(index);
      let anchor = !isBarChart && count > 1 && index === 0 ? "start" : !isBarChart && count > 1 && isLast ? "end" : "middle";
      if (anchor === "middle" && x + w / 2 > width) anchor = "end";
      if (anchor === "middle" && x - w / 2 < 0) anchor = "start";
      const labelX = anchor === "end" && isBarChart ? Math.min(x + band / 2, width) : anchor === "start" && isBarChart ? Math.max(x - band / 2, 0) : x;
      const left = anchor === "start" ? labelX : anchor === "end" ? labelX - w : labelX - w / 2;
      if (left < lastRight + 10) return;
      lastRight = left + w;
      labels.push(`<text x="${labelX.toFixed(1)}" y="${labelY}" font-size="11" fill="${labelColor}" text-anchor="${anchor}">${escapeXml(text)}</text>`);
    });
  }

  const markAttributes = (point: { label: string; series: string; value: number }, x: number, extraClass = ""): string => {
    const display = formatChartValue(point.value, unit);
    const label = hasMultipleSeries ? `${point.series} — ${point.label}: ${display}` : `${point.label}: ${display}`;
    return `class="org2-chart-mark${extraClass}" data-org2-chart-mark="true" data-label="${escapeXml(point.label)}" data-series="${escapeXml(point.series)}" data-value="${point.value}" data-display="${escapeXml(display)}" data-chart-x="${x.toFixed(1)}" role="graphics-symbol" aria-label="${escapeXml(label)}" tabindex="0"`;
  };
  const nativeTitle = (point: { label: string; series: string; value: number }): string =>
    hasMultipleSeries ? `${point.series} — ${point.label}: ${point.value}` : `${point.label}: ${point.value}`;

  const defs: string[] = [];
  const gradientBase = `org2-chart-fill-${hashString(`${titleText || ""}|${series.join(",")}|${candidate.spec.x}|${count}|${rawMaxValue}`)}`;
  const marks: string[] = [];
  if (isBarChart) {
    const showValues = showBarValues && band >= 30;
    sortedCategories.forEach((category, categoryIndex) => {
      const groupWidth = band * (isHistogram ? 0.94 : hasMultipleSeries ? 0.78 : 0.66);
      const gap = hasMultipleSeries ? Math.min(3, groupWidth * 0.05) : 0;
      const barWidth = Math.max(1, Math.min(isHistogram ? Infinity : 56 * category.points.length, groupWidth - gap * Math.max(0, category.points.length - 1)) / Math.max(1, category.points.length));
      const totalWidth = barWidth * category.points.length + gap * Math.max(0, category.points.length - 1);
      const groupX = margin.left + band * categoryIndex + (band - totalWidth) / 2;
      category.points.forEach((point, seriesIndex) => {
        const x = groupX + seriesIndex * (barWidth + gap);
        const top = yFor(Math.max(0, point.value));
        const h = Math.max(point.value === 0 ? 0 : 1, Math.abs(zeroY - yFor(point.value)));
        const radius = Math.min(4, barWidth / 3, h / 2);
        marks.push(`<rect ${markAttributes(point, x + barWidth / 2, " org2-chart-bar")} x="${x.toFixed(1)}" y="${(point.value >= 0 ? Math.min(top, zeroY - h) : zeroY).toFixed(1)}" width="${barWidth.toFixed(1)}" height="${h.toFixed(1)}" rx="${radius.toFixed(1)}" fill="${colorForSeries(seriesIndex)}"><title>${escapeXml(nativeTitle(point))}</title></rect>`);
        if (showValues) {
          const valueY = point.value >= 0 ? zeroY - h - 6 : zeroY + h + 14;
          marks.push(`<text class="org2-chart-value" data-series="${escapeXml(point.series)}" x="${(x + barWidth / 2).toFixed(1)}" y="${valueY.toFixed(1)}" font-size="11" font-weight="500" fill="${labelColor}" text-anchor="middle" pointer-events="none">${escapeXml(formatChartNumber(point.value, unit))}</text>`);
        }
      });
    });
  } else {
    const endPositions = series.map((_, seriesIndex) => yFor(sortedCategories[count - 1]!.points[seriesIndex]!.value));
    const endLabelY = spreadLabels(endPositions, 14, margin.top + 4, plotBottom - 2);
    series.forEach((name, seriesIndex) => {
      const points = sortedCategories.map((category) => category.points[seriesIndex]!).filter(Boolean);
      const color = colorForSeries(seriesIndex);
      const coordinates = points.map((point, index): [number, number] => [categoryX(index), yFor(point.value)]);
      const path = monotonePath(coordinates);
      const group: string[] = [`<g class="org2-chart-series" data-series="${escapeXml(name)}">`];
      if (series.length <= 2 && coordinates.length > 1) {
        const gradientID = `${gradientBase}-${seriesIndex}`;
        defs.push(`<linearGradient id="${gradientID}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" style="stop-color: ${color}; stop-opacity: ${series.length === 1 ? 0.22 : 0.12}"/><stop offset="1" style="stop-color: ${color}; stop-opacity: 0"/></linearGradient>`);
        const baseY = plotBottom;
        group.push(`<path class="org2-chart-area" d="${path}L${coordinates[coordinates.length - 1]![0].toFixed(1)},${baseY.toFixed(1)}L${coordinates[0]![0].toFixed(1)},${baseY.toFixed(1)}Z" fill="url(#${gradientID})" stroke="none" pointer-events="none"/>`);
      }
      group.push(`<path class="org2-chart-line" data-series="${escapeXml(name)}" d="${path}" fill="none" stroke="${color}" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>`);
      const [endX, endY] = coordinates[coordinates.length - 1]!;
      group.push(`<circle class="org2-chart-endpoint" cx="${endX.toFixed(1)}" cy="${endY.toFixed(1)}" r="3.5" fill="${color}" stroke="var(--org2-chart-surface, #ffffff)" stroke-width="2" pointer-events="none"/>`);
      group.push(`<text class="org2-chart-end-label" x="${(endX + 9).toFixed(1)}" y="${(endLabelY[seriesIndex]! + 4).toFixed(1)}" font-size="11" font-weight="600" fill="${color}" pointer-events="none">${escapeXml(endLabels[seriesIndex]!)}</text>`);
      points.forEach((point, index) => {
        const [x, y] = coordinates[index]!;
        group.push(`<circle ${markAttributes(point, x, " org2-chart-point")} cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="4" fill="${color}" fill-opacity="0" stroke="var(--org2-chart-surface, #ffffff)" stroke-opacity="0" stroke-width="2" vector-effect="non-scaling-stroke"><title>${escapeXml(nativeTitle(point))}</title></circle>`);
      });
      group.push(`</g>`);
      marks.push(group.join(""));
    });
  }

  const seriesLabel = series.join(", ");
  const accessibleTitle = titleText || `${seriesLabel} by ${candidate.spec.x}`;
  const svg = [
    `<svg xmlns="http://www.w3.org/2000/svg" class="org2-chart-svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="${escapeXml(accessibleTitle)}" font-family="system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" style="font-variant-numeric: tabular-nums" data-org2-chart-size="${candidate.spec.presentation.size}" data-org2-chart-interactive="${candidate.spec.presentation.interactive}" data-org2-chart-y-label="${escapeXml(yLabel)}" data-org2-chart-series="${escapeXml(series.join(","))}" data-org2-plot-top="${margin.top}" data-org2-plot-bottom="${plotBottom.toFixed(1)}">`,
    `<title>${escapeXml(accessibleTitle)}</title>`,
    `<desc>Org2 ${candidate.spec.type} chart for ${escapeXml(seriesLabel)} by ${escapeXml(candidate.spec.x)}</desc>`,
    defs.length ? `<defs>${defs.join("")}</defs>` : "",
    ...header,
    ...legend,
    ...yTicks,
    candidate.spec.presentation.interactive
      ? `<line class="org2-chart-crosshair" x1="${margin.left}" y1="${margin.top}" x2="${margin.left}" y2="${plotBottom.toFixed(1)}" stroke="${labelColor}" stroke-width="1" stroke-dasharray="3 3" vector-effect="non-scaling-stroke" visibility="hidden" pointer-events="none"/>`
      : "",
    ...marks,
    ...labels,
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
