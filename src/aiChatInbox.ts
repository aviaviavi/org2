import crypto from "node:crypto";
import path from "node:path";
import {
  aiChatInboxDirectory as sharedAIChatInboxDirectory,
  encodedJSONEnvelope,
  publishJSONEnvelope,
} from "./aiChatOperationJournal.js";
import { findOpenClawThread, loadOpenClawThreadState } from "./openClawThreadState.js";

export const AI_CHAT_INBOX_SCHEMA = "org2:ai-chat-inbox-message:v1";

export interface AIChatInboxMessage {
  schema: typeof AI_CHAT_INBOX_SCHEMA;
  id: string;
  threadID: string;
  content: string;
  createdAt: string;
  authorLabel: string;
  authorAgentRef?: string;
  source?: string;
}

export interface QueueAIChatInboxMessageOptions {
  authorLabel?: string;
  authorAgentRef?: string;
  source?: string;
  idempotencyKey?: string;
  apply?: boolean;
  now?: Date;
}

export interface QueueAIChatInboxMessageResult {
  applied: boolean;
  changed: boolean;
  file: string;
  message: AIChatInboxMessage;
}

export function aiChatInboxDirectory(corpusRoot: string): string {
  return sharedAIChatInboxDirectory(corpusRoot);
}

function normalizedOptional(value: string | undefined): string | undefined {
  const normalized = value?.trim();
  return normalized ? normalized : undefined;
}

function uuidForIdempotencyKey(key: string): string {
  const bytes = crypto.createHash("sha256").update(key).digest().subarray(0, 16);
  bytes[6] = (bytes[6]! & 0x0f) | 0x50;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function sameDelivery(left: AIChatInboxMessage, right: AIChatInboxMessage): boolean {
  return left.schema === right.schema
    && left.id === right.id
    && left.threadID === right.threadID
    && left.content === right.content
    && left.authorLabel === right.authorLabel
    && left.authorAgentRef === right.authorAgentRef
    && left.source === right.source;
}

export function queueAIChatInboxMessage(
  corpusRoot: string,
  threadID: string,
  rawContent: string,
  options: QueueAIChatInboxMessageOptions = {},
): QueueAIChatInboxMessageResult {
  const content = rawContent.trim();
  if (!content) throw new Error("AI chat message content is required");
  if (content.length > 200_000) throw new Error("AI chat message content exceeds 200000 characters");
  const requestedThreadID = threadID.trim();
  const state = loadOpenClawThreadState(corpusRoot, { hydrateThreadID: requestedThreadID });
  const thread = findOpenClawThread(state, requestedThreadID);
  if (!thread) {
    throw new Error(`unknown OpenClaw thread: ${threadID}`);
  }
  const canonicalThreadID = thread.id.toLowerCase();
  const idempotencyKey = normalizedOptional(options.idempotencyKey);
  const id = idempotencyKey
    ? uuidForIdempotencyKey(`${canonicalThreadID}\u0000${idempotencyKey}`)
    : crypto.randomUUID();
  const authorAgentRef = normalizedOptional(options.authorAgentRef);
  const authorLabel = normalizedOptional(options.authorLabel) || authorAgentRef;
  if (!authorLabel) throw new Error("AI chat message author or agent ref is required");
  if (authorLabel.length > 200) throw new Error("AI chat message author exceeds 200 characters");
  if (authorAgentRef && authorAgentRef.length > 1_000) throw new Error("AI chat agent ref exceeds 1000 characters");
  const now = options.now || new Date();
  if (!Number.isFinite(now.getTime())) throw new Error("AI chat message time must be valid");
  const source = normalizedOptional(options.source);
  if (source && source.length > 2_000) throw new Error("AI chat source exceeds 2000 characters");
  const message: AIChatInboxMessage = {
    schema: AI_CHAT_INBOX_SCHEMA,
    id,
    threadID: canonicalThreadID,
    content,
    createdAt: now.toISOString(),
    authorLabel,
    ...(authorAgentRef ? { authorAgentRef } : {}),
    ...(source ? { source } : {}),
  };
  const file = path.join(aiChatInboxDirectory(corpusRoot), `${id}.json`);
  const delivered = thread.messages?.find((item) => item.id === id);
  if (delivered) {
    const matches = delivered.content === message.content
      && delivered.authorLabel === message.authorLabel
      && delivered.authorAgentRef === message.authorAgentRef
      && delivered.source === message.source;
    if (!matches) {
      throw new Error(`AI chat idempotency key already delivered a different message to ${canonicalThreadID}`);
    }
    return { applied: false, changed: false, file, message };
  }
  // The Swift consumer caps the complete UTF-8 envelope at 512,000 bytes.
  // Validate that exact representation before preview or publication.
  encodedJSONEnvelope(message);
  if (!options.apply) return { applied: false, changed: true, file, message };
  const published = publishJSONEnvelope(file, message, sameDelivery, "message");
  return {
    applied: published.applied,
    changed: published.applied,
    file,
    message: published.payload,
  };
}
