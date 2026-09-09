// A foreground executor. OpenOrg owns tools, permissions, edits and history;
// this process only calls the configured model and requests tools over stdio.
export type ObjectValue = Record<string, unknown>;
export interface AgentTool {
  name: string;
  description: string;
  inputSchema: ObjectValue;
}
export interface AgentRequest {
  adapter: "openAI" | "openRouter" | "anthropic" | "ollama";
  endpoint: string;
  apiKey?: string;
  model: string;
  system: string;
  messages: Array<{ role: "user" | "assistant"; content: string }>;
  tools: AgentTool[];
  maxSteps?: number;
}
export interface ToolResult { success: boolean; text: string }
export type AgentEvent =
  | { type: "status"; step: number }
  | { type: "text"; text: string };

const MAX_BYTES = 4 * 1024 * 1024;
const ALLOWED_TOOLS = new Set([
  "org2_workspace_search", "org2_workspace_read",
  "org2_workspace_patch_preview", "org2_workspace_patch_apply",
]);

function object(value: unknown): ObjectValue {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("The model returned an invalid object.");
  }
  return value as ObjectValue;
}

function string(value: unknown): string {
  if (typeof value !== "string") throw new Error("The model returned an invalid string.");
  return value;
}

function bounded(value: unknown): string {
  const encoded = JSON.stringify(value);
  if (Buffer.byteLength(encoded) > MAX_BYTES) {
    throw new Error("The bundled agent context exceeded 4 MiB. Start a shorter conversation or narrow the request.");
  }
  return encoded;
}

async function readResponse(response: Response): Promise<ObjectValue> {
  if (!response.body) throw new Error("The model returned an empty response.");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BYTES) throw new Error("The model response exceeded 4 MiB.");
      chunks.push(value);
    }
    try {
      return object(JSON.parse(Buffer.concat(chunks).toString("utf8")));
    } catch {
      throw new Error("The model returned invalid JSON.");
    }
  } finally {
    await reader.cancel();
  }
}

export async function runBundledAgent(
  request: AgentRequest,
  execute: (name: string, args: ObjectValue) => Promise<ToolResult>,
  emit: (event: AgentEvent) => void,
  signal: AbortSignal,
  fetcher: typeof fetch = fetch,
): Promise<string> {
  const adapter = request.adapter;
  if (!["openAI", "openRouter", "anthropic", "ollama"].includes(adapter)) {
    throw new Error("Unsupported bundled agent provider.");
  }
  const base = new URL(request.endpoint);
  if (!["https:", "http:"].includes(base.protocol) || base.username || base.password || base.search || base.hash) {
    throw new Error("Use an HTTP(S) API base URL without credentials, query or fragment.");
  }
  if (!request.model?.trim()) throw new Error("Choose a model for this destination.");
  if (adapter !== "ollama" && !request.apiKey?.trim()) throw new Error("This provider requires an API key.");
  const maxSteps = request.maxSteps ?? 12;
  if (!Number.isInteger(maxSteps) || maxSteps < 1 || maxSteps > 24) throw new Error("Invalid step limit.");
  if (!Array.isArray(request.tools) || request.tools.some(tool => !ALLOWED_TOOLS.has(tool.name))) {
    throw new Error("Unsupported bundled agent tool.");
  }
  const allowed = new Set(request.tools.map(tool => tool.name));
  const anthropic = adapter === "anthropic";
  const ollama = adapter === "ollama";
  const endpoint = `${base.href.replace(/\/$/, "")}/${anthropic ? "messages" : ollama ? "chat" : "chat/completions"}`;
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (anthropic) {
    headers["x-api-key"] = request.apiKey!;
    headers["anthropic-version"] = "2023-06-01";
  } else if (request.apiKey) {
    headers.Authorization = `Bearer ${request.apiKey}`;
  }
  if (adapter === "openRouter") {
    headers["HTTP-Referer"] = "https://org2.avi.press";
    headers["X-Title"] = "OpenOrg";
  }
  const messages: ObjectValue[] = request.messages.map(message => ({
    role: message.role === "assistant" ? "assistant" : "user",
    content: string(message.content),
  }));
  if (!anthropic) messages.unshift({ role: "system", content: request.system });
  const tools = request.tools.map(tool => anthropic
    ? { name: tool.name, description: tool.description, input_schema: tool.inputSchema }
    : { type: "function", function: { name: tool.name, description: tool.description, parameters: tool.inputSchema } });
  let callCount = 0;
  for (let step = 1; step <= maxSteps; step++) {
    signal.throwIfAborted();
    emit({ type: "status", step });
    const body = bounded({ model: request.model, messages, tools, stream: false,
      ...(anthropic ? { system: request.system, max_tokens: 8192 } : {}) });
    let response: Response;
    try {
      response = await fetcher(endpoint, {
        method: "POST", headers, body, redirect: "error",
        signal: AbortSignal.any([signal, AbortSignal.timeout(120_000)]),
      });
    } catch {
      signal.throwIfAborted();
      throw new Error("The model request failed or timed out. Check the destination connection.");
    }
    if (!response.ok) {
      await response.body?.cancel();
      // Do not echo provider bodies: they may contain request text or credentials.
      throw new Error(`The model returned HTTP ${response.status}. Check the key, model and tool-calling support.`);
    }
    const result = await readResponse(response);
    signal.throwIfAborted();
    let text: string;
    let calls: Array<{ id: string; name: string; arguments: unknown }>;
    if (anthropic) {
      if (!Array.isArray(result.content)) throw new Error("Missing model response content.");
      const content = result.content.map(object);
      text = content.filter(block => block.type === "text").map(block => string(block.text)).join("\n");
      calls = content.filter(block => block.type === "tool_use").map(block => ({
        id: string(block.id), name: string(block.name), arguments: block.input,
      }));
      if (result.stop_reason === "max_tokens") throw new Error("The model response was truncated; no tools were executed from it.");
      messages.push({ role: "assistant", content });
    } else {
      const choice = ollama ? undefined : object((result.choices as unknown[])?.[0]);
      if (choice?.finish_reason === "length") throw new Error("The model response was truncated; no tools were executed from it.");
      const message = object(ollama ? result.message : choice?.message);
      text = message.content == null ? "" : string(message.content);
      if (message.tool_calls != null && !Array.isArray(message.tool_calls)) throw new Error("Invalid model tool calls.");
      calls = ((message.tool_calls ?? []) as unknown[]).map((raw, index) => {
        const call = object(raw);
        const fn = object(call.function);
        return { id: ollama ? `${step}-${index}` : string(call.id), name: string(fn.name), arguments: fn.arguments };
      });
      // Keep provider metadata such as Ollama thinking / OpenRouter reasoning.
      messages.push({ ...message, role: "assistant" });
    }
    if (text) emit({ type: "text", text });
    if (!calls.length) {
      if (!text.trim()) throw new Error("The model returned neither text nor tool calls.");
      return text.trim();
    }
    if (step === maxSteps || callCount + calls.length > 48) {
      throw new Error("The bundled agent reached its tool limit. Review any changes and send a follow-up to continue.");
    }
    const results: ObjectValue[] = [];
    for (const call of calls) {
      signal.throwIfAborted();
      callCount++;
      let toolResult: ToolResult;
      let args: ObjectValue | undefined;
      try {
        args = object(typeof call.arguments === "string" ? JSON.parse(call.arguments) : call.arguments);
      } catch { /* Return a recoverable tool error without echoing raw arguments. */ }
      if (!allowed.has(call.name)) {
        toolResult = { success: false, text: "This tool is not available in the bundled agent." };
      } else if (!args) {
        toolResult = { success: false, text: "Tool arguments must be a JSON object. Correct the arguments and retry." };
      } else {
        toolResult = await execute(call.name, args);
      }
      signal.throwIfAborted();
      bounded(toolResult);
      if (anthropic) {
        results.push({ type: "tool_result", tool_use_id: call.id, content: toolResult.text, is_error: !toolResult.success });
      } else {
        messages.push({ role: "tool", ...(ollama ? { tool_name: call.name } : { tool_call_id: call.id }), content: toolResult.text });
      }
    }
    if (anthropic) messages.push({ role: "user", content: results });
  }
  throw new Error("The bundled agent reached its step limit.");
}
