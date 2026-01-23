#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const PROJECT_ROOT = path.resolve(__dirname, "..");
const DIST_DIR = path.join(PROJECT_ROOT, "dist");

// Test fixture
const testOrgContent = `* First Headline
Some content here.

* Second Headline
More content.

** Nested Headline
Nested content.

* Third Headline
#+BEGIN_SRC typescript
const x = 1;
#+END_SRC

- List item 1
- List item 2
  - Nested item
`;

async function testLSP() {
  console.log("Starting LSP test harness...\n");

  const lspProcess = spawn("node", [path.join(DIST_DIR, "lsp.js")], {
    cwd: PROJECT_ROOT,
  });

  let responseBuffer = "";
  const receivedMessages = [];

  lspProcess.stdout.on("data", (data) => {
    responseBuffer += data.toString();

    // Parse complete messages
    while (responseBuffer.includes("\r\n\r\n")) {
      const headerEnd = responseBuffer.indexOf("\r\n\r\n");
      const headers = responseBuffer.substring(0, headerEnd);
      responseBuffer = responseBuffer.substring(headerEnd + 4);

      const lengthMatch = headers.match(/Content-Length: (\d+)/);
      if (!lengthMatch) continue;

      const contentLength = parseInt(lengthMatch[1], 10);
      if (responseBuffer.length < contentLength) {
        // Not enough data yet, put it back
        responseBuffer = headers + "\r\n\r\n" + responseBuffer;
        break;
      }

      const message = responseBuffer.substring(0, contentLength);
      responseBuffer = responseBuffer.substring(contentLength);

      try {
        const parsed = JSON.parse(message);
        receivedMessages.push(parsed);
        console.log("Received:", JSON.stringify(parsed, null, 2));
      } catch (e) {
        console.error("Failed to parse message:", e);
      }
    }
  });

  lspProcess.stderr.on("data", (data) => {
    console.error("LSP stderr:", data.toString());
  });

  return new Promise((resolve) => {
    setTimeout(() => {
      // Wait a bit for the server to start
      sendInitialize(lspProcess);

      setTimeout(() => {
        sendDidOpen(lspProcess);

        setTimeout(() => {
          sendDocumentSymbol(lspProcess);

          setTimeout(() => {
            sendFoldingRange(lspProcess);

            setTimeout(() => {
              sendShutdown(lspProcess);

              setTimeout(() => {
                lspProcess.kill();
                resolve({
                  messages: receivedMessages,
                  success: receivedMessages.length > 0,
                });
              }, 500);
            }, 500);
          }, 500);
        }, 500);
      }, 500);
    }, 500);
  });
}

function sendMessage(process, message) {
  const content = JSON.stringify(message);
  const headers = `Content-Length: ${Buffer.byteLength(content, "utf8")}\r\n\r\n`;
  process.stdin.write(headers + content);
}

function sendInitialize(process) {
  console.log("\n--- Sending initialize ---");
  sendMessage(process, {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      processId: process.pid,
      clientInfo: { name: "test-client" },
      rootUri: `file://${PROJECT_ROOT}`,
      capabilities: {},
    },
  });
}

function sendDidOpen(process) {
  console.log("\n--- Sending textDocument/didOpen ---");
  sendMessage(process, {
    jsonrpc: "2.0",
    method: "textDocument/didOpen",
    params: {
      textDocument: {
        uri: "file:///test.org",
        languageId: "org",
        version: 1,
        text: testOrgContent,
      },
    },
  });
}

function sendDocumentSymbol(process) {
  console.log("\n--- Sending textDocument/documentSymbol ---");
  sendMessage(process, {
    jsonrpc: "2.0",
    id: 2,
    method: "textDocument/documentSymbol",
    params: {
      textDocument: {
        uri: "file:///test.org",
      },
    },
  });
}

function sendFoldingRange(process) {
  console.log("\n--- Sending textDocument/foldingRange ---");
  sendMessage(process, {
    jsonrpc: "2.0",
    id: 3,
    method: "textDocument/foldingRange",
    params: {
      textDocument: {
        uri: "file:///test.org",
      },
    },
  });
}

function sendShutdown(process) {
  console.log("\n--- Sending shutdown ---");
  sendMessage(process, {
    jsonrpc: "2.0",
    id: 4,
    method: "shutdown",
    params: {},
  });
}

testLSP()
  .then((result) => {
    console.log("\n=== Test Result ===");
    console.log(`Success: ${result.success}`);
    console.log(`Messages received: ${result.messages.length}`);
    process.exit(result.success ? 0 : 1);
  })
  .catch((e) => {
    console.error("Test failed:", e);
    process.exit(1);
  });
