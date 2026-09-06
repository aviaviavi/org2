#!/usr/bin/env node

/**
 * Integration test for LSP server
 * Tests JSON-RPC message handling and basic LSP operations
 */

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { resolve } from "node:path";

const testCases = [
  {
    name: "Initialize",
    request: {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        processId: process.pid,
        clientInfo: { name: "test" },
        rootUri: "file:///test",
        capabilities: {},
      },
    },
  },
  {
    name: "DidOpen",
    request: {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///test.org",
          languageId: "org",
          version: 1,
          text: "* Headline\nContent\n",
        },
      },
    },
  },
  {
    name: "DocumentSymbol",
    request: {
      jsonrpc: "2.0",
      id: 2,
      method: "textDocument/documentSymbol",
      params: {
        textDocument: {
          uri: "file:///test.org",
        },
      },
    },
  },
];

function sendMessage(server, request) {
  const content = JSON.stringify(request);
  server.stdin.write(`Content-Length: ${Buffer.byteLength(content, "utf8")}\r\n\r\n${content}`);
}

async function runTests() {
  console.log("Starting org2 LSP integration tests...\n");

  const server = spawn(process.execPath, ["dist/lsp.js"], { cwd: resolve(".") });

  let responseBuffer = "";
  const responses = [];
  const responsesById = new Map();
  let stderr = "";

  server.stdout.on("data", (data) => {
    responseBuffer += data.toString();

    while (responseBuffer.includes("\r\n\r\n")) {
      const headerEnd = responseBuffer.indexOf("\r\n\r\n");
      const headers = responseBuffer.substring(0, headerEnd);
      responseBuffer = responseBuffer.substring(headerEnd + 4);

      const lengthMatch = headers.match(/Content-Length: (\d+)/);
      if (!lengthMatch) continue;

      const contentLength = parseInt(lengthMatch[1], 10);
      if (responseBuffer.length < contentLength) {
        responseBuffer = headers + "\r\n\r\n" + responseBuffer;
        break;
      }

      const message = responseBuffer.substring(0, contentLength);
      responseBuffer = responseBuffer.substring(contentLength);

      const parsed = JSON.parse(message);
      responses.push(parsed);
      if (Object.prototype.hasOwnProperty.call(parsed, "id")) responsesById.set(parsed.id, parsed);
    }
  });

  server.stderr.on("data", (data) => {
    stderr += data.toString();
  });

  const waitForResponse = (id, timeoutMs = 5000) => new Promise((resolveResponse, reject) => {
    const deadline = Date.now() + timeoutMs;
    const check = () => {
      if (responsesById.has(id)) {
        resolveResponse(responsesById.get(id));
        return;
      }
      if (Date.now() > deadline) {
        reject(new Error(`Timed out waiting for LSP response id=${id}${stderr ? `: ${stderr.trim()}` : ""}`));
        return;
      }
      setTimeout(check, 20);
    };
    check();
  });

  try {
    sendMessage(server, testCases[0].request);
    const initialize = await waitForResponse(1);
    assert.equal(initialize?.error, undefined, `initialize failed: ${JSON.stringify(initialize?.error)}`);
    assert.equal(initialize?.result?.serverInfo?.name, "org2-lsp");
    assert.deepEqual(initialize?.result?.capabilities?.documentLinkProvider, { resolveProvider: false });

    sendMessage(server, { jsonrpc: "2.0", method: "initialized", params: {} });
    sendMessage(server, testCases[1].request);
    sendMessage(server, testCases[2].request);

    const documentSymbols = await waitForResponse(2);
    assert.equal(documentSymbols?.error, undefined, `documentSymbol failed: ${JSON.stringify(documentSymbols?.error)}`);
    assert.deepEqual(documentSymbols?.result?.map((symbol) => symbol.name), ["Headline"]);

    sendMessage(server, { jsonrpc: "2.0", id: 999, method: "shutdown", params: {} });
    await waitForResponse(999);

    console.log("Responses received:", responses.length);
    console.log(JSON.stringify(responses, null, 2));
    console.log("\n✓ LSP integration test passed!");
    return true;
  } finally {
    server.kill();
  }
}

runTests()
  .then((success) => {
    process.exit(success ? 0 : 1);
  })
  .catch((e) => {
    console.error("Test error:", e);
    process.exit(1);
  });
