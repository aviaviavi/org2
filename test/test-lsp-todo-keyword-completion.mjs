#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn } from "node:child_process";

const docUri = "file:///todo-completion.org2";
const docText = "* \n* C\n* TODO Open\n* NEXT Custom state\n* DONE Closed\n";

function sendMessage(process, message) {
  const content = JSON.stringify(message);
  const contentLength = Buffer.byteLength(content, "utf8");
  process.stdin.write(`Content-Length: ${contentLength}\r\n\r\n${content}`);
}

function collectResponses(server) {
  const responses = new Map();
  let buffer = "";

  server.stdout.on("data", (data) => {
    buffer += data.toString();

    while (buffer.includes("\r\n\r\n")) {
      const headerEnd = buffer.indexOf("\r\n\r\n");
      const headers = buffer.slice(0, headerEnd);
      buffer = buffer.slice(headerEnd + 4);

      const lengthMatch = headers.match(/Content-Length: (\d+)/);
      if (!lengthMatch) continue;

      const contentLength = Number(lengthMatch[1]);
      if (buffer.length < contentLength) {
        buffer = `${headers}\r\n\r\n${buffer}`;
        break;
      }

      const content = buffer.slice(0, contentLength);
      buffer = buffer.slice(contentLength);
      const response = JSON.parse(content);
      if (response.id !== undefined) {
        responses.set(response.id, response);
      }
    }
  });

  return responses;
}

function waitForResponse(responses, id, timeoutMs = 4000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const timer = setInterval(() => {
      if (responses.has(id)) {
        clearInterval(timer);
        resolve(responses.get(id));
        return;
      }

      if (Date.now() - start > timeoutMs) {
        clearInterval(timer);
        reject(new Error(`Timed out waiting for LSP response ${id}`));
      }
    }, 25);
  });
}

function labels(response) {
  assert.ok(Array.isArray(response?.result), `Expected completion array, got ${JSON.stringify(response)}`);
  return response.result.map((item) => item?.label);
}

function assertSameLabels(actual, expected) {
  assert.deepEqual([...actual].sort(), [...expected].sort());
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

function tokenText(token) {
  const line = docText.split("\n")[token.line] ?? "";
  return line.slice(token.start, token.start + token.length);
}

async function run() {
  const server = spawn("node", ["dist/lsp.js"]);
  const responses = collectResponses(server);
  let stderr = "";
  server.stderr.on("data", (data) => {
    stderr += data.toString();
  });

  try {
    sendMessage(server, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        capabilities: {},
        rootUri: "file:///",
      },
    });
    await waitForResponse(responses, 1);

    sendMessage(server, {
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri: docUri,
          languageId: "org",
          version: 1,
          text: docText,
        },
      },
    });

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 2,
      method: "textDocument/completion",
      params: {
        textDocument: { uri: docUri },
        position: { line: 0, character: 2 },
      },
    });
    const broadLabels = labels(await waitForResponse(responses, 2));
    assertSameLabels(broadLabels, ["TODO", "IN_PROGRESS", "DONE", "CANCELED", "CANCELLED"]);
    assert.equal(broadLabels.includes("NEXT"), false);
    assert.equal(broadLabels.includes("WAITING"), false);

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 3,
      method: "textDocument/completion",
      params: {
        textDocument: { uri: docUri },
        position: { line: 1, character: 3 },
      },
    });
    assertSameLabels(labels(await waitForResponse(responses, 3)), ["CANCELED", "CANCELLED"]);

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 4,
      method: "textDocument/hover",
      params: {
        textDocument: { uri: docUri },
        position: { line: 3, character: 3 },
      },
    });
    assert.match((await waitForResponse(responses, 4))?.result?.contents?.value || "", /Status bucket: `custom`/);

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 5,
      method: "textDocument/hover",
      params: {
        textDocument: { uri: docUri },
        position: { line: 4, character: 3 },
      },
    });
    assert.match((await waitForResponse(responses, 5))?.result?.contents?.value || "", /Status bucket: `closed`/);

    sendMessage(server, {
      jsonrpc: "2.0",
      id: 6,
      method: "textDocument/semanticTokens/full",
      params: {
        textDocument: { uri: docUri },
      },
    });
    const semanticTokenData = (await waitForResponse(responses, 6))?.result?.data;
    assert.ok(Array.isArray(semanticTokenData), `Expected semantic token data, got ${JSON.stringify(semanticTokenData)}`);
    const keywordTexts = decodeSemanticTokenData(semanticTokenData)
      .filter((token) => token.tokenType === 0)
      .map(tokenText);
    assert.ok(keywordTexts.includes("TODO"), `Expected TODO keyword token, got ${JSON.stringify(keywordTexts)}`);
    assert.ok(keywordTexts.includes("DONE"), `Expected DONE keyword token, got ${JSON.stringify(keywordTexts)}`);
    assert.equal(keywordTexts.includes("NEXT"), false);

    sendMessage(server, { jsonrpc: "2.0", id: 999, method: "shutdown", params: {} });
    await waitForResponse(responses, 999);
    server.kill();
  } catch (error) {
    server.kill();
    if (stderr) {
      error.message = `${error.message}\nLSP stderr:\n${stderr}`;
    }
    throw error;
  }
}

run()
  .then(() => {
    console.log("✓ LSP TODO keyword completion follows shared standard");
  })
  .catch((error) => {
    console.error("LSP TODO keyword completion test failed:", error);
    process.exit(1);
  });
