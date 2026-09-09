import assert from "node:assert/strict";
import { spawn } from "node:child_process";
function sendMessage(process, message) {
  const content = JSON.stringify(message);
  const contentLength = Buffer.byteLength(content, "utf8");
  process.stdin.write(`Content-Length: ${contentLength}\r\n\r\n${content}`);
}

function collectResponses(server) {
  const responses = new Map();
  let buffer = "";

  server.stdout.on("data", (data) => {
    buffer += data.toString();

    while (buffer.includes("\r\n\r\n")) {
      const headerEnd = buffer.indexOf("\r\n\r\n");
      const headers = buffer.slice(0, headerEnd);
      buffer = buffer.slice(headerEnd + 4);

      const lengthMatch = headers.match(/Content-Length: (\d+)/);
      if (!lengthMatch) continue;

      const contentLength = Number(lengthMatch[1]);
      if (buffer.length < contentLength) {
        buffer = `${headers}\r\n\r\n${buffer}`;
        break;
      }

      const content = buffer.slice(0, contentLength);
      buffer = buffer.slice(contentLength);
      const response = JSON.parse(content);
      if (response.id !== undefined) {
        responses.set(response.id, response);
      }
    }
  });

  return responses;
}

function waitForResponse(responses, id, timeoutMs = 4000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const timer = setInterval(() => {
      if (responses.has(id)) {
        clearInterval(timer);
        resolve(responses.get(id));
        return;
      }

      if (Date.now() - start > timeoutMs) {
        clearInterval(timer);
        reject(new Error(`Timed out waiting for LSP response ${id}`));
      }
    }, 25);
  });
}


const server = spawn(process.execPath, ["dist/lsp.js"]);
const responses = collectResponses(server);
let id = 0;
const uri = "file:///nonexistent-checkbox-unsaved.org";
async function request(method, params) {
  const requestId = ++id;
  sendMessage(server, { jsonrpc: "2.0", id: requestId, method, params });
  const response = await waitForResponse(responses, requestId);
  assert.equal(response.error, undefined);
  return response.result;
}
try {
  const initialized = await request("initialize", { capabilities: {}, rootUri: "file:///" });
  assert.ok(initialized.capabilities.codeActionProvider.codeActionKinds.includes("refactor.rewrite"));
  let version = 1;
  for (const [before, after] of [[" ", "-"], ["-", "X"], ["x", " "]]) {
    const text = `* Work\n  - [${before}] Task\n#+begin_src org\n- [ ] Literal\n#+end_src\n`;
    sendMessage(server, { jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri, version: version++, languageId: "org", text } } });
    const actions = (line, only) => request("textDocument/codeAction", { textDocument: { uri }, range: { start: { line, character: 10 }, end: { line, character: 10 } }, context: { diagnostics: [], ...(only ? { only } : {}) } });
    const cycle = await actions(1);
    assert.equal(cycle.length, 1);
    assert.equal(cycle[0].title, `Org2: Cycle checkbox to [${after}]`);
    assert.deepEqual(cycle[0].edit.changes[uri], [{ range: { start: { line: 1, character: 5 }, end: { line: 1, character: 6 } }, newText: after }]);
    assert.equal((await actions(1, ["refactor"])).length, 1);
    assert.deepEqual(await actions(1, ["quickfix"]), []);
    assert.deepEqual(await actions(0), []);
    assert.deepEqual(await actions(3), []);
  }
  await request("shutdown", {});
  console.log("✓ LSP checkbox cycling edits unsaved buffers and respects action filters");
} finally { server.kill(); }
