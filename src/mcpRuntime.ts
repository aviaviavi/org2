import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { spawnSync } from "node:child_process";
import { listAgentRuns, mutateAgentRun, saveAgentRun, transitionAgentRun } from "./agentRun.js";
import { instantiateWorkflow, listWorkflows, loadWorkflow } from "./agentWorkflow.js";

type JsonObject = Record<string, unknown>;
type JsonRpcId = string | number | null;

interface JsonRpcRequest {
  id?: JsonRpcId;
  method: string;
  params: JsonObject;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id?: JsonRpcId;
  result?: unknown;
  error?: { code: number; message: string };
}

class InvalidJsonRpcRequestError extends Error {}

function jsonObject(value: unknown): JsonObject | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as JsonObject
    : undefined;
}

function parseJsonRpcRequest(value: unknown): JsonRpcRequest {
  const request = jsonObject(value);
  if (!request || request.jsonrpc !== "2.0" || typeof request.method !== "string" || !request.method.trim()) {
    throw new InvalidJsonRpcRequestError("invalid JSON-RPC request");
  }
  if (request.id !== undefined && request.id !== null && typeof request.id !== "string" && typeof request.id !== "number") {
    throw new InvalidJsonRpcRequestError("invalid JSON-RPC request id");
  }
  const params = request.params === undefined ? {} : jsonObject(request.params);
  if (!params) throw new InvalidJsonRpcRequestError("JSON-RPC params must be an object");
  return { id: request.id as JsonRpcId | undefined, method: request.method, params };
}

function parseJsonRpcMessage(line: string): JsonObject {
  const value: unknown = JSON.parse(line);
  const message = jsonObject(value);
  if (!message) throw new Error("MCP client returned a non-object JSON-RPC message");
  return message;
}

function responseResult(message: JsonObject | undefined): JsonObject | undefined {
  return jsonObject(message?.result);
}

function responseArray(message: JsonObject | undefined, key: string): unknown[] {
  const value = responseResult(message)?.[key];
  return Array.isArray(value) ? value : [];
}

function responseErrorMessage(message: JsonObject | undefined): string | undefined {
  if (message?.error === undefined) return undefined;
  const error = jsonObject(message?.error);
  return typeof error?.message === "string" ? error.message : "unknown MCP error";
}

function requiredString(value: unknown, label: string): string {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${label} must be a non-empty string`);
  return value;
}

function optionalString(value: unknown, label: string): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new Error(`${label} must be a string`);
  return value;
}

function stringArray(value: unknown, label: string): string[] | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) {
    throw new Error(`${label} must be an array of strings`);
  }
  return value;
}

function workflowInputs(value: unknown): Record<string, string> {
  if (value === undefined) return {};
  const inputs = jsonObject(value);
  if (!inputs || Object.values(inputs).some((item) => typeof item !== "string")) {
    throw new Error("workflow inputs must be an object with string values");
  }
  return inputs as Record<string, string>;
}

export interface McpClientDefinition {
  id: string;
  command: string;
  args?: string[];
  environmentVariables?: string[];
  capabilities?: string[];
}

export interface McpSnapshot {
  schema: "org2:mcp-snapshot:v1";
  id: string;
  source: string;
  retrievedAt: string;
  identity?: string;
  freshUntil?: string;
  payload: unknown;
}

export function mcpClientConfigPath(root: string): string { return path.join(path.resolve(root), ".org2", "mcp-clients.json"); }
export function loadMcpClients(root: string): McpClientDefinition[] {
  const file = mcpClientConfigPath(root);
  if (!fs.existsSync(file)) return [];
  const value = JSON.parse(fs.readFileSync(file, "utf8")) as { clients?: McpClientDefinition[] } | McpClientDefinition[];
  return Array.isArray(value) ? value : value.clients || [];
}
export function saveMcpClients(root: string, clients: McpClientDefinition[]): string {
  const file = mcpClientConfigPath(root);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({ schema: "org2:mcp-clients:v1", clients }, null, 2)}\n`, "utf8");
  return file;
}
export function writeMcpSnapshot(root: string, snapshot: McpSnapshot): string {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(snapshot.id)) throw new Error("invalid snapshot id");
  const file = path.join(path.resolve(root), "raw", "connectors", "mcp", `${snapshot.id}.json`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(snapshot, null, 2)}\n`, "utf8");
  return file;
}

export function discoverMcpClient(root: string, clientId: string, options: { timeoutMs?: number; snapshotId?: string; now?: string } = {}): { client: McpClientDefinition; capabilities: Record<string, unknown>; snapshot?: string } {
  const client = loadMcpClients(root).find((item) => item.id === clientId);
  if (!client) throw new Error(`MCP client not found: ${clientId}`);
  const requests = [
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "org2", version: "0.3.0" } } },
    { jsonrpc: "2.0", method: "notifications/initialized", params: {} },
    { jsonrpc: "2.0", id: 2, method: "resources/list", params: {} },
    { jsonrpc: "2.0", id: 3, method: "tools/list", params: {} },
    { jsonrpc: "2.0", id: 4, method: "prompts/list", params: {} },
  ];
  const execution = spawnSync(client.command, client.args || [], {
    cwd: path.resolve(root),
    env: process.env,
    input: `${requests.map((item) => JSON.stringify(item)).join("\n")}\n`,
    encoding: "utf8",
    timeout: options.timeoutMs || 10_000,
    maxBuffer: 10 * 1024 * 1024,
  });
  if (execution.error) throw execution.error;
  if (execution.status !== 0) throw new Error(`MCP client ${clientId} exited ${execution.status}: ${String(execution.stderr || "").trim()}`);
  const messages = String(execution.stdout || "").split(/\r?\n/).filter(Boolean).map(parseJsonRpcMessage);
  const byId = new Map<unknown, JsonObject>(messages.filter((item) => item.id !== undefined).map((item) => [item.id, item]));
  const initializeError = responseErrorMessage(byId.get(1));
  if (initializeError) throw new Error(`MCP initialize failed: ${initializeError}`);
  const initializeResult = responseResult(byId.get(1));
  const capabilities = {
    serverInfo: initializeResult?.serverInfo,
    protocolVersion: initializeResult?.protocolVersion,
    advertised: jsonObject(initializeResult?.capabilities) || {},
    resources: responseArray(byId.get(2), "resources"),
    tools: responseArray(byId.get(3), "tools"),
    prompts: responseArray(byId.get(4), "prompts"),
  };
  let snapshot: string | undefined;
  if (options.snapshotId) {
    snapshot = writeMcpSnapshot(root, {
      schema: "org2:mcp-snapshot:v1",
      id: options.snapshotId,
      source: `mcp-client:${client.id}`,
      retrievedAt: new Date(options.now || Date.now()).toISOString(),
      identity: client.id,
      payload: capabilities,
    });
  }
  return { client, capabilities, ...(snapshot ? { snapshot } : {}) };
}

function resourceList(root: string) {
  const files: string[] = [];
  const walk = (dir: string) => {
    if (!fs.existsSync(dir)) return;
    for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
      if ([".git", "node_modules", "dist", "site"].includes(item.name)) continue;
      const absolute = path.join(dir, item.name);
      if (item.isDirectory()) walk(absolute);
      else if (/\.org2?$/.test(item.name)) files.push(absolute);
    }
  };
  walk(root);
  return files.map((file) => ({ uri: `org2://corpus/${path.relative(root, file)}`, name: path.relative(root, file), mimeType: "text/org" }));
}

async function handle(root: string, request: JsonRpcRequest): Promise<JsonRpcResponse | null> {
  const id = request.id;
  const result = (value: unknown): JsonRpcResponse => ({ jsonrpc: "2.0", id, result: value });
  if (request.method === "initialize") return result({ protocolVersion: "2025-03-26", capabilities: { resources: {}, tools: {}, prompts: {} }, serverInfo: { name: "org2", version: "0.3.0" } });
  if (request.method === "notifications/initialized") return null;
  if (request.method === "resources/list") return result({ resources: resourceList(root) });
  if (request.method === "resources/read") {
    const uri = String(request.params.uri || "");
    const prefix = "org2://corpus/";
    if (!uri.startsWith(prefix)) throw new Error("unsupported resource URI");
    const relative = uri.slice(prefix.length);
    const file = path.resolve(root, relative);
    if (!(file === path.resolve(root) || file.startsWith(`${path.resolve(root)}${path.sep}`))) throw new Error("resource is outside the corpus");
    return result({ contents: [{ uri, mimeType: "text/org", text: fs.readFileSync(file, "utf8") }] });
  }
  if (request.method === "prompts/list") return result({ prompts: listWorkflows(root).map((workflow) => ({ name: workflow.id, description: workflow.description, arguments: workflow.inputs.map((input) => ({ name: input.id, description: input.description, required: input.required })) })) });
  if (request.method === "prompts/get") {
    const workflow = loadWorkflow(root, String(request.params.name || ""));
    return result({ description: workflow.description, messages: [{ role: "user", content: { type: "text", text: workflow.instructions } }] });
  }
  if (request.method === "tools/list") return result({ tools: [
    { name: "org2_run_create", description: "Create a durable Org2 agent run from a reusable workflow", inputSchema: { type: "object", required: ["workflow"], properties: { workflow: { type: "string" }, inputs: { type: "object" }, owner: { type: "string" } } } },
    { name: "org2_run_transition", description: "Transition a durable Org2 run. Completion requires a concise, human-readable summary.", inputSchema: { type: "object", required: ["run", "status"], properties: { run: { type: "string" }, status: { type: "string" }, actor: { type: "string" }, reason: { type: "string" }, summary: { type: "string" }, highlights: { type: "array", items: { type: "string" } }, nextActions: { type: "array", items: { type: "string" } } } } },
    { name: "org2_run_list", description: "List durable Org2 runs and review state", inputSchema: { type: "object", properties: {} } },
  ] });
  if (request.method === "tools/call") {
    const name = request.params.name;
    const args = jsonObject(request.params.arguments) || {};
    if (name === "org2_run_list") return result({ content: [{ type: "text", text: JSON.stringify(listAgentRuns(root), null, 2) }] });
    if (name === "org2_run_create") {
      const run = instantiateWorkflow(loadWorkflow(root, requiredString(args.workflow, "workflow")), workflowInputs(args.inputs), { owner: optionalString(args.owner, "owner") });
      const file = saveAgentRun(root, run);
      return result({ content: [{ type: "text", text: JSON.stringify({ run, file }, null, 2) }] });
    }
    if (name === "org2_run_transition") {
      const run = mutateAgentRun(root, requiredString(args.run, "run"), (current) => transitionAgentRun(current, requiredString(args.status, "status") as Parameters<typeof transitionAgentRun>[1], {
        actor: optionalString(args.actor, "actor"), reason: optionalString(args.reason, "reason"), summary: optionalString(args.summary, "summary"),
        highlights: stringArray(args.highlights, "highlights"), nextActions: stringArray(args.nextActions, "nextActions"),
      }));
      return result({ content: [{ type: "text", text: JSON.stringify(run, null, 2) }] });
    }
    throw new Error(`unknown tool: ${name}`);
  }
  return { jsonrpc: "2.0", id, error: { code: -32601, message: `method not found: ${request.method}` } };
}

export async function serveMcp(root: string, input: NodeJS.ReadableStream = process.stdin, output: NodeJS.WritableStream = process.stdout): Promise<void> {
  const lines = readline.createInterface({ input });
  for await (const line of lines) {
    if (!String(line).trim()) continue;
    let response: JsonRpcResponse | null;
    try {
      const value: unknown = JSON.parse(String(line));
      response = await handle(path.resolve(root), parseJsonRpcRequest(value));
    } catch (error) {
      response = {
        jsonrpc: "2.0",
        id: null,
        error: {
          code: error instanceof InvalidJsonRpcRequestError ? -32600 : -32603,
          message: error instanceof Error ? error.message : String(error),
        },
      };
    }
    if (response) output.write(`${JSON.stringify(response)}\n`);
  }
}

/** @deprecated Import from agentWorkflow instead. */
export { installBuiltinWorkflow } from "./agentWorkflow.js";
