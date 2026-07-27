import type { TimestampRepeater, TimestampWarning } from "./ast.js";

const TIMESTAMP_REPEATER_RE = /(?:^|\s)(\+\+|\.\+|\+)(\d+)([dwmy])(?=[^A-Za-z0-9]|$)/i;
const TIMESTAMP_WARNING_RE = /(?:^|\s)(--|-)(\d+)([dwmy])(?=[^A-Za-z0-9]|$)/i;

export function parseTimestampRepeater(raw: string): TimestampRepeater | undefined {
  const match = TIMESTAMP_REPEATER_RE.exec(raw);
  if (!match) return undefined;

  const mode = match[1];
  const value = Number.parseInt(match[2] ?? "", 10);
  const unit = (match[3] ?? "").toLowerCase();
  if (mode !== "+" && mode !== "++" && mode !== ".+") return undefined;
  if (!Number.isSafeInteger(value) || value <= 0) return undefined;
  if (unit !== "d" && unit !== "w" && unit !== "m" && unit !== "y") return undefined;

  return { mode, value, unit, raw: match[0].trim() };
}

export function parseTimestampWarning(raw: string): TimestampWarning | undefined {
  const match = TIMESTAMP_WARNING_RE.exec(raw);
  if (!match) return undefined;

  const mode = match[1];
  const value = Number.parseInt(match[2] ?? "", 10);
  const unit = (match[3] ?? "").toLowerCase();
  if (mode !== "-" && mode !== "--") return undefined;
  if (!Number.isSafeInteger(value) || value <= 0) return undefined;
  if (unit !== "d" && unit !== "w" && unit !== "m" && unit !== "y") return undefined;

  return { mode, value, unit, raw: match[0].trim() };
}
