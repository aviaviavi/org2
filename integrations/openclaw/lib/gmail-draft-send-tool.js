import { execFile } from "node:child_process";
import { mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";
import { promisify } from "node:util";
import {
  gmailDraftEffect,
  hydrateGogDraftEffect,
  strictProviderGmailSendReceipt,
} from "./approval-effects.js";

const execFileAsync = promisify(execFile);
const DEFAULT_GOG_EXECUTABLE = "/usr/local/bin/gog";

function result(payload) {
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    details: payload,
  };
}

export async function resolveCanonicalGogExecutable(
  configured = DEFAULT_GOG_EXECUTABLE,
  resolveRealpath = realpath,
) {
  const requested = String(configured || "").trim();
  if (!requested || !isAbsolute(requested)) {
    throw new Error("The Org2 Gmail sender requires an absolute gog executable path");
  }
  const resolved = await resolveRealpath(requested);
  if (!isAbsolute(resolved)) throw new Error("The resolved gog executable path is not absolute");
  return resolved;
}

export function createGmailDraftSendTool(options) {
  const lifecycle = options.lifecycle;
  if (!lifecycle) throw new Error("The Org2 Gmail sender requires a lifecycle");
  const executeFile = options.execFile || execFileAsync;
  const resolveRealpath = options.realpath || realpath;
  const configuredExecutable = options.gogExecutable || DEFAULT_GOG_EXECUTABLE;

  return {
    name: "org2_gmail_draft_send",
    label: "Send approved Gmail draft",
    description: "Send one existing Gmail draft only after its exact native Org2 approval has been durably reserved. Requires an explicit account selector and draft ID; the provider mailbox identity is resolved before approval.",
    promptSnippet: "Send an exact, already-reviewed Gmail draft through its native Org2 approval boundary.",
    promptGuidelines: [
      "Use org2_gmail_draft_send for Gmail draft sends. Direct shell/API email sends are blocked.",
      "If the tool reports a pending, stale, performed, or uncertain approval, do not retry through another tool.",
    ],
    parameters: {
      type: "object",
      required: ["account", "draftId"],
      properties: {
        account: {
          type: "string",
          minLength: 3,
          description: "Explicit Gmail account email or configured gog alias that owns the draft.",
        },
        draftId: {
          type: "string",
          minLength: 1,
          pattern: "^[A-Za-z0-9_-]+$",
          description: "Exact Gmail draft ID.",
        },
      },
      additionalProperties: false,
    },
    executionMode: "parallel",
    async execute(toolCallId, params, signal) {
      const account = String(params.account || "").trim();
      const draftId = String(params.draftId || "").trim();
      if (!account || /[\r\n\0]/.test(account)) throw new Error("A literal Gmail account is required");
      if (!/^[A-Za-z0-9_-]+$/.test(draftId)) throw new Error("A literal Gmail draft ID is required");
      const gogExecutable = await resolveCanonicalGogExecutable(configuredExecutable, resolveRealpath);
      const invoke = (command, args, execOptions = {}) => executeFile(command, args, {
        ...execOptions,
        ...(signal ? { signal } : {}),
      });
      const exact = await hydrateGogDraftEffect(
        gmailDraftEffect(account, draftId, gogExecutable),
        { gogExecutable, execFile: invoke },
      );
      await lifecycle.reserveDraftSend(exact, { toolCallId });

      // Once the durable reservation exists, every ambiguous failure stays blocked.
      // A human/provider reconciliation must explicitly release it; this path never
      // turns an uncertain external effect back into an allowed retry.
      const scratch = await mkdtemp(join(tmpdir(), "org2-gmail-send-"));
      let stdout = "";
      try {
        const bodyFile = join(scratch, "message.json");
        await writeFile(bodyFile, `${JSON.stringify({
          raw: exact.rawMessage,
          threadId: exact.threadId,
        })}\n`, { mode: 0o600 });
        ({ stdout } = await invoke(gogExecutable, [
          "api", "call", "gmail", "v1", "gmail.users.messages.send",
          "--params", JSON.stringify({ userId: "me" }),
          "--body", `@${bodyFile}`,
          "--allow-write", "--force",
          "--account", exact.account,
          "--json", "--no-input",
        ], { maxBuffer: 2_000_000, timeout: 30_000 }));
      } finally {
        await rm(scratch, { recursive: true, force: true });
      }
      const receipt = strictProviderGmailSendReceipt(stdout);
      if (receipt.threadId !== exact.threadId) {
        throw new Error(
          "Gmail sent the reviewed message into a different thread; "
          + "the effect reservation remains unresolved pending provider reconciliation",
        );
      }
      const externalId = receipt.messageId;
      await lifecycle.recordDraftSent(exact, { toolCallId, externalId });
      return result({
        sent: true,
        account: exact.account,
        draftId,
        draftRetained: true,
        messageId: externalId,
        threadId: receipt.threadId,
        materialDigest: exact.materialDigest,
      });
    },
  };
}
