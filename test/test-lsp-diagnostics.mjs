#!/usr/bin/env node

/**
 * Test LSP diagnostics feature
 * Verifies that parser errors are properly reported as diagnostics
 */

import { spawn } from "node:child_process";

const orgWithErrors = `* Headline 1
Content

*Invalid headline (no space after star)

More content

#+TITLE:\tBadTab

** Valid nested headline
All good here.
`;

async function testLSPDiagnostics() {
  console.log("=== LSP Diagnostics Test ===\n");

  const server = spawn("node", ["dist/lsp.js"]);

  let allMessages = [];
  let buffer = "";
  let testsPassed = 0;
  let testsFailed = 0;

  server.stdout.on("data", (data) => {
    buffer += data.toString();

    while (buffer.includes("\r\n\r\n")) {
      const headerEnd = buffer.indexOf("\r\n\r\n");
      const headers = buffer.substring(0, headerEnd);
      buffer = buffer.substring(headerEnd + 4);

      const lengthMatch = headers.match(/Content-Length: (\d+)/);
      if (!lengthMatch) continue;

      const contentLength = parseInt(lengthMatch[1], 10);
      if (buffer.length < contentLength) {
        buffer = headers + "\r\n\r\n" + buffer;
        break;
      }

      const content = buffer.substring(0, contentLength);
      buffer = buffer.substring(contentLength);

      try {
        const message = JSON.parse(content);
        allMessages.push(message);
      } catch (e) {
        console.error("Failed to parse message:", e);
      }
    }
  });

  return new Promise((resolve) => {
    setTimeout(() => {
      // Test 1: Initialize
      console.log("Test 1: Initialize LSP server");
      sendMessage(server, {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { processId: process.pid, clientInfo: { name: "test" }, rootUri: "file:///test", capabilities: {} },
      });

      setTimeout(() => {
        const initResp = allMessages.find((m) => m.id === 1);
        if (initResp?.result?.capabilities?.textDocumentSync !== undefined) {
          console.log("✓ Server initialized\n");
          testsPassed++;
        } else {
          console.log("✗ Initialization failed\n");
          testsFailed++;
        }

        // Test 2: Open document with errors
        console.log("Test 2: Open document with parse errors");
        sendMessage(server, {
          jsonrpc: "2.0",
          method: "textDocument/didOpen",
          params: {
            textDocument: {
              uri: "file:///test.org",
              languageId: "org",
              version: 1,
              text: orgWithErrors,
            },
          },
        });

        setTimeout(() => {
          // Look for publishDiagnostics notification
          const diagnostic = allMessages.find(
            (m) => m.method === "textDocument/publishDiagnostics" && m.params?.uri === "file:///test.org"
          );

          if (diagnostic) {
            const diagnostics = diagnostic.params.diagnostics;
            console.log(`✓ Received diagnostics notification with ${diagnostics.length} error(s)\n`);

            // Test 3: Verify diagnostic structure
            console.log("Test 3: Verify diagnostic structure");
            let hasValidDiagnostics = true;
            for (const diag of diagnostics) {
              if (!diag.range || typeof diag.range.start?.line !== "number" || !diag.message) {
                hasValidDiagnostics = false;
                break;
              }
            }

            if (hasValidDiagnostics && diagnostics.length > 0) {
              console.log("✓ Diagnostics have valid LSP structure");
              console.log(`  Line/column info present: ${diagnostics.length} errors\n`);
              testsPassed++;

              // Show first error
              if (diagnostics.length > 0) {
                const first = diagnostics[0];
                console.log(`  First error: Line ${first.range.start.line + 1}, Col ${first.range.start.character + 1}`);
                console.log(`  Message: "${first.message}"\n`);
              }
            } else if (diagnostics.length === 0) {
              console.log("✗ Expected diagnostics but got none\n");
              testsFailed++;
            } else {
              console.log("✗ Diagnostics missing required fields\n");
              testsFailed++;
            }
          } else {
            console.log("✗ No diagnostics notification received\n");
            testsFailed++;
          }

          // Test 4: Verify document symbols still work with errors
          console.log("Test 4: Document symbols work despite errors");
          sendMessage(server, {
            jsonrpc: "2.0",
            id: 2,
            method: "textDocument/documentSymbol",
            params: { textDocument: { uri: "file:///test.org" } },
          });

          setTimeout(() => {
            const symbolResp = allMessages.find((m) => m.id === 2);
            if (symbolResp?.result && Array.isArray(symbolResp.result)) {
              console.log(`✓ Document symbols retrieved despite errors (${symbolResp.result.length} symbols)\n`);
              testsPassed++;
            } else {
              console.log("✗ Document symbols request failed\n");
              testsFailed++;
            }

            // Test 5: Verify folding ranges still work
            console.log("Test 5: Folding ranges work despite errors");
            sendMessage(server, {
              jsonrpc: "2.0",
              id: 3,
              method: "textDocument/foldingRange",
              params: { textDocument: { uri: "file:///test.org" } },
            });

            setTimeout(() => {
              const foldResp = allMessages.find((m) => m.id === 3);
              if (foldResp?.result && Array.isArray(foldResp.result)) {
                console.log(`✓ Folding ranges retrieved despite errors (${foldResp.result.length} ranges)\n`);
                testsPassed++;
              } else {
                console.log("✗ Folding ranges request failed\n");
                testsFailed++;
              }

              // Shutdown
              sendMessage(server, {
                jsonrpc: "2.0",
                id: 4,
                method: "shutdown",
              });

              setTimeout(() => {
                server.kill();

                console.log("\n=== Test Summary ===");
                console.log(`Passed: ${testsPassed}`);
                console.log(`Failed: ${testsFailed}`);

                if (testsFailed === 0) {
                  console.log("\n✓ All tests passed!");
                  process.exit(0);
                } else {
                  console.log(`\n✗ ${testsFailed} test(s) failed`);
                  process.exit(1);
                }
              }, 500);
            }, 500);
          }, 500);
        }, 500);
      }, 500);
    }, 1000);

    resolve();
  });
}

function sendMessage(server, message) {
  const content = JSON.stringify(message);
  const contentLength = Buffer.byteLength(content, "utf8");
  const fullMessage = `Content-Length: ${contentLength}\r\n\r\n${content}`;
  server.stdin.write(fullMessage);
}

testLSPDiagnostics();
