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


import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-lsp-corpus-todo-"));
const config = path.join(root, "org2.json");
const file = path.join(root, "tasks.org");
const uri = pathToFileURL(file).href;
fs.writeFileSync(config, JSON.stringify({ todo: { sequences: ["TODO missed | DONE SKIPPED"] } }));
const server = spawn(process.execPath, ["dist/lsp.js"]);
const responses = collectResponses(server);
let id = 0;
async function request(method, params) {
  const requestId = ++id;
  sendMessage(server, { jsonrpc: "2.0", id: requestId, method, params });
  const response = await waitForResponse(responses, requestId);
  assert.equal(response.error, undefined);
  return response.result;
}
try {
  await request("initialize", { capabilities: {}, rootUri: pathToFileURL(root).href });
  const open = (text) => sendMessage(server, { jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri, version: 1, languageId: "org", text } } });
  const complete = (line) => request("textDocument/completion", { textDocument: { uri }, position: { line, character: 2 } });
  open("* \n* missed Follow up\n");
  assert.ok((await complete(0)).some(item => item.label === "missed"));
  const tokens = await request("textDocument/semanticTokens/full", { textDocument: { uri } });
  assert.ok(tokens.data.length > 0);
  fs.writeFileSync(config, JSON.stringify({ todo: { sequences: ["DRAFT | SHIPPED"] } }));
  assert.ok((await complete(0)).some(item => item.label === "DRAFT"));
  assert.ok(!(await complete(0)).some(item => item.label === "missed"));
  open("#+TODO: LOCAL | FINISHED\n* \n");
  const local = await complete(1);
  assert.ok(local.some(item => item.label === "LOCAL"));
  assert.ok(!local.some(item => item.label === "DRAFT"));
  await request("shutdown", {});
  console.log("✓ LSP corpus TODO defaults, live configuration changes, and file precedence");
} finally { server.kill(); fs.rmSync(root, { recursive: true, force: true }); }
