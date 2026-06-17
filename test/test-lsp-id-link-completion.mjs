#!/usr/bin/env node

import { spawn } from "node:child_process";

const idCatalogContent = `* BACKLOG [#A] Alpha Node :work:
:PROPERTIES:
:ID: abc-123
:END:

* WAIT [#B] Beta Node :ops:
:PROPERTIES:
:ID: abd-456
:END:
`;

const completionContent = `* Completion Playground
Link one: [[id:ab]]
Link two: [[id:abc]]
`;

function findPosition(haystack, needle) {
  const index = haystack.indexOf(needle);
  if (index < 0) return null;

  const before = haystack.slice(0, index);
  const lines = before.split("\n");
  return {
    line: lines.length - 1,
    character: lines[lines.length - 1]?.length ?? 0,
  };
}

function sendMessage(proc, message) {
  const content = JSON.stringify(message);
  const headers = `Content-Length: ${Buffer.byteLength(content, "utf8")}\r\n\r\n`;
  proc.stdin.write(headers + content);
}

async function run() {
  const server = spawn("node", ["dist/lsp.js"]);
  const responses = new Map();
  let responseBuffer = "";

  server.stdout.on("data", (data) => {
    responseBuffer += data.toString();
    while (responseBuffer.includes("\r\n\r\n")) {
      const headerEnd = responseBuffer.indexOf("\r\n\r\n");
      const headers = responseBuffer.slice(0, headerEnd);
      responseBuffer = responseBuffer.slice(headerEnd + 4);

      const lengthMatch = headers.match(/Content-Length: (\d+)/);
      if (!lengthMatch) continue;

      const contentLength = Number(lengthMatch[1]);
      if (responseBuffer.length < contentLength) {
        responseBuffer = headers + "\r\n\r\n" + responseBuffer;
        break;
      }

      const payload = responseBuffer.slice(0, contentLength);
      responseBuffer = responseBuffer.slice(contentLength);

      const message = JSON.parse(payload);
      if (Object.prototype.hasOwnProperty.call(message, "id")) {
        responses.set(message.id, message);
      }
    }
  });

  const waitForResponse = (id, timeoutMs = 2500) =>
    new Promise((resolve, reject) => {
      const deadline = Date.now() + timeoutMs;
      const tick = () => {
        if (responses.has(id)) {
          resolve(responses.get(id));
          return;
        }
        if (Date.now() > deadline) {
          reject(new Error(`Timed out waiting for response id=${id}`));
          return;
        }
        setTimeout(tick, 20);
      };
      tick();
    });

  try {
    const broadPosition = findPosition(completionContent, "id:ab");
    const narrowPosition = findPosition(completionContent, "id:abc");
    if (!broadPosition || !narrowPosition) {
      throw new Error("Could not determine completion test cursor positions");
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { processId: process.pid, rootUri: "file:///test", capabilities: {} },
    });

    const initResponse = await waitForResponse(1);
    if (!initResponse?.result?.capabilities?.completionProvider) {
      throw new Error(`Expected completionProvider capability, got ${JSON.stringify(initResponse?.result?.capabilities)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///ids.org",
          languageId: "org",
          version: 1,
          text: idCatalogContent,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///completion.org",
          languageId: "org",
          version: 1,
          text: completionContent,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 2,
      method: "textDocument/completion",
      params: {
        textDocument: { uri: "file:///completion.org" },
        position: {
          line: broadPosition.line,
          character: broadPosition.character + "id:ab".length,
        },
      },
    });

    const broadResponse = await waitForResponse(2);
    const broadItems = Array.isArray(broadResponse?.result) ? broadResponse.result : [];
    const broadLabels = broadItems.map((item) => item?.label);
    if (!broadLabels.includes("abc-123") || !broadLabels.includes("abd-456")) {
      throw new Error(`Expected broad ID completion suggestions, got ${JSON.stringify(broadResponse?.result)}`);
    }
    const alphaItem = broadItems.find((item) => item?.label === "abc-123");
    const betaItem = broadItems.find((item) => item?.label === "abd-456");
    if (!String(alphaItem?.detail || "").includes("Alpha Node") || !String(betaItem?.detail || "").includes("Beta Node")) {
      throw new Error(`Expected completion details to include normalized headline titles, got ${JSON.stringify(broadResponse?.result)}`);
    }
    if (/\[#|:work:|:ops:|\bBACKLOG\b|\bWAIT\b/.test(`${alphaItem?.detail || ""}\n${betaItem?.detail || ""}`)) {
      throw new Error(`Expected completion details to strip TODO/priority/tag syntax, got ${JSON.stringify(broadResponse?.result)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 3,
      method: "textDocument/completion",
      params: {
        textDocument: { uri: "file:///completion.org" },
        position: {
          line: narrowPosition.line,
          character: narrowPosition.character + "id:abc".length,
        },
      },
    });

    const narrowResponse = await waitForResponse(3);
    const narrowLabels = Array.isArray(narrowResponse?.result) ? narrowResponse.result.map((item) => item?.label) : [];
    if (!narrowLabels.includes("abc-123") || narrowLabels.includes("abd-456")) {
      throw new Error(`Expected narrowed ID completion suggestions, got ${JSON.stringify(narrowResponse?.result)}`);
    }

    sendMessage(server, { jsonrpc: "2.0", id: 999, method: "shutdown", params: {} });
    await waitForResponse(999);

    console.log("✓ LSP ID-link completion test passed");
    server.kill();
  } catch (error) {
    server.kill();
    throw error;
  }
}

run().catch((error) => {
  console.error("LSP ID-link completion test failed:", error);
  process.exit(1);
});
