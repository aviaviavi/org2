import { runBundledAgent, type AgentRequest, type ToolResult } from "./bundledAgent.js";

// Versioned newline-delimited JSON. Secrets arrive only in the initial stdin
// frame, never argv, environment additions, transcripts or diagnostics.
const abort = new AbortController();
let started = false;
let pending: { id: string; resolve: (result: ToolResult) => void } | undefined;
let buffer = "";
let sequence = 0;
const write = (event: unknown) => process.stdout.write(`${JSON.stringify(event)}\n`);
function fail(message: string) {
  write({ type: "error", message });
  process.exit(1);
}
process.stdin.setEncoding("utf8");
process.stdin.on("end", () => process.exit(started ? 1 : 0));
process.stdin.on("data", (chunk: string) => {
  buffer += chunk;
  if (Buffer.byteLength(buffer) > 8 * 1024 * 1024) fail("Agent input exceeded 8 MiB.");
  let newline: number;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    let frame;
    try { frame = JSON.parse(line); } catch { fail("Invalid agent protocol JSON."); }
    if (!frame || typeof frame !== "object") fail("Invalid agent protocol frame.");
    if (frame.type === "start" && frame.protocol === "openorg:bundled-agent:v1" && !started) {
      started = true;
      void runBundledAgent(frame.request as AgentRequest, (name, args) => new Promise(resolve => {
        const id = String(++sequence);
        pending = { id, resolve };
        write({ type: "tool", id, name, arguments: args });
      }), write, abort.signal).then(reply => {
        write({ type: "done", reply });
        process.stdout.end(() => process.exit(0));
      }).catch(error => fail(error instanceof Error ? error.message : "Bundled agent failed."));
    } else if (frame.type === "toolResult" && pending && frame.id === pending.id
      && typeof frame.result?.success === "boolean" && typeof frame.result?.text === "string") {
      const current = pending;
      pending = undefined;
      current.resolve(frame.result);
    } else if (frame.type === "cancel") {
      abort.abort();
      process.exit(1);
    } else {
      fail("Unexpected agent protocol frame.");
    }
  }
});
