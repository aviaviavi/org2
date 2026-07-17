import fs from "node:fs";
import { computeSubtreeRange, findHeadingAtOrAbove, findPlanningBlockEnd, splitSourceLines } from "./sourceLines.js";

export type PlanningKind = "SCHEDULED" | "DEADLINE";

export type PlanningKindArg = "scheduled" | "deadline";

export function planningKindFromArg(kind: PlanningKindArg): PlanningKind {
  if (kind === "deadline") return "DEADLINE";
  return "SCHEDULED";
}

function formatOrgDateTimestamp(dateIso: string): string {
  // Format like <2026-01-17 Sat>
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateIso);
  if (!m) throw new Error(`Invalid --date (expected YYYY-MM-DD): ${dateIso}`);

  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);

  const d = new Date(0);
  d.setUTCHours(0, 0, 0, 0);
  d.setUTCFullYear(year, month - 1, day);
  if (d.getUTCFullYear() !== year || d.getUTCMonth() !== month - 1 || d.getUTCDate() !== day) {
    throw new Error(`Invalid --date: ${dateIso}`);
  }

  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const dow = days[d.getUTCDay()];
  return `<${dateIso} ${dow}>`;
}

function replacePlanningTokenInLine(line: string, kind: PlanningKind, timestamp: string): string {
  // Supports either dedicated planning lines or shared lines like:
  // "SCHEDULED: <...> DEADLINE: <...>"
  // We replace only the token for `kind`, preserving the rest.

  const tokenRe = new RegExp(`\\b${kind}:\\s+<[^>]*>`, "i");
  if (tokenRe.test(line)) {
    return line.replace(tokenRe, `${kind}: ${timestamp}`);
  }

  // If the line contains `${kind}:` but not a recognized <...> timestamp, do a looser replacement.
  const looseRe = new RegExp(`\\b${kind}:\\s*[^\n]*?(?=(\\s+(SCHEDULED|DEADLINE|CLOSED):)|$)`, "i");
  if (looseRe.test(line)) {
    return line.replace(looseRe, `${kind}: ${timestamp}`);
  }

  // Otherwise append at the end (keep it on the same line).
  return line.trimEnd() + (line.trimEnd().length ? " " : "") + `${kind}: ${timestamp}`;
}

export type UpdatePlanningResult = {
  filePath: string;
  headingLineNumber: number; // 1-based
  kind: PlanningKind;
  date: string; // YYYY-MM-DD
  changed: boolean;
  text: string;
};

export type UpdatePlanningOptions = {
  filePath: string;
  lineNumber: number; // 1-based cursor line
  kind: PlanningKind;
  date: string; // YYYY-MM-DD
};

export function updatePlanningInText(input: string, opts: UpdatePlanningOptions): UpdatePlanningResult {
  const lines = splitSourceLines(input);
  const headingIndex = findHeadingAtOrAbove(lines, opts.lineNumber);

  const { endExclusive } = computeSubtreeRange(lines, headingIndex);

  const timestamp = formatOrgDateTimestamp(opts.date);

  // Planning lines (if present) are expected to appear immediately after the headline.
  // We'll update the first planning line that mentions the target kind; otherwise insert
  // a new planning line at the end of the planning block.

  const planStart = headingIndex + 1;
  const planEnd = findPlanningBlockEnd(lines, headingIndex, endExclusive);

  let changed = false;

  // Search within planning block.
  for (let i = planStart; i < planEnd; i++) {
    const line = lines[i] ?? "";
    if (new RegExp(`\\b${opts.kind}:`, "i").test(line)) {
      const updated = replacePlanningTokenInLine(line, opts.kind, timestamp);
      if (updated !== line) {
        lines[i] = updated;
        changed = true;
      }
      return {
        filePath: opts.filePath,
        headingLineNumber: headingIndex + 1,
        kind: opts.kind,
        date: opts.date,
        changed,
        text: lines.join("\n"),
      };
    }
  }

  // No existing token.
  if (planEnd === planStart) {
    // No planning lines; insert immediately after headline.
    lines.splice(planStart, 0, `${opts.kind}: ${timestamp}`);
    changed = true;
  } else {
    // Planning block exists, but doesn't include this kind; append to last planning line.
    const lastIdx = planEnd - 1;
    const before = lines[lastIdx] ?? "";
    const updated = replacePlanningTokenInLine(before, opts.kind, timestamp);
    if (updated !== before) {
      lines[lastIdx] = updated;
      changed = true;
    }
  }

  return {
    filePath: opts.filePath,
    headingLineNumber: headingIndex + 1,
    kind: opts.kind,
    date: opts.date,
    changed,
    text: lines.join("\n"),
  };
}

export function updatePlanningInFile(opts: UpdatePlanningOptions & { apply: boolean }): UpdatePlanningResult {
  const raw = fs.readFileSync(opts.filePath, "utf8");
  const res = updatePlanningInText(raw, opts);
  if (opts.apply) {
    fs.writeFileSync(opts.filePath, res.text, "utf8");
  }
  return res;
}
