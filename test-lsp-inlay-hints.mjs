#!/usr/bin/env node

import { spawn } from "node:child_process";

const inlayContent = `* Target Heading
:PROPERTIES:
:ID: alpha-123
:END:

* Links
Unlabeled: [[id:alpha-123]]
Labeled: [[id:alpha-123][Already Named]]
Missing: [[id:missing-999]]
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
    const unlabeledStart = findPosition(inlayContent, "[[id:alpha-123]]");
    if (!unlabeledStart) {
      throw new Error("Could not determine unlabeled ID link position");
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { processId: process.pid, rootUri: "file:///test", capabilities: {} },
    });

    const initResponse = await waitForResponse(1);
    if (!initResponse?.result?.capabilities?.inlayHintProvider) {
      throw new Error(`Expected inlayHintProvider capability, got ${JSON.stringify(initResponse?.result?.capabilities)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///test/inlay.org",
          languageId: "org",
          version: 1,
          text: inlayContent,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 2,
      method: "textDocument/inlayHint",
      params: {
        textDocument: { uri: "file:///test/inlay.org" },
        range: {
          start: { line: 0, character: 0 },
          end: { line: 200, character: 0 },
        },
      },
    });

    const hintsResponse = await waitForResponse(2, 15000);
    const hints = Array.isArray(hintsResponse?.result) ? hintsResponse.result : [];

    if (hints.length !== 1) {
      throw new Error(`Expected exactly one inlay hint for unlabeled ID links, got ${JSON.stringify(hints)}`);
    }

    const hint = hints[0] || {};
    if (String(hint.label || "").includes("Target Heading") !== true) {
      throw new Error(`Expected inlay hint label to include resolved heading title, got ${JSON.stringify(hint)}`);
    }

    const expectedPosition = {
      line: unlabeledStart.line,
      character: unlabeledStart.character + "[[id:alpha-123]]".length,
    };
    if (hint?.position?.line !== expectedPosition.line || hint?.position?.character !== expectedPosition.character) {
      throw new Error(`Expected inlay hint at unlabeled link end ${JSON.stringify(expectedPosition)}, got ${JSON.stringify(hint)}`);
    }

    sendMessage(server, { jsonrpc: "2.0", id: 999, method: "shutdown", params: {} });
    await waitForResponse(999);

    console.log("✓ LSP inlay-hint test passed");
    server.kill();
  } catch (error) {
    server.kill();
    throw error;
  }
}

run().catch((error) => {
  console.error("LSP inlay-hint test failed:", error);
  process.exit(1);
});
