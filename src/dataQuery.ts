import path from "node:path";
import { spawnSync } from "node:child_process";

export type DataQueryDiagnostic = {
  severity: "error" | "warning";
  message: string;
  source?: {
    line?: number;
    blockId?: string;
  };
};

export type DataQueryDataset = {
  id: string;
  line: number;
  type: "csv" | "parquet" | "json";
  engine: "duckdb";
  path: string;
  resolvedPath: string;
};

export type DataQuerySqlBlock = {
  resultId: string;
  line: number;
  endLine: number;
  sql: string;
};

export type DataQueryResult = {
  ok: boolean;
  engine: "duckdb";
  resultId?: string;
  source?: {
    file?: string;
    line: number;
    endLine: number;
  };
  datasets: DataQueryDataset[];
  rowCount: number;
  rows: Record<string, unknown>[];
  orgTable?: string;
  duckdbScript?: string;
  diagnostics: DataQueryDiagnostic[];
};

export type RunDataQueryOptions = {
  file?: string;
  resultId?: string;
  duckdbPath?: string;
  includeScript?: boolean;
};

type FencedBlock = {
  kind: string;
  args: string[];
  line: number;
  endLine: number;
  body: string;
};

const SUPPORTED_DATASET_TYPES = new Set(["csv", "parquet", "json"]);

function diagnostic(message: string, source?: { line?: number; blockId?: string }, severity: "error" | "warning" = "error"): DataQueryDiagnostic {
  return { severity, message, ...(source ? { source } : {}) };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function parseKeyValueBody(body: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of body.split("\n")) {
    const match = /^\s*([A-Za-z0-9_-]+)\s*[:=]\s*(.*?)\s*$/.exec(line);
    if (!match) continue;
    out.set(String(match[1] || "").toLowerCase(), String(match[2] || "").trim());
  }
  return out;
}

function parseFenceArgs(raw: string): { kind: string; args: string[] } | null {
  const tokens = raw.trim().split(/\s+/).filter(Boolean);
  const kind = String(tokens.shift() || "").toLowerCase();
  if (!kind) return null;
  return { kind, args: tokens };
}

function collectFencedBlocks(input: string): FencedBlock[] {
  const lines = input.replace(/\r\n/g, "\n").split("\n");
  const blocks: FencedBlock[] = [];
  let i = 0;

  while (i < lines.length) {
    const opener = /^\s*```(.*)$/.exec(lines[i] || "");
    if (!opener) {
      i++;
      continue;
    }

    const parsed = parseFenceArgs(String(opener[1] || ""));
    if (!parsed) {
      i++;
      continue;
    }

    const bodyLines: string[] = [];
    let j = i + 1;
    while (j < lines.length && !/^\s*```\s*$/.test(lines[j] || "")) {
      bodyLines.push(lines[j] || "");
      j++;
    }

    blocks.push({
      kind: parsed.kind,
      args: parsed.args,
      line: i + 1,
      endLine: Math.min(j + 1, lines.length),
      body: bodyLines.join("\n").trim(),
    });
    i = j + 1;
  }

  return blocks;
}

function argValue(args: string[], keys: string[]): string | undefined {
  for (const arg of args) {
    for (const key of keys) {
      const match = new RegExp(`^${key}=(.+)$`, "i").exec(arg);
      if (match) return String(match[1] || "").trim();
    }
  }
  return undefined;
}

function parseDataset(block: FencedBlock, baseDir: string): { dataset?: DataQueryDataset; diagnostics: DataQueryDiagnostic[] } {
  const diagnostics: DataQueryDiagnostic[] = [];
  const id = argValue(block.args, ["id", "name"]) || block.args.find((arg) => !arg.includes("=")) || "";
  if (!id) diagnostics.push(diagnostic("Dataset block requires a name, e.g. ```dataset fetches", { line: block.line }));

  const values = parseKeyValueBody(block.body);
  const typeRaw = (values.get("type") || "").toLowerCase();
  const engineRaw = (values.get("engine") || "duckdb").toLowerCase();
  const sourcePath = values.get("path") || values.get("file") || "";

  if (!SUPPORTED_DATASET_TYPES.has(typeRaw)) {
    diagnostics.push(diagnostic("Dataset type must be csv, parquet, or json", { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  if (engineRaw && engineRaw !== "duckdb") {
    diagnostics.push(diagnostic(`Unsupported dataset engine "${engineRaw}"; only duckdb is supported`, { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  if (!sourcePath) {
    diagnostics.push(diagnostic("Dataset block requires path: ./file.csv", { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  if (diagnostics.some((item) => item.severity === "error")) return { diagnostics };

  const resolvedPath = path.isAbsolute(sourcePath) ? sourcePath : path.resolve(baseDir, sourcePath);
  return {
    dataset: {
      id,
      line: block.line,
      type: typeRaw as DataQueryDataset["type"],
      engine: "duckdb",
      path: sourcePath,
      resolvedPath,
    },
    diagnostics,
  };
}

function parseSqlBlock(block: FencedBlock): { sql?: DataQuerySqlBlock; diagnostics: DataQueryDiagnostic[] } {
  const resultId = argValue(block.args, ["results", "result", "id", "name"]) || block.args.find((arg) => !arg.includes("=")) || "";
  const diagnostics: DataQueryDiagnostic[] = [];
  if (!resultId) diagnostics.push(diagnostic("SQL block requires results=NAME", { line: block.line }));
  if (!block.body.trim()) diagnostics.push(diagnostic("SQL block is empty", { line: block.line, ...(resultId ? { blockId: resultId } : {}) }));
  if (diagnostics.some((item) => item.severity === "error")) return { diagnostics };
  return { sql: { resultId, line: block.line, endLine: block.endLine, sql: block.body.trim() }, diagnostics };
}

function quoteIdentifier(value: string): string {
  return `"${value.replace(/"/g, '""')}"`;
}

function quoteString(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

function readFunctionForType(type: DataQueryDataset["type"]): string {
  if (type === "parquet") return "read_parquet";
  if (type === "json") return "read_json_auto";
  return "read_csv_auto";
}

function buildDuckDbScript(datasets: DataQueryDataset[], sql: string): string {
  const setup = datasets.map((dataset) => {
    const readFn = readFunctionForType(dataset.type);
    return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT * FROM ${readFn}(${quoteString(dataset.resolvedPath)});`;
  });
  return [...setup, sql.replace(/;\s*$/, "") + ";"].join("\n");
}

function parseDuckDbJson(stdout: string): Record<string, unknown>[] {
  const trimmed = stdout.trim();
  if (!trimmed) return [];
  const parsed = JSON.parse(trimmed);
  if (Array.isArray(parsed)) {
    if (parsed.every(isRecord)) return parsed;
    return parsed.map((value) => ({ value }));
  }
  if (isRecord(parsed) && Array.isArray(parsed.rows) && parsed.rows.every(isRecord)) return parsed.rows;
  if (isRecord(parsed)) return [parsed];
  return [{ value: parsed }];
}

function formatCell(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

export function rowsToOrgTable(rows: Record<string, unknown>[]): string {
  const headers = Array.from(rows.reduce((keys, row) => {
    for (const key of Object.keys(row)) keys.add(key);
    return keys;
  }, new Set<string>()));
  if (headers.length === 0) return "| |\n|-|\n";

  const renderedRows = rows.map((row) => headers.map((header) => formatCell(row[header])));
  const widths = headers.map((header, index) => {
    const cells = renderedRows.map((row) => row[index] || "");
    return Math.max(header.length, ...cells.map((cell) => cell.length));
  });

  const rowLine = (cells: string[]) => `| ${cells.map((cell, index) => cell.padEnd(widths[index] || 1)).join(" | ")} |`;
  const separator = `|${widths.map((width) => "-".repeat(width + 2)).join("+")}|`;
  return [rowLine(headers), separator, ...renderedRows.map(rowLine)].join("\n") + "\n";
}

function materializedResultTable(resultId: string, rows: Record<string, unknown>[]): string {
  return `#+name: ${resultId}\n#+results: query-data-${resultId}\n${rowsToOrgTable(rows)}`;
}

export function runOrg2DataQuery(input: string, opts: RunDataQueryOptions = {}): DataQueryResult {
  const file = opts.file;
  const baseDir = file ? path.dirname(path.resolve(file)) : process.cwd();
  const duckdbPath = opts.duckdbPath || "duckdb";
  const diagnostics: DataQueryDiagnostic[] = [];
  const blocks = collectFencedBlocks(input);
  const datasets: DataQueryDataset[] = [];
  const sqlBlocks: DataQuerySqlBlock[] = [];

  for (const block of blocks) {
    if (block.kind === "dataset" || block.kind === "data") {
      const parsed = parseDataset(block, baseDir);
      diagnostics.push(...parsed.diagnostics);
      if (parsed.dataset) datasets.push(parsed.dataset);
    } else if (block.kind === "sql") {
      const parsed = parseSqlBlock(block);
      diagnostics.push(...parsed.diagnostics);
      if (parsed.sql) sqlBlocks.push(parsed.sql);
    }
  }

  const resultId = opts.resultId?.trim() || (sqlBlocks.length === 1 ? sqlBlocks[0]?.resultId : "");
  const selected = resultId ? sqlBlocks.find((block) => block.resultId === resultId) : undefined;
  if (datasets.length === 0) diagnostics.push(diagnostic("No dataset blocks found"));
  if (sqlBlocks.length === 0) diagnostics.push(diagnostic("No SQL result blocks found"));
  if (!resultId && sqlBlocks.length > 1) diagnostics.push(diagnostic("Multiple SQL result blocks found; pass --results NAME"));
  if (resultId && !selected) diagnostics.push(diagnostic(`No SQL result block found for "${resultId}"`, { blockId: resultId }));

  if (diagnostics.some((item) => item.severity === "error") || !selected) {
    return { ok: false, engine: "duckdb", ...(resultId ? { resultId } : {}), datasets, rowCount: 0, rows: [], diagnostics };
  }

  const script = buildDuckDbScript(datasets, selected.sql);
  const child = spawnSync(duckdbPath, ["-json", ":memory:"], {
    encoding: "utf8",
    input: script,
    maxBuffer: 1024 * 1024 * 16,
  });

  if (child.error) {
    diagnostics.push(diagnostic(`Failed to run DuckDB CLI "${duckdbPath}": ${child.error.message}`, { line: selected.line, blockId: selected.resultId }));
  } else if (child.status !== 0) {
    const stderr = String(child.stderr || "").trim();
    diagnostics.push(diagnostic(`DuckDB query failed${stderr ? `: ${stderr}` : ""}`, { line: selected.line, blockId: selected.resultId }));
  }

  let rows: Record<string, unknown>[] = [];
  if (!diagnostics.some((item) => item.severity === "error")) {
    try {
      rows = parseDuckDbJson(String(child.stdout || ""));
    } catch (err) {
      diagnostics.push(diagnostic(`DuckDB did not return JSON rows: ${err instanceof Error ? err.message : String(err)}`, { line: selected.line, blockId: selected.resultId }));
    }
  }

  const ok = !diagnostics.some((item) => item.severity === "error");
  return {
    ok,
    engine: "duckdb",
    resultId: selected.resultId,
    source: { ...(file ? { file } : {}), line: selected.line, endLine: selected.endLine },
    datasets,
    rowCount: rows.length,
    rows,
    ...(ok ? { orgTable: materializedResultTable(selected.resultId, rows) } : {}),
    ...(opts.includeScript ? { duckdbScript: script } : {}),
    diagnostics,
  };
}
