import { formatOrgTimestamp } from "./todo.js";

export interface CaptureSource {
  type: string;
  origin: string;
  timestamp: string;
  title: string | null;
  author: string | null;
  contentHash: string;
  provenance: string | null;
}

/** Common source/provenance envelope for CLI and browser capture. */
export function renderCaptureEntry(input: {
  title: string; template: "note" | "task"; todoKeyword?: string | null;
  body: string; now: Date; source?: CaptureSource | null;
}): { text: string; capturedAt: string } {
  const { source } = input;
  const singleLine = (value: string) => value.replace(/[\r\n\u0000]/g, " ");
  const heading = `* ${input.template === "task" ? `${singleLine(input.todoKeyword || "TODO")} ` : ""}${singleLine(input.title)}`;
  const capturedAt = formatOrgTimestamp(input.now);
  const drawer = source ? [
    ":PROPERTIES:", `:SOURCE_TYPE: ${singleLine(source.type)}`,
    `:SOURCE_ORIGIN: ${singleLine(source.origin)}`, `:SOURCE_TIMESTAMP: ${singleLine(source.timestamp)}`,
    source.author ? `:SOURCE_AUTHOR: ${singleLine(source.author)}` : "",
    `:SOURCE_HASH: ${source.contentHash}`,
    source.provenance ? `:SOURCE_PROVENANCE: ${singleLine(source.provenance)}` : "", ":END:",
  ].filter(Boolean).join("\n") + "\n" : "";
  return { capturedAt, text: `${heading}\n${drawer}CAPTURED: ${capturedAt}\n${input.body ? `\n${input.body}\n` : ""}` };
}
