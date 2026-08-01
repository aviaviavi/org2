import fs from "node:fs";
import {
  computeSubtreeRange,
  findDrawerInLines,
  findHeadingAtOrAbove,
  findPlanningBlockEnd,
  getDrawerPropertyValue,
  splitSourceLines,
  upsertHeadlinePropertyInLines,
} from "./sourceLines.js";

export type TodoStatus = "todo" | "in_progress" | "done" | "canceled";
export type TerminalTodoStatus = Extract<TodoStatus, "done" | "canceled">;

export const TODO_KEYWORDS = ["TODO", "IN_PROGRESS", "DONE", "CANCELED", "CANCELLED"] as const;

export type TodoKeyword = typeof TODO_KEYWORDS[number];

const TODO_KEYWORD_SET = new Set<string>(TODO_KEYWORDS);

export function isTodoKeyword(value: string | undefined): value is TodoKeyword {
  return typeof value === "string" && TODO_KEYWORD_SET.has(value);
}

export function normalizeTodoKeyword(value: string | undefined): TodoKeyword | undefined {
  const normalized = (value || "").trim().toUpperCase();
  return isTodoKeyword(normalized) ? normalized : undefined;
}

export function keywordFromStatus(status: TodoStatus, opts?: { canceledKeyword?: "CANCELED" | "CANCELLED" }): TodoKeyword {
  if (status === "todo") return "TODO";
  if (status === "in_progress") return "IN_PROGRESS";
  if (status === "done") return "DONE";
  return opts?.canceledKeyword === "CANCELLED" ? "CANCELLED" : "CANCELED";
}

export function statusFromKeyword(keyword: string | undefined): TodoStatus {
  const k = (keyword || "").toUpperCase();
  if (k === "IN_PROGRESS") return "in_progress";
  if (k === "DONE") return "done";
  if (k === "CANCELED" || k === "CANCELLED") return "canceled";
  return "todo";
}

export function terminalTodoStatusFromKeyword(keyword: string | null | undefined): TerminalTodoStatus | undefined {
  const status = statusFromKeyword(normalizeTodoKeyword(keyword ?? undefined));
  return status === "done" || status === "canceled" ? status : undefined;
}

export function isTerminalTodoKeyword(keyword: string | null | undefined): boolean {
  return terminalTodoStatusFromKeyword(keyword) !== undefined;
}

export function isActiveTodoKeyword(keyword: string | null | undefined): boolean {
  return Boolean(keyword) && !isTerminalTodoKeyword(keyword);
}

export function formatOrgTimestamp(now: Date): string {
  // Format like <2026-01-21 Wed 12:34>
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  const dow = days[now.getDay()];
  const hh = String(now.getHours()).padStart(2, "0");
  const mm = String(now.getMinutes()).padStart(2, "0");
  return `<${year}-${month}-${day} ${dow} ${hh}:${mm}>`;
}

function parseHeadlineTodoKeyword(line: string): TodoKeyword | undefined {
  const m = /^(\*+)\s+(.*)$/.exec(line);
  if (!m) return undefined;
  const rest = m[2];
  const first = rest.split(/\s+/)[0] || "";
  return normalizeTodoKeyword(first);
}

function replaceOrInsertTodoKeyword(line: string, newKeyword: TodoKeyword): { line: string; oldKeyword?: TodoKeyword } {
  const m = /^(\*+)\s+(.*)$/.exec(line);
  if (!m) return { line };
  const stars = m[1];
  const rest = m[2];
  const old = parseHeadlineTodoKeyword(line);

  if (old) {
    // Replace only the leading keyword.
    const replaced = rest.replace(new RegExp(`^${old}\\b`), newKeyword);
    return { line: `${stars} ${replaced}`, oldKeyword: old };
  }

  // Insert keyword before title.
  return { line: `${stars} ${newKeyword} ${rest}`, oldKeyword: undefined };
}

function upsertClosedPlanning(lines: string[], headingIndex: number, endExclusive: number, closedAt: string): void {
  const planningEnd = findPlanningBlockEnd(lines, headingIndex, endExclusive);
  let firstClosedIndex = -1;

  for (let i = headingIndex + 1; i < planningEnd; i++) {
    if (!/^CLOSED:\s/.test(lines[i] ?? "")) continue;
    if (firstClosedIndex < 0) {
      firstClosedIndex = i;
      continue;
    }
    // Deduplicate stale duplicate CLOSED lines while preserving first position.
    lines.splice(i, 1);
    i--;
  }

  if (firstClosedIndex >= 0) {
    lines[firstClosedIndex] = `CLOSED: ${closedAt}`;
    return;
  }

  lines.splice(planningEnd, 0, `CLOSED: ${closedAt}`);
}

function removeClosedPlanning(lines: string[], headingIndex: number, endExclusive: number): void {
  const planningEnd = findPlanningBlockEnd(lines, headingIndex, endExclusive);
  for (let i = planningEnd - 1; i > headingIndex; i--) {
    if (/^CLOSED:\s/.test(lines[i] ?? "")) {
      lines.splice(i, 1);
    }
  }
}

function ensureLogbookDrawer(lines: string[], insertAt: number): { start: number; end: number } {
  lines.splice(insertAt, 0, ":LOGBOOK:", ":END:");
  return { start: insertAt, end: insertAt + 1 };
}

export type UpdateTodoResult = {
  filePath: string;
  headingLineNumber: number; // 1-based
  oldStatus: TodoStatus;
  newStatus: TodoStatus;
  closedAt?: string;
  changed: boolean;
  text: string;
};

export type UpdateTodoOptions = {
  filePath: string;
  lineNumber: number; // 1-based cursor line
  status?: TodoStatus;
  toggle?: boolean;
  now?: Date;
  logbook?: boolean;
};

export type AssignTodoResult = {
  filePath: string;
  headingLineNumber: number; // 1-based
  property: "ASSIGNEE";
  oldAssignee?: string;
  newAssignee: string;
  changed: boolean;
  text: string;
};

export type AssignTodoOptions = {
  filePath: string;
  lineNumber: number; // 1-based cursor line
  assignee: string;
};

export function computeToggleStatus(current: TodoStatus): TodoStatus {
  // Cycle: todo -> in_progress -> done -> todo
  if (current === "todo") return "in_progress";
  if (current === "in_progress") return "done";
  // done or canceled -> todo
  return "todo";
}

export function updateTodoInText(input: string, opts: UpdateTodoOptions): UpdateTodoResult {
  const now = opts.now ?? new Date();
  const stamp = formatOrgTimestamp(now);
  const lines = splitSourceLines(input);

  const headingIndex = findHeadingAtOrAbove(lines, opts.lineNumber);

  const oldKeyword = parseHeadlineTodoKeyword(lines[headingIndex] ?? "");
  const oldStatus = statusFromKeyword(oldKeyword);

  const targetStatus = opts.toggle ? computeToggleStatus(oldStatus) : opts.status;
  if (!targetStatus) {
    throw new Error("Must provide either status or toggle");
  }

  const canceledKeywordPreference = oldKeyword === "CANCELLED" ? "CANCELLED" : undefined;
  const newKeyword = keywordFromStatus(targetStatus, {
    ...(canceledKeywordPreference ? { canceledKeyword: canceledKeywordPreference } : {}),
  });

  const { line: newHeadlineLine } = replaceOrInsertTodoKeyword(lines[headingIndex] ?? "", newKeyword);
  const changed = newHeadlineLine !== (lines[headingIndex] ?? "");
  lines[headingIndex] = newHeadlineLine;

  const subtreeEndExclusive = (): number => computeSubtreeRange(lines, headingIndex).endExclusive;

  // Optionally write state transition logbook entries.
  if (oldStatus !== targetStatus) {
    // closedAt for done/canceled; reopening clears stale CLOSED metadata.
    let closedAt: string | undefined;
    if (targetStatus === "done" || targetStatus === "canceled") {
      closedAt = stamp;
      upsertClosedPlanning(lines, headingIndex, subtreeEndExclusive(), closedAt);
    } else {
      removeClosedPlanning(lines, headingIndex, subtreeEndExclusive());
    }

    // Figure insertion base after planning block and property drawer (if present).
    let endExclusive = subtreeEndExclusive();
    const afterPlanning = findPlanningBlockEnd(lines, headingIndex, endExclusive);
    let insertAfterProps = afterPlanning;

    const props = findDrawerInLines(lines, afterPlanning, endExclusive, "PROPERTIES");
    if (props && props.terminated) {
      insertAfterProps = props.end + 1;
    }

    if (opts.logbook) {
      // Prefer existing LOGBOOK drawer placement (even if it appears before PROPERTIES)
      // to avoid creating duplicate drawers during status transitions.
      const logbookSearchStart = afterPlanning;
      let logbook = findDrawerInLines(lines, logbookSearchStart, endExclusive, "LOGBOOK");
      if (!logbook || !logbook.terminated) {
        const created = ensureLogbookDrawer(lines, insertAfterProps);
        logbook = { start: created.start, end: created.end, terminated: true };
      }

      // Insert log entry before :END:
      // Find end again (may have shifted)
      endExclusive = subtreeEndExclusive();
      const log2 = findDrawerInLines(lines, logbookSearchStart, endExclusive, "LOGBOOK");
      if (log2 && log2.terminated) {
        const oldKeywordForLog =
          oldKeyword && statusFromKeyword(oldKeyword) === oldStatus
            ? oldKeyword
            : keywordFromStatus(oldStatus, {
                ...(canceledKeywordPreference ? { canceledKeyword: canceledKeywordPreference } : {}),
              });
        const entry = `- State \"${newKeyword}\" from \"${oldKeywordForLog}\" ${stamp}`;
        lines.splice(log2.end, 0, entry);
      }
    }

    return {
      filePath: opts.filePath,
      headingLineNumber: headingIndex + 1,
      oldStatus,
      newStatus: targetStatus,
      ...(closedAt ? { closedAt } : {}),
      changed,
      text: lines.join("\n"),
    };
  }

  return {
    filePath: opts.filePath,
    headingLineNumber: headingIndex + 1,
    oldStatus,
    newStatus: targetStatus,
    changed,
    text: lines.join("\n"),
  };
}

export function updateTodoInFile(opts: UpdateTodoOptions & { apply: boolean }): UpdateTodoResult {
  const raw = fs.readFileSync(opts.filePath, "utf8");
  const res = updateTodoInText(raw, opts);
  if (opts.apply) {
    fs.writeFileSync(opts.filePath, res.text, "utf8");
  }
  return res;
}

export function assignTodoInText(input: string, opts: AssignTodoOptions): AssignTodoResult {
  const assignee = opts.assignee.trim();
  if (!assignee) throw new Error("Assignee cannot be empty");

  const lines = splitSourceLines(input);
  const headingIndex = findHeadingAtOrAbove(lines, opts.lineNumber);
  const endExclusive = computeSubtreeRange(lines, headingIndex).endExclusive;
  const afterPlanning = findPlanningBlockEnd(lines, headingIndex, endExclusive);

  const props = findDrawerInLines(lines, afterPlanning, endExclusive, "PROPERTIES");
  const oldAssignee = props ? getDrawerPropertyValue(lines, props, "ASSIGNEE") : undefined;
  const changed = oldAssignee !== assignee;
  if (changed) {
    upsertHeadlinePropertyInLines(lines, headingIndex, "ASSIGNEE", assignee);
  }

  return {
    filePath: opts.filePath,
    headingLineNumber: headingIndex + 1,
    property: "ASSIGNEE",
    ...(oldAssignee ? { oldAssignee } : {}),
    newAssignee: assignee,
    changed,
    text: lines.join("\n"),
  };
}

export function assignTodoInFile(opts: AssignTodoOptions & { apply: boolean }): AssignTodoResult {
  const raw = fs.readFileSync(opts.filePath, "utf8");
  const res = assignTodoInText(raw, opts);
  if (opts.apply) {
    fs.writeFileSync(opts.filePath, res.text, "utf8");
  }
  return res;
}
