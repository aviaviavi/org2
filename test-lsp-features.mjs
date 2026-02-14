#!/usr/bin/env node

/**
 * Test LSP feature coverage (symbols, folding, highlights, rename)
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

* Rename Playground
:PROPERTIES:
:ID: abc-123
:END:
Link one: [[id:abc-123][target]]
Link two: [[id:abc-123]]
`;

function findPosition(haystack, needle) {
  const index = haystack.indexOf(needle);
  if (index < 0) return null;

  const before = haystack.slice(0, index);
  const lines = before.split("\n");
  const line = lines.length - 1;
  const character = lines[lines.length - 1]?.length ?? 0;
  return { line, character };
}

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
      const renameLinkPos = findPosition(testOrgContent, "id:abc-123");

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

              // Test 5: DocumentHighlight (ID link + declaration in same document)
              console.log("Test 5: DocumentHighlight");
              if (!renameLinkPos) {
                console.log("✗ Could not find documentHighlight test token\n");
                testsFailed++;
              } else {
                sendMessage(server, {
                  jsonrpc: "2.0",
                  id: 4,
                  method: "textDocument/documentHighlight",
                  params: {
                    textDocument: { uri: "file:///test.org" },
                    position: { line: renameLinkPos.line, character: renameLinkPos.character + 4 },
                  },
                });
              }

              setTimeout(() => {
                const highlightResponse = allResponses.find((r) => r.id === 4);
                const highlights = Array.isArray(highlightResponse?.result) ? highlightResponse.result : null;
                if (highlights) {
                  const hasRead = highlights.some((h) => h?.kind === 2);
                  const hasWrite = highlights.some((h) => h?.kind === 3);
                  if (highlights.length >= 3 && hasRead && hasWrite) {
                    console.log(`✓ DocumentHighlight returned ${highlights.length} highlights (read + write)`);
                    testsPassed++;
                  } else {
                    console.log(`✗ DocumentHighlight missing expected highlight kinds: ${JSON.stringify(highlights)}`);
                    testsFailed++;
                  }
                } else {
                  console.log("✗ DocumentHighlight failed\n");
                  testsFailed++;
                }
                console.log();

                // Test 6: PrepareRename (ID link target)
                console.log("Test 6: PrepareRename");
                if (!renameLinkPos) {
                  console.log("✗ Could not find rename test token\n");
                  testsFailed++;
                } else {
                  sendMessage(server, {
                    jsonrpc: "2.0",
                    id: 5,
                    method: "textDocument/prepareRename",
                    params: {
                      textDocument: { uri: "file:///test.org" },
                      position: { line: renameLinkPos.line, character: renameLinkPos.character + 4 },
                    },
                  });
                }

                setTimeout(() => {
                  const prepareResponse = allResponses.find((r) => r.id === 5);
                  if (prepareResponse && prepareResponse.result && prepareResponse.result.placeholder) {
                    console.log(`✓ PrepareRename placeholder: ${prepareResponse.result.placeholder}`);
                    testsPassed++;
                  } else {
                    console.log("✗ PrepareRename failed\n");
                    testsFailed++;
                  }
                  console.log();

                  // Test 7: Rename (ID links + declaration)
                  console.log("Test 7: Rename");
                  if (!renameLinkPos) {
                    console.log("✗ Rename skipped (missing token position)\n");
                    testsFailed++;
                  } else {
                    sendMessage(server, {
                      jsonrpc: "2.0",
                      id: 6,
                      method: "textDocument/rename",
                      params: {
                        textDocument: { uri: "file:///test.org" },
                        position: { line: renameLinkPos.line, character: renameLinkPos.character + 4 },
                        newName: "xyz-789",
                      },
                    });
                  }

                  setTimeout(() => {
                    const renameResponse = allResponses.find((r) => r.id === 6);
                    const edits = renameResponse?.result?.changes?.["file:///test.org"];
                    if (Array.isArray(edits)) {
                      const hasLinkEdit = edits.some((edit) => edit?.newText === "id:xyz-789");
                      const hasDefinitionEdit = edits.some((edit) => edit?.newText === "xyz-789");
                      if (hasLinkEdit && hasDefinitionEdit && edits.length >= 3) {
                        console.log(`✓ Rename produced ${edits.length} edits (links + declaration)`);
                        testsPassed++;
                      } else {
                        console.log(`✗ Rename edits missing expected replacements: ${JSON.stringify(edits)}`);
                        testsFailed++;
                      }
                    } else {
                      console.log("✗ Rename failed\n");
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
