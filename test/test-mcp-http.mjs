import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { mcpAccessTokenHash, startMcpHttpServer } from "../dist/mcpHttp.js";

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "org2-mcp-http-test-"));
const root = path.join(temporary, "corpus");
const notes = path.join(root, "notes");
const accessToken = "org2_test_read_token";
fs.mkdirSync(notes, { recursive: true });
fs.mkdirSync(path.join(root, ".org2", "runs"), { recursive: true });
fs.mkdirSync(path.join(root, "archive"), { recursive: true });
fs.writeFileSync(path.join(root, "org2.json"), `${JSON.stringify({ schemaVersion: "v0", corpus: { id: "mcp-http-test", name: "MCP HTTP test", kind: "project" } }, null, 2)}\n`);
fs.writeFileSync(path.join(notes, "billing.org"), `* Billing migration\n:PROPERTIES:\n:ID: billing-migration\n:END:\nThe billing migration needs a staged rollout.\n`);
fs.writeFileSync(path.join(root, ".org2", "runs", "private.org2"), "* Hidden runtime state\n");
fs.writeFileSync(path.join(root, "archive", "old.org"), "* Archived source\n");
fs.symlinkSync(notes, path.join(root, "linked-notes"));
for (let index = 0; index < 105; index += 1) {
  fs.writeFileSync(path.join(notes, `resource-${String(index).padStart(3, "0")}.org`), `* Resource ${index}\n`);
}

let server;
try {
  server = await startMcpHttpServer({
    root,
    host: "127.0.0.1",
    port: 0,
    accessTokens: [{ tokenHash: mcpAccessTokenHash(accessToken), scopes: ["corpus:read"] }],
  });

  const request = (message, options = {}) => fetch(server.endpoint, {
    method: options.method || "POST",
    headers: {
      Accept: "application/json, text/event-stream",
      "Content-Type": "application/json",
      ...(options.protocolVersion === false ? {} : { "MCP-Protocol-Version": options.protocolVersion || "2025-03-26" }),
      ...(options.authorized === false ? {} : { Authorization: `Bearer ${accessToken}` }),
      ...(options.origin ? { Origin: options.origin } : {}),
    },
    body: (options.method || "POST") === "POST" ? JSON.stringify(message) : undefined,
  });

  const unauthorized = await request({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }, { authorized: false });
  assert.equal(unauthorized.status, 401);
  assert.equal(unauthorized.headers.get("www-authenticate"), "Bearer");

  const rejectedOrigin = await request(
    { jsonrpc: "2.0", id: 2, method: "initialize", params: {} },
    { origin: "https://untrusted.example" },
  );
  assert.equal(rejectedOrigin.status, 403);

  const rejectedVersion = await request(
    { jsonrpc: "2.0", id: 21, method: "initialize", params: {} },
    { protocolVersion: "2099-01-01" },
  );
  assert.equal(rejectedVersion.status, 400);

  const initialize = await request({ jsonrpc: "2.0", id: 3, method: "initialize", params: { protocolVersion: "2025-03-26" } });
  assert.equal(initialize.status, 200);
  const initialized = await initialize.json();
  assert.equal(initialized.result.serverInfo.name, "org2");
  assert.match(initialized.result.instructions, /Read-only Org2 corpus/);

  const listed = await request({ jsonrpc: "2.0", id: 4, method: "tools/list", params: {} });
  const tools = (await listed.json()).result.tools;
  assert.deepEqual(
    tools.map((tool) => tool.name),
    ["org2_search", "org2_fetch", "org2_context", "org2_agent_profile_resolve", "org2_run_list"],
  );
  assert.equal(tools.every((tool) => tool.annotations.readOnlyHint === true), true);

  const notification = await request({ jsonrpc: "2.0", method: "notifications/unknown", params: {} });
  assert.equal(notification.status, 202);
  assert.equal(await notification.text(), "");

  const clientResponse = await request({ jsonrpc: "2.0", id: 99, result: {} });
  assert.equal(clientResponse.status, 202);
  assert.equal(await clientResponse.text(), "");

  const batch = await request([
    { jsonrpc: "2.0", id: 22, method: "tools/list", params: {} },
    { jsonrpc: "2.0", method: "notifications/unknown", params: {} },
  ]);
  const batchResult = await batch.json();
  assert.equal(batchResult.length, 1);
  assert.equal(batchResult[0].id, 22);
  assert.equal(batchResult[0].result.tools.length, 5);

  const searched = await request({
    jsonrpc: "2.0",
    id: 5,
    method: "tools/call",
    params: { name: "org2_search", arguments: { query: "staged rollout", limit: 5, maxChars: 4_000 } },
  });
  const searchResult = (await searched.json()).result.structuredContent;
  assert.equal(searchResult.action, "search");
  assert.equal(searchResult.results[0].id, "billing-migration");
  assert.match(searchResult.results[0].citation, /notes\/billing\.org:/);

  const fetched = await request({
    jsonrpc: "2.0",
    id: 6,
    method: "tools/call",
    params: { name: "org2_fetch", arguments: { id: "billing-migration", include: ["sources"] } },
  });
  const fetchResult = (await fetched.json()).result.structuredContent;
  assert.equal(fetchResult.action, "fetch");
  assert.equal(fetchResult.results[0].title, "Billing migration");

  const firstResources = await request({ jsonrpc: "2.0", id: 7, method: "resources/list", params: {} });
  const firstPage = (await firstResources.json()).result;
  assert.equal(firstPage.resources.length, 100);
  assert.ok(firstPage.nextCursor);
  const secondResources = await request({ jsonrpc: "2.0", id: 8, method: "resources/list", params: { cursor: firstPage.nextCursor } });
  const secondPage = (await secondResources.json()).result;
  assert.equal(secondPage.resources.length, 6);
  assert.equal(secondPage.nextCursor, undefined);
  assert.equal(
    [...firstPage.resources, ...secondPage.resources].some((resource) => resource.uri.includes("/.org2/") || resource.uri.includes("/archive/")),
    false,
  );

  const resourceRead = await request({ jsonrpc: "2.0", id: 9, method: "resources/read", params: { uri: "org2://corpus/notes/billing.org" } });
  const resource = (await resourceRead.json()).result.contents[0];
  assert.match(resource.text, /staged rollout/);
  assert.match(resource._meta.revision, /^sha256:[a-f0-9]{64}$/);
  assert.equal(resource._meta.lineCount, 6);

  const hiddenResource = await request({ jsonrpc: "2.0", id: 10, method: "resources/read", params: { uri: "org2://corpus/.org2/runs/private.org2" } });
  const hiddenError = await hiddenResource.json();
  assert.equal(hiddenError.error.code, -32603);
  assert.match(hiddenError.error.message, /not an Org2 source file exposed by this server/);

  const linkedResource = await request({ jsonrpc: "2.0", id: 11, method: "resources/read", params: { uri: "org2://corpus/linked-notes/billing.org" } });
  const linkedError = await linkedResource.json();
  assert.equal(linkedError.error.code, -32603);
  assert.match(linkedError.error.message, /resource is a symbolic link/);

  const get = await request(undefined, { method: "GET" });
  assert.equal(get.status, 405);
  assert.equal(get.headers.get("allow"), "POST");

  console.log("read-only Streamable HTTP MCP tests passed");
} finally {
  await server?.close();
  fs.rmSync(temporary, { recursive: true, force: true });
}
