#!/usr/bin/env node

import { spawn } from "node:child_process";

const tableOrgContent = "| a  |b|\n| longer | c |\n|---+---|\n| x | yyy |\n";
const nonTableOrgContent = "* Heading\nPlain text line\n";

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
    sendMessage(server, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { processId: process.pid, rootUri: "file:///test", capabilities: {} },
    });

    const initResponse = await waitForResponse(1);
    const onTypeProvider = initResponse?.result?.capabilities?.documentOnTypeFormattingProvider;
    if (onTypeProvider?.firstTriggerCharacter !== "|") {
      throw new Error(`Expected firstTriggerCharacter='|', got ${JSON.stringify(onTypeProvider)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///on-type-table.org",
          languageId: "org",
          version: 1,
          text: tableOrgContent,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 2,
      method: "textDocument/onTypeFormatting",
      params: {
        textDocument: { uri: "file:///on-type-table.org" },
        position: { line: 3, character: 1 },
        ch: "|",
        options: { tabSize: 2, insertSpaces: true },
      },
    });

    const onTypeResponse = await waitForResponse(2);
    const edits = Array.isArray(onTypeResponse?.result) ? onTypeResponse.result : [];
    const firstEditText = edits[0]?.newText || "";
    if (!edits.length || !firstEditText.includes("| a      | b   |")) {
      throw new Error(`Expected table-format edit from onTypeFormatting, got ${JSON.stringify(onTypeResponse?.result)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///on-type-non-table.org",
          languageId: "org",
          version: 1,
          text: nonTableOrgContent,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 3,
      method: "textDocument/onTypeFormatting",
      params: {
        textDocument: { uri: "file:///on-type-non-table.org" },
        position: { line: 1, character: 5 },
        ch: "|",
        options: { tabSize: 2, insertSpaces: true },
      },
    });

    const noEditResponse = await waitForResponse(3);
    const nonTableEdits = Array.isArray(noEditResponse?.result) ? noEditResponse.result : null;
    if (!nonTableEdits || nonTableEdits.length !== 0) {
      throw new Error(`Expected no edits for non-table onTypeFormatting, got ${JSON.stringify(noEditResponse?.result)}`);
    }

    sendMessage(server, { jsonrpc: "2.0", id: 999, method: "shutdown", params: {} });
    await waitForResponse(999);

    console.log("✓ LSP on-type formatting test passed");
    server.kill();
  } catch (error) {
    server.kill();
    throw error;
  }
}

run().catch((error) => {
  console.error("LSP on-type formatting test failed:", error);
  process.exit(1);
});
