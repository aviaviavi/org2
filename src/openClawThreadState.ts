import fs from "node:fs";
import path from "node:path";

export const OPENCLAW_THREAD_STATE_SCHEMA = "org2:openclaw-thread-state:v1";
export const OPENCLAW_TRANSCRIPT_VERSION = 6;
const APPLE_REFERENCE_DATE_UNIX_SECONDS = 978_307_200;

export interface OpenClawThreadSettlementSettings {
  autoSettleAfterSeconds: number | null;
}

export interface OpenClawChatThreadRecord {
  id: string;
  title?: string;
  updatedAt: number | string;
  messages?: Array<{
    role?: string;
    deliveryStatus?: string;
    sendFailure?: string | null;
    [key: string]: unknown;
  }>;
  isPinned?: boolean;
  isArchived?: boolean;
  settledAt?: number | string | null;
  unreadMessageCount?: number;
  pendingTurn?: unknown;
  [key: string]: unknown;
}

export interface OpenClawTranscriptRecord {
  version: number;
  messages?: unknown[] | null;
  threads?: OpenClawChatThreadRecord[] | null;
  selectedThreadID?: string | null;
  settlementSettings?: Partial<OpenClawThreadSettlementSettings> | null;
  [key: string]: unknown;
}

export interface OpenClawThreadState {
  schema: typeof OPENCLAW_THREAD_STATE_SCHEMA;
  file: string;
  version: number;
  selectedThreadID: string | null;
  settlementSettings: OpenClawThreadSettlementSettings;
  threads: OpenClawChatThreadRecord[];
}

export interface OpenClawThreadMutationResult {
  applied: boolean;
  changed: boolean;
  state: OpenClawThreadState;
  affectedThreadIds: string[];
}

export function openClawTranscriptPath(corpusRoot: string): string {
  return path.join(path.resolve(corpusRoot), ".org2", "openclaw-chat.json");
}

function settlementSettings(payload: OpenClawTranscriptRecord): OpenClawThreadSettlementSettings {
  const value = payload.settlementSettings?.autoSettleAfterSeconds;
  return {
    autoSettleAfterSeconds: typeof value === "number" && Number.isFinite(value) && value > 0
      ? value
      : null,
  };
}

function normalizedThreads(payload: OpenClawTranscriptRecord): OpenClawChatThreadRecord[] {
  if (!Array.isArray(payload.threads)) return [];
  return payload.threads.filter((thread): thread is OpenClawChatThreadRecord => (
    Boolean(thread)
      && typeof thread === "object"
      && typeof thread.id === "string"
      && (typeof thread.updatedAt === "number" || typeof thread.updatedAt === "string")
  ));
}

function parsePayload(file: string): OpenClawTranscriptRecord {
  if (!fs.existsSync(file)) {
    return { version: OPENCLAW_TRANSCRIPT_VERSION, threads: [], selectedThreadID: null };
  }
  const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`invalid OpenClaw transcript payload: ${file}`);
  }
  return parsed as OpenClawTranscriptRecord;
}

function stateFromPayload(file: string, payload: OpenClawTranscriptRecord): OpenClawThreadState {
  return {
    schema: OPENCLAW_THREAD_STATE_SCHEMA,
    file,
    version: Number.isFinite(payload.version) ? payload.version : 1,
    selectedThreadID: typeof payload.selectedThreadID === "string" ? payload.selectedThreadID : null,
    settlementSettings: settlementSettings(payload),
    threads: normalizedThreads(payload),
  };
}

export function loadOpenClawThreadState(corpusRoot: string): OpenClawThreadState {
  const file = openClawTranscriptPath(corpusRoot);
  return stateFromPayload(file, parsePayload(file));
}

export function isOpenClawThreadSettled(thread: OpenClawChatThreadRecord): boolean {
  return thread.settledAt !== undefined && thread.settledAt !== null
    ? true
    : thread.isArchived === true;
}

export function openClawDateMilliseconds(value: number | string): number {
  if (typeof value === "number") {
    return (value + APPLE_REFERENCE_DATE_UNIX_SECONDS) * 1000;
  }
  return Date.parse(value);
}

export function appleReferenceDateSeconds(date: Date): number {
  return date.getTime() / 1000 - APPLE_REFERENCE_DATE_UNIX_SECONDS;
}

export function canAutoSettleOpenClawThread(
  thread: OpenClawChatThreadRecord,
  settings: OpenClawThreadSettlementSettings,
  now = new Date(),
  selectedThreadID: string | null = null,
): boolean {
  const interval = settings.autoSettleAfterSeconds;
  if (!interval || interval <= 0 || isOpenClawThreadSettled(thread)) return false;
  if (thread.id === selectedThreadID || thread.isPinned || thread.pendingTurn) return false;
  if ((thread.unreadMessageCount || 0) > 0) return false;
  const latestMessage = thread.messages?.[thread.messages.length - 1];
  if (
    latestMessage?.deliveryStatus === "sending"
    || latestMessage?.deliveryStatus === "failed"
    || latestMessage?.deliveryStatus === "interrupted"
    || Boolean(latestMessage?.sendFailure)
  ) return false;
  const updatedAt = openClawDateMilliseconds(thread.updatedAt);
  return Number.isFinite(updatedAt) && updatedAt <= now.getTime() - interval * 1000;
}

function settledThread(thread: OpenClawChatThreadRecord, at: Date): OpenClawChatThreadRecord {
  return {
    ...thread,
    isArchived: true,
    settledAt: appleReferenceDateSeconds(at),
  };
}

function reopenedThread(thread: OpenClawChatThreadRecord): OpenClawChatThreadRecord {
  return {
    ...thread,
    isArchived: false,
    settledAt: null,
  };
}

function savePayload(file: string, payload: OpenClawTranscriptRecord): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(payload, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
  fs.renameSync(temporary, file);
  fs.chmodSync(file, 0o600);
}

function mutateOpenClawThreadState(
  corpusRoot: string,
  mutate: (payload: OpenClawTranscriptRecord) => string[],
  apply: boolean,
): OpenClawThreadMutationResult {
  const file = openClawTranscriptPath(corpusRoot);
  const payload = parsePayload(file);
  const affectedThreadIds = mutate(payload);
  const changed = affectedThreadIds.length > 0;
  if (changed) payload.version = Math.max(OPENCLAW_TRANSCRIPT_VERSION, payload.version || 1);
  if (changed && apply) savePayload(file, payload);
  return {
    applied: changed && apply,
    changed,
    state: stateFromPayload(file, payload),
    affectedThreadIds,
  };
}

export function settleOpenClawThread(
  corpusRoot: string,
  threadID: string,
  options: { apply?: boolean; now?: Date } = {},
): OpenClawThreadMutationResult {
  return mutateOpenClawThreadState(corpusRoot, (payload) => {
    const threads = normalizedThreads(payload);
    const index = threads.findIndex((thread) => thread.id === threadID);
    if (index < 0) throw new Error(`unknown OpenClaw thread: ${threadID}`);
    if (isOpenClawThreadSettled(threads[index]!)) return [];
    threads[index] = settledThread(threads[index]!, options.now || new Date());
    payload.threads = threads;
    return [threadID];
  }, options.apply === true);
}

export function reopenOpenClawThread(
  corpusRoot: string,
  threadID: string,
  options: { apply?: boolean } = {},
): OpenClawThreadMutationResult {
  return mutateOpenClawThreadState(corpusRoot, (payload) => {
    const threads = normalizedThreads(payload);
    const index = threads.findIndex((thread) => thread.id === threadID);
    if (index < 0) throw new Error(`unknown OpenClaw thread: ${threadID}`);
    if (!isOpenClawThreadSettled(threads[index]!)) return [];
    threads[index] = reopenedThread(threads[index]!);
    payload.threads = threads;
    return [threadID];
  }, options.apply === true);
}

export function configureOpenClawThreadSettlement(
  corpusRoot: string,
  autoSettleAfterSeconds: number | null,
  options: { apply?: boolean } = {},
): OpenClawThreadMutationResult {
  if (autoSettleAfterSeconds !== null && (!Number.isFinite(autoSettleAfterSeconds) || autoSettleAfterSeconds <= 0)) {
    throw new Error("auto-settle interval must be a positive number of seconds or null");
  }
  return mutateOpenClawThreadState(corpusRoot, (payload) => {
    const current = settlementSettings(payload).autoSettleAfterSeconds;
    if (current === autoSettleAfterSeconds) return [];
    payload.settlementSettings = { autoSettleAfterSeconds };
    return ["settings"];
  }, options.apply === true);
}

export function autoSettleOpenClawThreads(
  corpusRoot: string,
  options: { apply?: boolean; now?: Date } = {},
): OpenClawThreadMutationResult {
  return mutateOpenClawThreadState(corpusRoot, (payload) => {
    const settings = settlementSettings(payload);
    const now = options.now || new Date();
    const affected: string[] = [];
    payload.threads = normalizedThreads(payload).map((thread) => {
      if (!canAutoSettleOpenClawThread(thread, settings, now, payload.selectedThreadID || null)) return thread;
      affected.push(thread.id);
      return settledThread(thread, now);
    });
    return affected;
  }, options.apply === true);
}
