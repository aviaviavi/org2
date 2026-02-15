#!/usr/bin/env node

import { spawn } from "node:child_process";

const primaryDoc = `* Links
Simple: [[file:notes.org]]
With search: [[file:notes.org::*Roadmap]]
`;

const secondaryDoc = `* Cross refs
Relative: [[../a/notes.org]]
`;

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

  const waitForResponse = (id, timeoutMs = 3000) =>
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
    sendMessage(server, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { processId: process.pid, rootUri: "file:///workspace", capabilities: {} },
    });

    const initResponse = await waitForResponse(1);
    const willRenameFilters = initResponse?.result?.capabilities?.workspace?.fileOperations?.willRename?.filters;
    if (!Array.isArray(willRenameFilters) || willRenameFilters.length === 0) {
      throw new Error(`Expected workspace file-rename capability, got ${JSON.stringify(initResponse?.result?.capabilities)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///workspace/a/index.org",
          languageId: "org",
          version: 1,
          text: primaryDoc,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///workspace/sub/refs.org",
          languageId: "org",
          version: 1,
          text: secondaryDoc,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 2,
      method: "workspace/willRenameFiles",
      params: {
        files: [
          {
            oldUri: "file:///workspace/a/notes.org",
            newUri: "file:///workspace/a/archive/notes-2026.org",
          },
        ],
      },
    });

    const renameResponse = await waitForResponse(2);
    const primaryEdits = renameResponse?.result?.changes?.["file:///workspace/a/index.org"];
    const secondaryEdits = renameResponse?.result?.changes?.["file:///workspace/sub/refs.org"];

    const primaryTexts = Array.isArray(primaryEdits) ? primaryEdits.map((edit) => edit?.newText) : [];
    const secondaryTexts = Array.isArray(secondaryEdits) ? secondaryEdits.map((edit) => edit?.newText) : [];

    const primaryOk =
      primaryTexts.includes("file:archive/notes-2026.org") &&
      primaryTexts.includes("file:archive/notes-2026.org::*Roadmap");
    const secondaryOk = secondaryTexts.includes("../a/archive/notes-2026.org");

    if (!primaryOk || !secondaryOk) {
      throw new Error(`Expected file-link updates from workspace/willRenameFiles, got ${JSON.stringify(renameResponse?.result)}`);
    }

    sendMessage(server, { jsonrpc: "2.0", id: 999, method: "shutdown", params: {} });
    await waitForResponse(999);

    console.log("✓ LSP workspace willRenameFiles test passed");
    server.kill();
  } catch (error) {
    server.kill();
    throw error;
  }
}

run().catch((error) => {
  console.error("LSP workspace willRenameFiles test failed:", error);
  process.exit(1);
});
