import path from "node:path";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";

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
  type: "csv" | "parquet" | "json" | "table";
  engine: "duckdb";
  path?: string;
  url?: string;
  resolvedPath?: string;
  sourceTable?: string;
  source?: {
    line: number;
    endLine: number;
  };
  rowCount?: number;
};

export type DataQuerySqlBlock = {
  resultId: string;
  artifact?: string;
  line: number;
  endLine: number;
  sql: string;
};

export type DataQuerySqlView = {
  id: string;
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
  views: DataQuerySqlView[];
  rowCount: number;
  rows: Record<string, unknown>[];
  provenance?: {
    resultId: string;
    artifact?: string;
    querySha256: string;
    scriptSha256: string;
    datasetIds: string[];
    viewIds: string[];
  };
  orgTable?: string;
  duckdbScript?: string;
  diagnostics: DataQueryDiagnostic[];
};

export type RunDataQueryOptions = {
  file?: string;
  resultId?: string;
  resultLine?: number;
  outputArtifact?: string;
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

type NamedOrgTable = {
  name: string;
  line: number;
  endLine: number;
  headers: string[];
  rows: string[][];
};

const SUPPORTED_DATASET_TYPES = new Set(["csv", "parquet", "json", "table", "org-table"]);

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

function tokenizeBlockArgs(raw: string): string[] {
  return raw.trim().split(/\s+/).filter(Boolean);
}

function collectMarkdownFencedBlocks(input: string): FencedBlock[] {
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

function collectOrgStyleBlocks(input: string): FencedBlock[] {
  const lines = input.replace(/\r\n/g, "\n").split("\n");
  const blocks: FencedBlock[] = [];
  let pendingName = "";
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] || "";
    const keyword = parseKeywordLine(line);
    if (keyword) {
      pendingName = keyword.key === "NAME" ? keyword.value : pendingName;
      i++;
      continue;
    }

    const srcMatch = /^\s*#\+begin_src(?:\s+([A-Za-z0-9_-]+))?(.*)$/i.exec(line);
    const blockMatch = /^\s*#\+begin_(dataset|data|sql)\b(.*)$/i.exec(line);
    const kind = srcMatch ? String(srcMatch[1] || "").toLowerCase() : blockMatch ? String(blockMatch[1] || "").toLowerCase() : "";
    const argsRaw = srcMatch ? String(srcMatch[2] || "") : blockMatch ? String(blockMatch[2] || "") : "";

    if (kind) {
      const endPattern = srcMatch ? /^\s*#\+end_src\b/i : new RegExp(`^\\s*#\\+end_${kind}\\b`, "i");
      const bodyLines: string[] = [];
      let j = i + 1;
      while (j < lines.length && !endPattern.test(lines[j] || "")) {
        bodyLines.push(lines[j] || "");
        j++;
      }
      blocks.push({
        kind,
        args: [...(pendingName ? [`name=${pendingName}`] : []), ...tokenizeBlockArgs(argsRaw)],
        line: i + 1,
        endLine: Math.min(j + 1, lines.length),
        body: bodyLines.join("\n").trim(),
      });
      pendingName = "";
      i = j + 1;
      continue;
    }

    if (line.trim() !== "") pendingName = "";
    i++;
  }

  return blocks;
}

function collectFencedBlocks(input: string): FencedBlock[] {
  return [...collectMarkdownFencedBlocks(input), ...collectOrgStyleBlocks(input)].sort((a, b) => a.line - b.line || a.endLine - b.endLine);
}

function argValue(args: string[], keys: string[], opts: { separated?: boolean } = {}): string | undefined {
  const separated = opts.separated !== false;
  for (let index = 0; index < args.length; index++) {
    const arg = args[index] || "";
    for (const key of keys) {
      const match = new RegExp(`^:?${key}(?:=|:)(.+)$`, "i").exec(arg);
      if (match) return String(match[1] || "").trim();
      if (separated && new RegExp(`^:?${key}$`, "i").test(arg)) {
        const value = args[index + 1];
        if (value && !value.startsWith(":")) return value.trim();
      }
    }
  }
  return undefined;
}

function positionalArg(args: string[]): string | undefined {
  return args.find((arg, index) => Boolean(arg && !arg.includes("=") && !arg.startsWith(":") && !(args[index - 1] || "").startsWith(":")));
}

function parseKeywordLine(line: string): { key: string; value: string } | null {
  const match = /^\s*#\+([A-Za-z0-9_]+):[ \t]*(.*)$/.exec(line);
  if (!match) return null;
  return { key: String(match[1] || "").toUpperCase(), value: String(match[2] || "").trim() };
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

function parseNamedOrgTable(name: string, line: number, endLine: number, tableLines: string[]): NamedOrgTable | null {
  const rows = tableLines.map(parseTableLine).filter((row): row is string[] => Array.isArray(row));
  const firstDataRow = rows.find((row) => !isHline(row));
  if (!firstDataRow) return null;
  const headerIndex = rows.indexOf(firstDataRow);
  return {
    name,
    line,
    endLine,
    headers: firstDataRow,
    rows: rows.slice(headerIndex + 1).filter((row) => !isHline(row)),
  };
}

function collectNamedOrgTables(input: string): Map<string, NamedOrgTable> {
  const lines = input.replace(/\r\n/g, "\n").split("\n");
  const tables = new Map<string, NamedOrgTable>();
  let pendingName = "";
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] || "";
    const keyword = parseKeywordLine(line);
    if (keyword) {
      pendingName = keyword.key === "NAME" ? keyword.value : pendingName;
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
      if (pendingName) {
        const table = parseNamedOrgTable(pendingName, tableStartLine, i, tableLines);
        if (table) tables.set(pendingName, table);
      }
      pendingName = "";
      continue;
    }

    if (line.trim() !== "") pendingName = "";
    i++;
  }

  return tables;
}

function parseDataset(block: FencedBlock, baseDir: string, namedTables: Map<string, NamedOrgTable>): { dataset?: DataQueryDataset; diagnostics: DataQueryDiagnostic[] } {
  const diagnostics: DataQueryDiagnostic[] = [];
  const id = argValue(block.args, ["id", "name"]) || positionalArg(block.args) || "";
  if (!id) diagnostics.push(diagnostic("Dataset block requires a name, e.g. ```dataset fetches", { line: block.line }));

  const values = parseKeyValueBody(block.body);
  const typeRaw = (values.get("type") || "").toLowerCase();
  const type = typeRaw === "org-table" ? "table" : typeRaw;
  const engineRaw = (values.get("engine") || "duckdb").toLowerCase();
  const sourcePath = values.get("path") || values.get("file") || "";
  const sourceUrl = values.get("url") || values.get("uri") || values.get("endpoint") || "";
  const sourceTable = values.get("source") || values.get("table") || "";

  if (!SUPPORTED_DATASET_TYPES.has(typeRaw)) {
    diagnostics.push(diagnostic("Dataset type must be csv, parquet, json, or table", { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  if (engineRaw && engineRaw !== "duckdb") {
    diagnostics.push(diagnostic(`Unsupported dataset engine "${engineRaw}"; only duckdb is supported`, { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  if (type === "table" && !sourceTable) {
    diagnostics.push(diagnostic("Table dataset block requires source: named_table", { line: block.line, ...(id ? { blockId: id } : {}) }));
  } else if (type !== "table" && !sourcePath && !sourceUrl) {
    diagnostics.push(diagnostic("Dataset block requires path: ./file.csv or url: https://example.com/file.csv", { line: block.line, ...(id ? { blockId: id } : {}) }));
  } else if (type !== "table" && sourcePath && sourceUrl) {
    diagnostics.push(diagnostic("Dataset block accepts only one of path/file or url/uri/endpoint", { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  const table = type === "table" && sourceTable ? namedTables.get(sourceTable) : undefined;
  if (type === "table" && sourceTable && !table) {
    diagnostics.push(diagnostic(`No named org table found for dataset source "${sourceTable}"`, { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  if (diagnostics.some((item) => item.severity === "error")) return { diagnostics };

  if (type === "table" && table) {
    return {
      dataset: {
        id,
        line: block.line,
        type: "table",
        engine: "duckdb",
        sourceTable,
        source: { line: table.line, endLine: table.endLine },
        rowCount: table.rows.length,
      },
      diagnostics,
    };
  }

  const resolvedPath = sourcePath ? (path.isAbsolute(sourcePath) ? sourcePath : path.resolve(baseDir, sourcePath)) : "";
  return {
    dataset: {
      id,
      line: block.line,
      type: type as DataQueryDataset["type"],
      engine: "duckdb",
      ...(sourcePath ? { path: sourcePath, resolvedPath } : {}),
      ...(sourceUrl ? { url: sourceUrl } : {}),
    },
    diagnostics,
  };
}

function parseSqlBlock(block: FencedBlock): { sql?: DataQuerySqlBlock; diagnostics: DataQueryDiagnostic[] } {
  const resultId = argValue(block.args, ["id", "name"]) || argValue(block.args, ["results", "result"], { separated: false }) || positionalArg(block.args) || "";
  const artifact = argValue(block.args, ["artifact", "out", "output"]);
  const diagnostics: DataQueryDiagnostic[] = [];
  if (!resultId) diagnostics.push(diagnostic("SQL block requires results=NAME", { line: block.line }));
  if (!block.body.trim()) diagnostics.push(diagnostic("SQL block is empty", { line: block.line, ...(resultId ? { blockId: resultId } : {}) }));
  if (diagnostics.some((item) => item.severity === "error")) return { diagnostics };
  return { sql: { resultId, ...(artifact ? { artifact } : {}), line: block.line, endLine: block.endLine, sql: block.body.trim() }, diagnostics };
}

function hasSqlViewArg(block: FencedBlock): boolean {
  return block.args.some((arg) => /^:?view(?:=|:|$)/i.test(arg));
}

function parseSqlViewBlock(block: FencedBlock): { view?: DataQuerySqlView; diagnostics: DataQueryDiagnostic[] } {
  const viewId = argValue(block.args, ["view"]) || argValue(block.args, ["id", "name"]) || positionalArg(block.args) || "";
  const resultId = argValue(block.args, ["results", "result"], { separated: false });
  const diagnostics: DataQueryDiagnostic[] = [];
  if (resultId) diagnostics.push(diagnostic("SQL block cannot declare both view=NAME and results=NAME", { line: block.line, blockId: resultId }));
  if (!viewId) diagnostics.push(diagnostic("SQL view block requires view=NAME", { line: block.line }));
  if (!block.body.trim()) diagnostics.push(diagnostic("SQL view block is empty", { line: block.line, ...(viewId ? { blockId: viewId } : {}) }));
  if (diagnostics.some((item) => item.severity === "error")) return { diagnostics };
  return { view: { id: viewId, line: block.line, endLine: block.endLine, sql: block.body.trim() }, diagnostics };
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

function sqlLiteral(value: string): string {
  const trimmed = value.trim();
  if (trimmed === "") return "NULL";
  if (/^-?(?:\d+|\d*\.\d+)$/.test(trimmed)) return trimmed;
  if (/^(?:true|false)$/i.test(trimmed)) return trimmed.toLowerCase();
  return quoteString(value);
}

function inlineOrgTableView(dataset: DataQueryDataset, table: NamedOrgTable): string {
  if (table.rows.length === 0) {
    const columns = table.headers.map((header) => `NULL AS ${quoteIdentifier(header)}`).join(", ");
    return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT ${columns} WHERE false;`;
  }

  const values = table.rows
    .map((row) => `(${table.headers.map((_, index) => sqlLiteral(row[index] || "")).join(", ")})`)
    .join(", ");
  const columns = table.headers.map(quoteIdentifier).join(", ");
  return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT * FROM (VALUES ${values}) AS t(${columns});`;
}

function viewSql(view: DataQuerySqlView): string {
  return `CREATE OR REPLACE VIEW ${quoteIdentifier(view.id)} AS SELECT * FROM (${view.sql.replace(/;\s*$/, "")}) AS org2_view;`;
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function buildDuckDbScript(datasets: DataQueryDataset[], views: DataQuerySqlView[], sql: string, namedTables: Map<string, NamedOrgTable>): string {
  const setup = datasets.map((dataset) => {
    if (dataset.type === "table" && dataset.sourceTable) {
      const table = namedTables.get(dataset.sourceTable);
      if (table) return inlineOrgTableView(dataset, table);
    }
    const readFn = readFunctionForType(dataset.type);
    return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT * FROM ${readFn}(${quoteString(dataset.url || dataset.resolvedPath || "")});`;
  });
  return [...setup, ...views.map(viewSql), sql.replace(/;\s*$/, "") + ";"].join("\n");
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

function materializedResultTable(resultId: string, rows: Record<string, unknown>[], provenance: NonNullable<DataQueryResult["provenance"]>): string {
  const artifact = provenance.artifact ? ` artifact=${provenance.artifact}` : "";
  return `#+query-data: result=${resultId} rows=${rows.length}${artifact} query_sha256=${provenance.querySha256} script_sha256=${provenance.scriptSha256}\n#+name: ${resultId}\n#+results: query-data-${resultId}\n${rowsToOrgTable(rows)}`;
}

function selectSqlBlockByLine(blocks: DataQuerySqlBlock[], line: number): DataQuerySqlBlock | undefined {
  return blocks.find((block) => line >= block.line && line <= block.endLine) || blocks.find((block) => block.line >= line);
}

export function runOrg2DataQuery(input: string, opts: RunDataQueryOptions = {}): DataQueryResult {
  const file = opts.file;
  const baseDir = file ? path.dirname(path.resolve(file)) : process.cwd();
  const duckdbPath = opts.duckdbPath || "duckdb";
  const diagnostics: DataQueryDiagnostic[] = [];
  const blocks = collectFencedBlocks(input);
  const namedTables = collectNamedOrgTables(input);
  const datasets: DataQueryDataset[] = [];
  const views: DataQuerySqlView[] = [];
  const sqlBlocks: DataQuerySqlBlock[] = [];

  for (const block of blocks) {
    if (block.kind === "dataset" || block.kind === "data") {
      const parsed = parseDataset(block, baseDir, namedTables);
      diagnostics.push(...parsed.diagnostics);
      if (parsed.dataset) datasets.push(parsed.dataset);
    } else if (block.kind === "sql") {
      if (hasSqlViewArg(block)) {
        const parsed = parseSqlViewBlock(block);
        diagnostics.push(...parsed.diagnostics);
        if (parsed.view) views.push(parsed.view);
      } else {
        const parsed = parseSqlBlock(block);
        diagnostics.push(...parsed.diagnostics);
        if (parsed.sql) sqlBlocks.push(parsed.sql);
      }
    }
  }

  const seenDatasetIds = new Set<string>();
  for (const dataset of datasets) {
    if (seenDatasetIds.has(dataset.id)) {
      diagnostics.push(diagnostic(`Duplicate dataset block "${dataset.id}"`, { line: dataset.line, blockId: dataset.id }));
    }
    seenDatasetIds.add(dataset.id);
  }

  const seenViewIds = new Set<string>();
  for (const view of views) {
    if (seenViewIds.has(view.id)) {
      diagnostics.push(diagnostic(`Duplicate SQL view block "${view.id}"`, { line: view.line, blockId: view.id }));
    }
    seenViewIds.add(view.id);
  }

  const seenResultIds = new Set<string>();
  for (const block of sqlBlocks) {
    if (seenResultIds.has(block.resultId)) {
      diagnostics.push(diagnostic(`Duplicate SQL result block "${block.resultId}"`, { line: block.line, blockId: block.resultId }));
    }
    seenResultIds.add(block.resultId);
  }

  const selectedByLine = opts.resultLine && opts.resultLine > 0 ? selectSqlBlockByLine(sqlBlocks, opts.resultLine) : undefined;
  const resultId = opts.resultId?.trim() || selectedByLine?.resultId || (sqlBlocks.length === 1 ? sqlBlocks[0]?.resultId : "");
  const selected = selectedByLine || (resultId ? sqlBlocks.find((block) => block.resultId === resultId) : undefined);
  if (datasets.length === 0) diagnostics.push(diagnostic("No dataset blocks found"));
  if (sqlBlocks.length === 0) diagnostics.push(diagnostic("No SQL result blocks found"));
  if (!resultId && sqlBlocks.length > 1) diagnostics.push(diagnostic("Multiple SQL result blocks found; pass --results NAME or --line N"));
  if (opts.resultLine && opts.resultLine > 0 && !selectedByLine) diagnostics.push(diagnostic(`No SQL result block found at or after line ${opts.resultLine}`, { line: opts.resultLine }));
  if (resultId && !selected) diagnostics.push(diagnostic(`No SQL result block found for "${resultId}"`, { blockId: resultId }));

  if (diagnostics.some((item) => item.severity === "error") || !selected) {
    return { ok: false, engine: "duckdb", ...(resultId ? { resultId } : {}), datasets, views, rowCount: 0, rows: [], diagnostics };
  }

  const script = buildDuckDbScript(datasets, views, selected.sql, namedTables);
  const provenance = {
    resultId: selected.resultId,
    ...(opts.outputArtifact || selected.artifact ? { artifact: opts.outputArtifact || selected.artifact } : {}),
    querySha256: sha256(selected.sql),
    scriptSha256: sha256(script),
    datasetIds: datasets.map((dataset) => dataset.id),
    viewIds: views.map((view) => view.id),
  };
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
    views,
    rowCount: rows.length,
    rows,
    provenance,
    ...(ok ? { orgTable: materializedResultTable(selected.resultId, rows, provenance) } : {}),
    ...(opts.includeScript ? { duckdbScript: script } : {}),
    diagnostics,
  };
}
