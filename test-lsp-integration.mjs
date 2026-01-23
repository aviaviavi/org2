#!/usr/bin/env node

/**
 * Integration test for LSP server
 * Tests JSON-RPC message handling and basic LSP operations
 */

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
    expectResult: true,
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
    expectResult: false, // No response expected
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
    expectResult: true,
  },
];

async function runTests() {
  console.log("Starting org2 LSP integration tests...\n");

  const server = spawn("node", ["dist/lsp.js"], { cwd: resolve(".") });

  let responseBuffer = "";
  const responses = [];

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
    }
  });

  // Send test requests
  for (const test of testCases) {
    const content = JSON.stringify(test.request);
    const message = `Content-Length: ${Buffer.byteLength(content, "utf8")}\r\n\r\n${content}`;
    server.stdin.write(message);

    // Wait for response
    await new Promise((resolve) => setTimeout(resolve, 200));
  }

  // Shutdown
  const shutdownContent = JSON.stringify({
    jsonrpc: "2.0",
    id: 999,
    method: "shutdown",
    params: {},
  });
  server.stdin.write(`Content-Length: ${Buffer.byteLength(shutdownContent, "utf8")}\r\n\r\n${shutdownContent}`);

  await new Promise((resolve) => setTimeout(resolve, 500));

  server.kill();

  console.log("Responses received:", responses.length);
  console.log(
    JSON.stringify(responses, null, 2)
  );

  if (responses.length >= 2) {
    console.log("\n✓ LSP integration test passed!");
    return true;
  } else {
    console.log("\n✗ LSP integration test failed - insufficient responses");
    return false;
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
