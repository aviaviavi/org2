import type { Org2DataSourceConfig } from "./config.js";

export type RemoteDatasetRequest =
  | {
      type: "clickhouse";
      profile: string;
      query: string;
    }
  | {
      type: "metabase";
      profile: string;
      questionId?: number;
      query?: string;
      parameters?: unknown;
    };

export type RemoteDatasetLoadResult = {
  rows: Record<string, unknown>[];
  profile: string;
  sourceType: RemoteDatasetRequest["type"];
};

const DEFAULT_TIMEOUT_MS = 5 * 60_000;
const DEFAULT_MAX_ROWS = 10_000;
const DEFAULT_MAX_RESPONSE_BYTES = 16 * 1024 * 1024;

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function boundedInteger(value: unknown, fallback: number, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  return Math.max(minimum, Math.min(maximum, Math.trunc(value)));
}

function profileUrl(profile: Org2DataSourceConfig, profileName: string): URL {
  let url: URL;
  try {
    url = new URL(String(profile.url || ""));
  } catch {
    throw new Error(`Data source profile "${profileName}" has an invalid URL`);
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error(`Data source profile "${profileName}" must use an HTTP(S) URL`);
  }
  const loopback = url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]";
  if (url.protocol !== "https:" && !loopback) {
    throw new Error(`Data source profile "${profileName}" must use HTTPS unless it targets localhost`);
  }
  return url;
}

function requiredEnvironmentValue(name: string | undefined, profileName: string, purpose: string, env: NodeJS.ProcessEnv): string {
  const variable = String(name || "").trim();
  if (!variable) throw new Error(`Data source profile "${profileName}" requires ${purpose} environment variable metadata`);
  const value = String(env[variable] || "");
  if (!value) throw new Error(`Environment variable ${variable} required by data source profile "${profileName}" is not set`);
  return value;
}

function metabaseDatabaseId(profile: Extract<Org2DataSourceConfig, { type: "metabase" }>, profileName: string, env: NodeJS.ProcessEnv): number {
  const raw = profile.databaseId ?? (profile.databaseIdEnv ? requiredEnvironmentValue(profile.databaseIdEnv, profileName, "a database ID", env) : undefined);
  const value = typeof raw === "number" ? raw : Number.parseInt(String(raw || ""), 10);
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`Data source profile "${profileName}" requires a positive Metabase databaseId or databaseIdEnv`);
  }
  return value;
}

async function responseText(response: Response, maxBytes: number, profileName: string): Promise<string> {
  const contentLength = Number.parseInt(response.headers.get("content-length") || "", 10);
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    throw new Error(`Data source profile "${profileName}" returned more than ${maxBytes} bytes`);
  }
  const reader = response.body?.getReader();
  let body: string;
  if (reader) {
    const chunks: Uint8Array[] = [];
    let byteCount = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      byteCount += value.byteLength;
      if (byteCount > maxBytes) {
        await reader.cancel();
        throw new Error(`Data source profile "${profileName}" returned more than ${maxBytes} bytes`);
      }
      chunks.push(value);
    }
    body = Buffer.concat(chunks.map((chunk) => Buffer.from(chunk))).toString("utf8");
  } else {
    body = await response.text();
    if (Buffer.byteLength(body, "utf8") > maxBytes) {
      throw new Error(`Data source profile "${profileName}" returned more than ${maxBytes} bytes`);
    }
  }
  if (!response.ok) {
    const summary = body.replace(/\s+/g, " ").trim().slice(0, 500);
    if (response.status === 401 || response.status === 403) {
      throw new Error(
        `Data source profile "${profileName}" authentication failed (HTTP ${response.status}). Check its API key and permissions${summary ? `: ${summary}` : ""}`,
      );
    }
    throw new Error(`Data source profile "${profileName}" returned HTTP ${response.status}${summary ? `: ${summary}` : ""}`);
  }
  return body;
}

async function requestJson(
  url: URL,
  init: RequestInit,
  profileName: string,
  timeoutMs: number,
  maxResponseBytes: number,
): Promise<unknown> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { ...init, redirect: "error", signal: controller.signal });
    const body = await responseText(response, maxResponseBytes, profileName);
    try {
      return JSON.parse(body);
    } catch (error) {
      throw new Error(`Data source profile "${profileName}" returned invalid JSON: ${error instanceof Error ? error.message : String(error)}`);
    }
  } catch (error) {
    if (error instanceof Error && error.name === "AbortError") {
      throw new Error(`Data source profile "${profileName}" timed out after ${timeoutMs}ms`);
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function rowsFromJson(value: unknown, profileName: string, maxRows: number): Record<string, unknown>[] {
  const rows = Array.isArray(value)
    ? value
    : isRecord(value) && Array.isArray(value.data)
      ? value.data
      : isRecord(value) && Array.isArray(value.rows)
        ? value.rows
        : null;
  if (!rows || !rows.every(isRecord)) {
    throw new Error(`Data source profile "${profileName}" did not return an array of row objects`);
  }
  if (rows.length > maxRows) {
    throw new Error(`Data source profile "${profileName}" returned ${rows.length} rows; limit is ${maxRows}`);
  }
  return rows;
}

function rowsFromMetabaseDataset(value: unknown, profileName: string, maxRows: number): Record<string, unknown>[] {
  const data = isRecord(value) && isRecord(value.data) ? value.data : undefined;
  const rows = data && Array.isArray(data.rows) ? data.rows : null;
  const cols = data && Array.isArray(data.cols) ? data.cols : null;
  if (!rows || !cols || !rows.every(Array.isArray) || !cols.every(isRecord)) {
    throw new Error(`Data source profile "${profileName}" returned an invalid Metabase dataset response`);
  }
  if (rows.length > maxRows) {
    throw new Error(`Data source profile "${profileName}" returned ${rows.length} rows; limit is ${maxRows}`);
  }
  const names = cols.map((column, index) => String(column.name || column.display_name || `column_${index + 1}`));
  return rows.map((row) => Object.fromEntries(names.map((name, index) => [name, row[index]])));
}

async function loadClickHouse(
  request: Extract<RemoteDatasetRequest, { type: "clickhouse" }>,
  profile: Extract<Org2DataSourceConfig, { type: "clickhouse" }>,
  env: NodeJS.ProcessEnv,
): Promise<Record<string, unknown>[]> {
  const url = profileUrl(profile, request.profile);
  const timeoutMs = boundedInteger(profile.timeoutMs, DEFAULT_TIMEOUT_MS, 1_000, 60 * 60_000);
  const maxRows = boundedInteger(profile.maxRows, DEFAULT_MAX_ROWS, 1, 1_000_000);
  const maxResponseBytes = boundedInteger(profile.maxResponseBytes, DEFAULT_MAX_RESPONSE_BYTES, 1_024, 256 * 1024 * 1024);
  url.searchParams.set("readonly", "2");
  url.searchParams.set("max_result_rows", String(maxRows));
  url.searchParams.set("result_overflow_mode", "throw");
  url.searchParams.set("max_execution_time", String(Math.max(1, Math.ceil(timeoutMs / 1_000))));

  const headers = new Headers({
    "Content-Type": "text/plain; charset=utf-8",
    "X-ClickHouse-Format": "JSON",
  });
  if (profile.database) headers.set("X-ClickHouse-Database", profile.database);
  if (profile.userEnv) headers.set("X-ClickHouse-User", requiredEnvironmentValue(profile.userEnv, request.profile, "a username", env));
  if (profile.passwordEnv) headers.set("X-ClickHouse-Key", requiredEnvironmentValue(profile.passwordEnv, request.profile, "a password", env));

  const value = await requestJson(url, { method: "POST", headers, body: request.query }, request.profile, timeoutMs, maxResponseBytes);
  return rowsFromJson(value, request.profile, maxRows);
}

async function loadMetabase(
  request: Extract<RemoteDatasetRequest, { type: "metabase" }>,
  profile: Extract<Org2DataSourceConfig, { type: "metabase" }>,
  env: NodeJS.ProcessEnv,
): Promise<Record<string, unknown>[]> {
  const baseUrl = profileUrl(profile, request.profile);
  const timeoutMs = boundedInteger(profile.timeoutMs, DEFAULT_TIMEOUT_MS, 1_000, 60 * 60_000);
  const maxRows = boundedInteger(profile.maxRows, DEFAULT_MAX_ROWS, 1, 1_000_000);
  const maxResponseBytes = boundedInteger(profile.maxResponseBytes, DEFAULT_MAX_RESPONSE_BYTES, 1_024, 256 * 1024 * 1024);
  const nativeQuery = String(request.query || "").trim();
  const url = nativeQuery
    ? new URL("api/dataset", baseUrl.href.endsWith("/") ? baseUrl : new URL(`${baseUrl.href}/`))
    : new URL(`api/card/${request.questionId}/query/json`, baseUrl.href.endsWith("/") ? baseUrl : new URL(`${baseUrl.href}/`));
  if (!nativeQuery) url.searchParams.set("format_rows", "false");
  const parameters = request.parameters === undefined
    ? []
    : isRecord(request.parameters) && Array.isArray(request.parameters.parameters)
      ? request.parameters.parameters
      : request.parameters;
  const body = nativeQuery
    ? {
        database: metabaseDatabaseId(profile, request.profile, env),
        type: "native",
        native: { query: nativeQuery },
        parameters,
      }
    : { parameters };
  const value = await requestJson(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-Key": requiredEnvironmentValue(profile.apiKeyEnv, request.profile, "an API key", env),
    },
    body: JSON.stringify(body),
  }, request.profile, timeoutMs, maxResponseBytes);
  return nativeQuery ? rowsFromMetabaseDataset(value, request.profile, maxRows) : rowsFromJson(value, request.profile, maxRows);
}

export async function loadRemoteDataset(
  request: RemoteDatasetRequest,
  profiles: Record<string, Org2DataSourceConfig> | undefined,
  env: NodeJS.ProcessEnv = process.env,
): Promise<RemoteDatasetLoadResult> {
  const profile = profiles?.[request.profile];
  if (!profile) throw new Error(`No data source profile named "${request.profile}" was found in org2.json`);
  if (profile.type !== request.type) {
    throw new Error(`Data source profile "${request.profile}" is ${profile.type}, but the dataset requires ${request.type}`);
  }
  let rows: Record<string, unknown>[];
  if (request.type === "clickhouse" && profile.type === "clickhouse") {
    rows = await loadClickHouse(request, profile, env);
  } else if (request.type === "metabase" && profile.type === "metabase") {
    rows = await loadMetabase(request, profile, env);
  } else {
    throw new Error(`Data source profile "${request.profile}" type changed while loading`);
  }
  return { rows, profile: request.profile, sourceType: request.type };
}
