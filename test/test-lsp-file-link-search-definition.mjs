#!/usr/bin/env node

import { spawn } from "node:child_process";

const sourceDoc = `* Source
Heading link: [[file:target.org::*Deep Node]]
Custom link: [[file:target.org::#anchor-1]]
Line link: [[file:target.org::7]]
`;

const targetDoc = `* TODO [#C] Root :meta:
Intro line
* BACKLOG [#A] Deep Node :project:urgent:
:PROPERTIES:
:CUSTOM_ID: anchor-1
:END:
Marker line
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
    const headingPos = findPosition(sourceDoc, "file:target.org::*Deep Node");
    const customPos = findPosition(sourceDoc, "file:target.org::#anchor-1");
    const linePos = findPosition(sourceDoc, "file:target.org::7");
    if (!headingPos || !customPos || !linePos) {
      throw new Error("Could not determine fixture positions");
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { processId: process.pid, rootUri: "file:///workspace", capabilities: {} },
    });

    const initResponse = await waitForResponse(1);
    if (initResponse?.result?.capabilities?.definitionProvider !== true) {
      throw new Error(`Expected definition provider capability, got ${JSON.stringify(initResponse?.result?.capabilities)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///workspace/source.org",
          languageId: "org",
          version: 1,
          text: sourceDoc,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///workspace/target.org",
          languageId: "org",
          version: 1,
          text: targetDoc,
        },
      },
    });

    const navMethods = ["textDocument/definition", "textDocument/declaration", "textDocument/typeDefinition", "textDocument/implementation"];
    for (let i = 0; i < navMethods.length; i++) {
      const id = 10 + i;
      sendMessage(server, {
        jsonrpc: "2.0",
        id,
        method: navMethods[i],
        params: {
          textDocument: { uri: "file:///workspace/source.org" },
          position: {
            line: headingPos.line,
            character: headingPos.character + "file:".length,
          },
        },
      });

      const response = await waitForResponse(id);
      const location = response?.result?.[0];
      if (!location || location.uri !== "file:///workspace/target.org" || location.range?.start?.line !== 2) {
        throw new Error(`${navMethods[i]} should resolve heading search suffix to line 2, got ${JSON.stringify(response?.result)}`);
      }
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 20,
      method: "textDocument/definition",
      params: {
        textDocument: { uri: "file:///workspace/source.org" },
        position: {
          line: customPos.line,
          character: customPos.character + "file:".length,
        },
      },
    });

    const customResponse = await waitForResponse(20);
    const customLocation = customResponse?.result?.[0];
    if (!customLocation || customLocation.uri !== "file:///workspace/target.org" || customLocation.range?.start?.line !== 4) {
      throw new Error(`Custom ID search suffix should resolve to :CUSTOM_ID: line, got ${JSON.stringify(customResponse?.result)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 21,
      method: "textDocument/definition",
      params: {
        textDocument: { uri: "file:///workspace/source.org" },
        position: {
          line: linePos.line,
          character: linePos.character + "file:".length,
        },
      },
    });

    const lineResponse = await waitForResponse(21);
    const lineLocation = lineResponse?.result?.[0];
    if (!lineLocation || lineLocation.uri !== "file:///workspace/target.org" || lineLocation.range?.start?.line !== 6) {
      throw new Error(`Numeric search suffix should resolve to requested target line, got ${JSON.stringify(lineResponse?.result)}`);
    }

    sendMessage(server, { jsonrpc: "2.0", id: 999, method: "shutdown", params: {} });
    await waitForResponse(999);

    console.log("✓ LSP file-link search suffix definition test passed");
    server.kill();
  } catch (error) {
    server.kill();
    throw error;
  }
}

run().catch((error) => {
  console.error("LSP file-link search suffix definition test failed:", error);
  process.exit(1);
});
