import fs from "node:fs";

export type TodoStatus = "todo" | "in_progress" | "done" | "canceled";

export type TodoKeyword = "TODO" | "IN_PROGRESS" | "DONE" | "CANCELED" | "CANCELLED";

export const TODO_KEYWORDS: TodoKeyword[] = ["TODO", "IN_PROGRESS", "DONE", "CANCELED", "CANCELLED"];

export function keywordFromStatus(status: TodoStatus): TodoKeyword {
  if (status === "todo") return "TODO";
  if (status === "in_progress") return "IN_PROGRESS";
  if (status === "done") return "DONE";
  return "CANCELED";
}

export function statusFromKeyword(keyword: string | undefined): TodoStatus {
  const k = (keyword || "").toUpperCase();
  if (k === "IN_PROGRESS") return "in_progress";
  if (k === "DONE") return "done";
  if (k === "CANCELED" || k === "CANCELLED") return "canceled";
  return "todo";
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

function isHeadlineLine(line: string): boolean {
  return /^\*+\s+/.test(line);
}

function getHeadlineLevel(line: string): number {
  const m = /^(\*+)\s+/.exec(line);
  return m ? m[1].length : 0;
}

function parseHeadlineTodoKeyword(line: string): TodoKeyword | undefined {
  const m = /^(\*+)\s+(.*)$/.exec(line);
  if (!m) return undefined;
  const rest = m[2];
  const first = rest.split(/\s+/)[0] || "";
  const up = first.toUpperCase();
  if ((TODO_KEYWORDS as string[]).includes(up)) return up as TodoKeyword;
  return undefined;
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

function computeSubtreeRange(lines: string[], headingIndex: number): { start: number; endExclusive: number; level: number } {
  const level = getHeadlineLevel(lines[headingIndex] ?? "");
  for (let i = headingIndex + 1; i < lines.length; i++) {
    const line = lines[i] ?? "";
    if (isHeadlineLine(line) && getHeadlineLevel(line) <= level) {
      return { start: headingIndex, endExclusive: i, level };
    }
  }
  return { start: headingIndex, endExclusive: lines.length, level };
}

function findPlanningBlockEnd(lines: string[], headingIndex: number, endExclusive: number): number {
  // Planning lines typically immediately follow headline.
  // We'll treat lines starting with SCHEDULED:, DEADLINE:, CLOSED: as planning.
  let i = headingIndex + 1;
  while (i < endExclusive) {
    const line = lines[i] ?? "";
    if (/^(SCHEDULED:|DEADLINE:|CLOSED:)\s/.test(line)) {
      i++;
      continue;
    }
    break;
  }
  return i;
}

function upsertClosedPlanning(lines: string[], headingIndex: number, endExclusive: number, closedAt: string): void {
  const planningEnd = findPlanningBlockEnd(lines, headingIndex, endExclusive);
  for (let i = headingIndex + 1; i < planningEnd; i++) {
    if (/^CLOSED:\s/.test(lines[i] ?? "")) {
      lines[i] = `CLOSED: ${closedAt}`;
      return;
    }
  }
  lines.splice(planningEnd, 0, `CLOSED: ${closedAt}`);
}

function removeClosedPlanning(lines: string[], headingIndex: number, endExclusive: number): void {
  const planningEnd = findPlanningBlockEnd(lines, headingIndex, endExclusive);
  for (let i = headingIndex + 1; i < planningEnd; i++) {
    if (/^CLOSED:\s/.test(lines[i] ?? "")) {
      lines.splice(i, 1);
      return;
    }
  }
}

function findDrawer(lines: string[], start: number, endExclusive: number, name: string): { start: number; end: number; terminated: boolean } | null {
  const begin = `:${name}:`;
  for (let i = start; i < endExclusive; i++) {
    if ((lines[i] ?? "") === begin) {
      for (let j = i + 1; j < endExclusive; j++) {
        if ((lines[j] ?? "") === ":END:") {
          return { start: i, end: j, terminated: true };
        }
      }
      return { start: i, end: endExclusive - 1, terminated: false };
    }
  }
  return null;
}

function upsertProperty(lines: string[], propsStart: number, propsEnd: number, key: string, value: string): void {
  const keyPrefix = `:${key}:`;
  for (let i = propsStart + 1; i < propsEnd; i++) {
    const line = lines[i] ?? "";
    if (line.toUpperCase().startsWith(keyPrefix.toUpperCase())) {
      lines[i] = `${keyPrefix} ${value}`;
      return;
    }
  }
  // Insert before :END:
  lines.splice(propsEnd, 0, `${keyPrefix} ${value}`);
}

function ensurePropertyDrawer(lines: string[], insertAt: number): { start: number; end: number } {
  // Insert a new drawer:
  // :PROPERTIES:
  // :END:
  lines.splice(insertAt, 0, ":PROPERTIES:", ":END:");
  return { start: insertAt, end: insertAt + 1 };
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
  const lines = input.split("\n");

  const cursorIndex = Math.max(0, Math.min(lines.length - 1, opts.lineNumber - 1));

  let headingIndex = -1;
  for (let i = cursorIndex; i >= 0; i--) {
    if (isHeadlineLine(lines[i] ?? "")) {
      headingIndex = i;
      break;
    }
  }
  if (headingIndex < 0) {
    throw new Error(`No headline found at or above line ${opts.lineNumber}`);
  }

  const oldKeyword = parseHeadlineTodoKeyword(lines[headingIndex] ?? "");
  const oldStatus = statusFromKeyword(oldKeyword);

  const targetStatus = opts.toggle ? computeToggleStatus(oldStatus) : opts.status;
  if (!targetStatus) {
    throw new Error("Must provide either status or toggle");
  }

  const newKeyword = keywordFromStatus(targetStatus);

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

    const props = findDrawer(lines, afterPlanning, endExclusive, "PROPERTIES");
    if (props && props.terminated) {
      insertAfterProps = props.end + 1;
    }

    if (opts.logbook) {
      // Ensure LOGBOOK drawer
      let logbook = findDrawer(lines, insertAfterProps, endExclusive, "LOGBOOK");
      if (!logbook || !logbook.terminated) {
        const created = ensureLogbookDrawer(lines, insertAfterProps);
        logbook = { start: created.start, end: created.end, terminated: true };
      }

      // Insert log entry before :END:
      // Find end again (may have shifted)
      endExclusive = subtreeEndExclusive();
      const log2 = findDrawer(lines, insertAfterProps, endExclusive, "LOGBOOK");
      if (log2 && log2.terminated) {
        const entry = `- State \"${newKeyword}\" from \"${keywordFromStatus(oldStatus)}\" ${stamp}`;
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
