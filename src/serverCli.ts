import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { assignAutomationHost } from "./automationHost.js";
import { corpusIdentityStatus } from "./corpusIdentity.js";
import { guardedWriteFile } from "./guardedFile.js";
import { safeIdentifier } from "./safeIdentifier.js";

interface ServerDestination {
  id: string; name: string; mention: string; adapter: string; endpoint: string;
  agentID: string; workspaceRoot: string; isEnabled: boolean;
}

export interface ServerConfiguration {
  schema: "org2:server-config:v1";
  hostRef: string;
  name: string;
  corpusRoot: string;
  bindHost: string;
  port: number;
  repoRoot: string;
  nodePath: string;
  executable: string;
  destinations: ServerDestination[];
  schedulesEnabled: boolean;
}

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const help = `OpenOrg headless server (macOS 14 or later)

  org2 server init --dir CORPUS --host-ref HOST --bind TAILSCALE_IP [--name NAME] [--destination codex|claude|openclaw] [--apply]
  org2 server start [--config FILE]
  org2 server status|pair|stop [--config FILE]
  org2 server revoke --device-id ID [--config FILE]
  org2 server push-config --team-id ID --key-id ID --key-file FILE [--apply] [--config FILE]
  org2 server assign --dir CORPUS --host-ref HOST [--apply]
  org2 server service [--config FILE] [--apply]

init, assign, and service preview by default. init writes machine-local configuration,
outside the corpus. assign chooses the corpus scheduler owner (desktop by default).
start runs in the foreground; service installs a launchd agent that runs at login
and restarts after failures. pair issues a one-use code valid for ten minutes.
The private control socket permits only this OS user; the relay binds only to Tailscale.
Build the native worker with npm run build:server before starting from a checkout.
Use --config for separate hosts. --executable PATH overrides the native worker at init.
`;

function existingRealPath(file: string): string {
  if (fs.existsSync(file)) return fs.realpathSync(file);
  return path.join(existingRealPath(path.dirname(file)), path.basename(file));
}

function contained(root: string, file: string): boolean {
  const relative = path.relative(root, file);
  return !relative || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative));
}

export function validateServerConfiguration(value: unknown, configFile: string): ServerConfiguration {
  if (!value || typeof value !== "object") throw new Error("Invalid server configuration");
  const config = value as ServerConfiguration;
  if (config.schema !== "org2:server-config:v1") throw new Error("Unsupported server configuration schema");
  safeIdentifier(config.hostRef);
  if (!config.name?.trim() || config.name.length > 120) throw new Error("Server name must contain 1-120 characters");
  const octets = String(config.bindHost).split(".");
  if (octets.length !== 4 || octets.some((part) => !/^\d{1,3}$/.test(part) || Number(part) > 255)
    || Number(octets[0]) !== 100 || Number(octets[1]) < 64 || Number(octets[1]) > 127) {
    throw new Error("--bind must be this host's Tailscale IPv4 address");
  }
  if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535) throw new Error("Invalid server port");
  for (const key of ["corpusRoot", "repoRoot", "nodePath", "executable"] as const) {
    if (typeof config[key] !== "string" || !path.isAbsolute(config[key])) throw new Error(`${key} must be an absolute path`);
  }
  const corpus = corpusIdentityStatus(config.corpusRoot);
  if (!corpus.valid) throw new Error(`Invalid corpus: ${corpus.issues.map((item) => item.message).join("; ")}`);
  const localConfig = existingRealPath(configFile);
  if (contained(fs.realpathSync(config.corpusRoot), localConfig) || contained(existingRealPath(config.repoRoot), localConfig)) {
    throw new Error("Server configuration must be machine-local, outside the corpus and source checkout");
  }
  if (typeof config.schedulesEnabled !== "boolean") throw new Error("schedulesEnabled must be a boolean");
  if (!Array.isArray(config.destinations) || !config.destinations.length) throw new Error("Choose at least one AI destination");
  const ids = new Set<string>();
  for (const destination of config.destinations) {
    if (!destination.id || ids.has(destination.id)) throw new Error("AI destination IDs must be unique");
    ids.add(destination.id);
    if (!["codexLocal", "claudeLocal", "openClaw", "codexRemote", "codexManagedRemote", "openAI", "anthropic", "openRouter", "ollama"].includes(destination.adapter)) {
      throw new Error(`Unsupported AI destination adapter: ${destination.adapter}`);
    }
    for (const key of ["name", "mention", "endpoint", "agentID", "workspaceRoot"] as const) {
      if (typeof destination[key] !== "string") throw new Error(`Destination ${key} must be a string`);
    }
    if (typeof destination.isEnabled !== "boolean") throw new Error("Destination isEnabled must be a boolean");
    if (/token|secret|password|credential|api.?key/i.test(Object.keys(destination).filter((key) => !["id", "name", "mention", "adapter", "endpoint", "agentID", "workspaceRoot", "model", "isEnabled"].includes(key)).join(" "))) {
      throw new Error("Credentials must stay in the runtime's login store or Keychain");
    }
  }
  return config;
}

function socketPath(configFile: string): string {
  return path.join(path.dirname(configFile), `control-${crypto.createHash("sha256").update(configFile).digest("hex").slice(0, 12)}.sock`);
}

export function serverControl(configFile: string, command: string, extra: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const client = net.createConnection(socketPath(configFile));
    let buffer = "";
    client.setTimeout(30_000, () => client.destroy(new Error("Server control request timed out")));
    client.on("error", reject);
    client.on("connect", () => client.write(`${JSON.stringify({ command, ...extra })}\n`));
    client.on("data", (chunk) => {
      buffer += chunk.toString();
      if (buffer.length > 1_000_000) { client.destroy(new Error("Oversized server control response")); return; }
      if (!buffer.includes("\n")) return;
      client.end();
      try { resolve(JSON.parse(buffer.slice(0, buffer.indexOf("\n")))); } catch (error) { reject(error); }
    });
    client.on("end", () => { if (!buffer.includes("\n")) reject(new Error("Server closed the control connection")); });
  });
}

async function serve(configFile: string, config: ServerConfiguration): Promise<void> {
  if (process.platform !== "darwin") throw new Error("The current chat worker requires macOS 14 or later");
  fs.accessSync(config.executable, fs.constants.X_OK);
  const directory = path.dirname(configFile);
  const directoryStat = fs.statSync(directory);
  if (directoryStat.uid !== process.getuid?.() || (directoryStat.mode & 0o077) !== 0) {
    throw new Error("The server config directory must be owned by this user with mode 0700");
  }
  const socket = socketPath(configFile);
  if (Buffer.byteLength(socket) > 100) throw new Error("Server config path is too long for its private control socket; use a shorter state directory");
  if (fs.existsSync(socket)) {
    try { await serverControl(configFile, "status"); throw new Error("This server is already running"); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ECONNREFUSED") throw error;
      fs.unlinkSync(socket);
    }
  }
  const pending = new Map<string, { client: net.Socket; timer: NodeJS.Timeout }>();
  const clients = new Set<net.Socket>();
  let stopping = false;
  let child: ReturnType<typeof spawn> | undefined;
  const server = net.createServer((client) => {
    clients.add(client);
    client.on("close", () => clients.delete(client));
    client.on("error", () => {});
    client.setTimeout(35_000, () => client.destroy());
    let buffer = "";
    client.on("data", (chunk) => {
      buffer += chunk.toString();
      if (buffer.length > 4096) { client.destroy(); return; }
      if (!buffer.includes("\n")) return;
      client.removeAllListeners("data");
      try {
        const request = JSON.parse(buffer.slice(0, buffer.indexOf("\n")));
        if (!["status", "pair", "revoke", "stop", "push-config"].includes(request.command)) throw new Error("Unknown control command");
        if (!child?.stdin?.writable) throw new Error("Server worker is starting or unavailable");
        const id = crypto.randomUUID();
        const timer = setTimeout(() => { pending.delete(id); client.end('{"error":"Worker timed out"}\n'); }, 30_000);
        pending.set(id, { client, timer });
        child.stdin.write(`${JSON.stringify({ ...request, id })}\n`);
      } catch (error) { client.end(`${JSON.stringify({ error: (error as Error).message })}\n`); }
    });
  });
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(socket, resolve); });
  fs.chmodSync(socket, 0o600);
  const stop = () => {
    if (stopping) return;
    stopping = true;
    child?.stdin?.end();
    setTimeout(() => child?.kill("SIGKILL"), 25_000).unref();
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  try {
    child = spawn(config.executable, ["--config", configFile], { stdio: ["pipe", "pipe", "inherit"] });
    const lines = readline.createInterface({ input: child.stdout! });
    lines.on("line", (line) => {
      try {
        const event = JSON.parse(line);
        if (event.event === "ready") process.stdout.write(`${JSON.stringify(event)}\n`);
        const request = pending.get(event.id);
        if (request) {
          clearTimeout(request.timer);
          pending.delete(event.id);
          if (event.result?.stopped === true) event.result.supervisorPID = process.pid;
          request.client.end(`${JSON.stringify(event.result)}\n`);
        }
      } catch { /* Native diagnostics are not control replies. */ }
    });
    const result = await new Promise<number>((resolve, reject) => {
      child!.once("error", reject);
      child!.once("exit", (code) => resolve(code ?? 1));
    });
    if (result !== 0) throw new Error(`OpenOrg server worker exited with status ${result}`);
  } finally {
    process.removeListener("SIGTERM", stop);
    process.removeListener("SIGINT", stop);
    for (const { client, timer } of pending.values()) { clearTimeout(timer); client.destroy(); }
    for (const client of clients) client.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

function xml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export function serverLaunchAgent(configFile: string, config: ServerConfiguration): string {
  const argumentsList = [config.nodePath, path.join(config.repoRoot, "dist", "cli.js"), "server", "start", "--config", configFile];
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>org.org2.server.${xml(config.hostRef)}</string>
<key>ProgramArguments</key><array>${argumentsList.map((arg) => `<string>${xml(arg)}</string>`).join("")}</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>15</integer>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml([path.dirname(config.nodePath), "/opt/homebrew/bin", "/usr/local/bin", path.join(os.homedir(), ".local/bin"), "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(":"))}</string></dict>
<key>StandardOutPath</key><string>${xml(path.join(path.dirname(configFile), "server.log"))}</string>
<key>StandardErrorPath</key><string>${xml(path.join(path.dirname(configFile), "server-error.log"))}</string>
</dict></plist>
`;
}

export async function runServerCommand(args: string[]): Promise<void> {
  const { values, positionals } = parseArgs({ args, allowPositionals: true, options: {
    config: { type: "string" }, dir: { type: "string" }, "host-ref": { type: "string" },
    bind: { type: "string" }, name: { type: "string" }, port: { type: "string" },
    executable: { type: "string" }, destination: { type: "string" }, "device-id": { type: "string" },
    "team-id": { type: "string" }, "key-id": { type: "string" }, "key-file": { type: "string" },
    apply: { type: "boolean" }, json: { type: "boolean" }, help: { type: "boolean" },
  } });
  const command = positionals[0];
  if (!command || values.help) { process.stdout.write(help); return; }
  const configFile = path.resolve(values.config || path.join(os.homedir(), ".local/state/openorg/server.json"));
  const print = (value: unknown) => process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  if (command === "assign") {
    if (!values.dir || !values["host-ref"]) throw new Error("assign requires --dir and --host-ref");
    print(assignAutomationHost(path.resolve(values.dir), values["host-ref"], !!values.apply));
    return;
  }
  if (command === "init") {
    if (!values.dir || !values["host-ref"] || !values.bind) throw new Error("init requires --dir, --host-ref, and --bind");
    const destination = values.destination || "codex";
    if (!["codex", "claude", "openclaw"].includes(destination)) throw new Error("Choose codex, claude, or openclaw");
    const config = validateServerConfiguration({
      schema: "org2:server-config:v1", hostRef: values["host-ref"], name: values.name || `OpenOrg on ${values["host-ref"]}`,
      corpusRoot: fs.realpathSync(path.resolve(values.dir)), bindHost: values.bind, port: Number(values.port || 48922),
      repoRoot: packageRoot, nodePath: process.execPath,
      executable: path.resolve(values.executable || path.join(packageRoot, "apps/macos/Org2Workspace/.build/debug/OpenOrgServer")),
      schedulesEnabled: true,
      destinations: [{ id: `builtin.${destination}`, name: destination === "codex" ? "Codex" : destination === "claude" ? "Claude Code" : "OpenClaw",
        mention: destination, adapter: destination === "codex" ? "codexLocal" : destination === "claude" ? "claudeLocal" : "openClaw",
        endpoint: "", agentID: "", workspaceRoot: "", isEnabled: true }],
    }, configFile);
    if (values.apply) {
      const directory = path.dirname(configFile);
      fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
      if ((fs.statSync(directory).mode & 0o077) !== 0) throw new Error("Use a private config directory with mode 0700");
      guardedWriteFile(configFile, `${JSON.stringify(config, null, 2)}\n`, { expectedRevision: null });
    }
    print({ applied: !!values.apply, configFile, config });
    return;
  }
  const config = validateServerConfiguration(JSON.parse(fs.readFileSync(configFile, "utf8")), configFile);
  if (command === "start") { await serve(configFile, config); return; }
  if (command === "push-config") {
    if (!values["team-id"] || !values["key-id"] || !values["key-file"]) throw new Error("push-config requires --team-id, --key-id, and --key-file");
    if (!values.apply) { print({ applied: false, teamID: values["team-id"], keyID: values["key-id"], keyFile: path.resolve(values["key-file"]) }); return; }
    const privateKey = fs.readFileSync(values["key-file"], "utf8");
    if (privateKey.length > 2048) throw new Error("Invalid APNs private key file");
    const result = await serverControl(configFile, "push-config", { teamID: values["team-id"], keyID: values["key-id"], privateKey });
    if (result.error) throw new Error(String(result.error));
    print(result); return;
  }
  if (["status", "pair", "revoke", "stop"].includes(command)) {
    if (command === "revoke" && !values["device-id"]) throw new Error("revoke requires --device-id");
    const result = await serverControl(configFile, command, { deviceID: values["device-id"] });
    if (result.error) throw new Error(String(result.error));
    if (command === "stop" && result.stopped && typeof result.supervisorPID === "number") {
      const deadline = Date.now() + 30_000;
      while (true) {
        try { process.kill(result.supervisorPID, 0); }
        catch (error) { if ((error as NodeJS.ErrnoException).code === "ESRCH") break; throw error; }
        if (Date.now() >= deadline) throw new Error("Worker saved its state, but the supervisor did not exit");
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
    }
    print(result); return;
  }
  if (command === "service") {
    if (process.platform !== "darwin") throw new Error("Service installation currently requires macOS launchd");
    const file = path.join(os.homedir(), "Library/LaunchAgents", `org.org2.server.${config.hostRef}.plist`);
    const plist = serverLaunchAgent(configFile, config);
    if (values.apply) {
      fs.accessSync(config.executable, fs.constants.X_OK);
      guardedWriteFile(file, plist, { expectedRevision: null });
    }
    print({ applied: !!values.apply, file, plist, start: ["launchctl", "bootstrap", `gui/${process.getuid?.()}`, file] });
    return;
  }
  throw new Error(`Unknown server command: ${command}`);
}
