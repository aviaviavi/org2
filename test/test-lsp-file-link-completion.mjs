#!/usr/bin/env node

import { spawn } from "node:child_process";

const completionContent = `* File Completion Playground
Prefixed broad: [[file:projects/]]
Prefixed narrow: [[file:projects/al]]
Bare link: [[arch]]
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
    const prefixedBroadPosition = findPosition(completionContent, "file:projects/");
    const prefixedNarrowPosition = findPosition(completionContent, "file:projects/al");
    const barePosition = findPosition(completionContent, "arch");
    if (!prefixedBroadPosition || !prefixedNarrowPosition || !barePosition) {
      throw new Error("Could not determine file-link completion test cursor positions");
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { processId: process.pid, rootUri: "file:///workspace", capabilities: {} },
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
          uri: "file:///workspace/notes/projects/alpha.org",
          languageId: "org",
          version: 1,
          text: "* Alpha\n",
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///workspace/notes/projects/almanac.org2",
          languageId: "org",
          version: 1,
          text: "* Almanac\n",
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///workspace/notes/projects/beta.org",
          languageId: "org",
          version: 1,
          text: "* Beta\n",
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///workspace/notes/archive.org",
          languageId: "org",
          version: 1,
          text: "* Archive\n",
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///workspace/notes/daily.org",
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
        textDocument: { uri: "file:///workspace/notes/daily.org" },
        position: {
          line: prefixedBroadPosition.line,
          character: prefixedBroadPosition.character + "file:projects/".length,
        },
      },
    });

    const broadResponse = await waitForResponse(2);
    const broadLabels = Array.isArray(broadResponse?.result) ? broadResponse.result.map((item) => item?.label) : [];
    if (
      !broadLabels.includes("projects/alpha.org") ||
      !broadLabels.includes("projects/almanac.org2") ||
      !broadLabels.includes("projects/beta.org") ||
      broadLabels.includes("archive.org")
    ) {
      throw new Error(`Expected broad file-link completion suggestions, got ${JSON.stringify(broadResponse?.result)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 3,
      method: "textDocument/completion",
      params: {
        textDocument: { uri: "file:///workspace/notes/daily.org" },
        position: {
          line: prefixedNarrowPosition.line,
          character: prefixedNarrowPosition.character + "file:projects/al".length,
        },
      },
    });

    const narrowResponse = await waitForResponse(3);
    const narrowLabels = Array.isArray(narrowResponse?.result) ? narrowResponse.result.map((item) => item?.label) : [];
    if (
      !narrowLabels.includes("projects/alpha.org") ||
      !narrowLabels.includes("projects/almanac.org2") ||
      narrowLabels.includes("projects/beta.org")
    ) {
      throw new Error(`Expected narrowed file-link completion suggestions, got ${JSON.stringify(narrowResponse?.result)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 4,
      method: "textDocument/completion",
      params: {
        textDocument: { uri: "file:///workspace/notes/daily.org" },
        position: {
          line: barePosition.line,
          character: barePosition.character + "arch".length,
        },
      },
    });

    const bareResponse = await waitForResponse(4);
    const bareLabels = Array.isArray(bareResponse?.result) ? bareResponse.result.map((item) => item?.label) : [];
    if (!bareLabels.includes("archive.org") || bareLabels.some((label) => String(label || "").startsWith("projects/"))) {
      throw new Error(`Expected bare-link completion to suggest archive.org only, got ${JSON.stringify(bareResponse?.result)}`);
    }

    sendMessage(server, { jsonrpc: "2.0", id: 999, method: "shutdown", params: {} });
    await waitForResponse(999);

    console.log("✓ LSP file-link completion test passed");
    server.kill();
  } catch (error) {
    server.kill();
    throw error;
  }
}

run().catch((error) => {
  console.error("LSP file-link completion test failed:", error);
  process.exit(1);
});
