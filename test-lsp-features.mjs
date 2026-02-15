#!/usr/bin/env node

/**
 * Test LSP feature coverage (symbols, folding, highlights, rename, linked editing, code actions, formatting, selection ranges, signature help, semantic tokens, code lenses, document colors)
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

const quickFixOrgContent = "* Quickfix Playground\r\n\tTabbed line\r\n";
const formattingOrgContent = "| a  |b|\n| longer | c |\n|---+---|\n| x | yyy |\n";
const rangeFormattingOrgContent = "* Keep\nBody.\n\n| a|bb |\n|longer| c|\n|--+--|\n|x|yyy|\n\n* Tail\nunchanged\n";
const signatureHelpOrgContent = "* Signature Playground\nSCHEDULED: <2026-02-14 Sat>\nDEADLINE: [2026-02-15 Sun]\n";
const semanticTokensOrgContent = `* TODO Semantic Playground
SCHEDULED: <2026-02-14 Sat>
:PROPERTIES:
:ID: semantic-123
:END:
Link: [[id:semantic-123][Semantic Playground]]
`;
const colorOrgContent = `* Color Playground
:PROPERTIES:
:THEME_COLOR: #12abef
:FADE: #33669980
:SHORT: #f0a
:END:
`;
const expectedFormattedTableSnippet = "| a      | b   |";
const expectedRangeFormattedSnippet = "| a      | bb  |";

function findPosition(haystack, needle) {
  const index = haystack.indexOf(needle);
  if (index < 0) return null;

  const before = haystack.slice(0, index);
  const lines = before.split("\n");
  const line = lines.length - 1;
  const character = lines[lines.length - 1]?.length ?? 0;
  return { line, character };
}

function flattenSelectionRanges(selectionRange) {
  const ranges = [];
  let current = selectionRange;
  while (current && current.range) {
    ranges.push(current.range);
    current = current.parent;
  }
  return ranges;
}

function decodeSemanticTokenData(data) {
  const tokens = [];
  let line = 0;
  let start = 0;

  for (let i = 0; i + 4 < data.length; i += 5) {
    const deltaLine = data[i];
    const deltaStart = data[i + 1];
    const length = data[i + 2];
    const tokenType = data[i + 3];
    const tokenModifiers = data[i + 4];

    line += deltaLine;
    start = deltaLine === 0 ? start + deltaStart : deltaStart;

    tokens.push({ line, start, length, tokenType, tokenModifiers });
  }

  return tokens;
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
      const scheduledKeywordPos = findPosition(signatureHelpOrgContent, "SCHEDULED:");
      const deadlineKeywordPos = findPosition(signatureHelpOrgContent, "DEADLINE:");

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
        const capabilities = initResponse?.result?.capabilities;
        const semanticTypes = capabilities?.semanticTokensProvider?.legend?.tokenTypes;
        const semanticLegendOk =
          Array.isArray(semanticTypes) &&
          semanticTypes.includes("keyword") &&
          semanticTypes.includes("property") &&
          semanticTypes.includes("string");
        const codeLensOk = capabilities?.codeLensProvider?.resolveProvider === false;
        const linkedEditingOk = capabilities?.linkedEditingRangeProvider === true;
        const documentColorOk = capabilities?.colorProvider === true;
        if (
          capabilities &&
          capabilities.signatureHelpProvider &&
          semanticLegendOk &&
          codeLensOk &&
          linkedEditingOk &&
          documentColorOk
        ) {
          console.log(
            "✓ Initialize response received (signatureHelp + semanticTokens + codeLens + linkedEditingRange + documentColor advertised)\n"
          );
          testsPassed++;
        } else {
          console.log("✗ Initialize failed or required LSP capabilities missing\n");
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

                    // Test 8: CodeAction quick fixes (CRLF + tabs)
                    console.log("Test 8: CodeAction");
                    sendMessage(server, {
                      jsonrpc: "2.0",
                      method: "textDocument/didOpen",
                      params: {
                        textDocument: {
                          uri: "file:///quickfix.org",
                          languageId: "org",
                          version: 1,
                          text: quickFixOrgContent,
                        },
                      },
                    });

                    setTimeout(() => {
                      sendMessage(server, {
                        jsonrpc: "2.0",
                        id: 7,
                        method: "textDocument/codeAction",
                        params: {
                          textDocument: { uri: "file:///quickfix.org" },
                          range: {
                            start: { line: 0, character: 0 },
                            end: { line: 1, character: 5 },
                          },
                          context: {
                            diagnostics: [
                              {
                                range: {
                                  start: { line: 0, character: 0 },
                                  end: { line: 0, character: 0 },
                                },
                                severity: 1,
                                message: "Unsupported line endings: CRLF",
                                code: "org2-parser",
                              },
                              {
                                range: {
                                  start: { line: 1, character: 0 },
                                  end: { line: 1, character: 1 },
                                },
                                severity: 1,
                                message: "Unsupported construct: tab character",
                                code: "org2-parser",
                              },
                            ],
                          },
                        },
                      });

                      setTimeout(() => {
                        const codeActionResponse = allResponses.find((r) => r.id === 7);
                        const actions = Array.isArray(codeActionResponse?.result) ? codeActionResponse.result : null;
                        if (actions) {
                          const hasCrLfFix = actions.some((action) => action?.title?.includes("CRLF"));
                          const hasTabFix = actions.some((action) => action?.title?.includes("tab"));
                          if (hasCrLfFix && hasTabFix) {
                            console.log(`✓ CodeAction returned quick fixes (${actions.length})`);
                            testsPassed++;
                          } else {
                            console.log(`✗ CodeAction missing expected quick fixes: ${JSON.stringify(actions)}`);
                            testsFailed++;
                          }
                        } else {
                          console.log("✗ CodeAction failed\n");
                          testsFailed++;
                        }
                        console.log();

                        // Test 9: Document formatting
                        console.log("Test 9: Formatting");
                        sendMessage(server, {
                          jsonrpc: "2.0",
                          method: "textDocument/didOpen",
                          params: {
                            textDocument: {
                              uri: "file:///formatting.org",
                              languageId: "org",
                              version: 1,
                              text: formattingOrgContent,
                            },
                          },
                        });

                        setTimeout(() => {
                          sendMessage(server, {
                            jsonrpc: "2.0",
                            id: 8,
                            method: "textDocument/formatting",
                            params: {
                              textDocument: { uri: "file:///formatting.org" },
                              options: {
                                tabSize: 2,
                                insertSpaces: true,
                              },
                            },
                          });

                          setTimeout(() => {
                            const formattingResponse = allResponses.find((r) => r.id === 8);
                            const formattingEdits = Array.isArray(formattingResponse?.result) ? formattingResponse.result : null;
                            const formattedText = formattingEdits?.[0]?.newText || "";
                            if (formattingEdits && formattingEdits.length > 0 && formattedText.includes(expectedFormattedTableSnippet)) {
                              console.log(`✓ Formatting returned ${formattingEdits.length} edit(s)`);
                              testsPassed++;
                            } else {
                              console.log(`✗ Formatting missing expected table alignment edit: ${JSON.stringify(formattingResponse)}`);
                              testsFailed++;
                            }
                            console.log();

                            // Test 10: Range formatting
                            console.log("Test 10: RangeFormatting");
                            sendMessage(server, {
                              jsonrpc: "2.0",
                              method: "textDocument/didOpen",
                              params: {
                                textDocument: {
                                  uri: "file:///range-formatting.org",
                                  languageId: "org",
                                  version: 1,
                                  text: rangeFormattingOrgContent,
                                },
                              },
                            });

                            setTimeout(() => {
                              sendMessage(server, {
                                jsonrpc: "2.0",
                                id: 9,
                                method: "textDocument/rangeFormatting",
                                params: {
                                  textDocument: { uri: "file:///range-formatting.org" },
                                  range: {
                                    start: { line: 3, character: 0 },
                                    end: { line: 7, character: 0 },
                                  },
                                  options: {
                                    tabSize: 2,
                                    insertSpaces: true,
                                  },
                                },
                              });

                              setTimeout(() => {
                                const rangeFormattingResponse = allResponses.find((r) => r.id === 9);
                                const rangeFormattingEdits = Array.isArray(rangeFormattingResponse?.result)
                                  ? rangeFormattingResponse.result
                                  : null;
                                const rangeFormattedText = rangeFormattingEdits?.[0]?.newText || "";
                                if (
                                  rangeFormattingEdits &&
                                  rangeFormattingEdits.length > 0 &&
                                  rangeFormattedText.includes(expectedRangeFormattedSnippet)
                                ) {
                                  console.log(`✓ RangeFormatting returned ${rangeFormattingEdits.length} edit(s)`);
                                  testsPassed++;
                                } else {
                                  console.log(
                                    `✗ RangeFormatting missing expected table alignment edit: ${JSON.stringify(rangeFormattingResponse)}`
                                  );
                                  testsFailed++;
                                }
                                console.log();

                                // Test 11: SelectionRange
                                console.log("Test 11: SelectionRange");
                                if (!renameLinkPos) {
                                  console.log("✗ SelectionRange skipped (missing token position)\n");
                                  testsFailed++;
                                } else {
                                  sendMessage(server, {
                                    jsonrpc: "2.0",
                                    id: 10,
                                    method: "textDocument/selectionRange",
                                    params: {
                                      textDocument: { uri: "file:///test.org" },
                                      positions: [{ line: renameLinkPos.line, character: renameLinkPos.character + 4 }],
                                    },
                                  });
                                }

                                setTimeout(() => {
                                  const selectionRangeResponse = allResponses.find((r) => r.id === 10);
                                  const selectionRanges = Array.isArray(selectionRangeResponse?.result)
                                    ? selectionRangeResponse.result
                                    : null;
                                  const flattenedRanges = selectionRanges?.[0]
                                    ? flattenSelectionRanges(selectionRanges[0])
                                    : [];

                                  const expectedTargetStart = renameLinkPos?.character ?? -1;
                                  const expectedTargetEnd = expectedTargetStart + "id:abc-123".length;
                                  const hasTargetRange = flattenedRanges.some(
                                    (range) =>
                                      range?.start?.line === renameLinkPos?.line &&
                                      range?.start?.character === expectedTargetStart &&
                                      range?.end?.line === renameLinkPos?.line &&
                                      range?.end?.character === expectedTargetEnd
                                  );
                                  const hasDocumentRange = flattenedRanges.some(
                                    (range) => range?.start?.line === 0 && range?.start?.character === 0
                                  );

                                  if (selectionRanges && flattenedRanges.length >= 3 && hasTargetRange && hasDocumentRange) {
                                    console.log(
                                      `✓ SelectionRange returned nested chain (${flattenedRanges.length} range${flattenedRanges.length === 1 ? "" : "s"})`
                                    );
                                    testsPassed++;
                                  } else {
                                    console.log(`✗ SelectionRange missing expected nested ranges: ${JSON.stringify(selectionRangeResponse)}`);
                                    testsFailed++;
                                  }
                                  console.log();

                                  // Test 12: SignatureHelp (planning keyword timestamp hints)
                                  console.log("Test 12: SignatureHelp");
                                  sendMessage(server, {
                                    jsonrpc: "2.0",
                                    method: "textDocument/didOpen",
                                    params: {
                                      textDocument: {
                                        uri: "file:///signature-help.org",
                                        languageId: "org",
                                        version: 1,
                                        text: signatureHelpOrgContent,
                                      },
                                    },
                                  });

                                  setTimeout(() => {
                                    if (!scheduledKeywordPos || !deadlineKeywordPos) {
                                      console.log("✗ SignatureHelp skipped (missing planning keyword positions)\n");
                                      testsFailed++;
                                    } else {
                                      sendMessage(server, {
                                        jsonrpc: "2.0",
                                        id: 11,
                                        method: "textDocument/signatureHelp",
                                        params: {
                                          textDocument: { uri: "file:///signature-help.org" },
                                          position: {
                                            line: scheduledKeywordPos.line,
                                            character: scheduledKeywordPos.character + "SCHEDULED: <2026".length,
                                          },
                                        },
                                      });

                                      sendMessage(server, {
                                        jsonrpc: "2.0",
                                        id: 12,
                                        method: "textDocument/signatureHelp",
                                        params: {
                                          textDocument: { uri: "file:///signature-help.org" },
                                          position: {
                                            line: deadlineKeywordPos.line,
                                            character: deadlineKeywordPos.character + "DEADLINE: [2026".length,
                                          },
                                        },
                                      });
                                    }

                                    setTimeout(() => {
                                      const scheduledSignatureResponse = allResponses.find((r) => r.id === 11);
                                      const deadlineSignatureResponse = allResponses.find((r) => r.id === 12);

                                      const scheduledSignatures = scheduledSignatureResponse?.result?.signatures;
                                      const deadlineSignatures = deadlineSignatureResponse?.result?.signatures;

                                      const scheduledOk =
                                        Array.isArray(scheduledSignatures) &&
                                        scheduledSignatures.length >= 2 &&
                                        scheduledSignatureResponse?.result?.activeSignature === 0;
                                      const deadlineOk =
                                        Array.isArray(deadlineSignatures) &&
                                        deadlineSignatures.length >= 2 &&
                                        deadlineSignatureResponse?.result?.activeSignature === 1;

                                      if (scheduledOk && deadlineOk) {
                                        console.log("✓ SignatureHelp returned planning timestamp signatures (active + inactive)");
                                        testsPassed++;
                                      } else {
                                        console.log(
                                          `✗ SignatureHelp missing expected signature variants: scheduled=${JSON.stringify(scheduledSignatureResponse)}, deadline=${JSON.stringify(deadlineSignatureResponse)}`
                                        );
                                        testsFailed++;
                                      }
                                      console.log();

                                      // Test 13: SemanticTokens
                                      console.log("Test 13: SemanticTokens");
                                      sendMessage(server, {
                                        jsonrpc: "2.0",
                                        method: "textDocument/didOpen",
                                        params: {
                                          textDocument: {
                                            uri: "file:///semantic-tokens.org",
                                            languageId: "org",
                                            version: 1,
                                            text: semanticTokensOrgContent,
                                          },
                                        },
                                      });

                                      setTimeout(() => {
                                        sendMessage(server, {
                                          jsonrpc: "2.0",
                                          id: 13,
                                          method: "textDocument/semanticTokens/full",
                                          params: {
                                            textDocument: { uri: "file:///semantic-tokens.org" },
                                          },
                                        });

                                        setTimeout(() => {
                                          const semanticTokensResponse = allResponses.find((r) => r.id === 13);
                                          const rawTokenData = Array.isArray(semanticTokensResponse?.result?.data)
                                            ? semanticTokensResponse.result.data
                                            : null;
                                          const decodedTokens = rawTokenData ? decodeSemanticTokenData(rawTokenData) : [];

                                          const hasKeywordToken = decodedTokens.some((token) => token?.tokenType === 0);
                                          const hasPropertyToken = decodedTokens.some((token) => token?.tokenType === 1);
                                          const hasStringToken = decodedTokens.some((token) => token?.tokenType === 2);

                                          if (
                                            rawTokenData &&
                                            decodedTokens.length >= 4 &&
                                            hasKeywordToken &&
                                            hasPropertyToken &&
                                            hasStringToken
                                          ) {
                                            console.log(
                                              `✓ SemanticTokens returned ${decodedTokens.length} token(s) with keyword/property/string coverage`
                                            );
                                            testsPassed++;
                                          } else {
                                            console.log(
                                              `✗ SemanticTokens missing expected token coverage: ${JSON.stringify(semanticTokensResponse)}`
                                            );
                                            testsFailed++;
                                          }
                                          console.log();

                                          // Test 14: CodeLens (backlink counts on :ID:)
                                          console.log("Test 14: CodeLens");
                                          sendMessage(server, {
                                            jsonrpc: "2.0",
                                            id: 14,
                                            method: "textDocument/codeLens",
                                            params: {
                                              textDocument: { uri: "file:///test.org" },
                                            },
                                          });

                                          setTimeout(() => {
                                            const codeLensResponse = allResponses.find((r) => r.id === 14);
                                            const codeLenses = Array.isArray(codeLensResponse?.result) ? codeLensResponse.result : null;
                                            const backlinkLens = codeLenses?.find((lens) =>
                                              typeof lens?.command?.title === "string" && lens.command.title.includes("2 backlinks")
                                            );
                                            if (codeLenses && backlinkLens) {
                                              console.log(`✓ CodeLens returned backlink lens (${codeLenses.length} total lens/lenses)`);
                                              testsPassed++;
                                            } else {
                                              console.log(`✗ CodeLens missing expected backlink lens: ${JSON.stringify(codeLensResponse)}`);
                                              testsFailed++;
                                            }
                                            console.log();

                                            // Test 15: LinkedEditingRange (ID link + declaration)
                                            console.log("Test 15: LinkedEditingRange");
                                            if (!renameLinkPos) {
                                              console.log("✗ LinkedEditingRange skipped (missing token position)\n");
                                              testsFailed++;
                                            } else {
                                              sendMessage(server, {
                                                jsonrpc: "2.0",
                                                id: 15,
                                                method: "textDocument/linkedEditingRange",
                                                params: {
                                                  textDocument: { uri: "file:///test.org" },
                                                  position: { line: renameLinkPos.line, character: renameLinkPos.character + 4 },
                                                },
                                              });
                                            }

                                            setTimeout(() => {
                                              const linkedEditingResponse = allResponses.find((r) => r.id === 15);
                                              const linkedRanges = Array.isArray(linkedEditingResponse?.result?.ranges)
                                                ? linkedEditingResponse.result.ranges
                                                : null;

                                              const hasCursorRange = linkedRanges?.some(
                                                (range) =>
                                                  range?.start?.line === renameLinkPos?.line &&
                                                  range?.start?.character === renameLinkPos?.character
                                              );
                                              const hasOtherRange = linkedRanges?.some(
                                                (range) => range?.start?.line !== renameLinkPos?.line
                                              );

                                              if (linkedRanges && linkedRanges.length >= 3 && hasCursorRange && hasOtherRange) {
                                                console.log(
                                                  `✓ LinkedEditingRange returned ${linkedRanges.length} synchronized range(s) across links + declaration`
                                                );
                                                testsPassed++;
                                              } else {
                                                console.log(
                                                  `✗ LinkedEditingRange missing expected synchronized ranges: ${JSON.stringify(linkedEditingResponse)}`
                                                );
                                                testsFailed++;
                                              }
                                              console.log();

                                              // Test 16: DocumentColor + ColorPresentation (hex color literals)
                                              console.log("Test 16: DocumentColor + ColorPresentation");
                                              sendMessage(server, {
                                                jsonrpc: "2.0",
                                                method: "textDocument/didOpen",
                                                params: {
                                                  textDocument: {
                                                    uri: "file:///colors.org",
                                                    languageId: "org",
                                                    version: 1,
                                                    text: colorOrgContent,
                                                  },
                                                },
                                              });

                                              setTimeout(() => {
                                                sendMessage(server, {
                                                  jsonrpc: "2.0",
                                                  id: 16,
                                                  method: "textDocument/documentColor",
                                                  params: {
                                                    textDocument: { uri: "file:///colors.org" },
                                                  },
                                                });

                                                setTimeout(() => {
                                                  const documentColorResponse = allResponses.find((r) => r.id === 16);
                                                  const colorInfos = Array.isArray(documentColorResponse?.result)
                                                    ? documentColorResponse.result
                                                    : null;

                                                  const hasShortHex = colorInfos?.some(
                                                    (info) => info?.range?.start?.line === 4 && info?.range?.end?.character - info?.range?.start?.character === 4
                                                  );
                                                  const hasAlphaHex = colorInfos?.some(
                                                    (info) => info?.range?.start?.line === 3 && info?.range?.end?.character - info?.range?.start?.character === 9
                                                  );

                                                  if (colorInfos && colorInfos.length >= 3 && hasShortHex && hasAlphaHex) {
                                                    console.log(`✓ DocumentColor returned ${colorInfos.length} color range(s) with short+alpha coverage`);
                                                    testsPassed++;
                                                  } else {
                                                    console.log(`✗ DocumentColor missing expected color ranges: ${JSON.stringify(documentColorResponse)}`);
                                                    testsFailed++;
                                                  }

                                                  const firstColor = colorInfos?.[0];
                                                  sendMessage(server, {
                                                    jsonrpc: "2.0",
                                                    id: 17,
                                                    method: "textDocument/colorPresentation",
                                                    params: {
                                                      textDocument: { uri: "file:///colors.org" },
                                                      color: firstColor?.color || { red: 0.07, green: 0.67, blue: 0.94, alpha: 1 },
                                                      range: firstColor?.range || {
                                                        start: { line: 2, character: 14 },
                                                        end: { line: 2, character: 21 },
                                                      },
                                                    },
                                                  });

                                                  setTimeout(() => {
                                                    const colorPresentationResponse = allResponses.find((r) => r.id === 17);
                                                    const presentations = Array.isArray(colorPresentationResponse?.result)
                                                      ? colorPresentationResponse.result
                                                      : null;
                                                    const hasHexLabel = presentations?.some((item) => /^#[A-F0-9]{3,8}$/.test(item?.label || ""));
                                                    const hasTextEdit = presentations?.some(
                                                      (item) => item?.textEdit?.newText && item.textEdit.newText === item?.label
                                                    );

                                                    if (presentations && presentations.length > 0 && hasHexLabel && hasTextEdit) {
                                                      console.log(
                                                        `✓ ColorPresentation returned ${presentations.length} presentation(s) with editable hex labels`
                                                      );
                                                      testsPassed++;
                                                    } else {
                                                      console.log(
                                                        `✗ ColorPresentation missing expected editable labels: ${JSON.stringify(colorPresentationResponse)}`
                                                      );
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
                                    }, 300);
                                  }, 300);
                                }, 300);
                              }, 300);
                            }, 300);
                          }, 300);
                        }, 300);
                      }, 300);
                    }, 300);
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
