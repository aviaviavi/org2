#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import crypto from "node:crypto";
import os from "node:os";
import { spawnSync } from "node:child_process";
import { parseOrgToCanonicalAst } from "./parser.js";
import { printCanonicalAstToOrg } from "./printer.js";
import { normalizePgpArmorForDecrypt, protectPgpBlocks, restorePgpBlocks } from "./pgp.js";
import {
  findConfigFile,
  loadConfig,
  resolveFilesFromConfig,
  resolveFilesFromDir,
  type Org2PublishProjectConfig,
} from "./config.js";
import { resolvePublishHeadIncludes } from "./publish-defaults.js";
import { formatOrgTimestamp, TODO_KEYWORDS, updateTodoInText, type TodoStatus } from "./todo.js";
import { planningKindFromArg, updatePlanningInText, type PlanningKindArg } from "./planning.js";
import { findBacklinksInText, type Backlink } from "./backlinks.js";
import { renderOrgDocumentToHtml, renderOrgExportIndexToHtml } from "./export.js";
import type {
  DocumentNode,
  HeadlineNode,
  Node,
  PlanningNode,
  TimestampNode,
  TimestampRangeNode,
} from "./ast.js";

// Parse ISO date string to Date
function parseIsoDate(dateStr: string): Date {
  const d = new Date(dateStr);
  if (isNaN(d.getTime())) {
    throw new Error(`Invalid date format: ${dateStr}`);
  }
  return d;
}

// Parse timestamp like "<2026-01-17 Sat>"
function extractDateFromTimestamp(raw: string): string | null {
  const match = raw.match(/(\d{4})-(\d{2})-(\d{2})/);
  return match ? match[0] : null;
}

function normalizeAgendaTimeToken(raw: string): string | null {
  const match = String(raw || "").match(/(?:^|\s)(\d{1,2}):(\d{2})(?=[^0-9]|$)/);
  if (!match) return null;

  const hour = Number.parseInt(match[1] ?? "", 10);
  const minute = Number.parseInt(match[2] ?? "", 10);

  if (!Number.isFinite(hour) || !Number.isFinite(minute)) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

function parseAgendaTimeToMinutes(raw: string | undefined): number | null {
  const normalized = normalizeAgendaTimeToken(String(raw || ""));
  if (!normalized) return null;

  const [hourRaw, minuteRaw] = normalized.split(":");
  const hour = Number.parseInt(hourRaw || "", 10);
  const minute = Number.parseInt(minuteRaw || "", 10);

  if (!Number.isFinite(hour) || !Number.isFinite(minute)) return null;
  return hour * 60 + minute;
}

function extractTimeFromTimestamp(raw: string): string | undefined {
  const normalized = normalizeAgendaTimeToken(raw);
  return normalized || undefined;
}

type TimestampRepeater = {
  mode: "+" | "++" | ".+";
  value: number;
  unit: "d" | "w" | "m" | "y";
};

type TimestampWarning = {
  mode: "-" | "--";
  value: number;
  unit: "d" | "w" | "m" | "y";
};

type ExportMetadataPayload = {
  author?: string;
  date?: string;
  subtitle?: string;
  description?: string;
  keywords?: string[];
  language?: string;
  htmlHead?: string[];
};

function hasExportMetadata(metadata: ExportMetadataPayload | null | undefined): boolean {
  if (!metadata) return false;
  return Boolean(
    metadata.author ||
      metadata.date ||
      metadata.subtitle ||
      metadata.description ||
      metadata.language ||
      (Array.isArray(metadata.keywords) && metadata.keywords.length > 0) ||
      (Array.isArray(metadata.htmlHead) && metadata.htmlHead.length > 0),
  );
}

function parseTimestampRepeater(raw: string): TimestampRepeater | null {
  const match = raw.match(/(?:^|\s)(\+\+|\.\+|\+)(\d+)([dwmy])(?=[^A-Za-z0-9]|$)/i);
  if (!match) return null;

  const modeRaw = match[1] ?? "+";
  const valueRaw = match[2] ?? "";
  const unitRaw = (match[3] ?? "").toLowerCase();

  const value = Number.parseInt(valueRaw, 10);
  if (!Number.isFinite(value) || value <= 0) return null;
  if (unitRaw !== "d" && unitRaw !== "w" && unitRaw !== "m" && unitRaw !== "y") return null;

  if (modeRaw !== "+" && modeRaw !== "++" && modeRaw !== ".+") return null;

  return {
    mode: modeRaw,
    value,
    unit: unitRaw,
  };
}

function parseTimestampWarning(raw: string): TimestampWarning | null {
  const match = raw.match(/(?:^|\s)(--|-)(\d+)([dwmy])(?=[^A-Za-z0-9]|$)/i);
  if (!match) return null;

  const modeRaw = match[1] ?? "-";
  const valueRaw = match[2] ?? "";
  const unitRaw = (match[3] ?? "").toLowerCase();

  const value = Number.parseInt(valueRaw, 10);
  if (!Number.isFinite(value) || value <= 0) return null;
  if (unitRaw !== "d" && unitRaw !== "w" && unitRaw !== "m" && unitRaw !== "y") return null;

  if (modeRaw !== "-" && modeRaw !== "--") return null;

  return {
    mode: modeRaw,
    value,
    unit: unitRaw,
  };
}

function daysInUtcMonth(year: number, monthZeroBased: number): number {
  return new Date(Date.UTC(year, monthZeroBased + 1, 0)).getUTCDate();
}

function addMonthsUtcClamped(date: Date, monthDelta: number): Date {
  const year = date.getUTCFullYear();
  const month = date.getUTCMonth();
  const day = date.getUTCDate();

  const totalMonths = year * 12 + month + monthDelta;
  const targetYear = Math.floor(totalMonths / 12);
  const targetMonth = ((totalMonths % 12) + 12) % 12;
  const targetDay = Math.min(day, daysInUtcMonth(targetYear, targetMonth));

  return new Date(
    Date.UTC(
      targetYear,
      targetMonth,
      targetDay,
      date.getUTCHours(),
      date.getUTCMinutes(),
      date.getUTCSeconds(),
      date.getUTCMilliseconds(),
    ),
  );
}

function addYearsUtcClamped(date: Date, yearDelta: number): Date {
  const targetYear = date.getUTCFullYear() + yearDelta;
  const targetMonth = date.getUTCMonth();
  const targetDay = Math.min(date.getUTCDate(), daysInUtcMonth(targetYear, targetMonth));

  return new Date(
    Date.UTC(
      targetYear,
      targetMonth,
      targetDay,
      date.getUTCHours(),
      date.getUTCMinutes(),
      date.getUTCSeconds(),
      date.getUTCMilliseconds(),
    ),
  );
}

function addTimestampInterval(
  date: Date,
  value: number,
  unit: "d" | "w" | "m" | "y",
  direction: 1 | -1,
): Date {
  const next = new Date(date.getTime());
  const signedValue = direction * value;

  switch (unit) {
    case "d":
      next.setUTCDate(next.getUTCDate() + signedValue);
      break;
    case "w":
      next.setUTCDate(next.getUTCDate() + signedValue * 7);
      break;
    case "m":
      return addMonthsUtcClamped(date, signedValue);
    case "y":
      return addYearsUtcClamped(date, signedValue);
  }

  return next;
}

function addRepeaterInterval(date: Date, repeater: TimestampRepeater): Date {
  // For agenda projection we treat +, ++, and .+ as fixed intervals from the
  // timestamp date and expand occurrences that fall within the requested range.
  return addTimestampInterval(date, repeater.value, repeater.unit, 1);
}

function subtractWarningInterval(date: Date, warning: TimestampWarning): Date {
  return addTimestampInterval(date, warning.value, warning.unit, -1);
}

function addWarningInterval(date: Date, warning: TimestampWarning): Date {
  return addTimestampInterval(date, warning.value, warning.unit, 1);
}

function formatIsoDateUtc(date: Date): string {
  const year = String(date.getUTCFullYear());
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  const day = String(date.getUTCDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function resolveAgendaDatesFromTimestamp(
  raw: string,
  startDate: Date,
  endDate: Date,
  wantsOverdue: boolean,
  planningKind: "SCHEDULED" | "DEADLINE",
): string[] {
  const dateStr = extractDateFromTimestamp(raw);
  if (!dateStr) return [];

  const firstDate = parseIsoDate(dateStr);
  const repeater = parseTimestampRepeater(raw);
  const warning = parseTimestampWarning(raw);

  const seen = new Set<string>();
  const resolved: string[] = [];
  let latestBeforeStart: Date | null = null;

  const addResolved = (date: Date): void => {
    const iso = formatIsoDateUtc(date);
    if (seen.has(iso)) return;
    seen.add(iso);
    resolved.push(iso);
  };

  const consider = (date: Date): void => {
    if (date >= startDate && date <= endDate) {
      addResolved(date);
      return;
    }

    if (date < startDate && (!latestBeforeStart || date.getTime() > latestBeforeStart.getTime())) {
      latestBeforeStart = new Date(date.getTime());
    }
  };

  const considerOccurrence = (occurrenceDate: Date, occurrenceIndex: number): void => {
    if (planningKind === "SCHEDULED") {
      let scheduledDate = occurrenceDate;
      if (warning) {
        const warningApplies = warning.mode === "-" || !repeater || occurrenceIndex === 0;
        if (warningApplies) {
          scheduledDate = addWarningInterval(occurrenceDate, warning);
        }
      }
      consider(scheduledDate);
      return;
    }

    consider(occurrenceDate);

    if (!warning) return;
    const warningDate = subtractWarningInterval(occurrenceDate, warning);

    if (warning.mode === "--") {
      if (warningDate < startDate) {
        const latestWindowBeforeStart = occurrenceDate < startDate
          ? new Date(occurrenceDate.getTime())
          : addTimestampInterval(startDate, 1, "d", -1);
        if (latestWindowBeforeStart.getTime() >= warningDate.getTime()) {
          consider(latestWindowBeforeStart);
        }
      }

      const inRangeStartMs = Math.max(warningDate.getTime(), startDate.getTime());
      const inRangeEndMs = Math.min(occurrenceDate.getTime(), endDate.getTime());
      if (inRangeStartMs <= inRangeEndMs) {
        let cursorDate = new Date(inRangeStartMs);
        while (cursorDate.getTime() <= inRangeEndMs) {
          consider(cursorDate);
          cursorDate = addTimestampInterval(cursorDate, 1, "d", 1);
        }
      }
      return;
    }

    consider(warningDate);
  };

  if (!repeater) {
    considerOccurrence(firstDate, 0);
    if (wantsOverdue && latestBeforeStart) addResolved(latestBeforeStart);
    return resolved.sort();
  }

  const maxIterations = 10000;
  let cursor = new Date(firstDate.getTime());
  let occurrenceIndex = 0;

  for (let i = 0; i < maxIterations && cursor < startDate; i += 1) {
    considerOccurrence(cursor, occurrenceIndex);
    occurrenceIndex += 1;

    const next = addRepeaterInterval(cursor, repeater);
    if (next.getTime() <= cursor.getTime()) break;
    cursor = next;
  }

  const repeatUpperBound = warning && planningKind === "DEADLINE"
    ? addTimestampInterval(endDate, warning.value, warning.unit, 1)
    : new Date(endDate.getTime());

  for (let i = 0; i < maxIterations && cursor <= repeatUpperBound; i += 1) {
    considerOccurrence(cursor, occurrenceIndex);
    occurrenceIndex += 1;

    const next = addRepeaterInterval(cursor, repeater);
    if (next.getTime() <= cursor.getTime()) break;
    cursor = next;
  }

  if (wantsOverdue && latestBeforeStart) {
    addResolved(latestBeforeStart);
  }

  return resolved.sort();
}

// Get today's date as YYYY-MM-DD string
function getTodayString(): string {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function normalizeRoamLinkLabel(raw: string): string {
  return String(raw || "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function parseRoamAliasTokens(raw: string): string[] {
  const input = String(raw || "").trim();
  if (!input) return [];

  const out: string[] = [];
  const seen = new Set<string>();
  const pushAlias = (value: string): void => {
    const alias = String(value || "").trim();
    if (!alias) return;
    const key = alias.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    out.push(alias);
  };

  const quotedRe = /"([^"]+)"/g;
  let m: RegExpExecArray | null;
  while ((m = quotedRe.exec(input)) !== null) {
    pushAlias(m[1] || "");
  }

  const remainder = input.replace(quotedRe, " ").trim();
  if (remainder) {
    const commaSplit = remainder.split(/[;,]/).map((part) => part.trim()).filter(Boolean);
    if (commaSplit.length > 1) {
      for (const part of commaSplit) pushAlias(part);
    } else {
      pushAlias(remainder);
    }
  }

  return out;
}

function parseHeadlineTitleForRoam(line: string): string {
  const withoutStars = String(line || "").trim().replace(/^\*+\s+/, "");
  const withoutTags = withoutStars.replace(/\s+:[^\s:]+(?::[^\s:]+)*:\s*$/, "").trim();
  const withoutTodo = withoutTags.replace(/^(TODO|IN_PROGRESS|DONE|CANCELLED|CANCELED)\s+/, "").trim();
  return withoutTodo;
}

type RoamNodeForIndex = {
  id: string;
  labels: string[];
};

function collectRoamNodesForIndex(content: string, filePath: string): RoamNodeForIndex[] {
  const raw = content.replace(/\r\n/g, "\n");
  const lines = raw.split("\n");
  const nodes: RoamNodeForIndex[] = [];

  const fileTitle = (() => {
    for (let i = 0; i < Math.min(lines.length, 80); i += 1) {
      const m = /^#\+title:\s*(.*?)\s*$/i.exec((lines[i] ?? "").trim());
      if (m) return (m[1] || "").trim();
    }
    return path.basename(filePath).replace(/\.(org2|org)$/i, "");
  })();

  const fileAliases = (() => {
    const aliases: string[] = [];
    for (let i = 0; i < Math.min(lines.length, 80); i += 1) {
      const m = /^#\+roam_alias(?:es)?:\s*(.*?)\s*$/i.exec((lines[i] ?? "").trim());
      if (!m) continue;
      aliases.push(...parseRoamAliasTokens(m[1] || ""));
    }
    return aliases;
  })();

  const seenNodeIds = new Set<string>();
  const pushNode = (idRaw: string, labels: string[]) => {
    const id = String(idRaw || "").trim().toLowerCase();
    if (!id) return;
    if (seenNodeIds.has(id)) return;

    const uniqueLabels = Array.from(
      new Set(
        labels
          .map((value) => String(value || "").trim())
          .filter((value) => value.length > 0),
      ),
    );
    if (uniqueLabels.length === 0) return;

    seenNodeIds.add(id);
    nodes.push({ id, labels: uniqueLabels });
  };

  // File-level #+id
  for (let i = 0; i < Math.min(lines.length, 30); i += 1) {
    const m = /^#\+id:\s*(\S+)\s*$/i.exec((lines[i] ?? "").trim());
    if (!m) continue;
    pushNode(m[1] || "", [fileTitle, ...fileAliases]);
    break;
  }

  // File-level drawer ID + aliases (allow any drawer before first headline).
  {
    const firstHeadlineIdx = lines.findIndex((line) => /^\*+\s+/.test(String(line || "")));
    const scanEnd = firstHeadlineIdx === -1 ? lines.length : firstHeadlineIdx;

    let propsStart = -1;
    let propsEnd = -1;
    for (let i = 0; i < scanEnd; i += 1) {
      if ((lines[i] ?? "").trim() !== ":PROPERTIES:") continue;
      propsStart = i;
      for (let j = i + 1; j < scanEnd; j += 1) {
        if ((lines[j] ?? "").trim() === ":END:") {
          propsEnd = j;
          break;
        }
      }
      if (propsEnd !== -1) break;
      propsStart = -1;
    }

    if (propsStart !== -1 && propsEnd !== -1) {
      let topId = "";
      const topAliases: string[] = [];
      for (let j = propsStart + 1; j < propsEnd; j += 1) {
        const l = (lines[j] ?? "").trim();
        const idMatch = /^:ID:\s*(\S+)\s*$/i.exec(l);
        if (idMatch) topId = String(idMatch[1] || "").trim();
        const aliasMatch = /^:ROAM_ALIASES:\s*(.*?)\s*$/i.exec(l);
        if (aliasMatch) topAliases.push(...parseRoamAliasTokens(aliasMatch[1] || ""));
      }
      if (topId) pushNode(topId, [fileTitle, ...fileAliases, ...topAliases]);
    }
  }

  let currentHeadlineTitle = "";
  let currentHeadlineLine = -1;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";

    const hm = /^(\*+)\s+/.exec(line);
    if (hm) {
      currentHeadlineTitle = parseHeadlineTitleForRoam(line);
      currentHeadlineLine = i;
      continue;
    }

    if (line.trim() !== ":PROPERTIES:") continue;

    let belongsToHeadline = false;
    if (currentHeadlineLine !== -1) {
      const prev = (lines[i - 1] ?? "").trim();
      if (i - 1 === currentHeadlineLine || (prev === "" && i - 2 === currentHeadlineLine)) {
        belongsToHeadline = true;
      }
    }

    let headlineId = "";
    const headlineAliases: string[] = [];
    for (let j = i + 1; j < lines.length; j += 1) {
      const l = (lines[j] ?? "").trim();
      if (l === ":END:") {
        i = j;
        break;
      }

      const idMatch = /^:ID:\s*(\S+)\s*$/i.exec(l);
      if (idMatch) headlineId = String(idMatch[1] || "").trim();

      const aliasMatch = /^:ROAM_ALIASES:\s*(.*?)\s*$/i.exec(l);
      if (aliasMatch) headlineAliases.push(...parseRoamAliasTokens(aliasMatch[1] || ""));
    }

    if (belongsToHeadline && headlineId && currentHeadlineTitle) {
      pushNode(headlineId, [currentHeadlineTitle, ...headlineAliases]);
    }
  }

  return nodes;
}

function buildRoamTitleIndex(files: string[]): Map<string, Set<string>> {
  const index = new Map<string, Set<string>>();

  const add = (labelRaw: string, idRaw: string): void => {
    const label = normalizeRoamLinkLabel(labelRaw);
    const id = String(idRaw || "").trim().toLowerCase();
    if (!label || !id) return;

    const existing = index.get(label);
    if (existing) {
      existing.add(id);
      return;
    }
    index.set(label, new Set([id]));
  };

  for (const filePath of files) {
    let content: string;
    try {
      content = fs.readFileSync(filePath, "utf8");
    } catch {
      continue;
    }

    const nodes = collectRoamNodesForIndex(content, filePath);
    for (const node of nodes) {
      for (const label of node.labels) {
        add(label, node.id);
      }
    }
  }

  return index;
}

interface ScheduledItem {
  filePath: string;
  // 0-based (VS Code uses 0-based positions)
  lineNumber: number;
  headline: string;
  todo: string | undefined;
  priority: string | undefined;
  effort: string | undefined;
  id: string | undefined;
  level: number;
  date: string;
  time: string | undefined;
  kind: string;
  tags: string[];
}

type AgendaStatusBucket = "todo" | "in_progress" | "done" | "canceled" | "custom";
type AgendaPlanningKind = "SCHEDULED" | "DEADLINE";
type AgendaWhenBucket = "overdue" | "today" | "upcoming";

type AgendaStatusFilter = Set<AgendaStatusBucket> | null;
type AgendaExcludeStatusFilter = Set<AgendaStatusBucket> | null;
type AgendaPlanningFilter = Set<AgendaPlanningKind> | null;
type AgendaExcludePlanningFilter = Set<AgendaPlanningKind> | null;
type AgendaWhenFilter = Set<AgendaWhenBucket> | null;
type AgendaExcludeWhenFilter = Set<AgendaWhenBucket> | null;
type AgendaWeekdayFilter = Set<number> | null;
type AgendaExcludeWeekdayFilter = Set<number> | null;
type AgendaWeekFilter = Set<number> | null;
type AgendaExcludeWeekFilter = Set<number> | null;
type AgendaDayOfMonthFilter = Set<number> | null;
type AgendaExcludeDayOfMonthFilter = Set<number> | null;
type AgendaMonthFilter = Set<number> | null;
type AgendaExcludeMonthFilter = Set<number> | null;
type AgendaQuarterFilter = Set<number> | null;
type AgendaExcludeQuarterFilter = Set<number> | null;
type AgendaYearFilter = Set<number> | null;
type AgendaExcludeYearFilter = Set<number> | null;
type AgendaDateFilter = Set<string> | null;
type AgendaExcludeDateFilter = Set<string> | null;
type AgendaLevelFilter = Set<number> | null;
type AgendaExcludeLevelFilter = Set<number> | null;
type AgendaMatchFilter = string[] | null;
type AgendaExcludeMatchFilter = string[] | null;
type AgendaTagFilter = string[] | null;
type AgendaIdFilter = Set<string> | null;
type AgendaTodoFilter = Set<string> | null;
type AgendaPriorityFilter = Set<string> | null;
type AgendaTimeRange = {
  startMinutes: number;
  endMinutes: number;
  wraps: boolean;
};
type AgendaTimeFilter = { tokens: Set<string>; ranges: AgendaTimeRange[] } | null;
type AgendaEffortFilter = Set<string> | null;
type AgendaPropertyFilterTerm = { key: string; value: string };
type AgendaPropertyFilter = AgendaPropertyFilterTerm[] | null;
type AgendaExcludeTagFilter = string[] | null;
type AgendaExcludeTodoFilter = Set<string> | null;
type AgendaExcludePriorityFilter = Set<string> | null;
type AgendaExcludeTimeFilter = AgendaTimeFilter;
type AgendaExcludeEffortFilter = Set<string> | null;
type AgendaExcludePropertyFilter = AgendaPropertyFilterTerm[] | null;
type AgendaExcludeIdFilter = AgendaIdFilter;
type AgendaFileFilter = string[] | null;
type AgendaExcludeFileFilter = string[] | null;
type AgendaTodoOrder = Map<string, number> | null;
type AgendaStatusOrder = Map<AgendaStatusBucket, number> | null;
type AgendaKindOrder = Map<AgendaPlanningKind, number> | null;
type AgendaPriorityOrder = Map<string, number> | null;
type AgendaTagOrder = Map<string, number> | null;
type AgendaEffortOrder = Map<string, number> | null;
type AgendaSortKey =
  | "file"
  | "headline"
  | "todo"
  | "status"
  | "priority"
  | "effort"
  | "id"
  | "level"
  | "time"
  | "kind"
  | "tags"
  | "line";
type AgendaSortDirection = "asc" | "desc";
type AgendaSortField = { key: AgendaSortKey; direction: AgendaSortDirection };
type AgendaSortOrder = AgendaSortField[] | null;
type AgendaGroupField = { key: AgendaSortKey; direction: AgendaSortDirection };
type AgendaGroupOrder = AgendaGroupField[] | null;
type AgendaDateOrder = "asc" | "desc";

const AGENDA_STATUS_ALLOWED_HINT =
  "all, active, actionable, open, todo, in_progress, done, canceled, closed, custom";
const AGENDA_STATUS_ORDER_ALLOWED_HINT =
  "default, todo|open|backlog, in_progress|in-progress|prog|doing|started|waiting|blocked|next|wip, done|complete|completed|finish|finished|resolved, canceled|cancel|cancelled|closed, custom";
const AGENDA_KIND_ORDER_ALLOWED_HINT = "default, scheduled, deadline";
const AGENDA_PRIORITY_ORDER_ALLOWED_HINT = "default, A-Z or 0-9 (for example: A,[#B],9)";
const AGENDA_EFFORT_ORDER_EMPTY = "__none__";
const AGENDA_KIND_ALLOWED_HINT = "all, scheduled, deadline";
const AGENDA_WHEN_ALLOWED_HINT = "all, overdue, today, upcoming";
const AGENDA_WEEKDAY_ALLOWED_HINT =
  "all, mon|monday, tue|tuesday, wed|wednesday, thu|thursday, fri|friday, sat|saturday, sun|sunday, weekday, weekend";
const AGENDA_WEEK_ALLOWED_HINT = "all, 1-53 or w1..w53 (for example: 1,w2,week10,53)";
const AGENDA_DAY_OF_MONTH_ALLOWED_HINT = "all, 1-31 (for example: 1,15,31)";
const AGENDA_MONTH_ALLOWED_HINT =
  "all, 1-12 or jan|january...dec|december (for example: 1,jan,mar,12)";
const AGENDA_QUARTER_ALLOWED_HINT = "all, 1-4 or q1..q4 (for example: 1,q2,quarter3,4)";
const AGENDA_YEAR_ALLOWED_HINT = "all, positive year numbers (for example: 2025,2026,2027)";
const AGENDA_DATE_ALLOWED_HINT = "all, YYYY-MM-DD (for example: 2026-02-17,2026-02-20)";
const AGENDA_LEVEL_ALLOWED_HINT = "positive integers (for example: 1,2,3)";
const AGENDA_ID_ALLOWED_HINT = "all, exact ID/CUSTOM_ID terms (for example: 9f8a7b6c,project-roadmap)";
const AGENDA_PRIORITY_ALLOWED_HINT = "A-Z or 0-9 (for example: A,B,C or [#A],[#B])";
const AGENDA_TIME_ALLOWED_HINT =
  "all, timed, untimed, HH:MM, HH:MM-HH:MM (for example: 09:30,17:45,09:00-12:30,22:00-02:00)";
const AGENDA_PROPERTY_ALLOWED_HINT = "KEY=VALUE (for example: OWNER=Avi,TEAM=Platform)";
const AGENDA_SORT_ALLOWED_HINT = "default, [+-]file, [+-]headline, [+-]todo, [+-]status, [+-]priority, [+-]effort, [+-]id, [+-]level, [+-]time, [+-]kind, [+-]tags, [+-]line";
const AGENDA_GROUP_ALLOWED_HINT = AGENDA_SORT_ALLOWED_HINT;
const AGENDA_DATE_ORDER_ALLOWED_HINT = "asc, desc";

function agendaStatusBucketForKeyword(todo: string | undefined): AgendaStatusBucket | null {
  const key = String(todo || "").trim().toUpperCase();
  if (!key) return null;

  if (key === "DONE" || key === "COMPLETED") return "done";
  if (key === "CANCELED" || key === "CANCELLED") return "canceled";
  if (["PROG", "IN_PROGRESS", "DOING", "STARTED", "WAITING", "BLOCKED", "NEXT", "WIP"].includes(key)) {
    return "in_progress";
  }
  if (["TODO", "OPEN", "BACKLOG"].includes(key)) return "todo";

  return "custom";
}

function normalizeAgendaStatusFilterToken(tokenRaw: string): string {
  return tokenRaw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

function parseTodoStatusArg(rawStatus: string): TodoStatus | "" {
  const token = normalizeAgendaStatusFilterToken(rawStatus);
  if (!token) return "";

  if (token === "todo" || token === "open") return "todo";
  if (token === "in_progress" || token === "inprogress" || token === "prog" || token === "doing" || token === "started" || token === "waiting" || token === "blocked" || token === "next" || token === "wip") return "in_progress";
  if (token === "done" || token === "complete" || token === "completed" || token === "finish" || token === "finished" || token === "closed" || token === "resolved") return "done";
  if (token === "canceled" || token === "cancelled" || token === "cancel") return "canceled";

  return "";
}

function parseAgendaStatusFilterArgs(rawArgs: string[]): {
  filter: AgendaStatusFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<AgendaStatusBucket>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = normalizeAgendaStatusFilterToken(tokenRaw);
    if (!token) return;

    if (token === "all") {
      sawAll = true;
      return;
    }

    if (token === "active") {
      selected.add("todo");
      selected.add("in_progress");
      return;
    }

    if (token === "actionable") {
      selected.add("todo");
      selected.add("in_progress");
      selected.add("custom");
      return;
    }

    if (token === "open" || token === "todo" || token === "backlog") {
      selected.add("todo");
      return;
    }

    if (
      token === "in_progress" ||
      token === "inprogress" ||
      token === "prog" ||
      token === "doing" ||
      token === "started" ||
      token === "waiting" ||
      token === "blocked" ||
      token === "next" ||
      token === "wip"
    ) {
      selected.add("in_progress");
      return;
    }

    if (
      token === "done" ||
      token === "complete" ||
      token === "completed" ||
      token === "finish" ||
      token === "finished" ||
      token === "resolved"
    ) {
      selected.add("done");
      return;
    }

    if (token === "canceled" || token === "cancelled" || token === "cancel") {
      selected.add("canceled");
      return;
    }

    if (token === "closed") {
      selected.add("done");
      selected.add("canceled");
      return;
    }

    if (token === "custom") {
      selected.add("custom");
      return;
    }

    invalid.push(tokenRaw.trim());
  };

  for (const raw of rawArgs) {
    for (const token of String(raw).split(",")) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeStatusFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeStatusFilter;
  invalid: string[];
} {
  return parseAgendaStatusFilterArgs(rawArgs);
}

function parseAgendaKindFilterArgs(rawArgs: string[]): {
  filter: AgendaPlanningFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<AgendaPlanningKind>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = tokenRaw.trim().toLowerCase();
    if (!token) return;

    if (token === "all") {
      sawAll = true;
      return;
    }

    if (token === "scheduled") {
      selected.add("SCHEDULED");
      return;
    }

    if (token === "deadline") {
      selected.add("DEADLINE");
      return;
    }

    invalid.push(tokenRaw.trim());
  };

  for (const raw of rawArgs) {
    for (const token of String(raw).split(",")) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeKindFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludePlanningFilter;
  invalid: string[];
} {
  return parseAgendaKindFilterArgs(rawArgs);
}

function parseAgendaWhenFilterArgs(rawArgs: string[]): {
  filter: AgendaWhenFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<AgendaWhenBucket>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = tokenRaw.trim().toLowerCase();
    if (!token) return;

    if (token === "all") {
      sawAll = true;
      return;
    }

    if (token === "overdue" || token === "today" || token === "upcoming") {
      selected.add(token as AgendaWhenBucket);
      return;
    }

    invalid.push(tokenRaw.trim());
  };

  for (const raw of rawArgs) {
    for (const token of String(raw).split(",")) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeWhenFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeWhenFilter;
  invalid: string[];
} {
  return parseAgendaWhenFilterArgs(rawArgs);
}

const AGENDA_WEEKDAY_TOKEN_MAP: Record<string, number[]> = {
  sunday: [0],
  sun: [0],
  monday: [1],
  mon: [1],
  tuesday: [2],
  tue: [2],
  tues: [2],
  wednesday: [3],
  wed: [3],
  thursday: [4],
  thu: [4],
  thur: [4],
  thurs: [4],
  friday: [5],
  fri: [5],
  saturday: [6],
  sat: [6],
  weekday: [1, 2, 3, 4, 5],
  weekdays: [1, 2, 3, 4, 5],
  weekend: [0, 6],
  weekends: [0, 6],
};

function parseAgendaWeekdayFilterArgs(rawArgs: string[]): {
  filter: AgendaWeekdayFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = tokenRaw.trim().toLowerCase();
    if (!token) return;

    if (token === "all") {
      sawAll = true;
      return;
    }

    const dayIndexes = AGENDA_WEEKDAY_TOKEN_MAP[token];
    if (!dayIndexes) {
      invalid.push(tokenRaw.trim());
      return;
    }

    for (const dayIndex of dayIndexes) {
      selected.add(dayIndex);
    }
  };

  for (const raw of rawArgs) {
    for (const token of String(raw).split(",")) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeWeekdayFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeWeekdayFilter;
  invalid: string[];
} {
  return parseAgendaWeekdayFilterArgs(rawArgs);
}

function parseAgendaWeekFilterArgs(rawArgs: string[]): {
  filter: AgendaWeekFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "all") {
        sawAll = true;
        continue;
      }

      const weekMatch = /^(?:w|week)?(\d{1,2})$/.exec(token);
      if (!weekMatch) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      const week = Number.parseInt(weekMatch[1] ?? "", 10);
      if (!Number.isFinite(week) || week < 1 || week > 53) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      selected.add(week);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeWeekFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeWeekFilter;
  invalid: string[];
} {
  return parseAgendaWeekFilterArgs(rawArgs);
}

function parseAgendaDayOfMonthFilterArgs(rawArgs: string[]): {
  filter: AgendaDayOfMonthFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "all") {
        sawAll = true;
        continue;
      }

      if (!/^\d+$/.test(token)) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      const day = Number.parseInt(token, 10);
      if (!Number.isFinite(day) || day < 1 || day > 31) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      selected.add(day);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeDayOfMonthFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeDayOfMonthFilter;
  invalid: string[];
} {
  return parseAgendaDayOfMonthFilterArgs(rawArgs);
}

const AGENDA_MONTH_TOKEN_MAP: Record<string, number> = {
  jan: 1,
  january: 1,
  feb: 2,
  february: 2,
  mar: 3,
  march: 3,
  apr: 4,
  april: 4,
  may: 5,
  jun: 6,
  june: 6,
  jul: 7,
  july: 7,
  aug: 8,
  august: 8,
  sep: 9,
  sept: 9,
  september: 9,
  oct: 10,
  october: 10,
  nov: 11,
  november: 11,
  dec: 12,
  december: 12,
};

function parseAgendaMonthFilterArgs(rawArgs: string[]): {
  filter: AgendaMonthFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "all") {
        sawAll = true;
        continue;
      }

      if (/^\d+$/.test(token)) {
        const month = Number.parseInt(token, 10);
        if (!Number.isFinite(month) || month < 1 || month > 12) {
          invalid.push(tokenRaw.trim());
          continue;
        }
        selected.add(month);
        continue;
      }

      const month = AGENDA_MONTH_TOKEN_MAP[token];
      if (!month) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      selected.add(month);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeMonthFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeMonthFilter;
  invalid: string[];
} {
  return parseAgendaMonthFilterArgs(rawArgs);
}

function parseAgendaQuarterFilterArgs(rawArgs: string[]): {
  filter: AgendaQuarterFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "all") {
        sawAll = true;
        continue;
      }

      const quarterMatch = /^(?:q|quarter)?([1-4])$/.exec(token);
      if (!quarterMatch) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      const quarter = Number.parseInt(quarterMatch[1] ?? "", 10);
      if (!Number.isFinite(quarter) || quarter < 1 || quarter > 4) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      selected.add(quarter);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeQuarterFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeQuarterFilter;
  invalid: string[];
} {
  return parseAgendaQuarterFilterArgs(rawArgs);
}

function parseAgendaYearFilterArgs(rawArgs: string[]): {
  filter: AgendaYearFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "all") {
        sawAll = true;
        continue;
      }

      if (!/^\d+$/.test(token)) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      const year = Number.parseInt(token, 10);
      if (!Number.isFinite(year) || year < 1) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      selected.add(year);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeYearFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeYearFilter;
  invalid: string[];
} {
  return parseAgendaYearFilterArgs(rawArgs);
}

function parseAgendaDateFilterArgs(rawArgs: string[]): {
  filter: AgendaDateFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<string>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;

      if (token.toLowerCase() === "all") {
        sawAll = true;
        continue;
      }

      if (!/^\d{4}-\d{2}-\d{2}$/.test(token)) {
        invalid.push(token);
        continue;
      }

      try {
        const normalized = parseIsoDate(token).toISOString().slice(0, 10);
        selected.add(normalized);
      } catch {
        invalid.push(token);
      }
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeDateFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeDateFilter;
  invalid: string[];
} {
  return parseAgendaDateFilterArgs(rawArgs);
}

function parseAgendaLevelFilterArgs(rawArgs: string[]): {
  filter: AgendaLevelFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;
      if (!/^\d+$/.test(token)) {
        invalid.push(token);
        continue;
      }

      const level = Number.parseInt(token, 10);
      if (!Number.isFinite(level) || level < 1) {
        invalid.push(token);
        continue;
      }

      selected.add(level);
    }
  }

  return { filter: selected.size > 0 ? selected : null, invalid };
}

function parseAgendaExcludeLevelFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeLevelFilter;
  invalid: string[];
} {
  return parseAgendaLevelFilterArgs(rawArgs);
}

function parseAgendaMatchFilterArgs(rawArgs: string[]): AgendaMatchFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaExcludeMatchFilterArgs(rawArgs: string[]): AgendaExcludeMatchFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaTagFilterArgs(rawArgs: string[]): AgendaTagFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaIdFilterArgs(rawArgs: string[]): {
  filter: AgendaIdFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<string>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = tokenRaw.trim().toLowerCase();
    if (!token) return;

    if (token === "all") {
      sawAll = true;
      return;
    }

    selected.add(token);
  };

  for (const raw of rawArgs) {
    for (const token of String(raw).split(",")) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeIdFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeIdFilter;
  invalid: string[];
} {
  return parseAgendaIdFilterArgs(rawArgs);
}

function parseAgendaTodoFilterArgs(rawArgs: string[]): AgendaTodoFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toUpperCase())
    .filter(Boolean);

  return tokens.length > 0 ? new Set(tokens) : null;
}

function normalizeAgendaPriorityToken(tokenRaw: string): string | null {
  let token = tokenRaw.trim();
  if (!token) return null;

  const bracketed = token.match(/^\[#([A-Za-z0-9])\]$/);
  if (bracketed) {
    token = bracketed[1] ?? "";
  }

  if (token.length !== 1 || !/^[A-Za-z0-9]$/.test(token)) return null;
  return token.toUpperCase();
}

function parseAgendaEffortToMinutes(tokenRaw: string): number | null {
  const token = String(tokenRaw || "").trim().toLowerCase().replace(/\s+/g, "");
  if (!token) return null;

  const parseIntStrict = (raw: string): number | null => {
    if (!/^\d+$/.test(raw)) return null;
    const parsed = Number.parseInt(raw, 10);
    return Number.isFinite(parsed) ? parsed : null;
  };

  const hm = token.match(/^(\d+):(\d{1,2})$/);
  if (hm) {
    const hours = parseIntStrict(hm[1] ?? "");
    const minutes = parseIntStrict(hm[2] ?? "");
    if (hours === null || minutes === null || minutes >= 60) return null;
    return hours * 60 + minutes;
  }

  const hoursOnly = token.match(/^(\d+)h$/);
  if (hoursOnly) {
    const hours = parseIntStrict(hoursOnly[1] ?? "");
    return hours === null ? null : hours * 60;
  }

  const minutesOnly = token.match(/^(\d+)m$/);
  if (minutesOnly) {
    return parseIntStrict(minutesOnly[1] ?? "");
  }

  const hmCompact = token.match(/^(\d+)h(\d+)m$/);
  if (hmCompact) {
    const hours = parseIntStrict(hmCompact[1] ?? "");
    const minutes = parseIntStrict(hmCompact[2] ?? "");
    if (hours === null || minutes === null) return null;
    return hours * 60 + minutes;
  }

  return parseIntStrict(token);
}

function normalizeAgendaEffortToken(tokenRaw: string): string {
  const token = String(tokenRaw || "").trim();
  if (!token) return "";

  const minutes = parseAgendaEffortToMinutes(token);
  if (minutes !== null) {
    return `m:${minutes}`;
  }

  return token.toLowerCase().replace(/\s+/g, " ");
}

function parseAgendaPriorityFilterArgs(rawArgs: string[]): {
  filter: AgendaPriorityFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<string>();
  const invalid: string[] = [];

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;

      const normalized = normalizeAgendaPriorityToken(token);
      if (!normalized) {
        invalid.push(token);
        continue;
      }

      selected.add(normalized);
    }
  }

  return { filter: selected.size > 0 ? selected : null, invalid };
}

function parseAgendaExcludePriorityFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludePriorityFilter;
  invalid: string[];
} {
  return parseAgendaPriorityFilterArgs(rawArgs);
}

const AGENDA_TIME_FILTER_TIMED = "__timed__";
const AGENDA_TIME_FILTER_UNTIMED = "__untimed__";

function parseAgendaTimeRangeToken(raw: string): AgendaTimeRange | null {
  const match = String(raw || "").match(/^(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})$/);
  if (!match) return null;

  const startToken = normalizeAgendaTimeToken(match[1] || "");
  const endToken = normalizeAgendaTimeToken(match[2] || "");
  if (!startToken || !endToken) return null;

  const startMinutes = parseAgendaTimeToMinutes(startToken);
  const endMinutes = parseAgendaTimeToMinutes(endToken);
  if (startMinutes === null || endMinutes === null) return null;

  return {
    startMinutes,
    endMinutes,
    wraps: startMinutes > endMinutes,
  };
}

function parseAgendaTimeFilterArgs(rawArgs: string[]): {
  filter: AgendaTimeFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<string>();
  const ranges: AgendaTimeRange[] = [];
  const seenRanges = new Set<string>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = tokenRaw.trim().toLowerCase();
    if (!token) return;

    if (token === "all") {
      sawAll = true;
      return;
    }

    if (token === "timed" || token === "time") {
      selected.add(AGENDA_TIME_FILTER_TIMED);
      return;
    }

    if (token === "untimed" || token === "no-time" || token === "none") {
      selected.add(AGENDA_TIME_FILTER_UNTIMED);
      return;
    }

    if (token.includes("-")) {
      const parsedRange = parseAgendaTimeRangeToken(token);
      if (!parsedRange) {
        invalid.push(tokenRaw.trim());
        return;
      }

      const rangeKey = `${parsedRange.startMinutes}-${parsedRange.endMinutes}`;
      if (!seenRanges.has(rangeKey)) {
        seenRanges.add(rangeKey);
        ranges.push(parsedRange);
      }
      return;
    }

    const normalized = normalizeAgendaTimeToken(token);
    if (!normalized) {
      invalid.push(tokenRaw.trim());
      return;
    }

    selected.add(normalized);
  };

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      addToken(tokenRaw);
    }
  }

  const builtFilter: AgendaTimeFilter =
    selected.size > 0 || ranges.length > 0
      ? {
          tokens: selected,
          ranges,
        }
      : null;

  if (invalid.length > 0) {
    return { filter: builtFilter, invalid };
  }

  if (sawAll || !builtFilter) {
    return { filter: null, invalid: [] };
  }

  return { filter: builtFilter, invalid: [] };
}

function parseAgendaExcludeTimeFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeTimeFilter;
  invalid: string[];
} {
  return parseAgendaTimeFilterArgs(rawArgs);
}

function parseAgendaEffortFilterArgs(rawArgs: string[]): AgendaEffortFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => normalizeAgendaEffortToken(token))
    .filter(Boolean);

  return tokens.length > 0 ? new Set(tokens) : null;
}

function parseAgendaExcludeEffortFilterArgs(rawArgs: string[]): AgendaExcludeEffortFilter {
  return parseAgendaEffortFilterArgs(rawArgs);
}

function normalizeAgendaPropertyKey(raw: string): string {
  return String(raw || "")
    .trim()
    .replace(/^:+|:+$/g, "")
    .toUpperCase();
}

function normalizeAgendaPropertyValue(raw: string): string {
  return String(raw || "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ");
}

function parseAgendaPropertyFilterArgs(rawArgs: string[]): {
  filter: AgendaPropertyFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const filters: AgendaPropertyFilterTerm[] = [];
  const invalid: string[] = [];
  const seen = new Set<string>();

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;

      const splitAt = token.indexOf("=");
      if (splitAt <= 0 || splitAt === token.length - 1) {
        invalid.push(token);
        continue;
      }

      const key = normalizeAgendaPropertyKey(token.slice(0, splitAt));
      const value = normalizeAgendaPropertyValue(token.slice(splitAt + 1));
      if (!key || !value) {
        invalid.push(token);
        continue;
      }

      const dedupeKey = `${key}=${value}`;
      if (seen.has(dedupeKey)) continue;
      seen.add(dedupeKey);
      filters.push({ key, value });
    }
  }

  return { filter: filters.length > 0 ? filters : null, invalid };
}

function parseAgendaExcludePropertyFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludePropertyFilter;
  invalid: string[];
} {
  return parseAgendaPropertyFilterArgs(rawArgs);
}

function parseAgendaExcludeTagFilterArgs(rawArgs: string[]): AgendaExcludeTagFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaExcludeTodoFilterArgs(rawArgs: string[]): AgendaExcludeTodoFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toUpperCase())
    .filter(Boolean);

  return tokens.length > 0 ? new Set(tokens) : null;
}

function parseAgendaTodoOrderArgs(rawArgs: string[]): AgendaTodoOrder {
  if (rawArgs.length === 0) return null;

  const ordered: string[] = [];
  const seen = new Set<string>();

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;

      const normalized = token.toUpperCase();
      if (normalized === "DEFAULT") continue;
      if (seen.has(normalized)) continue;

      seen.add(normalized);
      ordered.push(normalized);
    }
  }

  if (ordered.length === 0) return null;

  const rank = new Map<string, number>();
  for (let i = 0; i < ordered.length; i += 1) {
    rank.set(ordered[i]!, i);
  }

  return rank;
}

function parseAgendaStatusOrderArgs(rawArgs: string[]): {
  statusOrder: AgendaStatusOrder;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { statusOrder: null, invalid: [] };

  const rank = new Map<AgendaStatusBucket, number>();
  const invalid: string[] = [];
  let nextRank = 0;

  const normalizeToken = (tokenRaw: string): AgendaStatusBucket | null => {
    const token = normalizeAgendaStatusFilterToken(tokenRaw);
    if (token === "todo" || token === "open" || token === "backlog") return "todo";
    if (
      token === "in_progress" ||
      token === "inprogress" ||
      token === "prog" ||
      token === "doing" ||
      token === "started" ||
      token === "waiting" ||
      token === "blocked" ||
      token === "next" ||
      token === "wip"
    ) {
      return "in_progress";
    }
    if (
      token === "done" ||
      token === "complete" ||
      token === "completed" ||
      token === "finish" ||
      token === "finished" ||
      token === "resolved"
    ) {
      return "done";
    }
    if (token === "canceled" || token === "cancelled" || token === "cancel" || token === "closed") return "canceled";
    if (token === "custom") return "custom";
    return null;
  };

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = normalizeAgendaStatusFilterToken(tokenRaw);
      if (!token) continue;
      if (token === "default") continue;

      const normalized = normalizeToken(tokenRaw);
      if (!normalized) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      if (!rank.has(normalized)) {
        rank.set(normalized, nextRank);
        nextRank += 1;
      }
    }
  }

  if (invalid.length > 0) {
    return { statusOrder: rank.size > 0 ? rank : null, invalid };
  }

  return { statusOrder: rank.size > 0 ? rank : null, invalid: [] };
}

function parseAgendaKindOrderArgs(rawArgs: string[]): {
  kindOrder: AgendaKindOrder;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { kindOrder: null, invalid: [] };

  const rank = new Map<AgendaPlanningKind, number>();
  const invalid: string[] = [];
  let nextRank = 0;

  const normalizeToken = (token: string): AgendaPlanningKind | null => {
    if (token === "scheduled") return "SCHEDULED";
    if (token === "deadline") return "DEADLINE";
    return null;
  };

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;
      if (token === "default") continue;

      const normalized = normalizeToken(token);
      if (!normalized) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      if (!rank.has(normalized)) {
        rank.set(normalized, nextRank);
        nextRank += 1;
      }
    }
  }

  if (invalid.length > 0) {
    return { kindOrder: rank.size > 0 ? rank : null, invalid };
  }

  return { kindOrder: rank.size > 0 ? rank : null, invalid: [] };
}

function parseAgendaPriorityOrderArgs(rawArgs: string[]): {
  priorityOrder: AgendaPriorityOrder;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { priorityOrder: null, invalid: [] };

  const rank = new Map<string, number>();
  const invalid: string[] = [];
  let nextRank = 0;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;
      if (token.toLowerCase() === "default") continue;

      const normalized = normalizeAgendaPriorityToken(token);
      if (!normalized) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      if (!rank.has(normalized)) {
        rank.set(normalized, nextRank);
        nextRank += 1;
      }
    }
  }

  if (invalid.length > 0) {
    return { priorityOrder: rank.size > 0 ? rank : null, invalid };
  }

  return { priorityOrder: rank.size > 0 ? rank : null, invalid: [] };
}

function parseAgendaTagOrderArgs(rawArgs: string[]): AgendaTagOrder {
  if (rawArgs.length === 0) return null;

  const rank = new Map<string, number>();
  let nextRank = 0;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;
      if (token === "default") continue;

      if (!rank.has(token)) {
        rank.set(token, nextRank);
        nextRank += 1;
      }
    }
  }

  return rank.size > 0 ? rank : null;
}

function parseAgendaEffortOrderArgs(rawArgs: string[]): AgendaEffortOrder {
  if (rawArgs.length === 0) return null;

  const rank = new Map<string, number>();
  let nextRank = 0;

  const normalizeToken = (tokenRaw: string): string | null => {
    const token = tokenRaw.trim();
    if (!token) return null;

    const lowered = token.toLowerCase();
    if (lowered === "default") return null;
    if (lowered === "none" || lowered === "empty" || lowered === "unset" || lowered === "no-effort") {
      return AGENDA_EFFORT_ORDER_EMPTY;
    }

    return normalizeAgendaEffortToken(token);
  };

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const normalized = normalizeToken(tokenRaw);
      if (!normalized) continue;

      if (!rank.has(normalized)) {
        rank.set(normalized, nextRank);
        nextRank += 1;
      }
    }
  }

  return rank.size > 0 ? rank : null;
}

function parseAgendaFileFilterArgs(rawArgs: string[]): AgendaFileFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaExcludeFileFilterArgs(rawArgs: string[]): AgendaExcludeFileFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaSortArgs(rawArgs: string[]): {
  sortOrder: AgendaSortOrder;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { sortOrder: null, invalid: [] };

  const sortOrder: AgendaSortField[] = [];
  const seen = new Set<AgendaSortKey>();
  const invalid: string[] = [];

  const addToken = (tokenRaw: string): void => {
    const original = tokenRaw.trim();
    let token = original.toLowerCase();
    if (!token) return;

    if (token === "default") {
      return;
    }

    let direction: AgendaSortDirection = "asc";
    if (token.startsWith("+")) {
      token = token.slice(1);
    } else if (token.startsWith("-")) {
      direction = "desc";
      token = token.slice(1);
    }

    if (token.endsWith(":asc")) {
      direction = "asc";
      token = token.slice(0, -":asc".length);
    } else if (token.endsWith(":desc")) {
      direction = "desc";
      token = token.slice(0, -":desc".length);
    }

    let normalized: AgendaSortKey | null = null;
    if (token === "file" || token === "path") normalized = "file";
    else if (token === "headline" || token === "title") normalized = "headline";
    else if (token === "todo" || token === "keyword") normalized = "todo";
    else if (token === "status" || token === "state" || token === "bucket") normalized = "status";
    else if (token === "priority" || token === "prio") normalized = "priority";
    else if (token === "effort" || token === "estimate") normalized = "effort";
    else if (token === "id" || token === "custom-id" || token === "custom_id" || token === "node") normalized = "id";
    else if (token === "level" || token === "depth") normalized = "level";
    else if (token === "time" || token === "clock") normalized = "time";
    else if (token === "kind" || token === "planning") normalized = "kind";
    else if (token === "tags" || token === "tag" || token === "labels") normalized = "tags";
    else if (token === "line" || token === "position") normalized = "line";

    if (!normalized) {
      invalid.push(original);
      return;
    }

    if (!seen.has(normalized)) {
      seen.add(normalized);
      sortOrder.push({ key: normalized, direction });
    }
  };

  for (const raw of rawArgs) {
    for (const token of String(raw).split(",")) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { sortOrder: sortOrder.length > 0 ? sortOrder : null, invalid };
  }

  if (sortOrder.length === 0) {
    return { sortOrder: null, invalid: [] };
  }

  return { sortOrder, invalid: [] };
}

function parseAgendaGroupArgs(rawArgs: string[]): {
  groupOrder: AgendaGroupOrder;
  invalid: string[];
} {
  const parsed = parseAgendaSortArgs(rawArgs);
  return {
    groupOrder: parsed.sortOrder,
    invalid: parsed.invalid,
  };
}

function parseAgendaDateOrderArgs(rawArgs: string[]): {
  dateOrder: AgendaDateOrder;
  invalid: string[];
} {
  if (rawArgs.length === 0) {
    return { dateOrder: "asc", invalid: [] };
  }

  const invalid: string[] = [];
  let dateOrder: AgendaDateOrder = "asc";

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "asc" || token === "ascending" || token === "oldest") {
        dateOrder = "asc";
        continue;
      }

      if (token === "desc" || token === "descending" || token === "newest") {
        dateOrder = "desc";
        continue;
      }

      invalid.push(tokenRaw.trim());
    }
  }

  return { dateOrder, invalid };
}

function matchesAgendaTextFilter(headline: string, textFilter: AgendaMatchFilter): boolean {
  if (!textFilter || textFilter.length === 0) return true;

  const haystack = String(headline || "").trim().toLowerCase();
  return textFilter.some((token) => haystack.includes(token));
}

function matchesAgendaExcludeTextFilter(headline: string, excludeTextFilter: AgendaExcludeMatchFilter): boolean {
  if (!excludeTextFilter || excludeTextFilter.length === 0) return true;

  const haystack = String(headline || "").trim().toLowerCase();
  return !excludeTextFilter.some((token) => haystack.includes(token));
}

function matchesAgendaTagFilter(tags: string[], tagFilter: AgendaTagFilter): boolean {
  if (!tagFilter || tagFilter.length === 0) return true;

  const normalizedTags = tags.map((tag) => String(tag).trim().toLowerCase()).filter(Boolean);
  return tagFilter.some((token) => normalizedTags.includes(token));
}

function agendaIdsFromProperties(properties: Record<string, string>): string[] {
  const candidates = [properties.ID, properties.CUSTOM_ID]
    .map((value) => String(value || "").trim().toLowerCase())
    .filter(Boolean);
  return [...new Set(candidates)];
}

function agendaPrimaryIdFromProperties(properties: Record<string, string>): string | undefined {
  const directId = String(properties.ID || "").trim();
  if (directId) return directId;

  const customId = String(properties.CUSTOM_ID || "").trim();
  if (customId) return customId;

  return undefined;
}

function normalizeAgendaItemId(item: ScheduledItem): string {
  return String(item.id || "").trim().toLowerCase();
}

function matchesAgendaIdFilter(properties: Record<string, string>, idFilter: AgendaIdFilter): boolean {
  if (!idFilter || idFilter.size === 0) return true;
  const ids = agendaIdsFromProperties(properties);
  if (ids.length === 0) return false;
  return ids.some((id) => idFilter.has(id));
}

function matchesAgendaExcludeIdFilter(properties: Record<string, string>, excludeIdFilter: AgendaExcludeIdFilter): boolean {
  if (!excludeIdFilter || excludeIdFilter.size === 0) return true;
  const ids = agendaIdsFromProperties(properties);
  if (ids.length === 0) return true;
  return !ids.some((id) => excludeIdFilter.has(id));
}

function matchesAgendaTodoFilter(todo: string | undefined, todoFilter: AgendaTodoFilter): boolean {
  if (!todoFilter || todoFilter.size === 0) return true;
  const normalized = String(todo || "").trim().toUpperCase();
  if (!normalized) return false;
  return todoFilter.has(normalized);
}

function matchesAgendaPriorityFilter(priority: string | undefined, priorityFilter: AgendaPriorityFilter): boolean {
  if (!priorityFilter || priorityFilter.size === 0) return true;
  const normalized = normalizeAgendaPriorityToken(String(priority || ""));
  if (!normalized) return false;
  return priorityFilter.has(normalized);
}

function matchesAgendaTimeFilterTokenSet(
  time: string | undefined,
  timeFilter: Exclude<AgendaTimeFilter, null>,
): boolean {
  const normalized = normalizeAgendaTimeToken(String(time || ""));
  const hasTime = Boolean(normalized);

  if (hasTime && timeFilter.tokens.has(AGENDA_TIME_FILTER_TIMED)) return true;
  if (!hasTime && timeFilter.tokens.has(AGENDA_TIME_FILTER_UNTIMED)) return true;
  if (normalized && timeFilter.tokens.has(normalized)) return true;

  if (normalized) {
    const minutes = parseAgendaTimeToMinutes(normalized);
    if (minutes !== null) {
      for (const range of timeFilter.ranges) {
        if (!range.wraps && minutes >= range.startMinutes && minutes <= range.endMinutes) {
          return true;
        }
        if (range.wraps && (minutes >= range.startMinutes || minutes <= range.endMinutes)) {
          return true;
        }
      }
    }
  }

  return false;
}

function matchesAgendaTimeFilter(time: string | undefined, timeFilter: AgendaTimeFilter): boolean {
  if (!timeFilter || (timeFilter.tokens.size === 0 && timeFilter.ranges.length === 0)) return true;
  return matchesAgendaTimeFilterTokenSet(time, timeFilter);
}

function matchesAgendaExcludeTimeFilter(time: string | undefined, excludeTimeFilter: AgendaExcludeTimeFilter): boolean {
  if (!excludeTimeFilter || (excludeTimeFilter.tokens.size === 0 && excludeTimeFilter.ranges.length === 0)) {
    return true;
  }
  return !matchesAgendaTimeFilterTokenSet(time, excludeTimeFilter);
}

function matchesAgendaExcludeStatusFilter(
  todo: string | undefined,
  excludeStatusFilter: AgendaExcludeStatusFilter,
): boolean {
  if (!excludeStatusFilter || excludeStatusFilter.size === 0) return true;
  const bucket = agendaStatusBucketForKeyword(todo);
  if (!bucket) return true;
  return !excludeStatusFilter.has(bucket);
}

function matchesAgendaExcludeKindFilter(
  kind: AgendaPlanningKind,
  excludeKindFilter: AgendaExcludePlanningFilter,
): boolean {
  if (!excludeKindFilter || excludeKindFilter.size === 0) return true;
  return !excludeKindFilter.has(kind);
}

function matchesAgendaExcludeTagFilter(tags: string[], excludeTagFilter: AgendaExcludeTagFilter): boolean {
  if (!excludeTagFilter || excludeTagFilter.length === 0) return true;

  const normalizedTags = tags.map((tag) => String(tag).trim().toLowerCase()).filter(Boolean);
  return !excludeTagFilter.some((token) => normalizedTags.includes(token));
}

function matchesAgendaExcludeTodoFilter(todo: string | undefined, excludeTodoFilter: AgendaExcludeTodoFilter): boolean {
  if (!excludeTodoFilter || excludeTodoFilter.size === 0) return true;
  const normalized = String(todo || "").trim().toUpperCase();
  if (!normalized) return true;
  return !excludeTodoFilter.has(normalized);
}

function matchesAgendaExcludePriorityFilter(
  priority: string | undefined,
  excludePriorityFilter: AgendaExcludePriorityFilter,
): boolean {
  if (!excludePriorityFilter || excludePriorityFilter.size === 0) return true;
  const normalized = normalizeAgendaPriorityToken(String(priority || ""));
  if (!normalized) return true;
  return !excludePriorityFilter.has(normalized);
}

function matchesAgendaEffortFilter(effort: string | undefined, effortFilter: AgendaEffortFilter): boolean {
  if (!effortFilter || effortFilter.size === 0) return true;
  const normalized = normalizeAgendaEffortToken(String(effort || ""));
  if (!normalized) return false;
  return effortFilter.has(normalized);
}

function matchesAgendaExcludeEffortFilter(
  effort: string | undefined,
  excludeEffortFilter: AgendaExcludeEffortFilter,
): boolean {
  if (!excludeEffortFilter || excludeEffortFilter.size === 0) return true;
  const normalized = normalizeAgendaEffortToken(String(effort || ""));
  if (!normalized) return true;
  return !excludeEffortFilter.has(normalized);
}

function matchesAgendaPropertyFilter(
  properties: Record<string, string>,
  propertyFilter: AgendaPropertyFilter,
): boolean {
  if (!propertyFilter || propertyFilter.length === 0) return true;

  return propertyFilter.some((term) => {
    const valueRaw = properties[term.key];
    if (!valueRaw) return false;
    return normalizeAgendaPropertyValue(valueRaw) === term.value;
  });
}

function matchesAgendaExcludePropertyFilter(
  properties: Record<string, string>,
  excludePropertyFilter: AgendaExcludePropertyFilter,
): boolean {
  if (!excludePropertyFilter || excludePropertyFilter.length === 0) return true;

  return !excludePropertyFilter.some((term) => {
    const valueRaw = properties[term.key];
    if (!valueRaw) return false;
    return normalizeAgendaPropertyValue(valueRaw) === term.value;
  });
}

function matchesAgendaFileFilter(filePath: string, fileFilter: AgendaFileFilter): boolean {
  if (!fileFilter || fileFilter.length === 0) return true;

  const normalizedPath = String(filePath || "").toLowerCase();
  return fileFilter.some((token) => normalizedPath.includes(token));
}

function matchesAgendaExcludeFileFilter(filePath: string, excludeFileFilter: AgendaExcludeFileFilter): boolean {
  if (!excludeFileFilter || excludeFileFilter.length === 0) return true;

  const normalizedPath = String(filePath || "").toLowerCase();
  return !excludeFileFilter.some((token) => normalizedPath.includes(token));
}

function agendaWhenBucketForDate(itemDate: Date, startDate: Date): AgendaWhenBucket {
  if (itemDate < startDate) return "overdue";

  const itemIso = itemDate.toISOString().slice(0, 10);
  const startIso = startDate.toISOString().slice(0, 10);
  if (itemIso === startIso) return "today";

  return "upcoming";
}

function matchesAgendaWhenFilter(
  itemDate: Date,
  startDate: Date,
  whenFilter: AgendaWhenFilter,
): boolean {
  if (!whenFilter || whenFilter.size === 0) return true;
  return whenFilter.has(agendaWhenBucketForDate(itemDate, startDate));
}

function matchesAgendaExcludeWhenFilter(
  itemDate: Date,
  startDate: Date,
  excludeWhenFilter: AgendaExcludeWhenFilter,
): boolean {
  if (!excludeWhenFilter || excludeWhenFilter.size === 0) return true;
  return !excludeWhenFilter.has(agendaWhenBucketForDate(itemDate, startDate));
}

function matchesAgendaWeekdayFilter(itemDate: Date, weekdayFilter: AgendaWeekdayFilter): boolean {
  if (!weekdayFilter || weekdayFilter.size === 0) return true;
  return weekdayFilter.has(itemDate.getUTCDay());
}

function matchesAgendaExcludeWeekdayFilter(
  itemDate: Date,
  excludeWeekdayFilter: AgendaExcludeWeekdayFilter,
): boolean {
  if (!excludeWeekdayFilter || excludeWeekdayFilter.size === 0) return true;
  return !excludeWeekdayFilter.has(itemDate.getUTCDay());
}

function agendaIsoWeekForDate(itemDate: Date): number {
  const normalized = new Date(Date.UTC(itemDate.getUTCFullYear(), itemDate.getUTCMonth(), itemDate.getUTCDate()));
  const weekday = normalized.getUTCDay() || 7;
  normalized.setUTCDate(normalized.getUTCDate() + 4 - weekday);

  const yearStart = new Date(Date.UTC(normalized.getUTCFullYear(), 0, 1));
  const dayOffset = Math.floor((normalized.getTime() - yearStart.getTime()) / (24 * 60 * 60 * 1000));
  return Math.floor((dayOffset + 7) / 7);
}

function matchesAgendaWeekFilter(itemDate: Date, weekFilter: AgendaWeekFilter): boolean {
  if (!weekFilter || weekFilter.size === 0) return true;
  return weekFilter.has(agendaIsoWeekForDate(itemDate));
}

function matchesAgendaExcludeWeekFilter(
  itemDate: Date,
  excludeWeekFilter: AgendaExcludeWeekFilter,
): boolean {
  if (!excludeWeekFilter || excludeWeekFilter.size === 0) return true;
  return !excludeWeekFilter.has(agendaIsoWeekForDate(itemDate));
}

function matchesAgendaDayOfMonthFilter(itemDate: Date, dayOfMonthFilter: AgendaDayOfMonthFilter): boolean {
  if (!dayOfMonthFilter || dayOfMonthFilter.size === 0) return true;
  return dayOfMonthFilter.has(itemDate.getUTCDate());
}

function matchesAgendaExcludeDayOfMonthFilter(
  itemDate: Date,
  excludeDayOfMonthFilter: AgendaExcludeDayOfMonthFilter,
): boolean {
  if (!excludeDayOfMonthFilter || excludeDayOfMonthFilter.size === 0) return true;
  return !excludeDayOfMonthFilter.has(itemDate.getUTCDate());
}

function matchesAgendaMonthFilter(itemDate: Date, monthFilter: AgendaMonthFilter): boolean {
  if (!monthFilter || monthFilter.size === 0) return true;
  return monthFilter.has(itemDate.getUTCMonth() + 1);
}

function matchesAgendaExcludeMonthFilter(itemDate: Date, excludeMonthFilter: AgendaExcludeMonthFilter): boolean {
  if (!excludeMonthFilter || excludeMonthFilter.size === 0) return true;
  return !excludeMonthFilter.has(itemDate.getUTCMonth() + 1);
}

function agendaQuarterForDate(itemDate: Date): number {
  return Math.floor(itemDate.getUTCMonth() / 3) + 1;
}

function matchesAgendaQuarterFilter(itemDate: Date, quarterFilter: AgendaQuarterFilter): boolean {
  if (!quarterFilter || quarterFilter.size === 0) return true;
  return quarterFilter.has(agendaQuarterForDate(itemDate));
}

function matchesAgendaExcludeQuarterFilter(
  itemDate: Date,
  excludeQuarterFilter: AgendaExcludeQuarterFilter,
): boolean {
  if (!excludeQuarterFilter || excludeQuarterFilter.size === 0) return true;
  return !excludeQuarterFilter.has(agendaQuarterForDate(itemDate));
}

function matchesAgendaYearFilter(itemDate: Date, yearFilter: AgendaYearFilter): boolean {
  if (!yearFilter || yearFilter.size === 0) return true;
  return yearFilter.has(itemDate.getUTCFullYear());
}

function matchesAgendaExcludeYearFilter(itemDate: Date, excludeYearFilter: AgendaExcludeYearFilter): boolean {
  if (!excludeYearFilter || excludeYearFilter.size === 0) return true;
  return !excludeYearFilter.has(itemDate.getUTCFullYear());
}

function matchesAgendaDateFilter(itemDate: Date, dateFilter: AgendaDateFilter): boolean {
  if (!dateFilter || dateFilter.size === 0) return true;
  return dateFilter.has(itemDate.toISOString().slice(0, 10));
}

function matchesAgendaExcludeDateFilter(itemDate: Date, excludeDateFilter: AgendaExcludeDateFilter): boolean {
  if (!excludeDateFilter || excludeDateFilter.size === 0) return true;
  return !excludeDateFilter.has(itemDate.toISOString().slice(0, 10));
}

function matchesAgendaLevelFilter(level: number, levelFilter: AgendaLevelFilter): boolean {
  if (!levelFilter || levelFilter.size === 0) return true;
  return levelFilter.has(level);
}

function matchesAgendaExcludeLevelFilter(level: number, excludeLevelFilter: AgendaExcludeLevelFilter): boolean {
  if (!excludeLevelFilter || excludeLevelFilter.size === 0) return true;
  return !excludeLevelFilter.has(level);
}

function agendaWantsOverdue(
  includeOverdue: boolean,
  whenFilter: AgendaWhenFilter,
  excludeWhenFilter: AgendaExcludeWhenFilter,
): boolean {
  const includesOverdue = whenFilter ? whenFilter.has("overdue") : includeOverdue;
  if (!includesOverdue) return false;
  if (excludeWhenFilter && excludeWhenFilter.has("overdue")) return false;
  return true;
}

function extractAgendaPriorityFromHeadlineTitle(rawTitle: string): { priority?: string; title: string } {
  let title = String(rawTitle || "").trimStart();
  const match = title.match(/^\[#([A-Za-z0-9])\](?:\s+|$)/);
  if (!match) {
    return { title };
  }

  const priority = normalizeAgendaPriorityToken(match[1] ?? "");
  title = title.slice(match[0].length).trimStart();

  if (!priority) {
    return { title };
  }

  return { priority, title };
}

function parseHeadlineLine(line: string): { todo?: string; priority?: string; title: string; tags: string[]; level: number } | null {
  const m = /^(\*+)\s+(.*)$/.exec(line);
  if (!m) return null;

  const level = m[1]!.length;
  let rest = m[2] ?? "";
  rest = rest.trimEnd();

  let tags: string[] = [];

  // Capture/strip tags suffix: " ... :tag:tag:".
  const tagSuffixMatch = /\s+:([^\s:]+(?::[^\s:]+)*)\:\s*$/.exec(rest);
  if (tagSuffixMatch) {
    tags = tagSuffixMatch[1]
      .split(":")
      .map((tag) => tag.trim().toLowerCase())
      .filter(Boolean);

    const suffixStart = tagSuffixMatch.index ?? rest.length;
    rest = rest.slice(0, suffixStart).trimEnd();
  }

  const pieces = rest.trim().split(/\s+/);
  const first = pieces[0] ?? "";
  let todo: string | undefined;
  let titleRest = rest;

  // Heuristic: TODO keywords are usually uppercase-ish.
  if (/^[A-Z][A-Z0-9_-]*$/.test(first) && pieces.length > 1) {
    todo = first;
    titleRest = rest.slice(first.length).trimStart();
  }

  const { priority, title } = extractAgendaPriorityFromHeadlineTitle(titleRest);

  if (todo) {
    return { todo, priority, title, tags, level };
  }

  return { priority, title, tags, level };
}

function extractAgendaPropertiesNearHeadline(lines: string[], headlineLineIndex: number): Record<string, string> {
  const properties: Record<string, string> = {};
  let inProperties = false;

  for (let i = headlineLineIndex + 1; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    if (/^(\*+)\s+/.test(line)) break;

    const trimmed = line.trim();

    if (!inProperties) {
      if (!trimmed) continue;
      if (/^(SCHEDULED|DEADLINE|CLOSED):/i.test(trimmed)) continue;
      if (trimmed === ":PROPERTIES:") {
        inProperties = true;
        continue;
      }
      break;
    }

    if (trimmed === ":END:") break;
    if (!trimmed) continue;

    const match = /^:([A-Za-z0-9_@#%+.-]+):\s*(.*)$/.exec(trimmed);
    if (!match) continue;

    const key = normalizeAgendaPropertyKey(match[1] ?? "");
    const value = (match[2] ?? "").trim();
    if (!key || !value) continue;

    properties[key] = value;
  }

  return properties;
}

function findScheduledItemsInText(
  content: string,
  filePath: string,
  startDate: Date,
  endDate: Date,
  includeOverdue: boolean,
  statusFilter: AgendaStatusFilter,
  excludeStatusFilter: AgendaExcludeStatusFilter,
  planningFilter: AgendaPlanningFilter,
  excludePlanningFilter: AgendaExcludePlanningFilter,
  whenFilter: AgendaWhenFilter,
  excludeWhenFilter: AgendaExcludeWhenFilter,
  weekdayFilter: AgendaWeekdayFilter,
  excludeWeekdayFilter: AgendaExcludeWeekdayFilter,
  weekFilter: AgendaWeekFilter,
  excludeWeekFilter: AgendaExcludeWeekFilter,
  dayOfMonthFilter: AgendaDayOfMonthFilter,
  excludeDayOfMonthFilter: AgendaExcludeDayOfMonthFilter,
  monthFilter: AgendaMonthFilter,
  excludeMonthFilter: AgendaExcludeMonthFilter,
  quarterFilter: AgendaQuarterFilter,
  excludeQuarterFilter: AgendaExcludeQuarterFilter,
  yearFilter: AgendaYearFilter,
  excludeYearFilter: AgendaExcludeYearFilter,
  dateFilter: AgendaDateFilter,
  excludeDateFilter: AgendaExcludeDateFilter,
  levelFilter: AgendaLevelFilter,
  excludeLevelFilter: AgendaExcludeLevelFilter,
  textFilter: AgendaMatchFilter,
  excludeTextFilter: AgendaExcludeMatchFilter,
  tagFilter: AgendaTagFilter,
  idFilter: AgendaIdFilter,
  todoFilter: AgendaTodoFilter,
  priorityFilter: AgendaPriorityFilter,
  timeFilter: AgendaTimeFilter,
  effortFilter: AgendaEffortFilter,
  propertyFilter: AgendaPropertyFilter,
  excludeTagFilter: AgendaExcludeTagFilter,
  excludeIdFilter: AgendaExcludeIdFilter,
  excludeTodoFilter: AgendaExcludeTodoFilter,
  excludePriorityFilter: AgendaExcludePriorityFilter,
  excludeTimeFilter: AgendaExcludeTimeFilter,
  excludeEffortFilter: AgendaExcludeEffortFilter,
  excludePropertyFilter: AgendaExcludePropertyFilter,
): ScheduledItem[] {
  const items: ScheduledItem[] = [];
  const lines = content.split("\n");

  let current: {
    todo?: string;
    priority?: string;
    effort?: string;
    properties: Record<string, string>;
    title: string;
    tags: string[];
    level: number;
    lineNumber: number;
  } | null = null;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";

    // Headline line
    if (/^(\*+)\s+/.test(line)) {
      const parsed = parseHeadlineLine(line);
      if (parsed) {
        const properties = extractAgendaPropertiesNearHeadline(lines, i);
        current = {
          ...parsed,
          effort: properties.EFFORT,
          properties,
          lineNumber: i,
        };
      } else {
        current = null;
      }
      continue;
    }

    // Planning line(s) belong to the most recent headline.
    if (!current) continue;

    // Skip non-todo headlines.
    const todo = current.todo;
    if (!todo) continue;

    const todoBucket = agendaStatusBucketForKeyword(todo);
    if (statusFilter && (!todoBucket || !statusFilter.has(todoBucket))) continue;
    if (!matchesAgendaExcludeStatusFilter(todo, excludeStatusFilter)) continue;
    if (!matchesAgendaTextFilter(current.title, textFilter)) continue;
    if (!matchesAgendaExcludeTextFilter(current.title, excludeTextFilter)) continue;
    if (!matchesAgendaTagFilter(current.tags, tagFilter)) continue;
    if (!matchesAgendaIdFilter(current.properties, idFilter)) continue;
    if (!matchesAgendaTodoFilter(todo, todoFilter)) continue;
    if (!matchesAgendaPriorityFilter(current.priority, priorityFilter)) continue;
    if (!matchesAgendaEffortFilter(current.effort, effortFilter)) continue;
    if (!matchesAgendaPropertyFilter(current.properties, propertyFilter)) continue;
    if (!matchesAgendaExcludeTagFilter(current.tags, excludeTagFilter)) continue;
    if (!matchesAgendaExcludeIdFilter(current.properties, excludeIdFilter)) continue;
    if (!matchesAgendaExcludeTodoFilter(todo, excludeTodoFilter)) continue;
    if (!matchesAgendaExcludePriorityFilter(current.priority, excludePriorityFilter)) continue;
    if (!matchesAgendaExcludeEffortFilter(current.effort, excludeEffortFilter)) continue;
    if (!matchesAgendaExcludePropertyFilter(current.properties, excludePropertyFilter)) continue;
    if (!matchesAgendaLevelFilter(current.level, levelFilter)) continue;
    if (!matchesAgendaExcludeLevelFilter(current.level, excludeLevelFilter)) continue;

    const isDoneLike = todo === "DONE" || todo === "CANCELLED" || todo === "CANCELED";
    const isProgLike = todo === "PROG" || todo === "IN_PROGRESS";

    // Match multiple planning tokens on a single line.
    // Example: "SCHEDULED: <2026-02-01 Sun> DEADLINE: <...>"
    const planningRe = /(SCHEDULED|DEADLINE|CLOSED):\s*([<[].*?[>\]])/g;
    planningRe.lastIndex = 0;

    let m: RegExpExecArray | null;
    while ((m = planningRe.exec(line)) !== null) {
      const kind = m[1] ?? "";
      // CLOSED is metadata for completed tasks; don't create a separate agenda entry.
      if (kind === "CLOSED") continue;
      if (planningFilter && !planningFilter.has(kind as AgendaPlanningKind)) continue;
      if (!matchesAgendaExcludeKindFilter(kind as AgendaPlanningKind, excludePlanningFilter)) continue;

      const tsRaw = m[2] ?? "";
      const planningTime = extractTimeFromTimestamp(tsRaw);
      if (!matchesAgendaTimeFilter(planningTime, timeFilter)) continue;
      if (!matchesAgendaExcludeTimeFilter(planningTime, excludeTimeFilter)) continue;
      const wantsOverdue = agendaWantsOverdue(includeOverdue, whenFilter, excludeWhenFilter);
      const agendaDates = resolveAgendaDatesFromTimestamp(tsRaw, startDate, endDate, wantsOverdue, kind as AgendaPlanningKind);

      for (const dateStr of agendaDates) {
        const itemDate = parseIsoDate(dateStr);
        const inRange = itemDate >= startDate && itemDate <= endDate;
        const isOverdue = itemDate < startDate;

        // TODO state filtering:
        // - DONE/CANCELLED: only show if not overdue.
        // - PROG (and IN_PROGRESS): can appear when overdue regardless of includeOverdue
        //   because those tasks are still active.
        // - Everything else: show inRange, and show overdue when includeOverdue (or when
        //   --when explicitly requests overdue rows).
        if (isDoneLike && isOverdue) continue;
        if (!(inRange || (isProgLike && isOverdue) || (!isDoneLike && wantsOverdue && isOverdue))) continue;
        if (!matchesAgendaWhenFilter(itemDate, startDate, whenFilter)) continue;
        if (!matchesAgendaExcludeWhenFilter(itemDate, startDate, excludeWhenFilter)) continue;
        if (!matchesAgendaWeekdayFilter(itemDate, weekdayFilter)) continue;
        if (!matchesAgendaExcludeWeekdayFilter(itemDate, excludeWeekdayFilter)) continue;
        if (!matchesAgendaWeekFilter(itemDate, weekFilter)) continue;
        if (!matchesAgendaExcludeWeekFilter(itemDate, excludeWeekFilter)) continue;
        if (!matchesAgendaDayOfMonthFilter(itemDate, dayOfMonthFilter)) continue;
        if (!matchesAgendaExcludeDayOfMonthFilter(itemDate, excludeDayOfMonthFilter)) continue;
        if (!matchesAgendaMonthFilter(itemDate, monthFilter)) continue;
        if (!matchesAgendaExcludeMonthFilter(itemDate, excludeMonthFilter)) continue;
        if (!matchesAgendaQuarterFilter(itemDate, quarterFilter)) continue;
        if (!matchesAgendaExcludeQuarterFilter(itemDate, excludeQuarterFilter)) continue;
        if (!matchesAgendaYearFilter(itemDate, yearFilter)) continue;
        if (!matchesAgendaExcludeYearFilter(itemDate, excludeYearFilter)) continue;
        if (!matchesAgendaDateFilter(itemDate, dateFilter)) continue;
        if (!matchesAgendaExcludeDateFilter(itemDate, excludeDateFilter)) continue;

        items.push({
          filePath,
          lineNumber: current.lineNumber,
          headline: current.title,
          todo,
          priority: current.priority,
          effort: current.effort,
          id: agendaPrimaryIdFromProperties(current.properties),
          level: current.level,
          date: dateStr,
          time: planningTime,
          kind,
          tags: [...current.tags],
        });
      }
    }
  }

  return items;
}

function findScheduledItems(
  ast: DocumentNode,
  filePath: string,
  startDate: Date,
  endDate: Date,
  includeOverdue: boolean,
  statusFilter: AgendaStatusFilter,
  excludeStatusFilter: AgendaExcludeStatusFilter,
  planningFilter: AgendaPlanningFilter,
  excludePlanningFilter: AgendaExcludePlanningFilter,
  whenFilter: AgendaWhenFilter,
  excludeWhenFilter: AgendaExcludeWhenFilter,
  weekdayFilter: AgendaWeekdayFilter,
  excludeWeekdayFilter: AgendaExcludeWeekdayFilter,
  dayOfMonthFilter: AgendaDayOfMonthFilter,
  excludeDayOfMonthFilter: AgendaExcludeDayOfMonthFilter,
  textFilter: AgendaMatchFilter,
  excludeTextFilter: AgendaExcludeMatchFilter,
  tagFilter: AgendaTagFilter,
  todoFilter: AgendaTodoFilter,
  priorityFilter: AgendaPriorityFilter,
  excludeTagFilter: AgendaExcludeTagFilter,
  excludeTodoFilter: AgendaExcludeTodoFilter,
  excludePriorityFilter: AgendaExcludePriorityFilter,
): ScheduledItem[] {
  const items: ScheduledItem[] = [];

  function traverseNodes(nodes: Node[], currentHeadline: HeadlineNode | null = null): void {
    for (const node of nodes) {
      if (node.type === "Headline") {
        const headline = node as HeadlineNode;
        // Check for planning nodes in children
        for (const child of headline.children) {
          if (child.type === "Planning") {
            const planning = child as PlanningNode;
            if (planning.timestamp) {
              const ts = planning.timestamp as TimestampNode | TimestampRangeNode;
              const raw = "start" in ts ? ts.start.raw : ts.raw;
              const planningTime = extractTimeFromTimestamp(raw);
              const wantsOverdue = agendaWantsOverdue(includeOverdue, whenFilter, excludeWhenFilter);
              const agendaDates = resolveAgendaDatesFromTimestamp(
                raw,
                startDate,
                endDate,
                wantsOverdue,
                planning.kind as AgendaPlanningKind,
              );
              if (agendaDates.length === 0) continue;

              const todo = headline.todo;
              if (!todo) continue;

              const todoBucket = agendaStatusBucketForKeyword(todo);
              if (statusFilter && (!todoBucket || !statusFilter.has(todoBucket))) continue;
              if (!matchesAgendaExcludeStatusFilter(todo, excludeStatusFilter)) continue;

              const isDoneLike = todo === "DONE" || todo === "CANCELLED" || todo === "CANCELED";
              const isProgLike = todo === "PROG" || todo === "IN_PROGRESS";

              const titleText = headline.title
                .filter((t) => t.type === "Text")
                .map((t) => t.value)
                .join("");
              const { priority, title: agendaTitle } = extractAgendaPriorityFromHeadlineTitle(titleText);

              if (!matchesAgendaTextFilter(agendaTitle, textFilter)) continue;
              if (!matchesAgendaExcludeTextFilter(agendaTitle, excludeTextFilter)) continue;
              if (!matchesAgendaTagFilter(headline.tags ?? [], tagFilter)) continue;
              if (!matchesAgendaTodoFilter(todo, todoFilter)) continue;
              if (!matchesAgendaPriorityFilter(priority, priorityFilter)) continue;
              if (!matchesAgendaExcludeTagFilter(headline.tags ?? [], excludeTagFilter)) continue;
              if (!matchesAgendaExcludeTodoFilter(todo, excludeTodoFilter)) continue;
              if (!matchesAgendaExcludePriorityFilter(priority, excludePriorityFilter)) continue;
              if (planning.kind === "CLOSED") continue;
              if (planningFilter && !planningFilter.has(planning.kind as AgendaPlanningKind)) continue;
              if (!matchesAgendaExcludeKindFilter(planning.kind as AgendaPlanningKind, excludePlanningFilter)) continue;

              for (const dateStr of agendaDates) {
                const itemDate = parseIsoDate(dateStr);
                const inRange = itemDate >= startDate && itemDate <= endDate;
                const isOverdue = itemDate < startDate;

                if (isDoneLike && isOverdue) continue;
                if (!(inRange || (isProgLike && isOverdue) || (!isDoneLike && wantsOverdue && isOverdue))) continue;
                if (!matchesAgendaWhenFilter(itemDate, startDate, whenFilter)) continue;
                if (!matchesAgendaExcludeWhenFilter(itemDate, startDate, excludeWhenFilter)) continue;
                if (!matchesAgendaWeekdayFilter(itemDate, weekdayFilter)) continue;
                if (!matchesAgendaExcludeWeekdayFilter(itemDate, excludeWeekdayFilter)) continue;
                if (!matchesAgendaDayOfMonthFilter(itemDate, dayOfMonthFilter)) continue;
                if (!matchesAgendaExcludeDayOfMonthFilter(itemDate, excludeDayOfMonthFilter)) continue;

                items.push({
                  filePath,
                  lineNumber: 0, // Line numbers not tracked in AST, using 0
                  headline: agendaTitle,
                  todo,
                  priority,
                  effort: undefined,
                  id: undefined,
                  level: headline.level,
                  date: dateStr,
                  time: planningTime,
                  kind: planning.kind,
                  tags: [...(headline.tags ?? [])],
                });
              }
            }
          }
        }
        // Recursively check children
        traverseNodes(headline.children, headline);
      } else if (node.type !== "Paragraph" && node.type !== "List") {
        // Recursively check other block types that might contain children
        if ("children" in node) {
          traverseNodes((node as { children: Node[] }).children, currentHeadline);
        }
      }
    }
  }

  traverseNodes(ast.children);
  return items;
}

function formatDateHeader(dateStr: string): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateStr);
  if (!match) return dateStr;

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);

  // Compute weekday deterministically without local timezone effects.
  const dateUtc = new Date(Date.UTC(year, month - 1, day));

  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const dayName = days[dateUtc.getUTCDay()];
  return `${dateStr} ${dayName}`;
}

function formatSectionHeader(title: string): string {
  const separator = "═".repeat(title.length + 2);
  return `\n${separator}\n ${title}\n${separator}\n\n`;
}

/**
 * Generate unified diff format for archive output.
 */
function formatArchiveDiff(
  sourcePath: string,
  archivePath: string,
  subtreeText: string
): string {
  let diff = `--- ${sourcePath}\n`;
  diff += `+++ ${archivePath}\n`;

  // Show what's being removed from source
  const subtreeLines = subtreeText.split("\n");

  diff += `@@ archive @@\n`;
  diff += `--- ${sourcePath} (removed lines)\n`;
  for (const line of subtreeLines) {
    if (line) diff += `- ${line}\n`;
  }

  diff += `\n+++ ${archivePath} (appended lines)\n`;
  for (const line of subtreeLines) {
    if (line) diff += `+ ${line}\n`;
  }

  return diff;
}

function formatOutput(
  items: ScheduledItem[],
  startDate: Date,
  dateOrder: AgendaDateOrder,
  groupOrder: AgendaGroupOrder,
  tagOrder: AgendaTagOrder,
): string {
  if (items.length === 0) {
    return "No scheduled items in range.\n";
  }

  const startIso = startDate.toISOString().slice(0, 10);
  const dateCompare = (a: ScheduledItem, b: ScheduledItem): number => {
    const cmp = a.date.localeCompare(b.date);
    return dateOrder === "desc" ? -cmp : cmp;
  };

  const overdueItems = items.filter((it) => it.date < startIso).sort(dateCompare);
  const upcomingItems = items.filter((it) => it.date >= startIso).sort(dateCompare);

  let output = "";

  if (overdueItems.length > 0) {
    output += formatSectionHeader(`OVERDUE (before ${startIso})`);
    output += formatUnifiedSection(overdueItems, groupOrder, tagOrder);

    if (upcomingItems.length > 0) {
      output += formatSectionHeader(`UPCOMING (from ${startIso})`);
    }
  }

  output += formatByDate(upcomingItems, dateOrder, groupOrder, tagOrder);
  return output;
}

function formatUnifiedSection(
  items: ScheduledItem[],
  groupOrder: AgendaGroupOrder,
  tagOrder: AgendaTagOrder,
): string {
  if (items.length === 0) return "";

  let output = "\n";

  if (groupOrder && groupOrder.length > 0) {
    let previousGroupKey = "";
    for (const item of items) {
      const nextGroupKey = agendaGroupKeyForItem(item, groupOrder, tagOrder);
      if (nextGroupKey !== previousGroupKey) {
        if (previousGroupKey) output += "\n";
        output += `  ─ ${agendaGroupLabelForItem(item, groupOrder, tagOrder)}\n`;
        previousGroupKey = nextGroupKey;
      }

      const status = item.todo || "ITEM";
      const timePrefix = item.time ? `${item.time} ` : "";
      output += `    [${status}] ${timePrefix}${item.headline} (${item.kind}) ${item.filePath}\n`;
    }
  } else {
    for (const item of items) {
      const status = item.todo || "ITEM";
      const timePrefix = item.time ? `${item.time} ` : "";
      output += `  [${status}] ${timePrefix}${item.headline} (${item.kind}) ${item.filePath}\n`;
    }
  }

  output += "\n";
  return output;
}

function formatByDate(
  items: ScheduledItem[],
  dateOrder: AgendaDateOrder,
  groupOrder: AgendaGroupOrder,
  tagOrder: AgendaTagOrder,
): string {
  if (items.length === 0) return "";

  // Group by date
  const byDate = new Map<string, ScheduledItem[]>();
  for (const item of items) {
    if (!byDate.has(item.date)) {
      byDate.set(item.date, []);
    }
    byDate.get(item.date)!.push(item);
  }

  // Sort dates
  const dates = Array.from(byDate.keys()).sort((a, b) => {
    const cmp = a.localeCompare(b);
    return dateOrder === "desc" ? -cmp : cmp;
  });

  let output = "";
  for (let i = 0; i < dates.length; i++) {
    const date = dates[i];
    const dateHeader = formatDateHeader(date);
    const separator = "═".repeat(dateHeader.length + 2);

    output += `\n${separator}\n`;
    output += ` ${dateHeader}\n`;
    output += `${separator}\n\n`;

    const dayItems = byDate.get(date)!;
    if (groupOrder && groupOrder.length > 0) {
      let previousGroupKey = "";
      for (const item of dayItems) {
        const nextGroupKey = agendaGroupKeyForItem(item, groupOrder, tagOrder);
        if (nextGroupKey !== previousGroupKey) {
          if (previousGroupKey) output += "\n";
          output += `  ─ ${agendaGroupLabelForItem(item, groupOrder, tagOrder)}\n`;
          previousGroupKey = nextGroupKey;
        }

        const status = item.todo || "ITEM";
        const timePrefix = item.time ? `${item.time} ` : "";
        output += `    [${status}] ${timePrefix}${item.headline} (${item.kind}) ${item.filePath}\n`;
      }
    } else {
      for (const item of dayItems) {
        const status = item.todo || "ITEM";
        const timePrefix = item.time ? `${item.time} ` : "";
        output += `  [${status}] ${timePrefix}${item.headline} (${item.kind}) ${item.filePath}\n`;
      }
    }

    output += "\n";
  }

  return output;
}

function compareAgendaPriorityValues(
  aPriority: string | undefined,
  bPriority: string | undefined,
  priorityOrder: AgendaPriorityOrder,
): number {
  const a = normalizeAgendaPriorityToken(String(aPriority || ""));
  const b = normalizeAgendaPriorityToken(String(bPriority || ""));

  if (!a && !b) return 0;
  if (!a) return 1;
  if (!b) return -1;

  const defaultRank = (priority: string): number => {
    if (/^[A-Z]$/.test(priority)) {
      return priority.charCodeAt(0) - 65;
    }
    if (/^[0-9]$/.test(priority)) {
      return 26 + Number.parseInt(priority, 10);
    }
    return 100 + priority.charCodeAt(0);
  };

  const rank = (priority: string): number => {
    if (priorityOrder && priorityOrder.size > 0) {
      const customRank = priorityOrder.get(priority);
      if (customRank !== undefined) return customRank;
      return priorityOrder.size + defaultRank(priority);
    }

    return defaultRank(priority);
  };

  return rank(a) - rank(b);
}

function agendaEffortOrderToken(effort: string | undefined): string {
  const normalized = normalizeAgendaEffortToken(String(effort || ""));
  if (!normalized) return AGENDA_EFFORT_ORDER_EMPTY;
  return normalized;
}

function compareAgendaEffortValues(
  aEffort: string | undefined,
  bEffort: string | undefined,
  effortOrder: AgendaEffortOrder,
): number {
  if (effortOrder && effortOrder.size > 0) {
    const aRank = effortOrder.get(agendaEffortOrderToken(aEffort));
    const bRank = effortOrder.get(agendaEffortOrderToken(bEffort));

    if (aRank !== undefined && bRank !== undefined) {
      const byRank = aRank - bRank;
      if (byRank !== 0) return byRank;
    } else if (aRank !== undefined) {
      return -1;
    } else if (bRank !== undefined) {
      return 1;
    }
  }

  const aMinutes = parseAgendaEffortToMinutes(String(aEffort || ""));
  const bMinutes = parseAgendaEffortToMinutes(String(bEffort || ""));

  if (aMinutes !== null && bMinutes !== null) {
    return aMinutes - bMinutes;
  }

  if (aMinutes !== null) return -1;
  if (bMinutes !== null) return 1;

  const aText = normalizeAgendaEffortToken(String(aEffort || ""));
  const bText = normalizeAgendaEffortToken(String(bEffort || ""));

  if (!aText && !bText) return 0;
  if (!aText) return 1;
  if (!bText) return -1;

  return aText.localeCompare(bText);
}

function agendaStatusSortBucketForItem(item: ScheduledItem): AgendaStatusBucket | null {
  return agendaStatusBucketForKeyword(item.todo);
}

function compareAgendaStatusBuckets(a: ScheduledItem, b: ScheduledItem, statusOrder: AgendaStatusOrder): number {
  const defaultRankForBucket = (bucket: AgendaStatusBucket | null): number => {
    if (bucket === "todo") return 0;
    if (bucket === "in_progress") return 1;
    if (bucket === "done") return 2;
    if (bucket === "canceled") return 3;
    if (bucket === "custom") return 4;
    return 5;
  };

  const rankForBucket = (bucket: AgendaStatusBucket | null): number => {
    if (!bucket) return 5;

    if (statusOrder && statusOrder.size > 0) {
      const customRank = statusOrder.get(bucket);
      if (customRank !== undefined) return customRank;
      return statusOrder.size + defaultRankForBucket(bucket);
    }

    return defaultRankForBucket(bucket);
  };

  const aBucket = agendaStatusSortBucketForItem(a);
  const bBucket = agendaStatusSortBucketForItem(b);

  const byRank = rankForBucket(aBucket) - rankForBucket(bBucket);
  if (byRank !== 0) return byRank;

  return String(a.todo || "").localeCompare(String(b.todo || ""));
}

function agendaPlanningKindForItem(item: ScheduledItem): AgendaPlanningKind | null {
  const kind = String(item.kind || "").trim().toUpperCase();
  if (kind === "SCHEDULED" || kind === "DEADLINE") return kind;
  return null;
}

function compareAgendaKinds(a: ScheduledItem, b: ScheduledItem, kindOrder: AgendaKindOrder): number {
  const defaultRankForKind = (kind: AgendaPlanningKind | null): number => {
    if (kind === "DEADLINE") return 0;
    if (kind === "SCHEDULED") return 1;
    return 2;
  };

  const rankForKind = (kind: AgendaPlanningKind | null): number => {
    if (!kind) return 2;

    if (kindOrder && kindOrder.size > 0) {
      const customRank = kindOrder.get(kind);
      if (customRank !== undefined) return customRank;
      return kindOrder.size + defaultRankForKind(kind);
    }

    return defaultRankForKind(kind);
  };

  const aKind = agendaPlanningKindForItem(a);
  const bKind = agendaPlanningKindForItem(b);

  const byRank = rankForKind(aKind) - rankForKind(bKind);
  if (byRank !== 0) return byRank;

  return String(a.kind || "").localeCompare(String(b.kind || ""));
}

function compareAgendaTodoValues(
  aTodo: string | undefined,
  bTodo: string | undefined,
  todoOrder: AgendaTodoOrder,
): number {
  const a = String(aTodo || "").trim().toUpperCase();
  const b = String(bTodo || "").trim().toUpperCase();

  if (todoOrder && todoOrder.size > 0) {
    const aRank = a ? todoOrder.get(a) : undefined;
    const bRank = b ? todoOrder.get(b) : undefined;

    if (aRank !== undefined && bRank !== undefined) {
      const byRank = aRank - bRank;
      if (byRank !== 0) return byRank;
    } else if (aRank !== undefined) {
      return -1;
    } else if (bRank !== undefined) {
      return 1;
    }
  }

  if (!a && !b) return 0;
  if (!a) return 1;
  if (!b) return -1;

  return a.localeCompare(b);
}

function compareAgendaTagTokens(aTag: string, bTag: string, tagOrder: AgendaTagOrder): number {
  if (tagOrder && tagOrder.size > 0) {
    const aRank = tagOrder.get(aTag);
    const bRank = tagOrder.get(bTag);
    if (aRank !== undefined && bRank !== undefined) {
      if (aRank !== bRank) return aRank - bRank;
    } else if (aRank !== undefined) {
      return -1;
    } else if (bRank !== undefined) {
      return 1;
    }
  }

  return aTag.localeCompare(bTag);
}

function normalizeAgendaTagsForOrdering(tags: string[], tagOrder: AgendaTagOrder): string[] {
  const normalized = Array.from(
    new Set(
      tags
        .map((tag) => String(tag).trim().toLowerCase())
        .filter(Boolean),
    ),
  );

  if (normalized.length === 0) return [];

  normalized.sort((a, b) => compareAgendaTagTokens(a, b, tagOrder));
  return normalized;
}

function compareAgendaTagValues(aTags: string[], bTags: string[], tagOrder: AgendaTagOrder): number {
  const aNormalized = normalizeAgendaTagsForOrdering(aTags, tagOrder);
  const bNormalized = normalizeAgendaTagsForOrdering(bTags, tagOrder);

  if (aNormalized.length === 0 && bNormalized.length === 0) return 0;
  if (tagOrder && tagOrder.size > 0) {
    if (aNormalized.length === 0) return 1;
    if (bNormalized.length === 0) return -1;
  } else {
    if (aNormalized.length === 0) return -1;
    if (bNormalized.length === 0) return 1;
  }

  const maxLen = Math.max(aNormalized.length, bNormalized.length);
  for (let i = 0; i < maxLen; i += 1) {
    const aTag = aNormalized[i];
    const bTag = bNormalized[i];

    if (aTag === undefined && bTag === undefined) break;
    if (aTag === undefined) return -1;
    if (bTag === undefined) return 1;

    const byTag = compareAgendaTagTokens(aTag, bTag, tagOrder);
    if (byTag !== 0) return byTag;
  }

  return 0;
}

function compareAgendaItemsByKey(
  a: ScheduledItem,
  b: ScheduledItem,
  key: AgendaSortKey,
  todoOrder: AgendaTodoOrder,
  statusOrder: AgendaStatusOrder,
  kindOrder: AgendaKindOrder,
  priorityOrder: AgendaPriorityOrder,
  effortOrder: AgendaEffortOrder,
  tagOrder: AgendaTagOrder,
): number {
  if (key === "file") {
    const byFile = a.filePath.localeCompare(b.filePath);
    if (byFile !== 0) return byFile;
    return a.lineNumber - b.lineNumber;
  }

  if (key === "headline") {
    return a.headline.localeCompare(b.headline);
  }

  if (key === "todo") {
    return compareAgendaTodoValues(a.todo, b.todo, todoOrder);
  }

  if (key === "status") {
    return compareAgendaStatusBuckets(a, b, statusOrder);
  }

  if (key === "priority") {
    return compareAgendaPriorityValues(a.priority, b.priority, priorityOrder);
  }

  if (key === "effort") {
    return compareAgendaEffortValues(a.effort, b.effort, effortOrder);
  }

  if (key === "id") {
    const aId = normalizeAgendaItemId(a);
    const bId = normalizeAgendaItemId(b);

    if (!aId && !bId) return 0;
    if (!aId) return 1;
    if (!bId) return -1;

    const byId = aId.localeCompare(bId);
    if (byId !== 0) return byId;
    return a.lineNumber - b.lineNumber;
  }

  if (key === "level") {
    return a.level - b.level;
  }

  if (key === "time") {
    const aMinutes = parseAgendaTimeToMinutes(a.time);
    const bMinutes = parseAgendaTimeToMinutes(b.time);

    if (aMinutes !== null && bMinutes !== null) {
      return aMinutes - bMinutes;
    }

    if (aMinutes !== null) return -1;
    if (bMinutes !== null) return 1;

    return String(a.time || "").localeCompare(String(b.time || ""));
  }

  if (key === "kind") {
    return compareAgendaKinds(a, b, kindOrder);
  }

  if (key === "tags") {
    const byTags = compareAgendaTagValues(a.tags || [], b.tags || [], tagOrder);
    if (byTags !== 0) return byTags;
    return a.lineNumber - b.lineNumber;
  }

  return a.lineNumber - b.lineNumber;
}

function agendaGroupValueForKey(item: ScheduledItem, key: AgendaSortKey, tagOrder: AgendaTagOrder): string {
  if (key === "file") return item.filePath;
  if (key === "headline") return item.headline;
  if (key === "todo") return String(item.todo || "").trim();
  if (key === "status") return agendaStatusSortBucketForItem(item) || "";
  if (key === "priority") return normalizeAgendaPriorityToken(String(item.priority || "")) || "";
  if (key === "effort") return String(item.effort || "").trim();
  if (key === "id") return normalizeAgendaItemId(item);
  if (key === "level") return String(item.level || "").trim();
  if (key === "time") return normalizeAgendaTimeToken(String(item.time || "")) || "";
  if (key === "kind") return String(item.kind || "").trim();
  if (key === "tags") {
    return normalizeAgendaTagsForOrdering(item.tags || [], tagOrder).join(",");
  }
  return String(item.lineNumber);
}

function agendaGroupLabelForItem(item: ScheduledItem, groupOrder: AgendaGroupOrder, tagOrder: AgendaTagOrder): string {
  if (!groupOrder || groupOrder.length === 0) return "";

  const labelForKey = (key: AgendaSortKey): string => {
    if (key === "file") return "File";
    if (key === "headline") return "Headline";
    if (key === "todo") return "TODO";
    if (key === "status") return "Status";
    if (key === "priority") return "Priority";
    if (key === "effort") return "Effort";
    if (key === "id") return "ID";
    if (key === "level") return "Level";
    if (key === "time") return "Time";
    if (key === "kind") return "Kind";
    if (key === "tags") return "Tags";
    return "Line";
  };

  return groupOrder
    .map((field) => {
      const value = agendaGroupValueForKey(item, field.key, tagOrder);
      return `${labelForKey(field.key)}: ${value || "(none)"}`;
    })
    .join(" · ");
}

function agendaGroupKeyForItem(item: ScheduledItem, groupOrder: AgendaGroupOrder, tagOrder: AgendaTagOrder): string {
  if (!groupOrder || groupOrder.length === 0) return "";
  return groupOrder.map((field) => `${field.key}=${agendaGroupValueForKey(item, field.key, tagOrder)}`).join("|\u001f|");
}

function compareAgendaItems(
  a: ScheduledItem,
  b: ScheduledItem,
  groupOrder: AgendaGroupOrder,
  sortOrder: AgendaSortOrder,
  dateOrder: AgendaDateOrder,
  todoOrder: AgendaTodoOrder,
  statusOrder: AgendaStatusOrder,
  kindOrder: AgendaKindOrder,
  priorityOrder: AgendaPriorityOrder,
  effortOrder: AgendaEffortOrder,
  tagOrder: AgendaTagOrder,
): number {
  if (groupOrder && groupOrder.length > 0) {
    for (const field of groupOrder) {
      const cmp = compareAgendaItemsByKey(
        a,
        b,
        field.key,
        todoOrder,
        statusOrder,
        kindOrder,
        priorityOrder,
        effortOrder,
        tagOrder,
      );
      if (cmp !== 0) {
        return field.direction === "desc" ? -cmp : cmp;
      }
    }
  }

  if (sortOrder && sortOrder.length > 0) {
    for (const field of sortOrder) {
      const cmp = compareAgendaItemsByKey(
        a,
        b,
        field.key,
        todoOrder,
        statusOrder,
        kindOrder,
        priorityOrder,
        effortOrder,
        tagOrder,
      );
      if (cmp !== 0) {
        return field.direction === "desc" ? -cmp : cmp;
      }
    }
  }

  const byDate = a.date.localeCompare(b.date);
  if (byDate !== 0) {
    return dateOrder === "desc" ? -byDate : byDate;
  }

  const byPriority = compareAgendaPriorityValues(a.priority, b.priority, priorityOrder);
  if (byPriority !== 0) return byPriority;

  const byFile = a.filePath.localeCompare(b.filePath);
  if (byFile !== 0) return byFile;

  const byLine = a.lineNumber - b.lineNumber;
  if (byLine !== 0) return byLine;

  const byHeadline = a.headline.localeCompare(b.headline);
  if (byHeadline !== 0) return byHeadline;

  const byTodo = String(a.todo || "").localeCompare(String(b.todo || ""));
  if (byTodo !== 0) return byTodo;

  return a.kind.localeCompare(b.kind);
}

function applyAgendaGroupLimit(
  items: ScheduledItem[],
  groupOrder: AgendaGroupOrder,
  groupLimit: number | null,
  tagOrder: AgendaTagOrder,
): ScheduledItem[] {
  if (!groupLimit || groupLimit < 1) return items;
  if (!groupOrder || groupOrder.length === 0) return items;

  const perDateGroupCounts = new Map<string, number>();
  const kept: ScheduledItem[] = [];

  for (const item of items) {
    const groupKey = agendaGroupKeyForItem(item, groupOrder, tagOrder);
    const dateGroupKey = `${item.date}\u001f${groupKey}`;
    const seen = perDateGroupCounts.get(dateGroupKey) || 0;
    if (seen >= groupLimit) continue;

    perDateGroupCounts.set(dateGroupKey, seen + 1);
    kept.push(item);
  }

  return kept;
}

function applyAgendaDayLimit(items: ScheduledItem[], dayLimit: number | null): ScheduledItem[] {
  if (!dayLimit || dayLimit < 1) return items;

  const perDayCounts = new Map<string, number>();
  const kept: ScheduledItem[] = [];

  for (const item of items) {
    const seen = perDayCounts.get(item.date) || 0;
    if (seen >= dayLimit) continue;

    perDayCounts.set(item.date, seen + 1);
    kept.push(item);
  }

  return kept;
}

function listOrgLikeFiles(rootDir: string, recursiveScan: boolean): string[] {
  const out: string[] = [];

  const walk = (d: string): void => {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }

    for (const ent of entries) {
      const full = path.join(d, ent.name);
      if (ent.isDirectory()) {
        // Skip common noisy directories
        if (ent.name === ".git" || ent.name === "node_modules" || ent.name === ".org2") continue;
        if (recursiveScan) walk(full);
        continue;
      }

      if (!ent.isFile()) continue;
      if (full.endsWith(".org") || full.endsWith(".org2")) out.push(full);
    }
  };

  walk(rootDir);
  return out;
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);

  let command = "";
  let dir = "";
  let files: string[] = [];
  let days = 7;
  let today = getTodayString();
  let format: "text" | "json" = "text";
  let recursive = false;
  let includeOverdue = true;
  let agendaStatusFiltersRaw: string[] = [];
  let agendaExcludeStatusFiltersRaw: string[] = [];
  let agendaKindFiltersRaw: string[] = [];
  let agendaExcludeKindFiltersRaw: string[] = [];
  let agendaWhenFiltersRaw: string[] = [];
  let agendaExcludeWhenFiltersRaw: string[] = [];
  let agendaWeekdayFiltersRaw: string[] = [];
  let agendaExcludeWeekdayFiltersRaw: string[] = [];
  let agendaWeekFiltersRaw: string[] = [];
  let agendaExcludeWeekFiltersRaw: string[] = [];
  let agendaDayOfMonthFiltersRaw: string[] = [];
  let agendaExcludeDayOfMonthFiltersRaw: string[] = [];
  let agendaMonthFiltersRaw: string[] = [];
  let agendaExcludeMonthFiltersRaw: string[] = [];
  let agendaQuarterFiltersRaw: string[] = [];
  let agendaExcludeQuarterFiltersRaw: string[] = [];
  let agendaYearFiltersRaw: string[] = [];
  let agendaExcludeYearFiltersRaw: string[] = [];
  let agendaDateFiltersRaw: string[] = [];
  let agendaExcludeDateFiltersRaw: string[] = [];
  let agendaLevelFiltersRaw: string[] = [];
  let agendaExcludeLevelFiltersRaw: string[] = [];
  let agendaMatchFiltersRaw: string[] = [];
  let agendaExcludeMatchFiltersRaw: string[] = [];
  let agendaTagFiltersRaw: string[] = [];
  let agendaIdFiltersRaw: string[] = [];
  let agendaTodoFiltersRaw: string[] = [];
  let agendaTodoOrderRaw: string[] = [];
  let agendaStatusOrderRaw: string[] = [];
  let agendaKindOrderRaw: string[] = [];
  let agendaPriorityOrderRaw: string[] = [];
  let agendaTagOrderRaw: string[] = [];
  let agendaEffortOrderRaw: string[] = [];
  let agendaPriorityFiltersRaw: string[] = [];
  let agendaTimeFiltersRaw: string[] = [];
  let agendaEffortFiltersRaw: string[] = [];
  let agendaPropertyFiltersRaw: string[] = [];
  let agendaExcludeTagFiltersRaw: string[] = [];
  let agendaExcludeIdFiltersRaw: string[] = [];
  let agendaExcludeTodoFiltersRaw: string[] = [];
  let agendaExcludePriorityFiltersRaw: string[] = [];
  let agendaExcludeTimeFiltersRaw: string[] = [];
  let agendaExcludeEffortFiltersRaw: string[] = [];
  let agendaExcludePropertyFiltersRaw: string[] = [];
  let agendaFileFiltersRaw: string[] = [];
  let agendaExcludeFileFiltersRaw: string[] = [];
  let agendaSortRaw: string[] = [];
  let agendaGroupRaw: string[] = [];
  let agendaDateOrderRaw: string[] = [];
  let agendaLimitRaw = "";
  let agendaDayLimitRaw = "";
  let agendaGroupLimitRaw = "";
  let agendaFromRaw = "";
  let agendaToRaw = "";
  let verboseErrors = false;
  let help = false;

  let archiveFile = "";
  let archivePos = "";
  let archiveApply = false;
  let archiveFormat: "text" | "diff" | "json" = "text";

  // Refile workflow
  let refileFile = "";
  let refilePos = "";
  let refileToFile = "";
  let refileToPos = "";
  let refileApply = false;
  let refileFormat: "text" | "diff" | "json" = "text";

  // HTML export/publishing
  let exportAction: "html" = "html";
  let exportFile = "";
  let publishProject = "";
  let publishConfigPath = "";
  let publishPreview = false;
  let publishFormat: "text" | "json" = "text";
  let exportOut = "";
  let exportOutDir = "";
  let exportIndex = "";
  let exportIndexTitle = "";
  let exportStylesheets: string[] = [];
  let exportIncludeDefaultStyle = true;
  let exportIncludeToc: boolean | undefined = undefined;
  let exportTocDepthRaw = "";
  let exportIncludeHeadlineNumbers: boolean | undefined = undefined;
  let exportHeadlineNumberDepthRaw = "";
  let exportRewriteFileLinks = false;
  let exportApply = false;
  let exportFormat: "text" | "json" = "text";
  let exportTitle = "";

  // Todo status editing
  let todoAction: "set" | "toggle" = "toggle";
  let todoFile = "";
  let todoLine = 0;
  let todoStatus: TodoStatus | "" = "";
  let todoApply = false;
  let todoFormat: "text" | "json" | "diff" = "json";
  let todoNow = ""; // ISO string
  let todoLogbook = false;
  let todoLogbookFlagSet = false;

  // Quick capture
  let captureFile = "";
  let captureTitle = "";
  let captureTemplateRaw = "note";
  let captureTodoKeywordRaw = "TODO";
  let captureTodoKeywordFlagSet = false;
  let captureBodyRaw = "";
  let captureNow = ""; // ISO string
  let captureApply = false;
  let captureFormat: "text" | "json" | "diff" = "text";

  // Planning editing
  let planAction: "set" | "today" = "set";
  let planFile = "";
  let planLine = 0;
  let planKind: PlanningKindArg | "" = "";
  let planDate = ""; // YYYY-MM-DD
  let planApply = false;
  let planFormat: "text" | "json" | "diff" = "json";

  // Org-crypt (basic)
  let cryptAction: "encrypt" | "decrypt" = "decrypt";
  let cryptFile = "";
  let cryptLine = 0;
  let cryptPassphrase = "";
  let cryptApply = false;
  let cryptFormat: "text" | "json" | "diff" = "json";
  let cryptGpgProgram = "gpg";

  // Formatter
  let fmtStdin = false;
  let fmtApply = false;
  let fmtCheck = false;
  let fmtFormat: "text" | "json" = "text";
  let fmtConfigPath = "";
  let fmtFileFiltersRaw: string[] = [];
  let fmtExcludeFileFiltersRaw: string[] = [];

  // IDs (Roam)
  let idAction: "get" | "ensure" = "get";
  let idFile = "";
  let idLine = 0;
  let idApply = false;
  let idFormat: "text" | "json" | "diff" = "text";
  let idForced = "";

  // Backlinks (Roam)
  let backlinksId = "";
  let backlinksFormat: "text" | "json" = "text";

  // Query (Roam)
  let queryId = "";
  let queryFormat: "text" | "json" = "text";

  // Roam meta
  let roamAction: "db-sync" | "backlinks" | "node" | "link" = "db-sync";
  let roamNodeAction: "new" = "new";
  let roamLinkAction: "insert-backlink" = "insert-backlink";
  let roamFormat: "text" | "json" = "text";
  let roamApply = false;
  let roamTitle = "";
  let roamIdForced = "";
  let roamLinkFile = "";
  let roamLinkPos = "";
  let roamLinkId = "";
  let roamLinkTitle = "";
  let roamLinkStyle: "wiki" | "id" = "wiki";

  // Parse arguments
  let i = 0;
  while (i < args.length) {
    const arg = args[i];

    if (arg === "--help" || arg === "-h") {
      help = true;
      i++;
      continue;
    }

    if (arg === "agenda") {
      command = "agenda";
      i++;
    } else if (arg === "archive") {
      command = "archive";
      i++;
    } else if (arg === "refile") {
      command = "refile";
      i++;
    } else if (arg === "export") {
      command = "export";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "html") {
          exportAction = "html";
          i++;
        }
      }
    } else if (arg === "publish") {
      command = "publish";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        publishProject = args[i]!;
        i++;
      }
    } else if (arg === "lsp") {
      command = "lsp";
      i++;
    } else if (arg === "fmt" || arg === "format") {
      command = "fmt";
      i++;
    } else if (arg === "todo") {
      command = "todo";
      i++;
      // Optional subcommand: set|toggle (default toggle)
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!
        if (sub === "set" || sub === "toggle") {
          todoAction = sub;
          i++;
        }
      }
    } else if (arg === "capture") {
      command = "capture";
      i++;
    } else if (arg === "plan" || arg === "planning") {
      command = "plan";
      i++;
      // Optional subcommand: set|today (default set)
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "set" || sub === "today") {
          planAction = sub;
          i++;
        }
      }
    } else if (arg === "crypt") {
      command = "crypt";
      i++;
      // Optional subcommand: encrypt|decrypt (default decrypt)
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = String(args[i] || "").trim().toLowerCase();
        if (sub === "encrypt" || sub === "decrypt") {
          cryptAction = sub as "encrypt" | "decrypt";
          i++;
        }
      }
    } else if (arg === "id") {
      command = "id";
      i++;
      // Optional subcommand: get|ensure (default get)
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "get" || sub === "ensure") {
          idAction = sub;
          i++;
        }
      }
    } else if (arg === "backlinks") {
      command = "backlinks";
      i++;
    } else if (arg === "query") {
      command = "query";
      i++;
    } else if (arg === "roam") {
      command = "roam";
      i++;
      // Optional subcommands:
      // - db-sync (default)
      // - node new
      // - link insert-backlink
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "db-sync") {
          roamAction = "db-sync";
          i++;
        } else if (sub === "backlinks") {
          roamAction = "backlinks";
          i++;
        } else if (sub === "node") {
          roamAction = "node";
          i++;
          if (i < args.length && !args[i]!.startsWith("--")) {
            const sub2 = args[i]!;
            if (sub2 === "new") {
              roamNodeAction = "new";
              i++;
            }
          }
        } else if (sub === "link") {
          roamAction = "link";
          i++;
          if (i < args.length && !args[i]!.startsWith("--")) {
            const sub2 = args[i]!;
            if (sub2 === "insert-backlink") {
              roamLinkAction = "insert-backlink";
              i++;
            }
          }
        }
      }
    } else if (arg === "--dir") {
      i++;
      if (i < args.length) {
        dir = args[i];
        i++;
      }
    } else if (arg === "--files") {
      i++;
      // Collect all following non-flag arguments as files
      while (i < args.length && !args[i].startsWith("--")) {
        files.push(args[i]);
        i++;
      }
    } else if (arg === "--file") {
      i++;
      if (i < args.length) {
        if (command === "todo") {
          todoFile = args[i]!;
        } else if (command === "capture") {
          captureFile = args[i]!;
        } else if (command === "plan") {
          planFile = args[i]!;
        } else if (command === "crypt") {
          cryptFile = args[i]!;
        } else if (command === "id") {
          idFile = args[i]!;
        } else if (command === "refile") {
          refileFile = args[i]!;
        } else if (command === "export") {
          exportFile = args[i]!;
        } else if (command === "roam" && roamAction === "link") {
          roamLinkFile = args[i]!;
        } else {
          files.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--line") {
      i++;
      if (i < args.length) {
        const n = parseInt(args[i]!, 10);
        if (command === "todo") {
          todoLine = n;
        } else if (command === "plan") {
          planLine = n;
        } else if (command === "crypt") {
          cryptLine = n;
        } else if (command === "id") {
          idLine = n;
        }
        i++;
      }
    } else if (arg === "--status") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaStatusFiltersRaw.push(args[i]!);
        } else {
          todoStatus = parseTodoStatusArg(args[i] ?? "");
        }
        i++;
      }
    } else if (arg === "--exclude-status") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeStatusFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--now") {
      i++;
      if (i < args.length) {
        if (command === "capture") {
          captureNow = args[i]!;
        } else {
          todoNow = args[i]!;
        }
        i++;
      }
    } else if (arg === "--logbook") {
      if (command === "todo") {
        todoLogbook = true;
        todoLogbookFlagSet = true;
      }
      i++;
    } else if (arg === "--days") {
      i++;
      if (i < args.length) {
        days = parseInt(args[i], 10);
        if (isNaN(days) || days < 1) {
          days = 1;
        }
        i++;
      }
    } else if (arg === "--today") {
      i++;
      if (i < args.length) {
        today = args[i];
        i++;
      }
    } else if (arg === "--from") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaFromRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--to") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaToRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--kind") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaKindFiltersRaw.push(args[i]!);
        } else {
          planKind = args[i] as PlanningKindArg;
        }
        i++;
      }
    } else if (arg === "--exclude-kind") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeKindFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--when") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaWhenFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-when") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeWhenFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--weekday") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaWeekdayFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-weekday") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeWeekdayFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--week") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaWeekFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-week") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeWeekFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--day-of-month") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaDayOfMonthFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-day-of-month") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeDayOfMonthFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--month") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaMonthFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-month") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeMonthFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--quarter") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaQuarterFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-quarter") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeQuarterFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--year") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaYearFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-year") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeYearFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--level") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaLevelFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-level") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeLevelFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--match") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaMatchFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-match") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeMatchFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--tag") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaTagFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--todo") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaTodoFiltersRaw.push(args[i]!);
        } else if (command === "capture") {
          captureTodoKeywordRaw = args[i]!;
          captureTodoKeywordFlagSet = true;
        }
        i++;
      }
    } else if (arg === "--todo-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaTodoOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--status-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaStatusOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--kind-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaKindOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--priority-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaPriorityOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--tag-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaTagOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--effort-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaEffortOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--priority") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaPriorityFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--time") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaTimeFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--effort") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaEffortFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--property") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaPropertyFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-tag") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeTagFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-id") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeIdFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-todo") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeTodoFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-priority") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludePriorityFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-time") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeTimeFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-effort") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeEffortFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-property") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludePropertyFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--file-match") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaFileFiltersRaw.push(args[i]!);
        } else if (command === "fmt") {
          fmtFileFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-file") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeFileFiltersRaw.push(args[i]!);
        } else if (command === "fmt") {
          fmtExcludeFileFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--config") {
      i++;
      if (i < args.length) {
        if (command === "fmt") {
          fmtConfigPath = args[i]!;
        } else if (command === "publish") {
          publishConfigPath = args[i]!;
        }
        i++;
      }
    } else if (arg === "--sort") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaSortRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--group") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaGroupRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--date-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaDateOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--limit") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaLimitRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--day-limit") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaDayLimitRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--group-limit") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaGroupLimitRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--date") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaDateFiltersRaw.push(args[i]!);
        } else {
          planDate = args[i]!;
        }
        i++;
      }
    } else if (arg === "--exclude-date") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeDateFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--template") {
      i++;
      if (i < args.length) {
        if (command === "capture") {
          captureTemplateRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--title") {
      i++;
      if (i < args.length) {
        if (command === "roam") {
          if (roamAction === "link") {
            roamLinkTitle = args[i]!;
          } else {
            roamTitle = args[i]!;
          }
        } else if (command === "capture") {
          captureTitle = args[i]!;
        } else if (command === "export") {
          exportTitle = args[i]!;
        }
        i++;
      }
    } else if (arg === "--body") {
      i++;
      if (i < args.length) {
        if (command === "capture") {
          captureBodyRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--passphrase") {
      i++;
      if (i < args.length) {
        if (command === "crypt") {
          cryptPassphrase = args[i]!;
        }
        i++;
      }
    } else if (arg === "--gpg-program") {
      i++;
      if (i < args.length) {
        if (command === "crypt") {
          cryptGpgProgram = args[i]!;
        }
        i++;
      }
    } else if (arg === "--id") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaIdFiltersRaw.push(args[i]!);
        } else if (command === "id") {
          idForced = args[i]!;
        } else if (command === "backlinks") {
          backlinksId = args[i]!;
        } else if (command === "query") {
          queryId = args[i]!;
        } else if (command === "roam") {
          if (roamAction === "link") {
            roamLinkId = args[i]!;
          } else if (roamAction === "backlinks") {
            backlinksId = args[i]!;
          } else {
            roamIdForced = args[i]!;
          }
        }
        i++;
      }
    } else if (arg === "--format") {
      i++;
      if (i < args.length) {
        const v = args[i];
        if (command === "archive" && (v === "text" || v === "diff" || v === "json")) {
          archiveFormat = v as "text" | "diff" | "json";
        } else if (command === "refile" && (v === "text" || v === "diff" || v === "json")) {
          refileFormat = v as "text" | "diff" | "json";
        } else if (command === "export" && (v === "text" || v === "json")) {
          exportFormat = v;
        } else if (command === "publish" && (v === "text" || v === "json")) {
          publishFormat = v;
        } else if (command === "agenda" && (v === "text" || v === "json")) {
          format = v;
        } else if (command === "todo" && (v === "text" || v === "json" || v === "diff")) {
          todoFormat = v as "text" | "json" | "diff";
        } else if (command === "capture" && (v === "text" || v === "json" || v === "diff")) {
          captureFormat = v as "text" | "json" | "diff";
        } else if (command === "plan" && (v === "text" || v === "json" || v === "diff")) {
          planFormat = v as "text" | "json" | "diff";
        } else if (command === "crypt" && (v === "text" || v === "json" || v === "diff")) {
          cryptFormat = v as "text" | "json" | "diff";
        } else if (command === "fmt" && (v === "text" || v === "json")) {
          fmtFormat = v;
        } else if (command === "id" && (v === "text" || v === "json" || v === "diff")) {
          idFormat = v;
        } else if (command === "backlinks" && (v === "text" || v === "json")) {
          backlinksFormat = v;
        } else if (command === "query" && (v === "text" || v === "json")) {
          queryFormat = v;
        } else if (
          command === "roam" &&
          roamAction === "backlinks" &&
          (v === "text" || v === "json")
        ) {
          backlinksFormat = v;
        } else if (command === "roam" && (v === "text" || v === "json")) {
          roamFormat = v;
        }
        i++;
      }
    } else if (arg === "--style" || arg === "--link-style") {
      i++;
      if (i < args.length) {
        const v = String(args[i] || "").trim().toLowerCase();
        if (command === "roam" && roamAction === "link" && (v === "wiki" || v === "id")) {
          roamLinkStyle = v;
        }
        i++;
      }
    } else if (arg === "--recursive") {
      recursive = true;
      i++;
    } else if (arg === "--no-overdue") {
      includeOverdue = false;
      i++;
    } else if (arg === "--overdue") {
      includeOverdue = true;
      i++;
    } else if (arg === "--project") {
      i++;
      if (i < args.length) {
        if (command === "publish") {
          publishProject = args[i]!;
        }
        i++;
      }
    } else if (arg === "--preview") {
      if (command === "publish") {
        publishPreview = true;
      }
      i++;
    } else if (arg === "--out" || arg === "--output") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportOut = args[i]!;
        }
        i++;
      }
    } else if (arg === "--out-dir") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportOutDir = args[i]!;
        }
        i++;
      }
    } else if (arg === "--index") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportIndex = args[i]!;
        }
        i++;
      }
    } else if (arg === "--index-title") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportIndexTitle = args[i]!;
        }
        i++;
      }
    } else if (arg === "--css") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          const cssValues = String(args[i] || "")
            .split(",")
            .map((value) => value.trim())
            .filter((value) => value.length > 0);
          exportStylesheets.push(...cssValues);
        }
        i++;
      }
    } else if (arg === "--no-default-style") {
      if (command === "export") {
        exportIncludeDefaultStyle = false;
      }
      i++;
    } else if (arg === "--toc") {
      if (command === "export") {
        exportIncludeToc = true;
      }
      i++;
    } else if (arg === "--toc-depth") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportTocDepthRaw = String(args[i] || "");
          exportIncludeToc = true;
        }
        i++;
      }
    } else if (arg === "--number-headings") {
      if (command === "export") {
        exportIncludeHeadlineNumbers = true;
      }
      i++;
    } else if (arg === "--number-headings-depth") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportHeadlineNumberDepthRaw = String(args[i] || "");
          exportIncludeHeadlineNumbers = true;
        }
        i++;
      }
    } else if (arg === "--rewrite-file-links") {
      if (command === "export") {
        exportRewriteFileLinks = true;
      }
      i++;
    } else if (arg === "--archive-file") {
      i++;
      if (i < args.length) {
        archiveFile = args[i];
        i++;
      }
    } else if (arg === "--to-file") {
      i++;
      if (i < args.length) {
        if (command === "refile") {
          refileToFile = args[i]!;
        }
        i++;
      }
    } else if (arg === "--to-pos") {
      i++;
      if (i < args.length) {
        if (command === "refile") {
          refileToPos = args[i]!;
        }
        i++;
      }
    } else if (arg === "--pos") {
      i++;
      if (i < args.length) {
        const rawPos = args[i]!;
        // For editor integrations it's convenient to pass LINE[:COL].
        // - archive uses the full string
        // - todo/plan/id only use the line component
        if (command === "archive") {
          archivePos = rawPos;
        } else if (command === "refile") {
          refilePos = rawPos;
        } else if (command === "todo") {
          todoLine = parseInt(rawPos.split(":")[0]!, 10);
        } else if (command === "plan") {
          planLine = parseInt(rawPos.split(":")[0]!, 10);
        } else if (command === "crypt") {
          cryptLine = parseInt(rawPos.split(":")[0]!, 10);
        } else if (command === "id") {
          idLine = parseInt(rawPos.split(":")[0]!, 10);
        } else if (command === "roam" && roamAction === "link") {
          roamLinkPos = rawPos;
        }
        i++;
      }
    } else if (arg === "--stdin") {
      fmtStdin = true;
      i++;
    } else if (arg === "--check") {
      if (command === "fmt") {
        fmtCheck = true;
      }
      i++;
    } else if (arg === "--apply" || arg === "--in-place") {
      if (command === "todo") {
        todoApply = true;
      } else if (command === "capture") {
        captureApply = true;
      } else if (command === "plan") {
        planApply = true;
      } else if (command === "crypt") {
        cryptApply = true;
      } else if (command === "archive") {
        archiveApply = true;
      } else if (command === "refile") {
        refileApply = true;
      } else if (command === "export") {
        exportApply = true;
      } else if (command === "fmt") {
        fmtApply = true;
      } else if (command === "id") {
        idApply = true;
      } else if (command === "roam") {
        roamApply = true;
      }
      i++;
    } else if (arg === "--verbose" || arg === "--verbose-errors") {
      verboseErrors = true;
      i++;
    } else {
      i++;
    }
  }


function printGeneralUsage(exitCode: number): never {
  console.error(`org2 CLI

Usage:
  org2 <command> [options]

Core commands:
  org2 agenda --dir DIR [--recursive] [--from YYYY-MM-DD] [--to YYYY-MM-DD]
  org2 todo <set|toggle> --file FILE (--line N | --pos LINE[:COL]) [--apply]
  org2 plan <set|today> --file FILE (--line N | --pos LINE[:COL]) [--apply]
  org2 crypt <encrypt|decrypt> --file FILE (--line N | --pos LINE[:COL]) --passphrase PASS [--gpg-program PATH] [--apply]
  org2 capture --file FILE --title TITLE [--template note|task] [--apply]
  org2 archive --file FILE --pos LINE[:COL] [--archive-file FILE] [--apply]
  org2 refile --file FILE --pos LINE[:COL] --to-file FILE [--to-pos LINE[:COL]] [--apply]

Export / publish:
  org2 export html --file FILE [--out FILE] [--apply]
  org2 export html --dir DIR [--recursive] [--out-dir DIR] [--index FILE] [--apply]
  org2 publish [PROJECT] [--config PATH] [--preview]

Roam / IDs:
  org2 id <get|ensure> --file FILE [--line N|--pos LINE[:COL]] [--apply]
  org2 backlinks --id UUID [--dir DIR] [--recursive]
  org2 query --id UUID [--dir DIR] [--recursive]
  org2 roam db-sync --dir DIR [--recursive] [--apply]
  org2 roam node new --dir DIR --title TITLE [--id UUID] [--apply]
  org2 roam link insert-backlink --file FILE --pos LINE[:COL] --title TITLE [--style wiki|id] [--id UUID] [--apply]

Other:
  org2 fmt [--stdin] [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--check] [--apply]
  org2 lsp

Tips:
  - Use --help with subcommands for detailed flags (e.g., org2 agenda --help).
  - Use --format json for scriptable output where supported.`);
  process.exit(exitCode);
}

  if (help) {
    printGeneralUsage(0);
  }

  if (command !== "agenda" && command !== "archive" && command !== "refile" && command !== "export" && command !== "publish" && command !== "todo" && command !== "capture" && command !== "plan" && command !== "crypt" && command !== "fmt" && command !== "lsp" && command !== "id" && command !== "backlinks" && command !== "query" && command !== "roam") {
    printGeneralUsage(1);
  }

  if (command === "lsp") {
    // The LSP server runs over stdio and expects to own stdin/stdout.
    // Importing this module starts the server.
    await import("./lsp.js");
    return;
  }

  // Treat `org2 roam backlinks ...` as a namespaced alias for `org2 backlinks ...`.
  // This lets editor integrations stay under `roam` while sharing the same implementation.
  if (command === "roam" && roamAction === "backlinks") {
    command = "backlinks";
  }

  if (command === "roam") {
    if (roamAction !== "link" && !dir) {
      console.error("Error: org2 roam requires --dir DIR");
      process.exit(1);
    }

    if (roamAction === "link") {
      if (roamLinkAction !== "insert-backlink") {
        console.error("Error: org2 roam link requires a subcommand (insert-backlink)");
        process.exit(1);
      }
      if (!roamLinkFile) {
        console.error("Error: org2 roam link insert-backlink requires --file FILE");
        process.exit(1);
      }
      if (!roamLinkPos) {
        console.error("Error: org2 roam link insert-backlink requires --pos LINE[:COL]");
        process.exit(1);
      }
      if (!roamLinkTitle) {
        console.error("Error: org2 roam link insert-backlink requires --title TITLE");
        process.exit(1);
      }
      if (roamLinkStyle === "id" && !roamLinkId) {
        console.error("Error: org2 roam link insert-backlink with --style id requires --id UUID");
        process.exit(1);
      }

      const raw = fs.readFileSync(roamLinkFile, "utf8").replace(/\r\n/g, "\n");
      const [lineRaw, colRaw] = roamLinkPos.split(":");
      const line1 = parseInt(lineRaw, 10);
      if (!Number.isFinite(line1) || line1 < 1) {
        console.error(`Error: invalid --pos ${roamLinkPos}`);
        process.exit(1);
      }
      let col: number | null = null;
      if (colRaw !== undefined) {
        const c = parseInt(colRaw, 10);
        if (!Number.isFinite(c) || c < 0) {
          console.error(`Error: invalid --pos ${roamLinkPos}`);
          process.exit(1);
        }
        col = c;
      }

      const lines = raw.split("\n");
      const lineIndex = line1 - 1;
      if (lineIndex >= lines.length) {
        console.error(`Error: --pos line out of range: ${roamLinkPos}`);
        process.exit(1);
      }

      const lineText = lines[lineIndex] ?? "";
      const linkText = roamLinkStyle === "id" ? `[[id:${roamLinkId}][${roamLinkTitle}]]` : `[[${roamLinkTitle}]]`;
      const insertCol = col === null ? lineText.length : Math.min(col, lineText.length);
      lines[lineIndex] = lineText.slice(0, insertCol) + linkText + lineText.slice(insertCol);

      const outText = lines.join("\n");
      const changed = outText !== raw;

      if (roamApply) {
        fs.writeFileSync(roamLinkFile, outText, "utf8");
      }

      if (roamFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              action: "link-insert-backlink",
              file: roamLinkFile,
              id: roamLinkId || null,
              title: roamLinkTitle,
              style: roamLinkStyle,
              link: linkText,
              pos: roamLinkPos,
              applied: roamApply,
              changed,
            },
            null,
            2,
          ) + "\n",
        );
      } else {
        process.stdout.write(outText + (outText.endsWith("\n") ? "" : "\n"));
      }

      return;
    }

    if (roamAction === "node") {
      if (roamNodeAction !== "new") {
        console.error("Error: org2 roam node requires a subcommand (new)");
        process.exit(1);
      }

      if (!roamTitle) {
        console.error("Error: org2 roam node new requires --title TITLE");
        process.exit(1);
      }

      const slugify = (s: string): string => {
        return s
          .trim()
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, "-")
          .replace(/^-+/, "")
          .replace(/-+$/, "")
          .replace(/-+/g, "-")
          .slice(0, 80);
      };

      const slug = slugify(roamTitle) || "node";
      const filePath = path.join(dir, `${slug}.org2`);
      const newId = roamIdForced || crypto.randomUUID();

      const content = `#+TITLE: ${roamTitle}\n\n:PROPERTIES:\n:ID: ${newId}\n:END:\n\n`;

      if (roamApply) {
        // Make this command idempotent so it can be safely re-run.
        // If the file exists and already matches, treat as success.
        if (fs.existsSync(filePath)) {
          const existing = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n");
          if (existing !== content) {
            console.error(`Error: file already exists with different contents: ${filePath}`);
            process.exit(1);
          }
        } else {
          fs.mkdirSync(dir, { recursive: true });
          fs.writeFileSync(filePath, content, "utf8");
        }
      } else {
        console.error("Error: org2 roam node new is mutating; pass --apply to write the file");
        process.exit(1);
      }

      if (roamFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              action: "node-new",
              dir,
              title: roamTitle,
              file: filePath,
              id: newId,
              applied: true,
            },
            null,
            2,
          ) + "\n",
        );
      } else {
        process.stdout.write(filePath + "\n");
      }

      return;
    }

    const hasFileId = (text: string): boolean => {
      const norm = text.replace(/\r\n/g, "\n");
      const top = norm.split("\n").slice(0, 80);

      // Accept a #+id keyword anywhere near the top (read-only compat).
      for (const l of top) {
        if (/^#\+id:\s*\S+/i.test(l.trim())) return true;
      }

      let i = 0;
      while (i < top.length && (top[i] ?? "").trim() === "") i += 1;
      if ((top[i] ?? "").trim() !== ":PROPERTIES:") return false;

      for (let j = i + 1; j < top.length; j += 1) {
        const l = (top[j] ?? "").trim();
        if (l === ":END:") break;
        if (/^:ID:\s*\S+/.test(l)) return true;
      }

      return false;
    };

    const allFiles = listOrgLikeFiles(dir, recursive);
    const missing: string[] = [];

    for (const filePath of allFiles) {
      try {
        const raw = fs.readFileSync(filePath, "utf8");
        if (!hasFileId(raw)) missing.push(filePath);
      } catch {
        // ignore unreadable
      }
    }

    let applied = 0;
    if (roamApply) {
      for (const filePath of missing) {
        try {
          const raw = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n");
          // Double-check before mutating.
          if (hasFileId(raw)) continue;

          const newId = crypto.randomUUID();
          const header = `:PROPERTIES:\n:ID: ${newId}\n:END:\n\n`;
          const out = header + raw.replace(/^\n+/, "");
          fs.writeFileSync(filePath, out, "utf8");
          applied += 1;
        } catch {
          // ignore write errors
        }
      }
    }

    if (roamFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            action: "db-sync",
            dir,
            recursive,
            scanned: allFiles.length,
            missingFileIdCount: missing.length,
            missingFileIds: missing,
            applied: roamApply,
            appliedCount: applied,
          },
          null,
          2
        ) + "\n"
      );
    } else {
      for (const filePath of missing) {
        process.stdout.write(filePath + "\n");
      }
      console.error(
        `org2 roam db-sync: scanned ${allFiles.length} file(s); ${missing.length} missing file-level IDs` +
          (roamApply ? `; applied IDs to ${applied} file(s)` : "")
      );
    }

    return;
  }

  if (command === "publish") {
    const configPathResolved = publishConfigPath.trim().length > 0
      ? path.resolve(publishConfigPath.trim())
      : findConfigFile(process.cwd());
    if (!configPathResolved) {
      console.error("Error: publish requires an org2.json config (pass --config PATH or run from a configured directory)");
      process.exit(1);
    }

    let project: Org2PublishProjectConfig | null = null;
    let projectNames: string[] = [];
    let configLinkAbbreviations: Record<string, string> | undefined;
    let configLinearTeam: string | undefined;
    try {
      const cfg = loadConfig(configPathResolved);
      configLinkAbbreviations = cfg.links?.abbreviations;
      configLinearTeam = cfg.links?.linearTeam;
      const projects = cfg.publish?.projects || {};
      projectNames = Object.keys(projects).sort((a, b) => a.localeCompare(b));
      if (!publishProject) {
        if (projectNames.length === 1) publishProject = projectNames[0]!;
        else {
          console.error(`Error: publish requires a project name${projectNames.length > 0 ? ` (available: ${projectNames.join(", ")})` : ""}`);
          process.exit(1);
        }
      }
      project = projects[publishProject] || null;
    } catch (err) {
      console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
      process.exit(1);
    }

    if (!project) {
      console.error(`Error: publish project \"${publishProject}\" not found in ${configPathResolved}${projectNames.length > 0 ? ` (available: ${projectNames.join(", ")})` : ""}`);
      process.exit(1);
    }

    const sourceDirValue = String(project.baseDir || "").trim();
    const outDirValue = String(project.outDir || "").trim();
    if (!sourceDirValue) {
      console.error(`Error: publish project \"${publishProject}\" is missing required field: baseDir`);
      process.exit(1);
    }
    if (!outDirValue) {
      console.error(`Error: publish project \"${publishProject}\" is missing required field: outDir`);
      process.exit(1);
    }

    const configDir = path.dirname(configPathResolved);
    const sourceDir = path.resolve(configDir, sourceDirValue);
    const outputRoot = path.resolve(configDir, outDirValue);
    const sourceDirInput = path.relative(process.cwd(), sourceDir) || sourceDir;
    const outputRootInput = path.relative(process.cwd(), outputRoot) || outputRoot;

    const includePatterns = Array.isArray(project.include) && project.include.length > 0 ? project.include : ["*.org", "*.org2"];
    const ignorePatterns = Array.isArray(project.ignore) ? project.ignore : [];
    const publishRecursive = project.recursive !== false;
    const sourceFiles = resolveFilesFromDir(sourceDir, includePatterns, ignorePatterns, publishRecursive).sort((a, b) => a.localeCompare(b));

    const toDisplayPath = (absolutePath: string): string => {
      const relative = path.relative(process.cwd(), absolutePath);
      if (!relative || (!relative.startsWith("..") && !path.isAbsolute(relative))) {
        return relative || path.basename(absolutePath);
      }
      return absolutePath;
    };

    const resolvedHeadIncludes = resolvePublishHeadIncludes(project);
    const ogBaseUrlRaw = String(project.sitemapXml?.baseUrl || "").trim();
    const ogBaseUrl = ogBaseUrlRaw ? ogBaseUrlRaw.replace(/\/$/, "") : "";
    const escapeHeadAttr = (value: string): string =>
      String(value || "")
        .replace(/&/g, "&amp;")
        .replace(/"/g, "&quot;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");

    const exported: Array<{ sourcePath: string; outputPath: string; outputPathAbsolute: string; title: string; changed: boolean; metadata?: ExportMetadataPayload; }> = [];
    for (const sourcePath of sourceFiles) {
      const sourceRaw = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
      const sourceAst = parseOrgToCanonicalAst(sourceRaw);

      const relativeSourcePath = path.relative(sourceDir, sourcePath);
      const outputRelativePath = /\.(org|org2)$/i.test(relativeSourcePath)
        ? relativeSourcePath.replace(/\.(org|org2)$/i, ".html")
        : `${relativeSourcePath}.html`;

      const outputPathAbsolute = path.resolve(outputRoot, outputRelativePath);
      const outputPathDisplay = path.join(outputRootInput, outputRelativePath);
      const outputRelativePathPosix = outputRelativePath.split(path.sep).join("/");

      const firstPass = renderOrgDocumentToHtml(sourceAst, {
        sourcePath: toDisplayPath(sourcePath),
        stylesheets: project.stylesheets,
        includeDefaultStyle: project.includeDefaultStyle,
        includeToc: project.toc,
        includeTocDepth: project.tocDepth,
        includeHeadlineNumbers: project.numberHeadings,
        includeHeadlineNumberDepth: project.numberHeadingsDepth,
        rewriteFileLinks: project.rewriteFileLinks,
        preambleHtml: project.preambleHtml,
        postambleHtml: project.postambleHtml,
        headIncludes: resolvedHeadIncludes,
        includeDocumentHeader: true,
        compatContentWrapper: true,
        linkAbbreviations: configLinkAbbreviations,
        linearTeam: configLinearTeam,
      });

      const ogSlug = outputRelativePathPosix
        .replace(/^\//, "")
        .replace(/\.html$/i, "")
        .replace(/\//g, "-") || "index";
      const ogRelPath = `assets/og/${ogSlug}.svg`;
      const ogAbsPath = path.resolve(outputRoot, ogRelPath);
      const ogTitle = firstPass.title;
      const ogSubtitle = String(firstPass.metadata?.subtitle || "").trim();
      const ogDescRaw = String(firstPass.metadata?.description || firstPass.metadata?.subtitle || firstPass.title || "Org2 docs").trim();
      const ogDesc = ogDescRaw.length > 220 ? `${ogDescRaw.slice(0, 217)}...` : ogDescRaw;

      const ogSvg = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">',
        '  <defs>',
        '    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">',
        '      <stop offset="0%" stop-color="#0b1020" />',
        '      <stop offset="100%" stop-color="#111827" />',
        '    </linearGradient>',
        '  </defs>',
        '  <rect width="1200" height="630" fill="url(#bg)"/>',
        '  <circle cx="1120" cy="88" r="190" fill="#1f2937" opacity="0.45"/>',
        '  <text x="80" y="110" font-family="Inter,Segoe UI,Arial,sans-serif" font-size="42" font-weight="700" fill="#5eead4">Org2</text>',
        `  <text x="80" y="250" font-family="Inter,Segoe UI,Arial,sans-serif" font-size="64" font-weight="700" fill="#e5e7eb">${escapeHeadAttr(ogTitle)}</text>`,
        ogSubtitle
          ? `  <text x="80" y="320" font-family="Inter,Segoe UI,Arial,sans-serif" font-size="34" fill="#9ca3af">${escapeHeadAttr(ogSubtitle)}</text>`
          : "",
        `  <text x="80" y="560" font-family="Inter,Segoe UI,Arial,sans-serif" font-size="28" fill="#9ca3af">${escapeHeadAttr(ogDesc)}</text>`,
        '</svg>',
        '',
      ].filter(Boolean).join("\n");

      const existingOg = fs.existsSync(ogAbsPath)
        ? fs.readFileSync(ogAbsPath, "utf8").replace(/\r\n/g, "\n")
        : "";
      if (!publishPreview && existingOg !== ogSvg) {
        fs.mkdirSync(path.dirname(ogAbsPath), { recursive: true });
        fs.writeFileSync(ogAbsPath, ogSvg, "utf8");
      }

      const pageUrl = ogBaseUrl ? `${ogBaseUrl}/${outputRelativePathPosix}` : "";
      const ogImageUrl = ogBaseUrl ? `${ogBaseUrl}/${ogRelPath}` : ogRelPath;
      const ogHeadIncludes = [
        '<meta property="og:type" content="website" />',
        `<meta property="og:title" content="${escapeHeadAttr(ogTitle)}" />`,
        `<meta property="og:description" content="${escapeHeadAttr(ogDesc)}" />`,
        pageUrl ? `<meta property="og:url" content="${escapeHeadAttr(pageUrl)}" />` : "",
        `<meta property="og:image" content="${escapeHeadAttr(ogImageUrl)}" />`,
        '<meta name="twitter:card" content="summary_large_image" />',
        `<meta name="twitter:title" content="${escapeHeadAttr(ogTitle)}" />`,
        `<meta name="twitter:description" content="${escapeHeadAttr(ogDesc)}" />`,
        `<meta name="twitter:image" content="${escapeHeadAttr(ogImageUrl)}" />`,
      ].filter((item) => String(item || "").trim().length > 0);

      const rendered = renderOrgDocumentToHtml(sourceAst, {
        sourcePath: toDisplayPath(sourcePath),
        stylesheets: project.stylesheets,
        includeDefaultStyle: project.includeDefaultStyle,
        includeToc: project.toc,
        includeTocDepth: project.tocDepth,
        includeHeadlineNumbers: project.numberHeadings,
        includeHeadlineNumberDepth: project.numberHeadingsDepth,
        rewriteFileLinks: project.rewriteFileLinks,
        preambleHtml: project.preambleHtml,
        postambleHtml: project.postambleHtml,
        headIncludes: [...resolvedHeadIncludes, ...ogHeadIncludes],
        includeDocumentHeader: true,
        compatContentWrapper: true,
        linkAbbreviations: configLinkAbbreviations,
        linearTeam: configLinearTeam,
      });

      const existingOutput = fs.existsSync(outputPathAbsolute)
        ? fs.readFileSync(outputPathAbsolute, "utf8").replace(/\r\n/g, "\n")
        : "";
      const changed = existingOutput !== rendered.html;

      if (!publishPreview) {
        fs.mkdirSync(path.dirname(outputPathAbsolute), { recursive: true });
        fs.writeFileSync(outputPathAbsolute, rendered.html, "utf8");
      }

      exported.push({
        sourcePath: toDisplayPath(sourcePath),
        outputPath: outputPathDisplay,
        outputPathAbsolute,
        title: rendered.title,
        changed,
        ...(hasExportMetadata(rendered.metadata) ? { metadata: rendered.metadata } : {}),
      });
    }

    const exportedForOutput = exported.map(({ sourcePath, outputPath, title, changed, metadata }) => ({
      sourcePath,
      outputPath,
      title,
      changed,
      ...(hasExportMetadata(metadata) ? { metadata } : {}),
    }));

    let indexOutput: { outputPath: string; title: string; changed: boolean } | null = null;
    let sitemapXmlOutput: { outputPath: string; urlCount: number; changed: boolean } | null = null;
    let indexPathRaw = "";
    let indexTitleRaw = "";
    if (typeof project.index === "string") indexPathRaw = project.index;
    else if (project.index && typeof project.index === "object") {
      indexPathRaw = String(project.index.file || "").trim();
      indexTitleRaw = String(project.index.title || "").trim();
    }

    if (indexPathRaw) {
      const indexPathAbsolute = path.isAbsolute(indexPathRaw) ? path.resolve(indexPathRaw) : path.resolve(outputRoot, indexPathRaw);
      const indexPathDisplay = path.isAbsolute(indexPathRaw) ? toDisplayPath(indexPathAbsolute) : path.join(outputRootInput, indexPathRaw);
      const indexRendered = renderOrgExportIndexToHtml({
        title: indexTitleRaw || undefined,
        sourcePath: indexPathRaw,
        stylesheets: project.stylesheets,
        includeDefaultStyle: project.includeDefaultStyle,
        items: exported.map((item) => {
          const hrefRaw = path.relative(path.dirname(indexPathAbsolute), item.outputPathAbsolute);
          const href = String(hrefRaw || path.basename(item.outputPathAbsolute)).split(path.sep).join("/");
          return { title: item.title, href };
        }),
      });

      const existingIndex = fs.existsSync(indexPathAbsolute)
        ? fs.readFileSync(indexPathAbsolute, "utf8").replace(/\r\n/g, "\n")
        : "";
      const indexChanged = existingIndex !== indexRendered.html;

      if (!publishPreview) {
        fs.mkdirSync(path.dirname(indexPathAbsolute), { recursive: true });
        fs.writeFileSync(indexPathAbsolute, indexRendered.html, "utf8");
      }

      indexOutput = { outputPath: indexPathDisplay, title: indexRendered.title, changed: indexChanged };
    }

    if (project.sitemapXml) {
      const baseUrlRaw = String(project.sitemapXml.baseUrl || "").trim();
      if (!baseUrlRaw) {
        console.error(`Error: publish project "${publishProject}" sitemapXml.baseUrl is required when sitemapXml is configured`);
        process.exit(1);
      }

      const baseUrl = baseUrlRaw.replace(/\/$/, "");
      const sitemapFileRaw = String(project.sitemapXml.file || "sitemap.xml").trim() || "sitemap.xml";
      const sitemapPathAbsolute = path.isAbsolute(sitemapFileRaw)
        ? path.resolve(sitemapFileRaw)
        : path.resolve(outputRoot, sitemapFileRaw);
      const sitemapPathDisplay = path.isAbsolute(sitemapFileRaw)
        ? toDisplayPath(sitemapPathAbsolute)
        : path.join(outputRootInput, sitemapFileRaw);

      const includeIndexPage = project.sitemapXml.includeIndexPage !== false;
      const urlEntries: string[] = [];
      if (includeIndexPage) {
        urlEntries.push(`${baseUrl}/`);
      }
      for (const item of exported) {
        const rel = path.relative(outputRoot, item.outputPathAbsolute).split(path.sep).join("/");
        const relWithoutDot = rel.startsWith("./") ? rel.slice(2) : rel;
        if (includeIndexPage && relWithoutDot === "index.html") continue;
        urlEntries.push(`${baseUrl}/${relWithoutDot}`);
      }

      const uniqueUrls = Array.from(new Set(urlEntries));
      const sitemapXml = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
        ...uniqueUrls.map((url) => {
          const escapedUrl = url
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/\"/g, "&quot;")
            .replace(/'/g, "&#39;");
          return `  <url>\n    <loc>${escapedUrl}</loc>\n  </url>`;
        }),
        '</urlset>',
        '',
      ].join("\n");

      const existingSitemap = fs.existsSync(sitemapPathAbsolute)
        ? fs.readFileSync(sitemapPathAbsolute, "utf8").replace(/\r\n/g, "\n")
        : "";
      const sitemapChanged = existingSitemap !== sitemapXml;

      if (!publishPreview) {
        fs.mkdirSync(path.dirname(sitemapPathAbsolute), { recursive: true });
        fs.writeFileSync(sitemapPathAbsolute, sitemapXml, "utf8");
      }

      sitemapXmlOutput = { outputPath: sitemapPathDisplay, urlCount: uniqueUrls.length, changed: sitemapChanged };
    }

    const copiedAssets: Array<{ sourcePath: string; outputPath: string; changed: boolean }> = [];
    const assetIncludePatterns = Array.isArray(project.assets?.include)
      ? project.assets!.include.map((pattern) => String(pattern || "").trim()).filter((pattern) => pattern.length > 0)
      : [];

    if (assetIncludePatterns.length > 0) {
      const orgSet = new Set(sourceFiles.map((file) => path.resolve(file)));
      const baseIgnore = Array.isArray(project.ignore)
        ? project.ignore.map((pattern) => String(pattern || "").trim()).filter((pattern) => pattern.length > 0)
        : [];
      const assetIgnore = Array.isArray(project.assets?.ignore)
        ? project.assets!.ignore.map((pattern) => String(pattern || "").trim()).filter((pattern) => pattern.length > 0)
        : [];
      const mergedIgnore = Array.from(new Set([...baseIgnore, ...assetIgnore]));

      const assetFiles = resolveFilesFromDir(sourceDir, assetIncludePatterns, mergedIgnore, publishRecursive)
        .map((file) => path.resolve(file))
        .filter((file) => !orgSet.has(file));

      for (const assetPath of assetFiles) {
        const relativeAssetPath = path.relative(sourceDir, assetPath);
        if (!relativeAssetPath || relativeAssetPath.startsWith("..")) continue;
        const outputAssetPathAbsolute = path.resolve(outputRoot, relativeAssetPath);
        const outputAssetPathDisplay = path.join(outputRootInput, relativeAssetPath);
        const assetBuffer = fs.readFileSync(assetPath);
        const existingAssetBuffer = fs.existsSync(outputAssetPathAbsolute) ? fs.readFileSync(outputAssetPathAbsolute) : null;
        const changed = !existingAssetBuffer || !existingAssetBuffer.equals(assetBuffer);

        if (!publishPreview) {
          fs.mkdirSync(path.dirname(outputAssetPathAbsolute), { recursive: true });
          fs.writeFileSync(outputAssetPathAbsolute, assetBuffer);
        }

        copiedAssets.push({
          sourcePath: toDisplayPath(assetPath),
          outputPath: outputAssetPathDisplay,
          changed,
        });
      }
    }

    if (publishFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            kind: "publish-html",
            project: publishProject,
            configPath: toDisplayPath(configPathResolved),
            sourceDir: sourceDirInput,
            outputDir: outputRootInput,
            recursive: publishRecursive,
            preview: publishPreview,
            count: exportedForOutput.length,
            exported: exportedForOutput,
            index: indexOutput,
            sitemapXml: sitemapXmlOutput,
            assets: copiedAssets,
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    process.stdout.write(`${publishPreview ? "Previewed" : "Published"} ${exportedForOutput.length} file(s) for project ${publishProject} to ${outputRootInput}\n`);
    for (const item of exportedForOutput) process.stdout.write(`${item.sourcePath} -> ${item.outputPath}${item.changed ? "" : " (unchanged)"}\n`);
    if (indexOutput) process.stdout.write(`index -> ${indexOutput.outputPath}${indexOutput.changed ? "" : " (unchanged)"}\n`);
    if (sitemapXmlOutput) process.stdout.write(`sitemap -> ${sitemapXmlOutput.outputPath}${sitemapXmlOutput.changed ? "" : " (unchanged)"}\n`);
    for (const asset of copiedAssets) process.stdout.write(`${asset.sourcePath} -> ${asset.outputPath}${asset.changed ? "" : " (unchanged)"}\n`);
    return;
  }

  if (command === "export") {
    if (exportAction !== "html") {
      console.error("Error: export currently supports only `html`");
      process.exit(1);
    }

    const hasSingleSource = Boolean(exportFile);
    const hasDirSource = Boolean(String(dir || "").trim());
    const exportStylesheetsNormalized = Array.from(
      new Set(exportStylesheets.map((href) => String(href || "").trim()).filter((href) => href.length > 0)),
    );

    let exportTocDepth: number | undefined;
    if (exportTocDepthRaw.trim().length > 0) {
      const rawDepth = exportTocDepthRaw.trim();
      if (!/^\d+$/.test(rawDepth)) {
        console.error(`Error: invalid export --toc-depth value: ${exportTocDepthRaw}. Expected a positive integer.`);
        process.exit(1);
      }
      const parsedDepth = Number.parseInt(rawDepth, 10);
      if (!Number.isFinite(parsedDepth) || parsedDepth < 1) {
        console.error(`Error: invalid export --toc-depth value: ${exportTocDepthRaw}. Expected a positive integer.`);
        process.exit(1);
      }
      exportTocDepth = parsedDepth;
    }

    let exportHeadlineNumberDepth: number | undefined;
    if (exportHeadlineNumberDepthRaw.trim().length > 0) {
      const rawDepth = exportHeadlineNumberDepthRaw.trim();
      if (!/^\d+$/.test(rawDepth)) {
        console.error(
          `Error: invalid export --number-headings-depth value: ${exportHeadlineNumberDepthRaw}. Expected a positive integer.`,
        );
        process.exit(1);
      }
      const parsedDepth = Number.parseInt(rawDepth, 10);
      if (!Number.isFinite(parsedDepth) || parsedDepth < 1) {
        console.error(
          `Error: invalid export --number-headings-depth value: ${exportHeadlineNumberDepthRaw}. Expected a positive integer.`,
        );
        process.exit(1);
      }
      exportHeadlineNumberDepth = parsedDepth;
    }

    if (hasSingleSource && hasDirSource) {
      console.error("Error: export html does not support combining --file with --dir");
      process.exit(1);
    }

    if (hasSingleSource && exportOutDir) {
      console.error("Error: --out-dir is only supported with export html --dir");
      process.exit(1);
    }

    if (hasSingleSource && exportIndex) {
      console.error("Error: --index is only supported with export html --dir");
      process.exit(1);
    }

    if (hasSingleSource && exportIndexTitle) {
      console.error("Error: --index-title is only supported with export html --dir --index");
      process.exit(1);
    }

    if (hasDirSource && exportOut) {
      console.error("Error: --out is only supported with export html --file");
      process.exit(1);
    }

    if (hasDirSource && exportTitle) {
      console.error("Error: --title is only supported with export html --file");
      process.exit(1);
    }

    if (hasDirSource && exportIndexTitle && !exportIndex) {
      console.error("Error: --index-title requires --index for export html --dir");
      process.exit(1);
    }

    if (!hasSingleSource && !hasDirSource) {
      console.error("Error: export html requires --file FILE or --dir DIR");
      process.exit(1);
    }

    let exportConfigLinkAbbreviations: Record<string, string> | undefined;
    let exportConfigLinearTeam: string | undefined;
    const exportConfigLookupStart = hasDirSource ? path.resolve(String(dir || "").trim()) : path.dirname(path.resolve(exportFile));
    const exportConfigPath = findConfigFile(exportConfigLookupStart);
    if (exportConfigPath) {
      try {
        const cfg = loadConfig(exportConfigPath);
        exportConfigLinkAbbreviations = cfg.links?.abbreviations;
        exportConfigLinearTeam = cfg.links?.linearTeam;
      } catch {
        // Ignore config errors for ad-hoc export flows.
      }
    }

    if (hasDirSource) {
      const sourceDirInput = String(dir || "").trim();
      const sourceDir = path.resolve(sourceDirInput);
      const sourceFiles = listOrgLikeFiles(sourceDir, recursive).sort((a, b) => a.localeCompare(b));
      const outputRootInput = String(exportOutDir || sourceDirInput).trim();
      const outputRoot = path.resolve(outputRootInput);

      const toDisplayPath = (absolutePath: string): string => {
        const relative = path.relative(process.cwd(), absolutePath);
        if (!relative || (!relative.startsWith("..") && !path.isAbsolute(relative))) {
          return relative || path.basename(absolutePath);
        }
        return absolutePath;
      };

      const exported: Array<{
        sourcePath: string;
        outputPath: string;
        outputPathAbsolute: string;
        title: string;
        changed: boolean;
        metadata?: ExportMetadataPayload;
      }> = [];

      for (const sourcePath of sourceFiles) {
        const sourceRaw = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
        const sourceAst = parseOrgToCanonicalAst(sourceRaw);
        const rendered = renderOrgDocumentToHtml(sourceAst, {
          sourcePath: toDisplayPath(sourcePath),
          stylesheets: exportStylesheetsNormalized,
          includeDefaultStyle: exportIncludeDefaultStyle,
          includeToc: exportIncludeToc,
          includeTocDepth: exportTocDepth,
          includeHeadlineNumbers: exportIncludeHeadlineNumbers,
          includeHeadlineNumberDepth: exportHeadlineNumberDepth,
          rewriteFileLinks: exportRewriteFileLinks,
          linkAbbreviations: exportConfigLinkAbbreviations,
          linearTeam: exportConfigLinearTeam,
        });

        const relativeSourcePath = path.relative(sourceDir, sourcePath);
        const outputRelativePath = /\.(org|org2)$/i.test(relativeSourcePath)
          ? relativeSourcePath.replace(/\.(org|org2)$/i, ".html")
          : `${relativeSourcePath}.html`;

        const outputPathAbsolute = path.resolve(outputRoot, outputRelativePath);
        const outputPathDisplay = path.join(outputRootInput, outputRelativePath);
        const existingOutput = fs.existsSync(outputPathAbsolute)
          ? fs.readFileSync(outputPathAbsolute, "utf8").replace(/\r\n/g, "\n")
          : "";
        const changed = existingOutput !== rendered.html;

        if (exportApply) {
          fs.mkdirSync(path.dirname(outputPathAbsolute), { recursive: true });
          fs.writeFileSync(outputPathAbsolute, rendered.html, "utf8");
        }

        exported.push({
          sourcePath: toDisplayPath(sourcePath),
          outputPath: outputPathDisplay,
          outputPathAbsolute,
          title: rendered.title,
          changed,
          ...(hasExportMetadata(rendered.metadata) ? { metadata: rendered.metadata } : {}),
        });
      }

      const exportedForOutput = exported.map(({ sourcePath, outputPath, title, changed, metadata }) => ({
        sourcePath,
        outputPath,
        title,
        changed,
        ...(hasExportMetadata(metadata) ? { metadata } : {}),
      }));

      let indexOutput: { outputPath: string; title: string; changed: boolean } | null = null;
      const indexRaw = String(exportIndex || "").trim();
      if (indexRaw) {
        const indexPathAbsolute = path.isAbsolute(indexRaw) ? path.resolve(indexRaw) : path.resolve(outputRoot, indexRaw);
        const indexPathDisplay = path.isAbsolute(indexRaw) ? toDisplayPath(indexPathAbsolute) : path.join(outputRootInput, indexRaw);
        const indexRendered = renderOrgExportIndexToHtml({
          title: exportIndexTitle || undefined,
          sourcePath: indexRaw,
          stylesheets: exportStylesheetsNormalized,
          includeDefaultStyle: exportIncludeDefaultStyle,
          items: exported.map((item) => {
            const hrefRaw = path.relative(path.dirname(indexPathAbsolute), item.outputPathAbsolute);
            const href = String(hrefRaw || path.basename(item.outputPathAbsolute)).split(path.sep).join("/");
            return {
              title: item.title,
              href,
              sourcePath: item.sourcePath,
            };
          }),
        });

        const existingIndex = fs.existsSync(indexPathAbsolute)
          ? fs.readFileSync(indexPathAbsolute, "utf8").replace(/\r\n/g, "\n")
          : "";
        const indexChanged = existingIndex !== indexRendered.html;

        if (exportApply) {
          fs.mkdirSync(path.dirname(indexPathAbsolute), { recursive: true });
          fs.writeFileSync(indexPathAbsolute, indexRendered.html, "utf8");
        }

        indexOutput = {
          outputPath: indexPathDisplay,
          title: indexRendered.title,
          changed: indexChanged,
        };
      }

      if (exportFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              kind: "export-html-batch",
              sourceDir: sourceDirInput,
              outputDir: outputRootInput,
              recursive,
              apply: exportApply,
              count: exportedForOutput.length,
              exported: exportedForOutput,
              index: indexOutput,
            },
            null,
            2,
          ) + "\n",
        );
        return;
      }

      if (exportedForOutput.length === 0 && !indexOutput) {
        process.stdout.write(`No Org/Org2 files found under ${sourceDirInput}\n`);
        return;
      }

      if (exportApply) {
        process.stdout.write(`Exported ${exportedForOutput.length} file(s) to ${outputRootInput}\n`);
      } else {
        process.stdout.write(`Previewed ${exportedForOutput.length} file(s) from ${sourceDirInput}\n`);
      }

      for (const item of exportedForOutput) {
        process.stdout.write(
          `${item.sourcePath} -> ${item.outputPath}${item.changed ? "" : " (unchanged)"}\n`,
        );
      }

      if (indexOutput) {
        process.stdout.write(`index -> ${indexOutput.outputPath}${indexOutput.changed ? "" : " (unchanged)"}\n`);
      }
      return;
    }

    const sourcePathInput = exportFile;
    const sourcePath = path.resolve(sourcePathInput);
    const sourceRaw = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
    const sourceAst = parseOrgToCanonicalAst(sourceRaw);
    const rendered = renderOrgDocumentToHtml(sourceAst, {
      title: exportTitle || undefined,
      sourcePath: sourcePathInput,
      stylesheets: exportStylesheetsNormalized,
      includeDefaultStyle: exportIncludeDefaultStyle,
      includeToc: exportIncludeToc,
      includeTocDepth: exportTocDepth,
      includeHeadlineNumbers: exportIncludeHeadlineNumbers,
      includeHeadlineNumberDepth: exportHeadlineNumberDepth,
      rewriteFileLinks: exportRewriteFileLinks,
      linkAbbreviations: exportConfigLinkAbbreviations,
      linearTeam: exportConfigLinearTeam,
    });

    const defaultOutputPath = (() => {
      if (/\.(org|org2)$/i.test(sourcePathInput)) {
        return sourcePathInput.replace(/\.(org|org2)$/i, ".html");
      }
      return `${sourcePathInput}.html`;
    })();

    const outputPathInput = exportOut || defaultOutputPath;
    const outputPath = path.resolve(outputPathInput);
    const existingOutput = fs.existsSync(outputPath) ? fs.readFileSync(outputPath, "utf8").replace(/\r\n/g, "\n") : "";
    const changed = existingOutput !== rendered.html;

    if (exportApply) {
      fs.mkdirSync(path.dirname(outputPath), { recursive: true });
      fs.writeFileSync(outputPath, rendered.html, "utf8");
    }

    if (exportFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            kind: "export-html",
            sourcePath: sourcePathInput,
            outputPath: outputPathInput,
            title: rendered.title,
            ...(hasExportMetadata(rendered.metadata) ? { metadata: rendered.metadata } : {}),
            apply: exportApply,
            changed,
            html: rendered.html,
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    if (!exportApply) {
      process.stdout.write(rendered.html);
      return;
    }

    process.stdout.write(`Exported HTML to ${outputPathInput}\n`);
    return;
  }

  if (command === "capture") {
    if (!captureFile) {
      console.error("Error: capture requires --file FILE");
      process.exit(1);
    }

    const normalizedTitle = captureTitle.trim();
    if (!normalizedTitle) {
      console.error("Error: capture requires --title TITLE");
      process.exit(1);
    }

    const normalizedTemplateRaw = captureTemplateRaw.trim().toLowerCase();
    if (normalizedTemplateRaw !== "note" && normalizedTemplateRaw !== "task") {
      console.error(`Error: invalid --template ${captureTemplateRaw}. Allowed: note, task`);
      process.exit(1);
    }
    const normalizedTemplate = normalizedTemplateRaw as "note" | "task";

    if (captureTodoKeywordFlagSet && normalizedTemplate !== "task") {
      console.error("Error: --todo is only supported with --template task");
      process.exit(1);
    }

    const normalizedTodoKeyword = captureTodoKeywordRaw.trim().toUpperCase();
    if (
      normalizedTemplate === "task" &&
      !(TODO_KEYWORDS as readonly string[]).includes(normalizedTodoKeyword)
    ) {
      console.error(
        `Error: invalid capture --todo value ${captureTodoKeywordRaw}. Allowed: ${TODO_KEYWORDS.join(", ")}`,
      );
      process.exit(1);
    }

    let captureNowDate = new Date();
    if (captureNow) {
      const parsedNow = new Date(captureNow);
      if (isNaN(parsedNow.getTime())) {
        console.error(`Error: invalid --now ${captureNow}`);
        process.exit(1);
      }
      captureNowDate = parsedNow;
    }

    const normalizedBody = captureBodyRaw.replace(/\r\n/g, "\n").trim();

    const headingLine =
      normalizedTemplate === "task"
        ? `* ${normalizedTodoKeyword} ${normalizedTitle}`
        : `* ${normalizedTitle}`;
    const capturedAt = formatOrgTimestamp(captureNowDate);
    const captureEntryText =
      normalizedBody.length > 0
        ? `${headingLine}\nCAPTURED: ${capturedAt}\n\n${normalizedBody}\n`
        : `${headingLine}\nCAPTURED: ${capturedAt}\n`;

    const beforeText = fs.existsSync(captureFile)
      ? fs.readFileSync(captureFile, "utf8").replace(/\r\n/g, "\n")
      : "";
    const beforeTrimmed = beforeText.trimEnd();
    const outText =
      beforeTrimmed.length > 0
        ? `${beforeTrimmed}\n\n${captureEntryText}`
        : captureEntryText;

    const changed = outText !== beforeText;
    const headingLine1 = beforeTrimmed.length === 0 ? 1 : beforeTrimmed.split("\n").length + 2;

    if (captureApply && changed) {
      fs.mkdirSync(path.dirname(captureFile), { recursive: true });
      fs.writeFileSync(captureFile, outText, "utf8");
    }

    const unifiedDiff = (before: string, after: string): string => {
      let tmpDir: string | null = null;
      try {
        tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-capture-diff-"));
        const aPath = path.join(tmpDir, "before.org2");
        const bPath = path.join(tmpDir, "after.org2");
        fs.writeFileSync(aPath, before, "utf8");
        fs.writeFileSync(bPath, after, "utf8");

        const res = spawnSync("diff", ["-u", aPath, bPath], { encoding: "utf8" });
        if (res.status !== 0 && res.status !== 1) {
          throw new Error(res.stderr || `diff exited with status ${res.status}`);
        }

        return (res.stdout || "").split(aPath).join(captureFile).split(bPath).join(captureFile);
      } finally {
        if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
      }
    };

    if (captureFormat === "diff") {
      if (changed) process.stdout.write(unifiedDiff(beforeText, outText));
      return;
    }

    if (captureFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            kind: "capture",
            file: captureFile,
            template: normalizedTemplate,
            title: normalizedTitle,
            todoKeyword: normalizedTemplate === "task" ? normalizedTodoKeyword : null,
            body: normalizedBody || null,
            capturedAt,
            headingLine1,
            apply: captureApply,
            changed,
            outText,
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    process.stdout.write(outText);
    return;
  }

  if (command === "id") {
    if (!idFile) {
      console.error("Error: id requires --file FILE");
      process.exit(1);
    }

    const raw = fs.readFileSync(idFile, "utf8").replace(/\r\n/g, "\n");
    const lines = raw.split("\n");

    const unifiedDiff = (before: string, after: string): string => {
      let tmpDir: string | null = null;
      try {
        tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-id-diff-"));
        const aPath = path.join(tmpDir, "before.org2");
        const bPath = path.join(tmpDir, "after.org2");
        fs.writeFileSync(aPath, before, "utf8");
        fs.writeFileSync(bPath, after, "utf8");

        const res = spawnSync("diff", ["-u", aPath, bPath], { encoding: "utf8" });
        // diff(1): 0=identical, 1=different, >1=error
        if (res.status !== 0 && res.status !== 1) {
          throw new Error(res.stderr || `diff exited with status ${res.status}`);
        }

        // Replace temp paths with the real filename for readability.
        return (res.stdout || "").split(aPath).join(idFile).split(bPath).join(idFile);
      } finally {
        if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
      }
    };

    if (idAction === "get" && idFormat === "diff") {
      console.error("Error: org2 id get does not support --format diff");
      process.exit(1);
    }

    const getHeadlineIdAtOrAboveLine = (
      line1: number,
    ):
      | { id: string; idLine1: number; headingLine1: number; changed: boolean; outText: string }
      | null => {
      if (!line1 || line1 < 1) return null;

      const startIdx = Math.min(Math.max(line1 - 1, 0), lines.length - 1);

      let headingIdx = -1;
      let headingLevel = 0;
      for (let idx = startIdx; idx >= 0; idx -= 1) {
        const m = /^(\*+)\s+/.exec(lines[idx] ?? "");
        if (m) {
          headingIdx = idx;
          headingLevel = m[1]!.length;
          break;
        }
      }

      if (headingIdx === -1) return null;

      // Search within this subtree (until the next heading at same-or-higher level).
      let subtreeEnd = lines.length;
      for (let idx = headingIdx + 1; idx < lines.length; idx += 1) {
        const m = /^(\*+)\s+/.exec(lines[idx] ?? "");
        if (m && m[1]!.length <= headingLevel) {
          subtreeEnd = idx;
          break;
        }
      }

      const idLineRe = /^\s*:ID:\s*(\S+)\s*$/;

      // Best-effort: allow blank lines between heading and drawer.
      let scanStart = headingIdx + 1;
      while (scanStart < subtreeEnd && (lines[scanStart] ?? "").trim() === "") scanStart += 1;

      // If there's a :PROPERTIES: drawer, use/extend it.
      if (((lines[scanStart] ?? "").trim() || "").toUpperCase() === ":PROPERTIES:") {
        let drawerEnd = -1;
        for (let j = scanStart + 1; j < subtreeEnd; j += 1) {
          const t = (lines[j] ?? "").trim();
          const m = idLineRe.exec(t);
          if (m) {
            return {
              id: m[1]!,
              idLine1: j + 1,
              headingLine1: headingIdx + 1,
              changed: false,
              outText: raw,
            };
          }
          if (t.toUpperCase() === ":END:") {
            drawerEnd = j;
            break;
          }
        }

        if (drawerEnd !== -1 && idAction === "ensure") {
          const newId = idForced || crypto.randomUUID();
          lines.splice(scanStart + 1, 0, `:ID: ${newId}`);
          const outText = lines.join("\n");
          return {
            id: newId,
            idLine1: scanStart + 2,
            headingLine1: headingIdx + 1,
            changed: true,
            outText,
          };
        }

        return null;
      }

      // No drawer: insert one directly under the heading.
      if (idAction === "ensure") {
        const newId = idForced || crypto.randomUUID();
        const drawer = [":PROPERTIES:", `:ID: ${newId}`, ":END:", ""];
        lines.splice(headingIdx + 1, 0, ...drawer);
        const outText = lines.join("\n");
        return {
          id: newId,
          idLine1: headingIdx + 3,
          headingLine1: headingIdx + 1,
          changed: true,
          outText,
        };
      }

      return null;
    };

    if (idLine > 0) {
      const headlineRes = getHeadlineIdAtOrAboveLine(idLine);
      if (headlineRes) {
        if (idAction === "get") {
          if (idFormat === "json") {
            process.stdout.write(
              JSON.stringify(
                {
                  id: headlineRes.id,
                  kind: "headline",
                  file: idFile,
                  line: headlineRes.idLine1,
                  headingLine: headlineRes.headingLine1,
                },
                null,
                2,
              ) + "\n",
            );
          } else {
            process.stdout.write(headlineRes.id + "\n");
          }
          return;
        }

        // ensure
        if (headlineRes.changed && idApply) {
          fs.writeFileSync(idFile, headlineRes.outText, "utf8");
        }

        if (idFormat === "json") {
          process.stdout.write(
            JSON.stringify(
              {
                id: headlineRes.id,
                kind: "headline",
                file: idFile,
                line: headlineRes.idLine1,
                headingLine: headlineRes.headingLine1,
                applied: idApply,
                changed: headlineRes.changed,
              },
              null,
              2,
            ) + "\n",
          );
        } else if (idFormat === "diff") {
          if (headlineRes.changed && !idApply) process.stdout.write(unifiedDiff(raw, headlineRes.outText));
        } else if (idApply || !headlineRes.changed) {
          process.stdout.write(headlineRes.id + "\n");
        } else {
          process.stdout.write(headlineRes.outText);
        }

        return;
      }
      // If no heading context found (or malformed drawer), fall back to file-level.
    }

    const getFileId = (): { id: string; line: number } | null => {
      // Accept `#+id: <uuid>` anywhere near top, but prefer a file-level property drawer.
      for (let j = 0; j < Math.min(lines.length, 30); j += 1) {
        const l = lines[j] ?? "";
        const m = /^#\+id:\s*(\S+)\s*$/i.exec(l.trim());
        if (m) return { id: m[1]!, line: j + 1 };
      }

      // Look for a top-of-file :PROPERTIES: drawer.
      // Allow leading blank lines and comments.
      let idx = 0;
      while (idx < lines.length) {
        const l = (lines[idx] ?? "").trim();
        if (l === "" || l.startsWith("#")) {
          idx += 1;
          continue;
        }
        break;
      }

      if ((lines[idx] ?? "").trim() !== ":PROPERTIES:") return null;

      for (let j = idx + 1; j < lines.length; j += 1) {
        const l = (lines[j] ?? "").trim();
        if (l === ":END:") return null;
        const m = /^:ID:\s*(\S+)\s*$/.exec(l);
        if (m) return { id: m[1]!, line: j + 1 };
      }

      return null;
    };

    const existing = getFileId();

    if (idAction === "get") {
      if (!existing) {
        console.error("Error: no file-level ID found");
        process.exit(1);
      }

      if (idFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              id: existing.id,
              kind: "file",
              file: idFile,
              line: existing.line,
            },
            null,
            2,
          ) + "\n",
        );
      } else {
        process.stdout.write(existing.id + "\n");
      }

      return;
    }

    // ensure
    if (existing) {
      if (idFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              id: existing.id,
              kind: "file",
              file: idFile,
              line: existing.line,
              applied: idApply,
              changed: false,
            },
            null,
            2,
          ) + "\n",
        );
      } else {
        process.stdout.write(existing.id + "\n");
      }
      return;
    }

    const newId = idForced || crypto.randomUUID();
    const header = `:PROPERTIES:\n:ID: ${newId}\n:END:\n\n`;
    const out = header + raw.replace(/^\n+/, "");

    if (idApply) {
      fs.writeFileSync(idFile, out, "utf8");
    }

    if (idFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            id: newId,
            kind: "file",
            file: idFile,
            line: 2,
            applied: idApply,
            changed: true,
          },
          null,
          2,
        ) + "\n",
      );
    } else if (idFormat === "diff") {
      if (!idApply) process.stdout.write(unifiedDiff(raw, out));
    } else if (idApply) {
      process.stdout.write(newId + "\n");
    } else {
      process.stdout.write(out);
    }

    return;
  }

  if (command === "backlinks") {
    if (!backlinksId) {
      console.error("Error: backlinks requires --id UUID");
      process.exit(1);
    }

    // Determine files to search (same as agenda)
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          const configDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, configDir);

          if (files.length === 0) {
            console.error(
              `Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`,
            );
            process.exit(1);
          }
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or org2.json config");
        process.exit(1);
      }
    }

    if (dir && files.length === 0) {
      const listOrgFiles = (dirPath: string): string[] => {
        const out: string[] = [];
        const entries = fs.readdirSync(dirPath, { withFileTypes: true });
        for (const entry of entries) {
          const fullPath = path.join(dirPath, entry.name);
          if (entry.isDirectory()) {
            if (!recursive) continue;
            if (entry.name.startsWith(".")) continue;
            out.push(...listOrgFiles(fullPath));
            continue;
          }
          if (!entry.isFile()) continue;
          if (!(entry.name.endsWith(".org") || entry.name.endsWith(".org2"))) continue;
          if (entry.name.startsWith(".#")) continue;
          out.push(fullPath);
        }
        return out;
      };

      files = listOrgFiles(dir);
    }

    const backlinks: Backlink[] = [];
    const titleIndex = buildRoamTitleIndex(files);
    const resolveWikiLinkIds = (label: string): string[] => {
      const key = normalizeRoamLinkLabel(label);
      if (!key) return [];

      const ids = titleIndex.get(key);
      if (!ids || ids.size === 0) return [];
      return Array.from(ids);
    };
    let skippedFileCount = 0;

    for (const filePath of files) {
      try {
        const content = fs.readFileSync(filePath, "utf8");
        backlinks.push(
          ...findBacklinksInText(content, filePath, backlinksId, {
            resolveWikiLinkIds,
          }),
        );
      } catch (err) {
        skippedFileCount += 1;
        if (verboseErrors) {
          console.error(`Error processing ${filePath}:`, err instanceof Error ? err.message : err);
        }
      }
    }

    if (skippedFileCount > 0 && !verboseErrors) {
      console.error(
        `Skipped ${skippedFileCount} file(s) due to parse errors (use --verbose-errors to see details).`,
      );
    }

    // Stable sort for tests/readability
    backlinks.sort((a, b) => (a.file + ":" + a.line).localeCompare(b.file + ":" + b.line));

    if (backlinksFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:backlinks:v1",
            id: backlinksId.toLowerCase(),
            backlinks: backlinks.map((b) => ({
              srcId: b.srcId,
              srcTitle: b.srcTitle,
              file: b.file,
              line: b.line,
              context: b.context,
            })),
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    if (backlinks.length === 0) {
      process.stdout.write("No backlinks found.\n");
      return;
    }

    for (const b of backlinks) {
      process.stdout.write(`${b.srcTitle} (${b.srcId ?? ""}) ${b.file}:${b.line + 1} ${b.context}\n`);
    }

    return;
  }

  if (command === "query") {
    if (!queryId) {
      console.error("Error: query requires --id UUID");
      process.exit(1);
    }

    const needle = queryId.toLowerCase();

    // Determine files to search (same logic as backlinks/agenda)
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          const configDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, configDir);

          if (files.length === 0) {
            console.error(
              `Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`,
            );
            process.exit(1);
          }
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or org2.json config");
        process.exit(1);
      }
    }

    if (dir && files.length === 0) {
      const listOrgFiles = (dirPath: string): string[] => {
        const out: string[] = [];
        const entries = fs.readdirSync(dirPath, { withFileTypes: true });
        for (const entry of entries) {
          const fullPath = path.join(dirPath, entry.name);
          if (entry.isDirectory()) {
            if (!recursive) continue;
            if (entry.name.startsWith(".")) continue;
            out.push(...listOrgFiles(fullPath));
            continue;
          }
          if (!entry.isFile()) continue;
          if (!(entry.name.endsWith(".org") || entry.name.endsWith(".org2"))) continue;
          if (entry.name.startsWith(".#")) continue;
          out.push(fullPath);
        }
        return out;
      };

      files = listOrgFiles(dir);
    }

    type QueryHit = {
      kind: "file" | "headline";
      id: string;
      file: string;
      line: number; // 0-based
      title: string;
      headingLine?: number; // 0-based
    };

    const hits: QueryHit[] = [];
    let skippedFileCount = 0;

    const findFileTitle = (lines: string[]): string | null => {
      for (let j = 0; j < Math.min(lines.length, 50); j += 1) {
        const m = /^#\+title:\s*(.*?)\s*$/i.exec((lines[j] ?? "").trim());
        if (m) return m[1] || null;
      }
      return null;
    };

    const parseHeadlineTitle = (headlineLine: string): string => {
      // "** TODO My title" → "My title"
      const raw = headlineLine.trim().replace(/^\*+\s+/, "");
      return raw.replace(/^(TODO|IN_PROGRESS|DONE|CANCELLED|CANCELED)\s+/, "");
    };

    for (const filePath of files) {
      try {
        const raw = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n");
        const lines = raw.split("\n");

        let inProps = false;
        let propsStart = -1; // 0-based

        for (let j = 0; j < lines.length; j += 1) {
          const l = (lines[j] ?? "").trim();

          if (l === ":PROPERTIES:") {
            inProps = true;
            propsStart = j;
            continue;
          }
          if (l === ":END:") {
            inProps = false;
            propsStart = -1;
            continue;
          }

          if (!inProps) continue;

          const m = /^:ID:\s*(\S+)\s*$/.exec(l);
          if (!m) continue;

          const found = (m[1] ?? "").toLowerCase();
          if (found !== needle) continue;

          // Determine whether this is file-level or headline-level by checking if
          // the drawer is at the top of file (allowing leading blanks/comments).
          let idx = 0;
          while (idx < lines.length) {
            const t = (lines[idx] ?? "").trim();
            if (t === "" || t.startsWith("#")) {
              idx += 1;
              continue;
            }
            break;
          }

          const isFile = propsStart === idx;

          if (isFile) {
            hits.push({
              kind: "file",
              id: found,
              file: filePath,
              line: j,
              title: findFileTitle(lines) ?? path.basename(filePath),
            });
          } else {
            // Find the headline for this drawer by scanning upward.
            let headlineLine = -1;
            let headlineText = "";
            for (let k = propsStart - 1; k >= 0; k -= 1) {
              const s = lines[k] ?? "";
              if (/^\*+\s+/.test(s)) {
                headlineLine = k;
                headlineText = s;
                break;
              }
            }

            hits.push({
              kind: "headline",
              id: found,
              file: filePath,
              line: j,
              headingLine: headlineLine >= 0 ? headlineLine : undefined,
              title: headlineText ? parseHeadlineTitle(headlineText) : path.basename(filePath),
            });
          }
        }
      } catch (err) {
        skippedFileCount += 1;
        if (verboseErrors) {
          console.error(`Error processing ${filePath}:`, err instanceof Error ? err.message : err);
        }
      }
    }

    if (skippedFileCount > 0 && !verboseErrors) {
      console.error(
        `Skipped ${skippedFileCount} file(s) due to parse errors (use --verbose-errors to see details).`,
      );
    }

    hits.sort((a, b) => (a.file + ":" + a.line).localeCompare(b.file + ":" + b.line));

    if (queryFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:query:v1",
            id: needle,
            results: hits.map((h) => ({
              kind: h.kind,
              id: h.id,
              file: h.file,
              line: h.line,
              title: h.title,
              ...(h.headingLine !== undefined ? { headingLine: h.headingLine } : {}),
            })),
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    if (hits.length === 0) {
      process.stdout.write("No matches found.\n");
      return;
    }

    for (const h of hits) {
      // Print 1-based line for humans
      process.stdout.write(`${h.kind} ${h.title} ${h.file}:${h.line + 1}\n`);
    }

    return;
  }

  if (command === "todo") {
    if (!todoFile) {
      console.error("Error: todo requires --file FILE");
      process.exit(1);
    }
    if (!Number.isFinite(todoLine) || todoLine < 1) {
      console.error("Error: todo requires --line N (1-based) or --pos LINE[:COL]");
      process.exit(1);
    }

    if (todoAction === "set") {
      if (!todoStatus || (todoStatus !== "todo" && todoStatus !== "in_progress" && todoStatus !== "done" && todoStatus !== "canceled")) {
        console.error("Error: todo set requires --status todo|in_progress|done|canceled (aliases: open, in-progress/in progress/prog/doing/started/waiting/blocked/next/wip, complete/completed/finish/finished/closed/resolved, cancel/cancelled)");
        process.exit(1);
      }
    }

    let nowDate: Date | undefined;
    if (todoNow) {
      const d = new Date(todoNow);
      if (isNaN(d.getTime())) {
        console.error(`Error: invalid --now ${todoNow}`);
        process.exit(1);
      }
      nowDate = d;
    }

    let todoLogbookEffective = todoLogbook;
    if (!todoLogbookFlagSet) {
      const configPath = findConfigFile(path.dirname(path.resolve(todoFile)));
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          if (config.todo?.writeTransitionLogbook === true) {
            todoLogbookEffective = true;
          }
        } catch (err) {
          console.error(
            `Error: failed to load config from ${configPath}: ${err instanceof Error ? err.message : String(err)}`
          );
          process.exit(1);
        }
      }
    }

    const beforeRaw = fs.readFileSync(todoFile, "utf8").replace(/\r\n/g, "\n");

    const res = updateTodoInText(beforeRaw, {
      filePath: todoFile,
      lineNumber: todoLine,
      ...(todoAction === "toggle" ? { toggle: true } : { status: todoStatus as TodoStatus }),
      ...(nowDate ? { now: nowDate } : {}),
      ...(todoLogbookEffective ? { logbook: true } : {}),
    });

    if (todoApply) {
      fs.writeFileSync(todoFile, res.text, "utf8");
    }

    if (todoFormat === "diff") {
      if (!res.changed) return;

      let tmpDir: string | null = null;
      try {
        tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-todo-diff-"));
        const aPath = path.join(tmpDir, "before.org2");
        const bPath = path.join(tmpDir, "after.org2");
        fs.writeFileSync(aPath, beforeRaw, "utf8");
        fs.writeFileSync(bPath, res.text, "utf8");

        const diffRes = spawnSync("diff", ["-u", aPath, bPath], { encoding: "utf8" });
        // diff(1): 0=identical, 1=different, >1=error
        if (diffRes.status !== 0 && diffRes.status !== 1) {
          throw new Error(diffRes.stderr || `diff exited with status ${diffRes.status}`);
        }

        const out = (diffRes.stdout || "").split(aPath).join(todoFile).split(bPath).join(todoFile);
        process.stdout.write(out);
      } finally {
        if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
      }
      return;
    }

    if (todoFormat === "text") {
      process.stdout.write(res.text + (res.text.endsWith("\n") ? "" : "\n"));
    } else {
      process.stdout.write(
        JSON.stringify(
          {
            file: res.filePath,
            headingLine: res.headingLineNumber,
            oldStatus: res.oldStatus,
            newStatus: res.newStatus,
            ...(res.closedAt ? { closedAt: res.closedAt } : {}),
            applied: todoApply,
            changed: res.changed,
          },
          null,
          2,
        ) + "\n",
      );
    }

    return;
  }

  if (command === "plan") {
    if (!planFile) {
      console.error("Error: plan requires --file FILE");
      process.exit(1);
    }
    if (!Number.isFinite(planLine) || planLine < 1) {
      console.error("Error: plan requires --line N (1-based) or --pos LINE[:COL]");
      process.exit(1);
    }
    if (!planKind || (planKind !== "scheduled" && planKind !== "deadline")) {
      console.error("Error: plan requires --kind scheduled|deadline");
      process.exit(1);
    }
    if (planAction === "today") {
      planDate = today;
    }

    planDate = planDate.trim();
    if (!planDate) {
      console.error("Error: plan requires --date YYYY-MM-DD (or use `plan today`)");
      process.exit(1);
    }

    const beforeRaw = fs.readFileSync(planFile, "utf8").replace(/\r\n/g, "\n");

    const res = updatePlanningInText(beforeRaw, {
      filePath: planFile,
      lineNumber: planLine,
      kind: planningKindFromArg(planKind as PlanningKindArg),
      date: planDate,
    });

    if (planApply) {
      fs.writeFileSync(planFile, res.text, "utf8");
    }

    if (planFormat === "diff") {
      if (!res.changed) return;

      let tmpDir: string | null = null;
      try {
        tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-plan-diff-"));
        const aPath = path.join(tmpDir, "before.org2");
        const bPath = path.join(tmpDir, "after.org2");
        fs.writeFileSync(aPath, beforeRaw, "utf8");
        fs.writeFileSync(bPath, res.text, "utf8");

        const diffRes = spawnSync("diff", ["-u", aPath, bPath], { encoding: "utf8" });
        // diff(1): 0=identical, 1=different, >1=error
        if (diffRes.status !== 0 && diffRes.status !== 1) {
          throw new Error(diffRes.stderr || `diff exited with status ${diffRes.status}`);
        }

        const out = (diffRes.stdout || "").split(aPath).join(planFile).split(bPath).join(planFile);
        process.stdout.write(out);
      } finally {
        if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
      }
      return;
    }

    if (planFormat === "text") {
      process.stdout.write(res.text + (res.text.endsWith("\n") ? "" : "\n"));
    } else {
      process.stdout.write(
        JSON.stringify(
          {
            file: res.filePath,
            headingLine: res.headingLineNumber,
            kind: res.kind,
            date: res.date,
            applied: planApply,
            changed: res.changed,
          },
          null,
          2,
        ) + "\n",
      );
    }

    return;
  }

  if (command === "crypt") {
    if (!cryptFile) {
      console.error("Error: crypt requires --file FILE");
      process.exit(1);
    }
    if (!Number.isFinite(cryptLine) || cryptLine < 1) {
      console.error("Error: crypt requires --line N (1-based) or --pos LINE[:COL]");
      process.exit(1);
    }
    if (!cryptPassphrase) {
      console.error("Error: crypt requires --passphrase PASS");
      process.exit(1);
    }
    if (!cryptGpgProgram.trim()) {
      console.error("Error: crypt requires --gpg-program PATH");
      process.exit(1);
    }

    const beforeRaw = fs.readFileSync(cryptFile, "utf8").replace(/\r\n/g, "\n");
    const lines = beforeRaw.split("\n");
    const targetIdx = Math.min(Math.max(cryptLine - 1, 0), Math.max(lines.length - 1, 0));

    let headingIdx = -1;
    let headingLevel = 0;
    for (let idx = targetIdx; idx >= 0; idx -= 1) {
      const m = /^(\*+)\s+/.exec(lines[idx] ?? "");
      if (!m) continue;
      headingIdx = idx;
      headingLevel = m[1]!.length;
      break;
    }
    if (headingIdx < 0) {
      console.error("Error: no headline found at or above --line/--pos");
      process.exit(1);
    }

    let subtreeEnd = lines.length;
    for (let idx = headingIdx + 1; idx < lines.length; idx += 1) {
      const m = /^(\*+)\s+/.exec(lines[idx] ?? "");
      if (m && m[1]!.length <= headingLevel) {
        subtreeEnd = idx;
        break;
      }
    }

    const beginRe = /^\s*-----BEGIN PGP MESSAGE-----\s*$/;
    const endRe = /^\s*-----END PGP MESSAGE-----\s*$/;
    let blockStart = -1;
    let blockEnd = -1;
    for (let idx = headingIdx + 1; idx < subtreeEnd; idx += 1) {
      if (blockStart === -1 && beginRe.test(lines[idx] ?? "")) {
        blockStart = idx;
        continue;
      }
      if (blockStart !== -1 && endRe.test(lines[idx] ?? "")) {
        blockEnd = idx;
        break;
      }
    }

    const runGpg = (
      action: "encrypt" | "decrypt",
      inputText: string,
    ): { ok: boolean; stdout: string; stderr: string; error?: string } => {
      const commonArgs = [
        "--batch",
        "--yes",
        "--pinentry-mode",
        "loopback",
        "--passphrase",
        cryptPassphrase,
      ];
      const commandArgs =
        action === "decrypt"
          ? [...commonArgs, "--decrypt"]
          : [...commonArgs, "--armor", "--symmetric", "--cipher-algo", "AES256"];

      const res = spawnSync(cryptGpgProgram, commandArgs, {
        input: inputText,
        encoding: "utf8",
      });

      if (res.error) {
        return {
          ok: false,
          stdout: String(res.stdout || ""),
          stderr: String(res.stderr || ""),
          error: String(res.error.message || res.error),
        };
      }

      return {
        ok: res.status === 0,
        stdout: String(res.stdout || ""),
        stderr: String(res.stderr || ""),
      };
    };

    const splitPreservingTrailing = (raw: string): string[] => {
      const normalized = String(raw || "").replace(/\r\n/g, "\n");
      if (normalized.length === 0) return [];
      const noTrailing = normalized.endsWith("\n") ? normalized.slice(0, -1) : normalized;
      if (noTrailing.length === 0) return [];
      return noTrailing.split("\n");
    };

    const buildDiff = (before: string, after: string): string => {
      let tmpDir: string | null = null;
      try {
        tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-crypt-diff-"));
        const aPath = path.join(tmpDir, "before.org2");
        const bPath = path.join(tmpDir, "after.org2");
        fs.writeFileSync(aPath, before, "utf8");
        fs.writeFileSync(bPath, after, "utf8");
        const diffRes = spawnSync("diff", ["-u", aPath, bPath], { encoding: "utf8" });
        if (diffRes.status !== 0 && diffRes.status !== 1) {
          throw new Error(diffRes.stderr || `diff exited with status ${diffRes.status}`);
        }
        return (diffRes.stdout || "").split(aPath).join(cryptFile).split(bPath).join(cryptFile);
      } finally {
        if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
      }
    };

    let outText = beforeRaw;
    let changed = false;

    if (cryptAction === "decrypt") {
      if (blockStart < 0 || blockEnd < blockStart) {
        console.error("Error: crypt decrypt found no armored PGP block in target subtree");
        process.exit(1);
      }

      const encryptedText = lines.slice(blockStart, blockEnd + 1).join("\n") + "\n";
      const normalizedEncryptedText = normalizePgpArmorForDecrypt(encryptedText);
      const gpg = runGpg("decrypt", normalizedEncryptedText);
      if (!gpg.ok) {
        const detail = [gpg.error, gpg.stderr.trim()].filter(Boolean).join(" | ");
        console.error(`Error: crypt decrypt failed${detail ? `: ${detail}` : ""}`);
        process.exit(1);
      }

      const plainLines = splitPreservingTrailing(gpg.stdout);
      const outLines = [...lines.slice(0, blockStart), ...plainLines, ...lines.slice(blockEnd + 1)];
      outText = outLines.join("\n");
      changed = outText !== beforeRaw;
    } else {
      if (blockStart >= 0 && blockEnd >= blockStart) {
        console.error("Error: crypt encrypt target subtree already contains an armored PGP block");
        process.exit(1);
      }

      const plainBodyLines = lines.slice(headingIdx + 1, subtreeEnd);
      const plainBody = plainBodyLines.join("\n").trim();
      if (!plainBody) {
        console.error("Error: crypt encrypt found no plaintext body in target subtree");
        process.exit(1);
      }

      const gpgInput = plainBodyLines.join("\n") + "\n";
      const gpg = runGpg("encrypt", gpgInput);
      if (!gpg.ok) {
        const detail = [gpg.error, gpg.stderr.trim()].filter(Boolean).join(" | ");
        console.error(`Error: crypt encrypt failed${detail ? `: ${detail}` : ""}`);
        process.exit(1);
      }

      const encryptedLines = splitPreservingTrailing(gpg.stdout);
      const outLines = [...lines.slice(0, headingIdx + 1), ...encryptedLines, ...lines.slice(subtreeEnd)];
      outText = outLines.join("\n");
      changed = outText !== beforeRaw;
    }

    if (cryptApply && changed) {
      fs.writeFileSync(cryptFile, outText, "utf8");
    }

    if (cryptFormat === "diff") {
      if (changed) process.stdout.write(buildDiff(beforeRaw, outText));
      return;
    }

    if (cryptFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:crypt:v1",
            action: cryptAction,
            file: cryptFile,
            headingLine: headingIdx + 1,
            applied: cryptApply,
            changed,
            gpgProgram: cryptGpgProgram,
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    process.stdout.write(outText + (outText.endsWith("\n") ? "" : "\n"));
    return;
  }

  if (command === "fmt") {
    const formatOne = (rawIn: string): string => {
      const normalized = rawIn.replace(/\r\n/g, "\n");
      const { text: protectedText, blocks } = protectPgpBlocks(normalized);
      const ast = parseOrgToCanonicalAst(protectedText);
      const formatted = printCanonicalAstToOrg(ast);
      return restorePgpBlocks(formatted, blocks);
    };

    const emitFmtCheckJson = (checkedFiles: string[], changedFiles: string[]): void => {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:fmt-check:v1",
            changed: changedFiles.length > 0,
            checkedFiles,
            changedFiles,
          },
          null,
          2,
        ) + "\n",
      );
    };

    const emitFmtPreviewJson = (file: string, formattedText: string, changed: boolean): void => {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:fmt-preview:v1",
            file,
            changed,
            formattedText,
          },
          null,
          2,
        ) + "\n",
      );
    };

    const emitFmtApplyJson = (processedFiles: string[], changedFiles: string[]): void => {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:fmt-apply:v1",
            changed: changedFiles.length > 0,
            processedFiles,
            changedFiles,
          },
          null,
          2,
        ) + "\n",
      );
    };

    const emitFmtStdinJson = (formattedText: string, changed: boolean): void => {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:fmt-stdin:v1",
            changed,
            formattedText,
          },
          null,
          2,
        ) + "\n",
      );
    };

    const parsedFmtFile = parseAgendaFileFilterArgs(fmtFileFiltersRaw);
    const parsedFmtExcludeFile = parseAgendaExcludeFileFilterArgs(fmtExcludeFileFiltersRaw);

    if (fmtStdin) {
      if (fmtConfigPath) {
        console.error("Error: fmt --stdin cannot be combined with --config");
        process.exit(1);
      }
      if (parsedFmtFile || parsedFmtExcludeFile) {
        console.error("Error: fmt --stdin cannot be combined with --file-match/--exclude-file");
        process.exit(1);
      }
      if (fmtCheck) {
        console.error("Error: fmt --check does not support --stdin");
        process.exit(1);
      }
      if (dir || files.length > 0) {
        console.error("Error: fmt --stdin cannot be combined with --dir/--file/--files");
        process.exit(1);
      }
      const stdinRaw = fs.readFileSync(0, "utf8");
      const normalizedStdinRaw = stdinRaw.replace(/\r\n/g, "\n");
      const formattedText = formatOne(stdinRaw);

      if (fmtFormat === "json") {
        emitFmtStdinJson(formattedText, formattedText !== normalizedStdinRaw);
        return;
      }

      process.stdout.write(formattedText);
      return;
    }

    if (fmtConfigPath && (dir || files.length > 0)) {
      console.error("Error: fmt --config cannot be combined with --dir/--file/--files");
      process.exit(1);
    }

    const fmtFiles: string[] = [];
    const seenFmtFiles = new Set<string>();

    const normalizeFmtPathFromConfig = (resolvedPath: string): string => {
      const rel = path.relative(process.cwd(), resolvedPath);
      if (!rel) return resolvedPath;
      if (rel === ".." || rel.startsWith(`..${path.sep}`)) return resolvedPath;
      return rel;
    };

    const addFmtFile = (filePath: string): void => {
      if (!matchesAgendaFileFilter(filePath, parsedFmtFile)) return;
      if (!matchesAgendaExcludeFileFilter(filePath, parsedFmtExcludeFile)) return;

      const dedupeKey = path.resolve(filePath);
      if (seenFmtFiles.has(dedupeKey)) return;
      seenFmtFiles.add(dedupeKey);
      fmtFiles.push(filePath);
    };

    for (const file of files) {
      addFmtFile(file);
    }

    if (dir) {
      const scanned = listOrgLikeFiles(dir, recursive);
      for (const filePath of scanned) {
        addFmtFile(filePath);
      }
    }

    if (fmtConfigPath) {
      const configPathResolved = path.resolve(fmtConfigPath);

      try {
        const cfg = loadConfig(configPathResolved);
        const configDir = path.dirname(configPathResolved);
        const resolvedFromConfig = resolveFilesFromConfig(cfg, configDir);

        for (const resolvedFile of resolvedFromConfig) {
          addFmtFile(normalizeFmtPathFromConfig(resolvedFile));
        }
      } catch (err) {
        console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
        process.exit(1);
      }
    }

    fmtFiles.sort((a, b) => a.localeCompare(b));

    if (fmtFiles.length === 0) {
      console.error(
        "Error: fmt found no matching files (provide --stdin, --dir DIR, --config PATH, or at least one file via --file/--files; check --file-match/--exclude-file filters)",
      );
      process.exit(1);
    }

    if (fmtCheck) {
      const changedFiles: string[] = [];
      for (const file of fmtFiles) {
        const raw = fs.readFileSync(file, "utf8");
        const out = formatOne(raw);
        if (out !== raw.replace(/\r\n/g, "\n")) {
          changedFiles.push(file);
        }
      }

      if (fmtFormat === "json") {
        emitFmtCheckJson(fmtFiles, changedFiles);
        if (changedFiles.length > 0) {
          process.exit(1);
        }
        return;
      }

      if (changedFiles.length > 0) {
        process.stdout.write(changedFiles.join("\n") + "\n");
        process.exit(1);
      }
      return;
    }

    if (!fmtApply) {
      if (fmtFiles.length !== 1) {
        console.error("Error: fmt without --apply requires exactly one file (use --check/--apply for multiple)");
        process.exit(1);
      }
      const targetFile = fmtFiles[0]!;
      const raw = fs.readFileSync(targetFile, "utf8");
      const out = formatOne(raw);

      if (fmtFormat === "json") {
        emitFmtPreviewJson(targetFile, out, out !== raw.replace(/\r\n/g, "\n"));
        return;
      }

      process.stdout.write(out);
      return;
    }

    const changedFiles: string[] = [];
    for (const file of fmtFiles) {
      const raw = fs.readFileSync(file, "utf8");
      const normalizedRaw = raw.replace(/\r\n/g, "\n");
      const out = formatOne(raw);
      if (out !== normalizedRaw) {
        fs.writeFileSync(file, out, "utf8");
        changedFiles.push(file);
      }
    }

    if (fmtFormat === "json") {
      emitFmtApplyJson(fmtFiles, changedFiles);
    }

    return;
  }

  if (command === "refile") {
    if (!refileFile) {
      console.error("Error: refile requires --file FILE");
      process.exit(1);
    }
    if (!refilePos) {
      console.error("Error: refile requires --pos LINE[:COL]");
      process.exit(1);
    }
    if (!refileToFile) {
      console.error("Error: refile requires --to-file FILE");
      process.exit(1);
    }

    const parsePosLine = (rawPos: string, flagName: string): number => {
      const line = parseInt(String(rawPos || "").split(":")[0] || "", 10);
      if (!Number.isFinite(line) || line < 1) {
        console.error(`Error: invalid ${flagName} ${rawPos}`);
        process.exit(1);
      }
      return line;
    };

    const findHeadingAtOrAbove = (
      lines: string[],
      line1: number,
    ): { lineIndex: number; level: number; line: string } | null => {
      const start = Math.min(Math.max(line1 - 1, 0), Math.max(0, lines.length - 1));
      for (let idx = start; idx >= 0; idx -= 1) {
        const line = lines[idx] ?? "";
        const m = /^(\*+)\s+/.exec(line);
        if (m) {
          return {
            lineIndex: idx,
            level: m[1]!.length,
            line,
          };
        }
      }
      return null;
    };

    const findSubtreeEndExclusive = (lines: string[], startLineIndex: number, level: number): number => {
      for (let idx = startLineIndex + 1; idx < lines.length; idx += 1) {
        const m = /^(\*+)\s+/.exec(lines[idx] ?? "");
        if (m && m[1]!.length <= level) {
          return idx;
        }
      }
      return lines.length;
    };

    const normalizeOutText = (lines: string[]): string => {
      const text = lines.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd();
      return text.length > 0 ? `${text}\n` : "";
    };

    const buildUnifiedDiff = (before: string, after: string, targetPath: string, tmpPrefix: string): string => {
      if (before === after) return "";

      let tmpDir: string | null = null;
      try {
        tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), tmpPrefix));
        const aPath = path.join(tmpDir, "before.org2");
        const bPath = path.join(tmpDir, "after.org2");
        fs.writeFileSync(aPath, before, "utf8");
        fs.writeFileSync(bPath, after, "utf8");

        const res = spawnSync(
          "diff",
          ["-u", "--label", targetPath, "--label", targetPath, aPath, bPath],
          { encoding: "utf8" },
        );
        if (res.status !== 0 && res.status !== 1) {
          throw new Error(res.stderr || `diff exited with status ${res.status}`);
        }

        return res.stdout || "";
      } finally {
        if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
      }
    };

    const sourcePathInput = refileFile;
    const destinationPathInput = refileToFile;
    const sourcePath = path.resolve(sourcePathInput);
    const destinationPath = path.resolve(destinationPathInput);
    const sameFile = sourcePath === destinationPath;

    const sourceRaw = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
    const sourceLines = sourceRaw.split("\n");

    const sourcePosLine1 = parsePosLine(refilePos, "--pos");
    const sourceHeading = findHeadingAtOrAbove(sourceLines, sourcePosLine1);
    if (!sourceHeading) {
      console.error("Error: no source headline found at or above --pos");
      process.exit(1);
    }

    const sourceEndExclusive = findSubtreeEndExclusive(sourceLines, sourceHeading.lineIndex, sourceHeading.level);
    const sourceSubtreeLines = sourceLines.slice(sourceHeading.lineIndex, sourceEndExclusive);
    const sourceSubtreeText = sourceSubtreeLines.join("\n").trimEnd() + "\n";

    const sourceRemainingLines = [
      ...sourceLines.slice(0, sourceHeading.lineIndex),
      ...sourceLines.slice(sourceEndExclusive),
    ];
    const sourceOutText = normalizeOutText(sourceRemainingLines);

    const destinationRaw = sameFile
      ? sourceRaw
      : fs.existsSync(destinationPath)
        ? fs.readFileSync(destinationPath, "utf8").replace(/\r\n/g, "\n")
        : "";

    const destinationBaseText = sameFile ? sourceOutText : destinationRaw;
    const destinationLines = destinationBaseText.length > 0 ? destinationBaseText.split("\n") : [];

    let destinationInsertIndex = destinationLines.length;
    let destinationHeadingLine1: number | null = null;
    let movedSubtreeLines = [...sourceSubtreeLines];
    let headingLevelDelta = 0;

    if (refileToPos) {
      const toPosLine1Raw = parsePosLine(refileToPos, "--to-pos");
      if (
        sameFile &&
        toPosLine1Raw >= sourceHeading.lineIndex + 1 &&
        toPosLine1Raw <= sourceEndExclusive
      ) {
        console.error("Error: --to-pos cannot point inside the subtree being moved");
        process.exit(1);
      }

      const removedLineCount = sourceEndExclusive - sourceHeading.lineIndex;
      const toPosLine1Adjusted =
        sameFile && toPosLine1Raw > sourceHeading.lineIndex + 1
          ? Math.max(1, toPosLine1Raw - removedLineCount)
          : toPosLine1Raw;

      const destinationHeading = findHeadingAtOrAbove(destinationLines, toPosLine1Adjusted);
      if (!destinationHeading) {
        console.error("Error: no destination headline found at or above --to-pos");
        process.exit(1);
      }

      destinationHeadingLine1 = destinationHeading.lineIndex + 1;
      destinationInsertIndex = findSubtreeEndExclusive(
        destinationLines,
        destinationHeading.lineIndex,
        destinationHeading.level,
      );

      headingLevelDelta = destinationHeading.level + 1 - sourceHeading.level;
      if (headingLevelDelta !== 0) {
        movedSubtreeLines = sourceSubtreeLines.map((line) => {
          const m = /^(\*+)(\s+.*)$/.exec(line);
          if (!m) return line;
          const nextLevel = Math.max(1, m[1]!.length + headingLevelDelta);
          return `${"*".repeat(nextLevel)}${m[2]!}`;
        });
      }
    }

    const movedBlockText = movedSubtreeLines.join("\n").trimEnd();
    const movedBlockLines = movedBlockText.length > 0 ? movedBlockText.split("\n") : [];
    const beforeDestination = destinationLines.slice(0, destinationInsertIndex);
    const afterDestination = destinationLines.slice(destinationInsertIndex);

    const destinationOutLines = [...beforeDestination];
    if (
      destinationOutLines.length > 0 &&
      (destinationOutLines[destinationOutLines.length - 1] ?? "").trim() !== ""
    ) {
      destinationOutLines.push("");
    }
    destinationOutLines.push(...movedBlockLines);
    if (afterDestination.length > 0 && (afterDestination[0] ?? "").trim() !== "") {
      destinationOutLines.push("");
    }
    destinationOutLines.push(...afterDestination);

    const destinationOutText = normalizeOutText(destinationOutLines);

    const sourceChanged = sameFile ? destinationOutText !== sourceRaw : sourceOutText !== sourceRaw;
    const destinationChanged = sameFile ? destinationOutText !== sourceRaw : destinationOutText !== destinationRaw;
    const changed = sameFile ? sourceChanged : sourceChanged || destinationChanged;

    const sourceDiff = buildUnifiedDiff(
      sourceRaw,
      sameFile ? destinationOutText : sourceOutText,
      sourcePathInput,
      "org2-refile-source-diff-",
    );
    const destinationDiff = sameFile
      ? ""
      : buildUnifiedDiff(destinationRaw, destinationOutText, destinationPathInput, "org2-refile-destination-diff-");
    const combinedDiff = [sourceDiff, destinationDiff].filter((part) => part.length > 0).join("\n");

    if (refileFormat === "diff") {
      if (combinedDiff) process.stdout.write(combinedDiff);
      return;
    }

    if (refileFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            kind: "refile",
            apply: refileApply,
            changed,
            sourceChanged,
            destinationChanged,
            sourcePath: sourcePathInput,
            destinationPath: destinationPathInput,
            sourceHeadlineLine1: sourceHeading.lineIndex + 1,
            sourceHeadline: sourceHeading.line,
            destinationHeadingLine1,
            headingLevelDelta,
            sourceSubtreeText,
            newSourceText: sameFile ? destinationOutText : sourceOutText,
            newDestinationText: destinationOutText,
            diff: combinedDiff,
          },
          null,
          2,
        ) + "\n",
      );

      if (!refileApply) return;
    }

    if (!refileApply) {
      process.stdout.write(
        `Would refile subtree starting at ${sourcePathInput}:${sourceHeading.lineIndex + 1} to ${destinationPathInput}` +
          (destinationHeadingLine1 ? ` under heading line ${destinationHeadingLine1}` : " (file end)") +
          "\nUse --apply to write changes.\n",
      );
      return;
    }

    if (!sameFile) {
      fs.mkdirSync(path.dirname(destinationPath), { recursive: true });
      fs.writeFileSync(sourcePath, sourceOutText, "utf8");
      fs.writeFileSync(destinationPath, destinationOutText, "utf8");
    } else {
      fs.writeFileSync(sourcePath, destinationOutText, "utf8");
    }

    if (refileFormat === "text") {
      process.stdout.write(
        `Refiled subtree from ${sourcePathInput}:${sourceHeading.lineIndex + 1} to ${destinationPathInput}` +
          (destinationHeadingLine1 ? ` under heading line ${destinationHeadingLine1}.` : ".") +
          "\n",
      );
    }

    return;
  }

  if (command === "archive") {
    if (files.length !== 1) {
      console.error("Error: archive requires exactly one file via --file/--files");
      process.exit(1);
    }
    if (!archivePos) {
      console.error("Error: archive requires --pos LINE[:COL]");
      process.exit(1);
    }

    const sourcePath = files[0]!;
    const raw = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
    const posLine = parseInt(archivePos.split(":")[0]!, 10);
    if (!Number.isFinite(posLine) || posLine < 1) {
      console.error(`Error: invalid --pos ${archivePos}`);
      process.exit(1);
    }

    const defaultArchivePath = sourcePath.endsWith(".org") ? `${sourcePath}_archive` : `${sourcePath}.archive`;
    const archivePath = archiveFile || defaultArchivePath;

    const lines = raw.split("\n");
    let headlineLineIndex = -1;
    for (let idx = Math.min(posLine - 1, lines.length - 1); idx >= 0; idx -= 1) {
      const line = lines[idx] ?? "";
      if (/^\*+\s+/.test(line)) {
        headlineLineIndex = idx;
        break;
      }
    }

    if (headlineLineIndex === -1) {
      console.error("Error: no headline found at or above --pos");
      process.exit(1);
    }

    const headlineLine = lines[headlineLineIndex] ?? "";
    const levelMatch = /^(\*+)\s+/.exec(headlineLine);
    const level = levelMatch ? levelMatch[1].length : 1;

    let endIndexExclusive = lines.length;
    for (let idx = headlineLineIndex + 1; idx < lines.length; idx += 1) {
      const line = lines[idx] ?? "";
      const m = /^(\*+)\s+/.exec(line);
      if (m && m[1].length <= level) {
        endIndexExclusive = idx;
        break;
      }
    }

    const subtreeLines = lines.slice(headlineLineIndex, endIndexExclusive);
    const remainingLines = [...lines.slice(0, headlineLineIndex), ...lines.slice(endIndexExclusive)];

    const subtreeText = subtreeLines.join("\n").trimEnd() + "\n";
    const newSourceText = remainingLines.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";

    // Handle --format diff
    if (archiveFormat === "diff") {
      const diffOutput = formatArchiveDiff(sourcePath, archivePath, subtreeText);
      process.stdout.write(diffOutput);
      return;
    }

    // Handle --format json (safe-edit primitive)
    if (archiveFormat === "json") {
      if (!archiveApply) {
        const payload = {
          kind: "archive",
          apply: false,
          sourcePath,
          archivePath,
          headlineLine1: headlineLineIndex + 1,
          headline: headlineLine,
          subtreeText,
          newSourceText,
          diff: formatArchiveDiff(sourcePath, archivePath, subtreeText),
        };
        process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
        return;
      }

      const existingArchive = fs.existsSync(archivePath)
        ? fs.readFileSync(archivePath, "utf8").replace(/\r\n/g, "\n")
        : "";
      const archiveOut = existingArchive.trimEnd() + "\n\n" + subtreeText;

      fs.writeFileSync(sourcePath, newSourceText, "utf8");
      fs.writeFileSync(archivePath, archiveOut, "utf8");

      const payload = {
        kind: "archive",
        apply: true,
        wrote: true,
        sourcePath,
        archivePath,
        headlineLine1: headlineLineIndex + 1,
        headline: headlineLine,
        subtreeText,
        newSourceText,
        diff: formatArchiveDiff(sourcePath, archivePath, subtreeText),
      };
      process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
      return;
    }

    if (!archiveApply) {
      process.stdout.write(
        `Would archive subtree starting at ${sourcePath}:${headlineLineIndex + 1} to ${archivePath}\n` +
          `Subtree first line: ${headlineLine}\n` +
          `Use --apply to write changes.\n`,
      );
      return;
    }

    const existingArchive = fs.existsSync(archivePath) ? fs.readFileSync(archivePath, "utf8").replace(/\r\n/g, "\n") : "";
    const archiveOut = existingArchive.trimEnd() + "\n\n" + subtreeText;

    fs.writeFileSync(sourcePath, newSourceText, "utf8");
    fs.writeFileSync(archivePath, archiveOut, "utf8");
    process.stdout.write(`Archived to ${archivePath}\n`);
    return;
  }

  // agenda
  // Determine files to process
  if (!dir && files.length === 0) {
    // Try to load from config
    const configPath = findConfigFile(process.cwd());
    if (configPath) {
      try {
        const config = loadConfig(configPath);
        const configDir = path.dirname(configPath);
        files = resolveFilesFromConfig(config, configDir);

        if (files.length === 0) {
          console.error(
            `Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`,
          );
          process.exit(1);
        }
      } catch (err) {
        console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
        process.exit(1);
      }
    } else {
      console.error("Error: provide either --dir, --files, or org2.json config");
      process.exit(1);
    }
  }

  if (dir && files.length === 0) {
    const listOrgFiles = (dirPath: string): string[] => {
      const out: string[] = [];
      const entries = fs.readdirSync(dirPath, { withFileTypes: true });
      for (const entry of entries) {
        const fullPath = path.join(dirPath, entry.name);
        if (entry.isDirectory()) {
          if (!recursive) continue;
          if (entry.name.startsWith(".")) continue;
          out.push(...listOrgFiles(fullPath));
          continue;
        }
        if (!entry.isFile()) continue;
        if (!(entry.name.endsWith(".org") || entry.name.endsWith(".org2"))) continue;
        if (entry.name.startsWith(".#")) continue; // Emacs lockfile
        out.push(fullPath);
      }
      return out;
    };

    files = listOrgFiles(dir);
  }

  const parsedAgendaStatus = parseAgendaStatusFilterArgs(agendaStatusFiltersRaw);
  if (parsedAgendaStatus.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --status value(s): ${parsedAgendaStatus.invalid.join(", ")}. Allowed: ${AGENDA_STATUS_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeStatus = parseAgendaExcludeStatusFilterArgs(agendaExcludeStatusFiltersRaw);
  if (parsedAgendaExcludeStatus.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-status value(s): ${parsedAgendaExcludeStatus.invalid.join(", ")}. Allowed: ${AGENDA_STATUS_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaKind = parseAgendaKindFilterArgs(agendaKindFiltersRaw);
  if (parsedAgendaKind.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --kind value(s): ${parsedAgendaKind.invalid.join(", ")}. Allowed: ${AGENDA_KIND_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeKind = parseAgendaExcludeKindFilterArgs(agendaExcludeKindFiltersRaw);
  if (parsedAgendaExcludeKind.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-kind value(s): ${parsedAgendaExcludeKind.invalid.join(", ")}. Allowed: ${AGENDA_KIND_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaWhen = parseAgendaWhenFilterArgs(agendaWhenFiltersRaw);
  if (parsedAgendaWhen.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --when value(s): ${parsedAgendaWhen.invalid.join(", ")}. Allowed: ${AGENDA_WHEN_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeWhen = parseAgendaExcludeWhenFilterArgs(agendaExcludeWhenFiltersRaw);
  if (parsedAgendaExcludeWhen.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-when value(s): ${parsedAgendaExcludeWhen.invalid.join(", ")}. Allowed: ${AGENDA_WHEN_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaWeekday = parseAgendaWeekdayFilterArgs(agendaWeekdayFiltersRaw);
  if (parsedAgendaWeekday.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --weekday value(s): ${parsedAgendaWeekday.invalid.join(", ")}. Allowed: ${AGENDA_WEEKDAY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeWeekday = parseAgendaExcludeWeekdayFilterArgs(agendaExcludeWeekdayFiltersRaw);
  if (parsedAgendaExcludeWeekday.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-weekday value(s): ${parsedAgendaExcludeWeekday.invalid.join(", ")}. Allowed: ${AGENDA_WEEKDAY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaWeek = parseAgendaWeekFilterArgs(agendaWeekFiltersRaw);
  if (parsedAgendaWeek.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --week value(s): ${parsedAgendaWeek.invalid.join(", ")}. Allowed: ${AGENDA_WEEK_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeWeek = parseAgendaExcludeWeekFilterArgs(agendaExcludeWeekFiltersRaw);
  if (parsedAgendaExcludeWeek.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-week value(s): ${parsedAgendaExcludeWeek.invalid.join(", ")}. Allowed: ${AGENDA_WEEK_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaDayOfMonth = parseAgendaDayOfMonthFilterArgs(agendaDayOfMonthFiltersRaw);
  if (parsedAgendaDayOfMonth.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --day-of-month value(s): ${parsedAgendaDayOfMonth.invalid.join(", ")}. Allowed: ${AGENDA_DAY_OF_MONTH_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeDayOfMonth = parseAgendaExcludeDayOfMonthFilterArgs(
    agendaExcludeDayOfMonthFiltersRaw,
  );
  if (parsedAgendaExcludeDayOfMonth.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-day-of-month value(s): ${parsedAgendaExcludeDayOfMonth.invalid.join(", ")}. Allowed: ${AGENDA_DAY_OF_MONTH_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaMonth = parseAgendaMonthFilterArgs(agendaMonthFiltersRaw);
  if (parsedAgendaMonth.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --month value(s): ${parsedAgendaMonth.invalid.join(", ")}. Allowed: ${AGENDA_MONTH_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeMonth = parseAgendaExcludeMonthFilterArgs(agendaExcludeMonthFiltersRaw);
  if (parsedAgendaExcludeMonth.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-month value(s): ${parsedAgendaExcludeMonth.invalid.join(", ")}. Allowed: ${AGENDA_MONTH_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaQuarter = parseAgendaQuarterFilterArgs(agendaQuarterFiltersRaw);
  if (parsedAgendaQuarter.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --quarter value(s): ${parsedAgendaQuarter.invalid.join(", ")}. Allowed: ${AGENDA_QUARTER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeQuarter = parseAgendaExcludeQuarterFilterArgs(agendaExcludeQuarterFiltersRaw);
  if (parsedAgendaExcludeQuarter.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-quarter value(s): ${parsedAgendaExcludeQuarter.invalid.join(", ")}. Allowed: ${AGENDA_QUARTER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaYear = parseAgendaYearFilterArgs(agendaYearFiltersRaw);
  if (parsedAgendaYear.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --year value(s): ${parsedAgendaYear.invalid.join(", ")}. Allowed: ${AGENDA_YEAR_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeYear = parseAgendaExcludeYearFilterArgs(agendaExcludeYearFiltersRaw);
  if (parsedAgendaExcludeYear.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-year value(s): ${parsedAgendaExcludeYear.invalid.join(", ")}. Allowed: ${AGENDA_YEAR_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaDate = parseAgendaDateFilterArgs(agendaDateFiltersRaw);
  if (parsedAgendaDate.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --date value(s): ${parsedAgendaDate.invalid.join(", ")}. Allowed: ${AGENDA_DATE_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeDate = parseAgendaExcludeDateFilterArgs(agendaExcludeDateFiltersRaw);
  if (parsedAgendaExcludeDate.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-date value(s): ${parsedAgendaExcludeDate.invalid.join(", ")}. Allowed: ${AGENDA_DATE_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaLevel = parseAgendaLevelFilterArgs(agendaLevelFiltersRaw);
  if (parsedAgendaLevel.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --level value(s): ${parsedAgendaLevel.invalid.join(", ")}. Allowed: ${AGENDA_LEVEL_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeLevel = parseAgendaExcludeLevelFilterArgs(agendaExcludeLevelFiltersRaw);
  if (parsedAgendaExcludeLevel.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-level value(s): ${parsedAgendaExcludeLevel.invalid.join(", ")}. Allowed: ${AGENDA_LEVEL_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaMatch = parseAgendaMatchFilterArgs(agendaMatchFiltersRaw);
  const parsedAgendaExcludeMatch = parseAgendaExcludeMatchFilterArgs(agendaExcludeMatchFiltersRaw);
  const parsedAgendaTag = parseAgendaTagFilterArgs(agendaTagFiltersRaw);
  const parsedAgendaId = parseAgendaIdFilterArgs(agendaIdFiltersRaw);
  if (parsedAgendaId.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --id value(s): ${parsedAgendaId.invalid.join(", ")}. Allowed: ${AGENDA_ID_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaTodo = parseAgendaTodoFilterArgs(agendaTodoFiltersRaw);
  const parsedAgendaTodoOrder = parseAgendaTodoOrderArgs(agendaTodoOrderRaw);
  const parsedAgendaStatusOrder = parseAgendaStatusOrderArgs(agendaStatusOrderRaw);
  if (parsedAgendaStatusOrder.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --status-order value(s): ${parsedAgendaStatusOrder.invalid.join(", ")}. Allowed: ${AGENDA_STATUS_ORDER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaKindOrder = parseAgendaKindOrderArgs(agendaKindOrderRaw);
  if (parsedAgendaKindOrder.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --kind-order value(s): ${parsedAgendaKindOrder.invalid.join(", ")}. Allowed: ${AGENDA_KIND_ORDER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaPriorityOrder = parseAgendaPriorityOrderArgs(agendaPriorityOrderRaw);
  if (parsedAgendaPriorityOrder.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --priority-order value(s): ${parsedAgendaPriorityOrder.invalid.join(", ")}. Allowed: ${AGENDA_PRIORITY_ORDER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaTagOrder = parseAgendaTagOrderArgs(agendaTagOrderRaw);
  const parsedAgendaEffortOrder = parseAgendaEffortOrderArgs(agendaEffortOrderRaw);
  const parsedAgendaPriority = parseAgendaPriorityFilterArgs(agendaPriorityFiltersRaw);
  if (parsedAgendaPriority.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --priority value(s): ${parsedAgendaPriority.invalid.join(", ")}. Allowed: ${AGENDA_PRIORITY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaTime = parseAgendaTimeFilterArgs(agendaTimeFiltersRaw);
  if (parsedAgendaTime.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --time value(s): ${parsedAgendaTime.invalid.join(", ")}. Allowed: ${AGENDA_TIME_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaEffort = parseAgendaEffortFilterArgs(agendaEffortFiltersRaw);
  const parsedAgendaProperty = parseAgendaPropertyFilterArgs(agendaPropertyFiltersRaw);
  if (parsedAgendaProperty.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --property value(s): ${parsedAgendaProperty.invalid.join(", ")}. Allowed: ${AGENDA_PROPERTY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaExcludeTag = parseAgendaExcludeTagFilterArgs(agendaExcludeTagFiltersRaw);
  const parsedAgendaExcludeId = parseAgendaExcludeIdFilterArgs(agendaExcludeIdFiltersRaw);
  if (parsedAgendaExcludeId.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-id value(s): ${parsedAgendaExcludeId.invalid.join(", ")}. Allowed: ${AGENDA_ID_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaExcludeTodo = parseAgendaExcludeTodoFilterArgs(agendaExcludeTodoFiltersRaw);
  const parsedAgendaExcludePriority = parseAgendaExcludePriorityFilterArgs(agendaExcludePriorityFiltersRaw);
  if (parsedAgendaExcludePriority.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-priority value(s): ${parsedAgendaExcludePriority.invalid.join(", ")}. Allowed: ${AGENDA_PRIORITY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaExcludeTime = parseAgendaExcludeTimeFilterArgs(agendaExcludeTimeFiltersRaw);
  if (parsedAgendaExcludeTime.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-time value(s): ${parsedAgendaExcludeTime.invalid.join(", ")}. Allowed: ${AGENDA_TIME_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaExcludeEffort = parseAgendaExcludeEffortFilterArgs(agendaExcludeEffortFiltersRaw);
  const parsedAgendaExcludeProperty = parseAgendaExcludePropertyFilterArgs(agendaExcludePropertyFiltersRaw);
  if (parsedAgendaExcludeProperty.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-property value(s): ${parsedAgendaExcludeProperty.invalid.join(", ")}. Allowed: ${AGENDA_PROPERTY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaFile = parseAgendaFileFilterArgs(agendaFileFiltersRaw);
  const parsedAgendaExcludeFile = parseAgendaExcludeFileFilterArgs(agendaExcludeFileFiltersRaw);
  const parsedAgendaSort = parseAgendaSortArgs(agendaSortRaw);
  if (parsedAgendaSort.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --sort value(s): ${parsedAgendaSort.invalid.join(", ")}. Allowed: ${AGENDA_SORT_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaGroup = parseAgendaGroupArgs(agendaGroupRaw);
  if (parsedAgendaGroup.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --group value(s): ${parsedAgendaGroup.invalid.join(", ")}. Allowed: ${AGENDA_GROUP_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaDateOrder = parseAgendaDateOrderArgs(agendaDateOrderRaw);
  if (parsedAgendaDateOrder.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --date-order value(s): ${parsedAgendaDateOrder.invalid.join(", ")}. Allowed: ${AGENDA_DATE_ORDER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  let agendaLimit: number | null = null;
  if (agendaLimitRaw.trim().length > 0) {
    const rawLimit = agendaLimitRaw.trim();
    if (!/^\d+$/.test(rawLimit)) {
      console.error(`Error: invalid agenda --limit value: ${agendaLimitRaw}. Expected a positive integer.`);
      process.exit(1);
    }
    const parsedLimit = Number.parseInt(rawLimit, 10);
    if (!Number.isFinite(parsedLimit) || parsedLimit < 1) {
      console.error(`Error: invalid agenda --limit value: ${agendaLimitRaw}. Expected a positive integer.`);
      process.exit(1);
    }
    agendaLimit = parsedLimit;
  }

  let agendaDayLimit: number | null = null;
  if (agendaDayLimitRaw.trim().length > 0) {
    const rawDayLimit = agendaDayLimitRaw.trim();
    if (!/^\d+$/.test(rawDayLimit)) {
      console.error(`Error: invalid agenda --day-limit value: ${agendaDayLimitRaw}. Expected a positive integer.`);
      process.exit(1);
    }
    const parsedDayLimit = Number.parseInt(rawDayLimit, 10);
    if (!Number.isFinite(parsedDayLimit) || parsedDayLimit < 1) {
      console.error(`Error: invalid agenda --day-limit value: ${agendaDayLimitRaw}. Expected a positive integer.`);
      process.exit(1);
    }
    agendaDayLimit = parsedDayLimit;
  }

  let agendaGroupLimit: number | null = null;
  if (agendaGroupLimitRaw.trim().length > 0) {
    const rawGroupLimit = agendaGroupLimitRaw.trim();
    if (!/^\d+$/.test(rawGroupLimit)) {
      console.error(
        `Error: invalid agenda --group-limit value: ${agendaGroupLimitRaw}. Expected a positive integer.`,
      );
      process.exit(1);
    }
    const parsedGroupLimit = Number.parseInt(rawGroupLimit, 10);
    if (!Number.isFinite(parsedGroupLimit) || parsedGroupLimit < 1) {
      console.error(
        `Error: invalid agenda --group-limit value: ${agendaGroupLimitRaw}. Expected a positive integer.`,
      );
      process.exit(1);
    }
    agendaGroupLimit = parsedGroupLimit;
  }

  let agendaFromDate: Date | null = null;
  if (agendaFromRaw.trim().length > 0) {
    const rawFrom = agendaFromRaw.trim();
    try {
      agendaFromDate = parseIsoDate(rawFrom);
    } catch {
      console.error(`Error: invalid agenda --from value: ${agendaFromRaw}. Expected YYYY-MM-DD.`);
      process.exit(1);
    }
  }

  let agendaToDate: Date | null = null;
  if (agendaToRaw.trim().length > 0) {
    const rawTo = agendaToRaw.trim();
    try {
      agendaToDate = parseIsoDate(rawTo);
    } catch {
      console.error(`Error: invalid agenda --to value: ${agendaToRaw}. Expected YYYY-MM-DD.`);
      process.exit(1);
    }
  }

  // Parse date range
  const startDate = agendaFromDate ?? parseIsoDate(today);
  const endDate = agendaToDate ? new Date(agendaToDate) : new Date(startDate);
  if (!agendaToDate) {
    endDate.setUTCDate(endDate.getUTCDate() + days - 1);
  }

  if (endDate < startDate) {
    console.error(
      `Error: invalid agenda date range: --to ${agendaToRaw || endDate.toISOString().slice(0, 10)} is before --from ${agendaFromRaw || startDate.toISOString().slice(0, 10)}.`,
    );
    process.exit(1);
  }

  const rangeDays = Math.floor((endDate.getTime() - startDate.getTime()) / (24 * 60 * 60 * 1000)) + 1;

  // Process files
  const allItems: ScheduledItem[] = [];
  let skippedFileCount = 0;

  for (const filePath of files) {
    if (!matchesAgendaFileFilter(filePath, parsedAgendaFile)) continue;
    if (!matchesAgendaExcludeFileFilter(filePath, parsedAgendaExcludeFile)) continue;

    try {
      const content = fs.readFileSync(filePath, "utf8");
      const normalized = content.replace(/\r\n/g, "\n");

      // Agenda intentionally uses a lightweight line-based scan so we can provide
      // stable 0-based line numbers for editor integrations (VS Code agenda → open file).
      // The canonical parser does not currently preserve source locations.
      const items = findScheduledItemsInText(
        normalized,
        filePath,
        startDate,
        endDate,
        includeOverdue,
        parsedAgendaStatus.filter,
        parsedAgendaExcludeStatus.filter,
        parsedAgendaKind.filter,
        parsedAgendaExcludeKind.filter,
        parsedAgendaWhen.filter,
        parsedAgendaExcludeWhen.filter,
        parsedAgendaWeekday.filter,
        parsedAgendaExcludeWeekday.filter,
        parsedAgendaWeek.filter,
        parsedAgendaExcludeWeek.filter,
        parsedAgendaDayOfMonth.filter,
        parsedAgendaExcludeDayOfMonth.filter,
        parsedAgendaMonth.filter,
        parsedAgendaExcludeMonth.filter,
        parsedAgendaQuarter.filter,
        parsedAgendaExcludeQuarter.filter,
        parsedAgendaYear.filter,
        parsedAgendaExcludeYear.filter,
        parsedAgendaDate.filter,
        parsedAgendaExcludeDate.filter,
        parsedAgendaLevel.filter,
        parsedAgendaExcludeLevel.filter,
        parsedAgendaMatch,
        parsedAgendaExcludeMatch,
        parsedAgendaTag,
        parsedAgendaId.filter,
        parsedAgendaTodo,
        parsedAgendaPriority.filter,
        parsedAgendaTime.filter,
        parsedAgendaEffort,
        parsedAgendaProperty.filter,
        parsedAgendaExcludeTag,
        parsedAgendaExcludeId.filter,
        parsedAgendaExcludeTodo,
        parsedAgendaExcludePriority.filter,
        parsedAgendaExcludeTime.filter,
        parsedAgendaExcludeEffort,
        parsedAgendaExcludeProperty.filter,
      );
      allItems.push(...items);
    } catch (err) {
      skippedFileCount += 1;
      if (verboseErrors) {
        console.error(`Error processing ${filePath}:`, err instanceof Error ? err.message : err);
      }
    }
  }

  if (skippedFileCount > 0 && !verboseErrors) {
    console.error(
      `Skipped ${skippedFileCount} file(s) due to parse errors (use --verbose-errors to see details).`,
    );
  }

  // Sort by date first, then optional user-selected tie-breakers.
  allItems.sort((a, b) =>
    compareAgendaItems(
      a,
      b,
      parsedAgendaGroup.groupOrder,
      parsedAgendaSort.sortOrder,
      parsedAgendaDateOrder.dateOrder,
      parsedAgendaTodoOrder,
      parsedAgendaStatusOrder.statusOrder,
      parsedAgendaKindOrder.kindOrder,
      parsedAgendaPriorityOrder.priorityOrder,
      parsedAgendaEffortOrder,
      parsedAgendaTagOrder,
    ),
  );

  const groupLimitedItems = applyAgendaGroupLimit(
    allItems,
    parsedAgendaGroup.groupOrder,
    agendaGroupLimit,
    parsedAgendaTagOrder,
  );
  const dayLimitedItems = applyAgendaDayLimit(groupLimitedItems, agendaDayLimit);
  const outputItems = agendaLimit ? dayLimitedItems.slice(0, agendaLimit) : dayLimitedItems;

  if (format === "json") {
    const startIso = startDate.toISOString().slice(0, 10);
    const endIso = endDate.toISOString().slice(0, 10);

    const overdue = outputItems.filter((it) => it.date < startIso);
    const upcoming = outputItems.filter((it) => it.date >= startIso);

    const group = (items: ScheduledItem[]) => {
      const byDate: Record<string, ScheduledItem[]> = {};
      for (const item of items) {
        (byDate[item.date] ??= []).push(item);
      }

      const serializeAgendaItem = (it: ScheduledItem) => ({
        todo: it.todo,
        headline: it.headline,
        kind: it.kind,
        file: it.filePath,
        line: it.lineNumber,
        ...(it.time ? { time: it.time } : {}),
        ...(it.effort ? { effort: it.effort } : {}),
        ...(it.id ? { id: it.id } : {}),
      });

      return Object.keys(byDate)
        .sort((a, b) => {
          const cmp = a.localeCompare(b);
          return parsedAgendaDateOrder.dateOrder === "desc" ? -cmp : cmp;
        })
        .map((date) => {
          const dayItems = byDate[date] ?? [];
          const dayPayload: {
            date: string;
            weekday: string;
            items: ReturnType<typeof serializeAgendaItem>[];
            groups?: Array<{ label: string; items: ReturnType<typeof serializeAgendaItem>[] }>;
          } = {
            date,
            weekday: formatDateHeader(date).split(" ").slice(1).join(" "),
            items: dayItems.map(serializeAgendaItem),
          };

          if (parsedAgendaGroup.groupOrder && parsedAgendaGroup.groupOrder.length > 0) {
            const groupedRows: Array<{ key: string; label: string; items: ReturnType<typeof serializeAgendaItem>[] }> = [];
            for (const row of dayItems) {
              const key = agendaGroupKeyForItem(row, parsedAgendaGroup.groupOrder, parsedAgendaTagOrder);
              const label = agendaGroupLabelForItem(row, parsedAgendaGroup.groupOrder, parsedAgendaTagOrder);
              const serialized = serializeAgendaItem(row);
              const previous = groupedRows[groupedRows.length - 1];

              if (!previous || previous.key !== key) {
                groupedRows.push({ key, label, items: [serialized] });
              } else {
                previous.items.push(serialized);
              }
            }

            dayPayload.groups = groupedRows.map(({ label, items: groupedItems }) => ({
              label,
              items: groupedItems,
            }));
          }

          return dayPayload;
        });
    };

    const payload = {
      $schema: "org2:agenda:v1",
      range: { start: startIso, end: endIso, days: rangeDays },
      overdue: group(overdue),
      days: group(upcoming),
      skippedFiles: skippedFileCount,
    };

    process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
    return;
  }

  // Output text
  const output = formatOutput(
    outputItems,
    startDate,
    parsedAgendaDateOrder.dateOrder,
    parsedAgendaGroup.groupOrder,
    parsedAgendaTagOrder,
  );
  process.stdout.write(output);
}

main().catch((err) => {
  console.error("Error:", err instanceof Error ? err.message : err);
  process.exit(1);
});
