import crypto from "node:crypto";
import http, { type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { handleMcpMessage, ORG2_MCP_PROTOCOL_VERSION } from "./mcpRuntime.js";

const MAXIMUM_REQUEST_BYTES = 2 * 1024 * 1024;

export interface McpHttpAccessToken {
  tokenHash: string;
  scopes: string[];
}

export interface McpHttpServerOptions {
  root: string;
  host: string;
  port: number;
  accessTokens: McpHttpAccessToken[];
  allowedOrigins?: string[];
}

export interface McpHttpServerHandle {
  endpoint: string;
  close(): Promise<void>;
}

function json(response: ServerResponse, statusCode: number, value: unknown): void {
  const body = Buffer.from(`${JSON.stringify(value)}\n`, "utf8");
  response.writeHead(statusCode, {
    "Cache-Control": "no-store",
    "Content-Length": String(body.byteLength),
    "Content-Type": "application/json; charset=utf-8",
    "MCP-Protocol-Version": ORG2_MCP_PROTOCOL_VERSION,
  });
  response.end(body);
}

function empty(response: ServerResponse, statusCode: number, headers: Record<string, string> = {}): void {
  response.writeHead(statusCode, {
    "Cache-Control": "no-store",
    "Content-Length": "0",
    ...headers,
  });
  response.end();
}

function bearerToken(request: IncomingMessage): string | undefined {
  const authorization = request.headers.authorization?.trim();
  if (!authorization?.toLowerCase().startsWith("bearer ")) return undefined;
  const token = authorization.slice(7).trim();
  return token || undefined;
}

function sha256(value: string): Buffer {
  return crypto.createHash("sha256").update(value).digest();
}

function authorized(request: IncomingMessage, accessTokens: McpHttpAccessToken[]): boolean {
  const token = bearerToken(request);
  if (!token) return false;
  const candidate = sha256(token);
  return accessTokens.some((configured) => {
    if (!configured.scopes.includes("corpus:read") || !/^[a-f0-9]{64}$/i.test(configured.tokenHash)) return false;
    const expected = Buffer.from(configured.tokenHash, "hex");
    return expected.byteLength === candidate.byteLength && crypto.timingSafeEqual(expected, candidate);
  });
}

function allowedOrigin(request: IncomingMessage, allowedOrigins: string[]): boolean {
  const origin = request.headers.origin;
  return origin === undefined || allowedOrigins.includes(origin);
}

function requestPath(request: IncomingMessage): string {
  try {
    return new URL(request.url || "/", "http://openorg.invalid").pathname;
  } catch {
    return request.url || "/";
  }
}

function hasSupportedProtocolVersion(request: IncomingMessage): boolean {
  const value = request.headers["mcp-protocol-version"];
  return value === undefined || value === ORG2_MCP_PROTOCOL_VERSION;
}

async function readBody(request: IncomingMessage): Promise<Buffer> {
  const declaredLength = Number(request.headers["content-length"] || 0);
  if (!Number.isFinite(declaredLength) || declaredLength < 0 || declaredLength > MAXIMUM_REQUEST_BYTES) {
    throw new RangeError("MCP request body is too large");
  }
  const chunks: Buffer[] = [];
  let length = 0;
  for await (const chunk of request) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    length += bytes.byteLength;
    if (length > MAXIMUM_REQUEST_BYTES) throw new RangeError("MCP request body is too large");
    chunks.push(bytes);
  }
  return Buffer.concat(chunks);
}

function parseError(message: string): Record<string, unknown> {
  return { jsonrpc: "2.0", id: null, error: { code: -32700, message } };
}

async function handleRequest(request: IncomingMessage, response: ServerResponse, options: McpHttpServerOptions): Promise<void> {
  if (requestPath(request) !== "/mcp") {
    json(response, 404, { error: "Not found" });
    return;
  }
  if (!allowedOrigin(request, options.allowedOrigins ?? [])) {
    json(response, 403, { error: "Origin is not allowed" });
    return;
  }
  if (!authorized(request, options.accessTokens)) {
    response.setHeader("WWW-Authenticate", "Bearer");
    json(response, 401, { error: "A valid read-only OpenOrg access token is required" });
    return;
  }
  if (request.method !== "POST") {
    empty(response, 405, { Allow: "POST" });
    return;
  }
  if (!hasSupportedProtocolVersion(request)) {
    json(response, 400, { jsonrpc: "2.0", id: null, error: { code: -32600, message: `Unsupported MCP-Protocol-Version; use ${ORG2_MCP_PROTOCOL_VERSION}` } });
    return;
  }
  const contentType = request.headers["content-type"] || "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    json(response, 415, { error: "MCP requests must use application/json" });
    return;
  }
  let body: Buffer;
  try {
    body = await readBody(request);
  } catch (error) {
    json(response, error instanceof RangeError ? 413 : 400, { error: error instanceof Error ? error.message : String(error) });
    return;
  }
  let value: unknown;
  try {
    value = JSON.parse(body.toString("utf8"));
  } catch (error) {
    json(response, 400, parseError(error instanceof Error ? error.message : String(error)));
    return;
  }
  const result = await handleMcpMessage(options.root, value, { readOnly: true });
  if (result === null) {
    empty(response, 202, { "MCP-Protocol-Version": ORG2_MCP_PROTOCOL_VERSION });
    return;
  }
  json(response, 200, result);
}

export async function startMcpHttpServer(options: McpHttpServerOptions): Promise<McpHttpServerHandle> {
  const server = http.createServer((request, response) => {
    void handleRequest(request, response, options).catch((error) => {
      if (!response.headersSent) json(response, 500, { error: error instanceof Error ? error.message : String(error) });
      else response.destroy(error instanceof Error ? error : undefined);
    });
  });
  server.headersTimeout = 10_000;
  server.requestTimeout = 65_000;
  server.keepAliveTimeout = 5_000;
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, options.host, () => resolve());
  });
  const address = server.address() as AddressInfo;
  return {
    endpoint: `http://${options.host}:${address.port}/mcp`,
    close: () => new Promise<void>((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
      server.closeAllConnections();
    }),
  };
}

export function mcpAccessTokenHash(token: string): string {
  return crypto.createHash("sha256").update(token).digest("hex");
}
