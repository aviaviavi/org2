import { parseOrgToCanonicalAst } from "./parser.js";

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
  source?: ChartRenderSource;
  diagnostics: ChartRenderDiagnostic[];
};

type Keyword = {
  key: string;
  value: string;
  line: number;
};

type ChartType = "bar" | "line" | "histogram";

type ChartSpec = {
  type: ChartType;
  x: string;
  y: string;
  title?: string;
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

function isTableLine(line: string): boolean {
  return /^\s*\|/.test(line);
}

function parseTableLine(line: string): string[] | null {
  if (!isTableLine(line)) return null;
  const trimmed = line.trim();
  const inner = trimmed.startsWith("|") ? trimmed.slice(1, trimmed.endsWith("|") ? -1 : undefined) : trimmed;
  return inner.split("|").map((cell) => cell.trim());
}

function isHline(cells: string[]): boolean {
  return cells.length > 0 && cells.every((cell) => /^[+\-= ]*$/.test(cell) && /[-=]/.test(cell));
}

function parseTable(lines: string[]): { headers: string[]; rows: string[][]; diagnostics: ChartRenderDiagnostic[] } {
  const parsed = lines.map(parseTableLine).filter((row): row is string[] => Array.isArray(row));
  const diagnostics: ChartRenderDiagnostic[] = [];
  const firstDataRow = parsed.find((row) => !isHline(row));
  if (!firstDataRow) {
    return { headers: [], rows: [], diagnostics: [diagnostic("Chart table has no header row")] };
  }

  const headerIndex = parsed.indexOf(firstDataRow);
  const rows = parsed.slice(headerIndex + 1).filter((row) => !isHline(row));
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
  if (!x) diagnostics.push(diagnostic("Chart spec requires x=column"));
  if (!y) diagnostics.push(diagnostic("Chart spec requires y=column"));
  if (!type || !x || !y) return { diagnostics };
  return { spec: { type, x, y, ...(title ? { title } : {}) }, diagnostics };
}

function keywordValue(keywords: Keyword[], key: string): string | undefined {
  return keywords.find((keyword) => keyword.key === key)?.value;
}

function isChartFenceOpener(line: string): boolean {
  const match = /^\s*```(.*)$/.exec(line);
  if (!match) return false;
  const afterFence = String(match[1] || "").trim();
  return /^(chart|plot)(?:\s|$)/i.test(afterFence);
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
  if (!isChartFenceOpener(opener)) return null;

  const openerMatch = /^\s*```(.*)$/.exec(opener);
  const openerRest = String(openerMatch?.[1] || "").trim();
  const bodyLines: string[] = [];
  let i = startIndex + 1;
  while (i < lines.length) {
    const line = lines[i] || "";
    if (/^\s*```\s*$/.test(line)) {
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
  const title = bodyParams.get("title");
  const source = bodyParams.get("source");

  if (x) tokens.push(`x=${x}`);
  if (y) tokens.push(`y=${y}`);

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
    spec: spec || { type: "bar", x: "", y: "" },
    headers: table.headers,
    rows: table.rows,
    diagnostics: [...diagnostics, ...table.diagnostics],
  };
}

function collectNamedTables(lines: string[], file?: string): Map<string, ParsedTableBlock> {
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

    if (isTableLine(line)) {
      const tableStartLine = i + 1;
      const tableLines: string[] = [];
      while (i < lines.length && isTableLine(lines[i] || "")) {
        tableLines.push(lines[i] || "");
        i++;
      }

      const name = keywordValue(pending, "NAME");
      if (name) {
        const parsedTable = parseTable(tableLines);
        tables.set(name, {
          source: { ...(file ? { file } : {}), line: tableStartLine, endLine: i, blockId: name, kind: "table" },
          headers: parsedTable.headers,
          rows: parsedTable.rows,
          diagnostics: parsedTable.diagnostics,
        });
      }
      pending = [];
      continue;
    }

    if (line.trim() !== "") pending = [];
    i++;
  }

  return tables;
}

function collectChartCandidates(raw: string, file?: string): ChartCandidate[] {
  // Parse first so malformed syntax still goes through the canonical parser in this API path.
  parseOrgToCanonicalAst(raw);

  const lines = raw.replace(/\r\n/g, "\n").split("\n");
  const candidates: ChartCandidate[] = [];
  const namedTables = collectNamedTables(lines, file);
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

    if (isTableLine(line)) {
      const tableStartLine = i + 1;
      const tableLines: string[] = [];
      while (i < lines.length && isTableLine(lines[i] || "")) {
        tableLines.push(lines[i] || "");
        i++;
      }
      const tableEndLine = i;

      const chartRaw = keywordValue(pending, "CHART") || keywordValue(pending, "PLOT");
      const name = keywordValue(pending, "NAME");
      const caption = keywordValue(pending, "CAPTION");
      const parsedTable = parseTable(tableLines);
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
              spec: parsedSpec.spec || { type: "bar", x: "", y: "" },
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
          spec: parsedSpec.spec || { type: "bar", x: "", y: "" },
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

function columnIndex(headers: string[], column: string): number {
  const lower = column.toLowerCase();
  return headers.findIndex((header) => header.toLowerCase() === lower);
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

  const width = 720;
  const height = 420;
  const margin = { top: candidate.spec.title ? 54 : 28, right: 28, bottom: 74, left: 64 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const maxValue = Math.max(1, ...points.map((point) => point.value));
  const minValue = Math.min(0, ...points.map((point) => point.value));
  const span = Math.max(1, maxValue - minValue);
  const yFor = (value: number): number => margin.top + plotHeight - ((value - minValue) / span) * plotHeight;
  const zeroY = yFor(0);
  const axisColor = "#334155";
  const gridColor = "#d7dee8";
  const markColor = "#2563eb";

  const labelEvery = Math.max(1, Math.ceil(points.length / 8));
  const labels = points.map((point, index) => {
    if (index % labelEvery !== 0 && index !== points.length - 1) return "";
    const x = margin.left + (points.length === 1 ? plotWidth / 2 : (plotWidth * index) / (points.length - 1));
    return `<text x="${x.toFixed(1)}" y="${height - 28}" font-size="12" fill="#475569" text-anchor="end" transform="rotate(-35 ${x.toFixed(1)} ${height - 28})">${escapeXml(point.label)}</text>`;
  }).filter(Boolean);

  const yTicks = [0, 0.25, 0.5, 0.75, 1].map((ratio) => {
    const value = minValue + span * ratio;
    const y = yFor(value);
    return `<line x1="${margin.left}" y1="${y.toFixed(1)}" x2="${width - margin.right}" y2="${y.toFixed(1)}" stroke="${gridColor}" stroke-width="1"/><text x="${margin.left - 10}" y="${(y + 4).toFixed(1)}" font-size="12" fill="#475569" text-anchor="end">${Number.isInteger(value) ? value.toFixed(0) : value.toFixed(1)}</text>`;
  });

  const marks = candidate.spec.type === "bar" || candidate.spec.type === "histogram"
    ? points.map((point, index) => {
        const band = plotWidth / Math.max(1, points.length);
        const barWidth = Math.max(8, band * 0.62);
        const x = margin.left + band * index + (band - barWidth) / 2;
        const y = yFor(Math.max(0, point.value));
        const h = Math.abs(zeroY - yFor(point.value));
        return `<rect x="${x.toFixed(1)}" y="${Math.min(y, zeroY).toFixed(1)}" width="${barWidth.toFixed(1)}" height="${h.toFixed(1)}" fill="${markColor}"><title>${escapeXml(point.label)}: ${point.value}</title></rect>`;
      })
    : [
        `<polyline fill="none" stroke="${markColor}" stroke-width="3" points="${points.map((point, index) => {
          const x = margin.left + (points.length === 1 ? plotWidth / 2 : (plotWidth * index) / (points.length - 1));
          return `${x.toFixed(1)},${yFor(point.value).toFixed(1)}`;
        }).join(" ")}"/>`,
        ...points.map((point, index) => {
          const x = margin.left + (points.length === 1 ? plotWidth / 2 : (plotWidth * index) / (points.length - 1));
          return `<circle cx="${x.toFixed(1)}" cy="${yFor(point.value).toFixed(1)}" r="4" fill="${markColor}"><title>${escapeXml(point.label)}: ${point.value}</title></circle>`;
        }),
      ];

  const title = candidate.spec.title
    ? `<text x="${margin.left}" y="28" font-size="18" font-weight="600" fill="#0f172a">${escapeXml(candidate.spec.title)}</text>`
    : "";
  const svg = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img">`,
    `<desc>Org2 ${candidate.spec.type} chart for ${escapeXml(candidate.spec.y)} by ${escapeXml(candidate.spec.x)}</desc>`,
    `<rect width="${width}" height="${height}" fill="#ffffff"/>`,
    title,
    ...yTicks,
    `<line x1="${margin.left}" y1="${margin.top}" x2="${margin.left}" y2="${height - margin.bottom}" stroke="${axisColor}" stroke-width="1.5"/>`,
    `<line x1="${margin.left}" y1="${zeroY.toFixed(1)}" x2="${width - margin.right}" y2="${zeroY.toFixed(1)}" stroke="${axisColor}" stroke-width="1.5"/>`,
    ...marks,
    ...labels,
    `<text x="${(margin.left + plotWidth / 2).toFixed(1)}" y="${height - 8}" font-size="13" fill="#334155" text-anchor="middle">${escapeXml(candidate.spec.x)}</text>`,
    `<text x="18" y="${(margin.top + plotHeight / 2).toFixed(1)}" font-size="13" fill="#334155" text-anchor="middle" transform="rotate(-90 18 ${(margin.top + plotHeight / 2).toFixed(1)})">${escapeXml(candidate.spec.y)}</text>`,
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
  return {
    ok: errors.length === 0 && Boolean(rendered.svg),
    format: "svg",
    ...(opts.outputPath ? { artifact: opts.outputPath } : {}),
    ...(rendered.svg ? { svg: rendered.svg } : {}),
    source: selected.source,
    diagnostics: rendered.diagnostics,
  };
}
