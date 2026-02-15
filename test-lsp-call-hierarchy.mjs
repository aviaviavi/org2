#!/usr/bin/env node

import { spawn } from "node:child_process";

const hierarchyContent = `* Target Node
:PROPERTIES:
:ID: abc-123
:END:
Outgoing link: [[id:def-456]]

* Referenced Node
:PROPERTIES:
:ID: def-456
:END:

* Incoming Node
Calls target here: [[id:abc-123]]
Calls target file: [[file:target.org]]
`;

const fileTargetContent = `* File Target
Links to another file: [[file:next.org]]
Links to referenced id: [[id:def-456]]
`;

const nextFileContent = `* Next File
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
    const idLinePos = findPosition(hierarchyContent, ":ID: abc-123");
    const incomingLinkPos = findPosition(hierarchyContent, "id:abc-123");
    const outgoingLinkPos = findPosition(hierarchyContent, "id:def-456");
    const fileLinkPos = findPosition(hierarchyContent, "file:target.org");
    const fileOutgoingLinkPos = findPosition(fileTargetContent, "file:next.org");
    const fileOutgoingIdPos = findPosition(fileTargetContent, "id:def-456");

    if (!idLinePos || !incomingLinkPos || !outgoingLinkPos || !fileLinkPos || !fileOutgoingLinkPos || !fileOutgoingIdPos) {
      throw new Error("Could not determine call hierarchy fixture positions");
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { processId: process.pid, rootUri: "file:///workspace", capabilities: {} },
    });

    const initResponse = await waitForResponse(1);
    if (initResponse?.result?.capabilities?.callHierarchyProvider !== true) {
      throw new Error(`Expected callHierarchyProvider capability, got ${JSON.stringify(initResponse?.result?.capabilities)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///workspace/hierarchy.org",
          languageId: "org",
          version: 1,
          text: hierarchyContent,
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
          text: fileTargetContent,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: "file:///workspace/next.org",
          languageId: "org",
          version: 1,
          text: nextFileContent,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 2,
      method: "textDocument/prepareCallHierarchy",
      params: {
        textDocument: { uri: "file:///workspace/hierarchy.org" },
        position: {
          line: idLinePos.line,
          character: idLinePos.character + ":ID: ".length,
        },
      },
    });

    const prepareIdResponse = await waitForResponse(2);
    const idItems = Array.isArray(prepareIdResponse?.result) ? prepareIdResponse.result : [];
    if (idItems.length === 0 || !String(idItems[0]?.detail || "").toLowerCase().startsWith("id:abc-123")) {
      throw new Error(`Expected prepareCallHierarchy item for id:abc-123, got ${JSON.stringify(prepareIdResponse?.result)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 3,
      method: "callHierarchy/incomingCalls",
      params: { item: idItems[0] },
    });

    const incomingIdResponse = await waitForResponse(3);
    const incomingIdCalls = Array.isArray(incomingIdResponse?.result) ? incomingIdResponse.result : [];
    const incomingIdHasTarget = incomingIdCalls.some((call) => {
      const fromName = String(call?.from?.name || "");
      const ranges = Array.isArray(call?.fromRanges) ? call.fromRanges : [];
      return fromName.includes("Incoming Node") && ranges.some((range) => range?.start?.line === incomingLinkPos.line);
    });
    if (!incomingIdHasTarget) {
      throw new Error(`Expected incoming call from Incoming Node for id target, got ${JSON.stringify(incomingIdResponse?.result)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 4,
      method: "callHierarchy/outgoingCalls",
      params: { item: idItems[0] },
    });

    const outgoingIdResponse = await waitForResponse(4);
    const outgoingIdCalls = Array.isArray(outgoingIdResponse?.result) ? outgoingIdResponse.result : [];
    const outgoingIdHasTarget = outgoingIdCalls.some((call) => {
      const toDetail = String(call?.to?.detail || "").toLowerCase();
      const ranges = Array.isArray(call?.fromRanges) ? call.fromRanges : [];
      return toDetail.startsWith("id:def-456") && ranges.some((range) => range?.start?.line === outgoingLinkPos.line);
    });
    if (!outgoingIdHasTarget) {
      throw new Error(`Expected outgoing call to id:def-456, got ${JSON.stringify(outgoingIdResponse?.result)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 5,
      method: "textDocument/prepareCallHierarchy",
      params: {
        textDocument: { uri: "file:///workspace/hierarchy.org" },
        position: {
          line: fileLinkPos.line,
          character: fileLinkPos.character + "file:".length,
        },
      },
    });

    const prepareFileResponse = await waitForResponse(5);
    const fileItems = Array.isArray(prepareFileResponse?.result) ? prepareFileResponse.result : [];
    if (fileItems.length === 0 || fileItems[0]?.data?.kind !== "file") {
      throw new Error(`Expected prepareCallHierarchy item for file target, got ${JSON.stringify(prepareFileResponse?.result)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 6,
      method: "callHierarchy/incomingCalls",
      params: { item: fileItems[0] },
    });

    const incomingFileResponse = await waitForResponse(6);
    const incomingFileCalls = Array.isArray(incomingFileResponse?.result) ? incomingFileResponse.result : [];
    const incomingFileHasTarget = incomingFileCalls.some((call) => {
      const fromName = String(call?.from?.name || "");
      const ranges = Array.isArray(call?.fromRanges) ? call.fromRanges : [];
      return fromName.includes("Incoming Node") && ranges.some((range) => range?.start?.line === fileLinkPos.line);
    });
    if (!incomingFileHasTarget) {
      throw new Error(`Expected incoming call from Incoming Node for file target, got ${JSON.stringify(incomingFileResponse?.result)}`);
    }

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 7,
      method: "callHierarchy/outgoingCalls",
      params: { item: fileItems[0] },
    });

    const outgoingFileResponse = await waitForResponse(7);
    const outgoingFileCalls = Array.isArray(outgoingFileResponse?.result) ? outgoingFileResponse.result : [];

    const outgoingFileHasFileTarget = outgoingFileCalls.some((call) => {
      const toPath = String(call?.to?.data?.targetPath || "");
      const ranges = Array.isArray(call?.fromRanges) ? call.fromRanges : [];
      return toPath.endsWith("/next.org") && ranges.some((range) => range?.start?.line === fileOutgoingLinkPos.line);
    });

    const outgoingFileHasIdTarget = outgoingFileCalls.some((call) => {
      const toDetail = String(call?.to?.detail || "").toLowerCase();
      const ranges = Array.isArray(call?.fromRanges) ? call.fromRanges : [];
      return toDetail.startsWith("id:def-456") && ranges.some((range) => range?.start?.line === fileOutgoingIdPos.line);
    });

    if (!outgoingFileHasFileTarget || !outgoingFileHasIdTarget) {
      throw new Error(`Expected outgoing file calls to next.org and id:def-456, got ${JSON.stringify(outgoingFileResponse?.result)}`);
    }

    sendMessage(server, { jsonrpc: "2.0", id: 999, method: "shutdown", params: {} });
    await waitForResponse(999);

    console.log("✓ LSP call hierarchy test passed");
    server.kill();
  } catch (error) {
    server.kill();
    throw error;
  }
}

run().catch((error) => {
  console.error("LSP call hierarchy test failed:", error);
  process.exit(1);
});
