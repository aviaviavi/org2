import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { STOP_CONTROL_TIMEOUT_MS, serverControl, waitForControlSocketClosed } from "../dist/serverCli.js";

// Regression: on a large corpus the worker can take over 30 s to persist every
// chat when stopping. restart --drain used to time out at 30 s and throw before
// starting the launchd service again, leaving the server stopped.

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-restart-"));
const configFile = path.join(dir, "server.json");
const socket = path.join(dir, `control-${crypto.createHash("sha256").update(configFile).digest("hex").slice(0, 12)}.sock`);

assert.ok(STOP_CONTROL_TIMEOUT_MS >= 120_000, "stop waits long enough for a large corpus to persist");

// A stop that answers slowly still succeeds rather than surfacing a timeout.
const server = net.createServer((client) => {
  client.once("data", () => setTimeout(() => client.end('{"stopped":true}\n'), 300));
});
await new Promise((resolve) => server.listen(socket, resolve));
assert.deepEqual(await serverControl(configFile, "stop"), { stopped: true });

// The socket wait reports "still open" while the supervisor is alive...
assert.equal(await waitForControlSocketClosed(configFile, 300, 50), false);
// ...and returns as soon as it goes away.
setTimeout(() => server.close(), 200);
const started = Date.now();
assert.equal(await waitForControlSocketClosed(configFile, 5_000, 50), true);
assert.ok(Date.now() - started < 4_000);

// restart must reach the launchctl kickstart even when stop throws.
const source = fs.readFileSync(new URL("../src/serverCli.ts", import.meta.url), "utf8");
const restartBlock = source.slice(source.indexOf('result = await serverControl(configFile, "stop");'));
assert.match(restartBlock.slice(0, 600), /catch \(error\) \{[\s\S]*if \(command !== "restart"\) throw error;/);
assert.ok(restartBlock.indexOf("waitForControlSocketClosed") < restartBlock.indexOf('"kickstart"'));

fs.rmSync(dir, { recursive: true, force: true });
console.log("server restart: ok");
