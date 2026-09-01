import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const AI_CHAT_OPERATION_SCHEMA = "org2:ai-chat-operation:v1";
export const AI_CHAT_ENVELOPE_MAX_BYTES = 512_000;

interface AIChatOperationBase {
  schema: typeof AI_CHAT_OPERATION_SCHEMA;
  id: string;
  createdAt: string;
}

export interface SettleAIChatThreadOperation extends AIChatOperationBase {
  kind: "settle-thread";
  threadID: string;
  settledAt: string;
}

export interface ReopenAIChatThreadOperation extends AIChatOperationBase {
  kind: "reopen-thread";
  threadID: string;
}

export interface ConfigureAIChatAutoSettlementOperation extends AIChatOperationBase {
  kind: "configure-auto-settle";
  autoSettleAfterSeconds: number | null;
}

export interface AutoSettleAIChatThreadsOperation extends AIChatOperationBase {
  kind: "auto-settle";
  evaluatedAt: string;
}

export type AIChatOperation =
  | SettleAIChatThreadOperation
  | ReopenAIChatThreadOperation
  | ConfigureAIChatAutoSettlementOperation
  | AutoSettleAIChatThreadsOperation;

export interface QueueAIChatOperationResult {
  applied: boolean;
  file: string;
  operation: AIChatOperation;
}

let lastOperationCreatedAtMilliseconds = 0;

export function aiChatInboxDirectory(corpusRoot: string): string {
  return path.join(path.resolve(corpusRoot), ".org2", "ai-chat-inbox");
}

export function aiChatOperationDirectory(corpusRoot: string): string {
  return path.join(aiChatInboxDirectory(corpusRoot), "operations");
}

export function nextAIChatOperationIdentity(): { id: string; createdAt: string } {
  const now = Date.now();
  lastOperationCreatedAtMilliseconds = Math.max(now, lastOperationCreatedAtMilliseconds + 1);
  return {
    id: crypto.randomUUID(),
    createdAt: new Date(lastOperationCreatedAtMilliseconds).toISOString(),
  };
}

function operationFileName(operation: AIChatOperation): string {
  const timestamp = Date.parse(operation.createdAt);
  const sortableTimestamp = String(timestamp).padStart(13, "0");
  return `${sortableTimestamp}-${operation.id}.json`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function validDate(value: unknown): value is string {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function validIdentifier(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0 && value.length <= 1_000;
}

function validUUID(value: unknown): value is string {
  return typeof value === "string"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value);
}

function parseAIChatOperation(value: unknown, file: string): AIChatOperation {
  if (!isRecord(value)
      || value.schema !== AI_CHAT_OPERATION_SCHEMA
      || !validUUID(value.id)
      || !validDate(value.createdAt)) {
    throw new Error(`invalid AI chat operation envelope: ${file}`);
  }
  if (value.kind === "settle-thread"
      && validIdentifier(value.threadID)
      && validDate(value.settledAt)) {
    return value as unknown as SettleAIChatThreadOperation;
  }
  if (value.kind === "reopen-thread" && validIdentifier(value.threadID)) {
    return value as unknown as ReopenAIChatThreadOperation;
  }
  if (value.kind === "configure-auto-settle"
      && (value.autoSettleAfterSeconds === null
        || (typeof value.autoSettleAfterSeconds === "number"
          && Number.isFinite(value.autoSettleAfterSeconds)
          && value.autoSettleAfterSeconds > 0))) {
    return value as unknown as ConfigureAIChatAutoSettlementOperation;
  }
  if (value.kind === "auto-settle" && validDate(value.evaluatedAt)) {
    return value as unknown as AutoSettleAIChatThreadsOperation;
  }
  throw new Error(`invalid AI chat operation envelope: ${file}`);
}

export function encodedJSONEnvelope(value: unknown): Buffer {
  const encoded = Buffer.from(`${JSON.stringify(value, null, 2)}\n`, "utf8");
  if (encoded.byteLength > AI_CHAT_ENVELOPE_MAX_BYTES) {
    throw new Error(`AI chat inbox envelope exceeds ${AI_CHAT_ENVELOPE_MAX_BYTES} bytes`);
  }
  return encoded;
}

function ensurePrivateDirectory(directory: string): void {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const info = fs.lstatSync(directory);
  if (!info.isDirectory() || info.isSymbolicLink()) {
    throw new Error(`unsafe AI chat inbox directory: ${directory}`);
  }
  fs.chmodSync(directory, 0o700);
}

function syncDirectory(directory: string): void {
  let descriptor: number | undefined;
  try {
    descriptor = fs.openSync(directory, "r");
    fs.fsyncSync(descriptor);
  } catch {
    // Some supported filesystems do not allow fsync on a directory. The file
    // itself is still synced and installed atomically without replacement.
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

export function publishJSONEnvelope<T>(
  file: string,
  payload: T,
  samePayload: (left: T, right: T) => boolean,
  conflictLabel = "operation",
): { applied: boolean; payload: T } {
  const directory = path.dirname(file);
  ensurePrivateDirectory(directory);
  const encoded = encodedJSONEnvelope(payload);
  const temporary = path.join(
    directory,
    `.${path.basename(file)}.${process.pid}.${crypto.randomUUID()}.tmp`,
  );
  let descriptor: number | undefined;
  try {
    descriptor = fs.openSync(temporary, "wx", 0o600);
    fs.writeFileSync(descriptor, encoded);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    try {
      // Linking a complete temporary file gives us atomic no-replace
      // publication. Unlike rename(), a concurrent idempotency-key conflict
      // cannot silently overwrite the winner.
      fs.linkSync(temporary, file);
      fs.chmodSync(file, 0o600);
      syncDirectory(directory);
      return { applied: true, payload };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      const info = fs.lstatSync(file);
      if (!info.isFile() || info.isSymbolicLink() || info.size > AI_CHAT_ENVELOPE_MAX_BYTES) {
        throw new Error(`unsafe or oversized AI chat inbox envelope: ${file}`);
      }
      const existing = JSON.parse(fs.readFileSync(file, "utf8")) as T;
      if (!samePayload(existing, payload)) {
        throw new Error(`AI chat idempotency key already queues a different ${conflictLabel}: ${file}`);
      }
      return { applied: false, payload: existing };
    }
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try {
      fs.unlinkSync(temporary);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
}

export function queueAIChatOperation(
  corpusRoot: string,
  operation: AIChatOperation,
  apply: boolean,
): QueueAIChatOperationResult {
  const file = path.join(aiChatOperationDirectory(corpusRoot), operationFileName(operation));
  // Validate the exact bytes even for previews so an apply does not introduce
  // a late size-dependent behavior change.
  encodedJSONEnvelope(operation);
  if (!apply) return { applied: false, file, operation };
  const published = publishJSONEnvelope(file, operation, (left, right) => (
    JSON.stringify(left) === JSON.stringify(right)
  ));
  return { applied: published.applied, file, operation: published.payload };
}

export function loadAIChatOperations(corpusRoot: string): AIChatOperation[] {
  const directory = aiChatOperationDirectory(corpusRoot);
  let entries: fs.Dirent[];
  try {
    const info = fs.lstatSync(directory);
    if (!info.isDirectory() || info.isSymbolicLink()) {
      throw new Error(`unsafe AI chat operation directory: ${directory}`);
    }
    entries = fs.readdirSync(directory, { withFileTypes: true });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
  const operations = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
    .map((entry) => {
      const file = path.join(directory, entry.name);
      const info = fs.lstatSync(file);
      if (!info.isFile() || info.isSymbolicLink() || info.size > AI_CHAT_ENVELOPE_MAX_BYTES) {
        throw new Error(`unsafe or oversized AI chat operation envelope: ${file}`);
      }
      return parseAIChatOperation(JSON.parse(fs.readFileSync(file, "utf8")), file);
    });
  operations.sort((left, right) => {
    const time = Date.parse(left.createdAt) - Date.parse(right.createdAt);
    return time || left.id.localeCompare(right.id);
  });
  return operations;
}
