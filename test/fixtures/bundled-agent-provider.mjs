// Local, deterministic UI smoke provider. This is a fixture, not an AI model.
// Use only with OpenOrg Preview's disposable corpus. No credentials required.
import { createServer } from "node:http";

const path = "notes/project.org2";
const model = "openorg-ui-fixture";
const tool = (name, args) => ({ role: "assistant", content: "", tool_calls: [{
  type: "function", function: { name, arguments: args },
}] });
const server = createServer(async (request, response) => {
  response.setHeader("Content-Type", "application/json");
  if (request.method === "GET" && request.url === "/api/tags") {
    response.end(JSON.stringify({ models: [{ name: model, model }] }));
    return;
  }
  if (request.method !== "POST" || request.url !== "/api/chat") {
    response.writeHead(404).end("{}");
    return;
  }
  try {
    let bytes = 0;
    const chunks = [];
    for await (const chunk of request) {
      bytes += chunk.length;
      if (bytes > 4 * 1024 * 1024) throw new Error("Request too large");
      chunks.push(chunk);
    }
    const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    const latest = body.messages.at(-1);
    let message;
    if (!body.tools?.length) {
      message = { role: "assistant", content: "Fixture context-only chat: no workspace tools were offered." };
    } else if (latest?.role !== "tool") {
      message = tool("org2_workspace_read", { path });
    } else {
      let result;
      try { result = JSON.parse(latest.content); } catch { /* Host decline / error. */ }
      if (latest.tool_name === "org2_workspace_read" && result?.exists) {
        message = tool("org2_workspace_patch_preview", { edits: [{
          path, expectedSha256: result.sha256,
          replacementText: result.text + "\n* Bundled agent smoke test\nApplied after native patch review.\n",
        }] });
      } else if (latest.tool_name === "org2_workspace_patch_preview" && result?.previewId) {
        message = tool("org2_workspace_patch_apply", { previewId: result.previewId });
      } else {
        message = { role: "assistant", content: result?.changes
          ? "Fixture smoke test completed. The disposable project note was updated after native review."
          : "Fixture stopped without applying an edit. The host returned: " + latest.content };
      }
    }
    response.end(JSON.stringify({ model, message, done: true }));
  } catch {
    response.writeHead(400).end(JSON.stringify({ error: "Invalid fixture request" }));
  }
});
server.listen(11435, "127.0.0.1", () => {
  console.log(`UI fixture listening at http://127.0.0.1:11435/api; model ${model}. Use only with the disposable Preview corpus.`);
});
