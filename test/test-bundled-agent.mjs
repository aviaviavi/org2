import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { runBundledAgent } from "../dist/bundledAgent.js";

const tools = [{ name: "org2_workspace_read", description: "Read", inputSchema: { type: "object" } }];
const base = {
  adapter: "ollama", endpoint: "http://localhost:11434/api", model: "fixture", system: "Workspace rules",
  messages: [{ role: "user", content: "Read notes/example.org" }], tools,
};
const signal = () => new AbortController().signal;
const json = value => new Response(JSON.stringify(value), { headers: { "Content-Type": "application/json" } });

for (const adapter of ["openAI", "openRouter", "anthropic", "ollama"]) {
  let step = 0;
  const events = [];
  const executed = [];
  const reply = await runBundledAgent({ ...base, adapter, apiKey: "test-credential" }, async (name, args) => {
    executed.push([name, args]);
    return { success: true, text: "* Example\nThe answer is 42." };
  }, event => events.push(event), signal(), async (url, options) => {
    const body = JSON.parse(options.body);
    assert.equal(options.redirect, "error");
    assert.equal(body.model, "fixture");
    assert.equal(body.tools.length, 1);
    if (adapter === "anthropic") {
      assert.ok(url.endsWith("/messages"));
      assert.equal(options.headers["x-api-key"], "test-credential");
      assert.equal(body.system, base.system);
      if (step++ === 0) return json({ content: [
        { type: "text", text: "I will read it." },
        { type: "tool_use", id: "read1", name: tools[0].name, input: { path: "notes/example.org" } },
        { type: "tool_use", id: "read2", name: tools[0].name, input: { path: "notes/second.org" } },
      ], stop_reason: "tool_use" });
      assert.equal(body.messages.at(-1).role, "user");
      assert.deepEqual(body.messages.at(-1).content.map(result => result.tool_use_id), ["read1", "read2"]);
      return json({ content: [{ type: "text", text: "42. [[notes/example.org][Source]]" }], stop_reason: "end_turn" });
    }
    const ollama = adapter === "ollama";
    assert.ok(url.endsWith(ollama ? "/chat" : "/chat/completions"));
    assert.equal(body.messages[0].role, "system");
    if (step++ === 0) {
      const message = { role: "assistant", content: "I will read it.", tool_calls: [
        { id: "read1", type: "function", function: { name: tools[0].name,
          arguments: ollama ? { path: "notes/example.org" } : JSON.stringify({ path: "notes/example.org" }) } },
      ], ...(ollama ? { thinking: "retained provider metadata" } : {}) };
      return json(ollama ? { message } : { choices: [{ message, finish_reason: "tool_calls" }] });
    }
    assert.equal(body.messages.at(-1).role, "tool");
    assert.equal(body.messages.at(-1)[ollama ? "tool_name" : "tool_call_id"], ollama ? tools[0].name : "read1");
    if (ollama) assert.equal(body.messages.at(-2).thinking, "retained provider metadata");
    const message = { role: "assistant", content: "42. [[notes/example.org][Source]]" };
    return json(ollama ? { message } : { choices: [{ message, finish_reason: "stop" }] });
  });
  assert.equal(reply, "42. [[notes/example.org][Source]]");
  assert.equal(executed.length, adapter === "anthropic" ? 2 : 1);
  assert.deepEqual(executed[0], [tools[0].name, { path: "notes/example.org" }]);
  assert.equal(events.filter(event => event.type === "status").length, 2);
}

// Unknown tools and malformed arguments return recoverable errors, never execute.
for (const call of [
  { name: "exec", arguments: { cmd: "touch forbidden" } },
  { name: tools[0].name, arguments: "not JSON" },
]) {
  let step = 0;
  await runBundledAgent(base, async () => assert.fail("Unsafe call executed"), () => {}, signal(), async (_url, options) => {
    if (step++ === 0) return json({ message: { content: "", tool_calls: [{ function: call }] } });
    assert.match(JSON.parse(options.body).messages.at(-1).content, /not available|JSON object/);
    return json({ message: { content: "I could not do that." } });
  });
}

await assert.rejects(runBundledAgent({ ...base, maxSteps: 1 }, async () => assert.fail("Limit executed a tool"), () => {}, signal(),
  async () => json({ message: { content: "", tool_calls: [{ function: { name: tools[0].name, arguments: {} } }] } })), /tool limit/);
await assert.rejects(runBundledAgent(base, async () => assert.fail(), () => {}, signal(),
  async () => new Response("secret provider body", { status: 401 })), error => error.message.includes("401") && !error.message.includes("secret"));
await assert.rejects(runBundledAgent(base, async () => assert.fail(), () => {}, signal(),
  async () => json({ message: { content: "" } })), /neither text nor tool calls/);
await assert.rejects(runBundledAgent({ ...base, system: "x".repeat(4 * 1024 * 1024) }, async () => assert.fail(), () => {}, signal(),
  async () => assert.fail("Oversized request sent")), /exceeded 4 MiB/);
const cancellation = new AbortController();
await assert.rejects(runBundledAgent(base, async () => {
  cancellation.abort();
  return { success: true, text: "read" };
}, () => {}, cancellation.signal, async () => json({ message: { content: "", tool_calls: [
  { function: { name: tools[0].name, arguments: {} } },
] } })), /abort/i);

// Exercise the actual stdio executable against a local HTTP fixture, including
// host tool round trips, protocol version, and clean process exit.
let requests = 0;
const server = createServer(async (req, res) => {
  let input = "";
  for await (const chunk of req) input += chunk;
  const body = JSON.parse(input);
  if (requests++) assert.equal(body.messages.at(-1).content, "Fixture tool result");
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify({ message: requests === 1
    ? { content: "", tool_calls: [{ function: { name: tools[0].name, arguments: { path: "fixture.org" } } }] }
    : { content: "Fixture answer" } }));
});
server.listen(0, "127.0.0.1");
await once(server, "listening");
try {
  const child = spawn(process.execPath, [new URL("../dist/bundled-agent.js", import.meta.url).pathname], { stdio: ["pipe", "pipe", "pipe"] });
  const exit = once(child, "exit");
  let stdout = "";
  let stderr = "";
  let pending = "";
  child.stderr.on("data", chunk => { stderr += chunk; });
  child.stdout.on("data", chunk => {
    stdout += chunk;
    pending += chunk;
    let index;
    while ((index = pending.indexOf("\n")) >= 0) {
      const event = JSON.parse(pending.slice(0, index));
      pending = pending.slice(index + 1);
      if (event.type === "tool") child.stdin.write(JSON.stringify({ type: "toolResult", id: event.id,
        result: { success: true, text: "Fixture tool result" } }) + "\n");
    }
  });
  child.stdin.write(JSON.stringify({ type: "start", protocol: "openorg:bundled-agent:v1",
    request: { ...base, endpoint: `http://127.0.0.1:${server.address().port}/api` } }) + "\n");
  const timeout = setTimeout(() => child.kill(), 10_000);
  const [status] = await exit;
  clearTimeout(timeout);
  assert.equal(status, 0, stderr + stdout);
  assert.equal(JSON.parse(stdout.trim().split("\n").at(-1)).reply, "Fixture answer");
} finally {
  server.closeAllConnections();
  server.close();
}
console.log("Bundled agent: four provider formats, limits, cancellation, tool safety and stdio passed.");
