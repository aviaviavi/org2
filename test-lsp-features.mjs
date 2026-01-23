#!/usr/bin/env node

/**
 * Test LSP documentSymbol and foldingRange features
 */

import { spawn } from "node:child_process";

const testOrgContent = `* First Headline
Some content here.

** Nested Headline
Nested content.

* Second Headline
More content here.

#+BEGIN_SRC typescript
const x = 1;
const y = 2;
#+END_SRC

Some text after code block.

- List item 1
- List item 2
  - Nested item

* Third Headline
Final content.
`;

async function testLSPFeatures() {
  console.log("=== LSP Features Test ===\n");

  const server = spawn("node", ["dist/lsp.js"]);

  let allResponses = [];
  let responseBuffer = "";
  let testsPassed = 0;
  let testsFailed = 0;

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
      allResponses.push(parsed);
    }
  });

  return new Promise((resolve) => {
    setTimeout(() => {
      // Test 1: Initialize
      console.log("Test 1: Initialize");
      sendMessage(server, {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { processId: process.pid, clientInfo: { name: "test" }, rootUri: "file:///test", capabilities: {} },
      });

      setTimeout(() => {
        const initResponse = allResponses.find((r) => r.id === 1);
        if (initResponse && initResponse.result && initResponse.result.capabilities) {
          console.log("✓ Initialize response received\n");
          testsPassed++;
        } else {
          console.log("✗ Initialize failed\n");
          testsFailed++;
        }

        // Test 2: DidOpen
        console.log("Test 2: DidOpen");
        sendMessage(server, {
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

        setTimeout(() => {
          console.log("✓ DidOpen sent (no response expected)\n");
          testsPassed++;

          // Test 3: DocumentSymbol
          console.log("Test 3: DocumentSymbol");
          sendMessage(server, {
            jsonrpc: "2.0",
            id: 2,
            method: "textDocument/documentSymbol",
            params: {
              textDocument: { uri: "file:///test.org" },
            },
          });

          setTimeout(() => {
            const symbolResponse = allResponses.find((r) => r.id === 2);
            if (symbolResponse && Array.isArray(symbolResponse.result)) {
              const symbols = symbolResponse.result;
              console.log(`✓ DocumentSymbol response received with ${symbols.length} symbols`);
              if (symbols.length >= 3) {
                console.log(`✓ Found expected headlines (${symbols.length})`);
                testsPassed++;
              } else {
                console.log(`✗ Expected 3+ headlines, got ${symbols.length}`);
                testsFailed++;
              }
              console.log(JSON.stringify(symbols.slice(0, 2), null, 2));
            } else {
              console.log("✗ DocumentSymbol failed\n");
              testsFailed++;
            }
            console.log();

            // Test 4: FoldingRange
            console.log("Test 4: FoldingRange");
            sendMessage(server, {
              jsonrpc: "2.0",
              id: 3,
              method: "textDocument/foldingRange",
              params: {
                textDocument: { uri: "file:///test.org" },
              },
            });

            setTimeout(() => {
              const rangeResponse = allResponses.find((r) => r.id === 3);
              if (rangeResponse && Array.isArray(rangeResponse.result)) {
                const ranges = rangeResponse.result;
                console.log(`✓ FoldingRange response received with ${ranges.length} ranges`);
                testsPassed++;
                console.log(JSON.stringify(ranges.slice(0, 3), null, 2));
              } else {
                console.log("✗ FoldingRange failed\n");
                testsFailed++;
              }
              console.log();

              // Shutdown
              console.log("Shutting down...");
              sendMessage(server, {
                jsonrpc: "2.0",
                id: 999,
                method: "shutdown",
                params: {},
              });

              setTimeout(() => {
                server.kill();

                console.log("\n=== Test Summary ===");
                console.log(`Passed: ${testsPassed}`);
                console.log(`Failed: ${testsFailed}`);

                resolve(testsFailed === 0);
              }, 200);
            }, 300);
          }, 300);
        }, 300);
      }, 300);
    }, 500);
  });
}

function sendMessage(process, message) {
  const content = JSON.stringify(message);
  const contentLength = Buffer.byteLength(content, "utf8");
  const headers = `Content-Length: ${contentLength}\r\n\r\n`;
  process.stdin.write(headers + content);
}

testLSPFeatures()
  .then((success) => {
    process.exit(success ? 0 : 1);
  })
  .catch((e) => {
    console.error("Test error:", e);
    process.exit(1);
  });
