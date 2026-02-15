#!/usr/bin/env node

import { spawn } from "node:child_process";

const linkedEditingContent = `* Linked Editing File Playground
Primary: [[file:notes.org]]
Secondary: [[file:notes.org]]
Bare form: [[notes.org]]
Anchored: [[file:notes.org::*Heading]]
Different file: [[file:other.org]]
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
    const fileLinkPos = findPosition(linkedEditingContent, "file:notes.org");
    const anchoredLinkPos = findPosition(linkedEditingContent, "file:notes.org::*Heading");

    if (!fileLinkPos || !anchoredLinkPos) {
      throw new Error("Could not determine linked-editing fixture positions");
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { processId: process.pid, rootUri: "file:///workspace", capabilities: {} },
    });

    const initResponse = await waitForResponse(1);
    if (initResponse?.result?.capabilities?.linkedEditingRangeProvider !== true) {
      throw new Error(`Expected linkedEditingRangeProvider capability, got ${JSON.stringify(initResponse?.result?.capabilities)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///workspace/links.org",
          languageId: "org",
          version: 1,
          text: linkedEditingContent,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 2,
      method: "textDocument/linkedEditingRange",
      params: {
        textDocument: { uri: "file:///workspace/links.org" },
        position: {
          line: fileLinkPos.line,
          character: fileLinkPos.character + "file:".length,
        },
      },
    });

    const sharedResponse = await waitForResponse(2);
    const sharedRanges = Array.isArray(sharedResponse?.result?.ranges) ? sharedResponse.result.ranges : [];

    const expectedLines = new Set([1, 2, 3]);
    const actualLines = new Set(sharedRanges.map((range) => range?.start?.line));
    const hasExpectedLines = Array.from(expectedLines).every((line) => actualLines.has(line));
    const excludesAnchored = !actualLines.has(4);

    if (sharedRanges.length !== 3 || !hasExpectedLines || !excludesAnchored) {
      throw new Error(`Expected 3 shared file-link ranges on lines 1/2/3 (excluding anchored line 4), got ${JSON.stringify(sharedResponse?.result)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 3,
      method: "textDocument/linkedEditingRange",
      params: {
        textDocument: { uri: "file:///workspace/links.org" },
        position: {
          line: anchoredLinkPos.line,
          character: anchoredLinkPos.character + "file:".length,
        },
      },
    });

    const anchoredResponse = await waitForResponse(3);
    if (anchoredResponse?.result !== null) {
      throw new Error(`Expected null linkedEditingRange for unique anchored link, got ${JSON.stringify(anchoredResponse?.result)}`);
    }

    sendMessage(server, { jsonrpc: "2.0", id: 999, method: "shutdown", params: {} });
    await waitForResponse(999);

    console.log("✓ LSP linked editing file-link test passed");
    server.kill();
  } catch (error) {
    server.kill();
    throw error;
  }
}

run().catch((error) => {
  console.error("LSP linked editing file-link test failed:", error);
  process.exit(1);
});
