#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import crypto from "node:crypto";
import os from "node:os";
import { spawnSync } from "node:child_process";
import { parseOrgToCanonicalAst } from "./parser.js";
import { printCanonicalAstToOrg } from "./printer.js";
import { findConfigFile, loadConfig, resolveFilesFromConfig } from "./config.js";
import { updateTodoInText, type TodoStatus } from "./todo.js";
import { planningKindFromArg, updatePlanningInText, type PlanningKindArg } from "./planning.js";
import { findBacklinksInText, type Backlink } from "./backlinks.js";
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

// Get today's date as YYYY-MM-DD string
function getTodayString(): string {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

interface ScheduledItem {
  filePath: string;
  // 0-based (VS Code uses 0-based positions)
  lineNumber: number;
  headline: string;
  todo: string | undefined;
  date: string;
  kind: string;
}

type AgendaStatusBucket = "todo" | "in_progress" | "done" | "canceled" | "custom";
type AgendaPlanningKind = "SCHEDULED" | "DEADLINE";
type AgendaWhenBucket = "overdue" | "today" | "upcoming";

type AgendaStatusFilter = Set<AgendaStatusBucket> | null;
type AgendaPlanningFilter = Set<AgendaPlanningKind> | null;
type AgendaWhenFilter = Set<AgendaWhenBucket> | null;
type AgendaMatchFilter = string[] | null;
type AgendaExcludeMatchFilter = string[] | null;
type AgendaTagFilter = string[] | null;
type AgendaTodoFilter = Set<string> | null;
type AgendaExcludeTagFilter = string[] | null;
type AgendaExcludeTodoFilter = Set<string> | null;
type AgendaFileFilter = string[] | null;
type AgendaExcludeFileFilter = string[] | null;
type AgendaSortKey = "file" | "headline" | "todo" | "kind" | "line";
type AgendaSortOrder = AgendaSortKey[] | null;

const AGENDA_STATUS_ALLOWED_HINT =
  "all, active, actionable, open, todo, in_progress, done, canceled, closed, custom";
const AGENDA_KIND_ALLOWED_HINT = "all, scheduled, deadline";
const AGENDA_WHEN_ALLOWED_HINT = "all, overdue, today, upcoming";
const AGENDA_SORT_ALLOWED_HINT = "default, file, headline, todo, kind, line";

function agendaStatusBucketForKeyword(todo: string | undefined): AgendaStatusBucket | null {
  const key = String(todo || "").trim().toUpperCase();
  if (!key) return null;

  if (key === "DONE" || key === "COMPLETED") return "done";
  if (key === "CANCELED" || key === "CANCELLED") return "canceled";
  if (["PROG", "IN_PROGRESS", "DOING", "STARTED", "WAITING", "BLOCKED", "NEXT"].includes(key)) {
    return "in_progress";
  }
  if (["TODO", "OPEN", "BACKLOG"].includes(key)) return "todo";

  return "custom";
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
    const token = tokenRaw.trim().toLowerCase();
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

    if (token === "open" || token === "todo") {
      selected.add("todo");
      return;
    }

    if (token === "in_progress" || token === "in-progress" || token === "inprogress" || token === "prog") {
      selected.add("in_progress");
      return;
    }

    if (token === "done") {
      selected.add("done");
      return;
    }

    if (token === "canceled" || token === "cancelled") {
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

function parseAgendaTodoFilterArgs(rawArgs: string[]): AgendaTodoFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toUpperCase())
    .filter(Boolean);

  return tokens.length > 0 ? new Set(tokens) : null;
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

  const sortOrder: AgendaSortKey[] = [];
  const seen = new Set<AgendaSortKey>();
  const invalid: string[] = [];

  const addToken = (tokenRaw: string): void => {
    const token = tokenRaw.trim().toLowerCase();
    if (!token) return;

    if (token === "default") {
      return;
    }

    let normalized: AgendaSortKey | null = null;
    if (token === "file" || token === "path") normalized = "file";
    else if (token === "headline" || token === "title") normalized = "headline";
    else if (token === "todo" || token === "status") normalized = "todo";
    else if (token === "kind" || token === "planning") normalized = "kind";
    else if (token === "line" || token === "position") normalized = "line";

    if (!normalized) {
      invalid.push(tokenRaw.trim());
      return;
    }

    if (!seen.has(normalized)) {
      seen.add(normalized);
      sortOrder.push(normalized);
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

function matchesAgendaTodoFilter(todo: string | undefined, todoFilter: AgendaTodoFilter): boolean {
  if (!todoFilter || todoFilter.size === 0) return true;
  const normalized = String(todo || "").trim().toUpperCase();
  if (!normalized) return false;
  return todoFilter.has(normalized);
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

function parseHeadlineLine(line: string): { todo?: string; title: string; tags: string[] } | null {
  const m = /^(\*+)\s+(.*)$/.exec(line);
  if (!m) return null;

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

  // Heuristic: TODO keywords are usually uppercase-ish.
  if (/^[A-Z][A-Z0-9_-]*$/.test(first) && pieces.length > 1) {
    return { todo: first, title: rest.slice(first.length).trimStart(), tags };
  }

  return { title: rest, tags };
}

function findScheduledItemsInText(
  content: string,
  filePath: string,
  startDate: Date,
  endDate: Date,
  includeOverdue: boolean,
  statusFilter: AgendaStatusFilter,
  planningFilter: AgendaPlanningFilter,
  whenFilter: AgendaWhenFilter,
  textFilter: AgendaMatchFilter,
  excludeTextFilter: AgendaExcludeMatchFilter,
  tagFilter: AgendaTagFilter,
  todoFilter: AgendaTodoFilter,
  excludeTagFilter: AgendaExcludeTagFilter,
  excludeTodoFilter: AgendaExcludeTodoFilter,
): ScheduledItem[] {
  const items: ScheduledItem[] = [];
  const lines = content.split("\n");

  let current: { todo?: string; title: string; tags: string[]; lineNumber: number } | null = null;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";

    // Headline line
    if (/^(\*+)\s+/.test(line)) {
      const parsed = parseHeadlineLine(line);
      if (parsed) {
        current = { ...parsed, lineNumber: i };
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
    if (!matchesAgendaTextFilter(current.title, textFilter)) continue;
    if (!matchesAgendaExcludeTextFilter(current.title, excludeTextFilter)) continue;
    if (!matchesAgendaTagFilter(current.tags, tagFilter)) continue;
    if (!matchesAgendaTodoFilter(todo, todoFilter)) continue;
    if (!matchesAgendaExcludeTagFilter(current.tags, excludeTagFilter)) continue;
    if (!matchesAgendaExcludeTodoFilter(todo, excludeTodoFilter)) continue;

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

      const tsRaw = m[2] ?? "";
      const dateStr = extractDateFromTimestamp(tsRaw);
      if (!dateStr) continue;

      const itemDate = parseIsoDate(dateStr);
      const inRange = itemDate >= startDate && itemDate <= endDate;
      const isOverdue = itemDate < startDate;
      const wantsOverdue = whenFilter ? whenFilter.has("overdue") : includeOverdue;

      // TODO state filtering:
      // - DONE/CANCELLED: only show if not overdue.
      // - PROG (and IN_PROGRESS): can appear when overdue regardless of includeOverdue
      //   because those tasks are still active.
      // - Everything else: show inRange, and show overdue when includeOverdue (or when
      //   --when explicitly requests overdue rows).
      if (isDoneLike && isOverdue) continue;
      if (!(inRange || (isProgLike && isOverdue) || (!isDoneLike && wantsOverdue && isOverdue))) continue;
      if (!matchesAgendaWhenFilter(itemDate, startDate, whenFilter)) continue;

      items.push({
        filePath,
        lineNumber: current.lineNumber,
        headline: current.title,
        todo,
        date: dateStr,
        kind,
      });
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
  planningFilter: AgendaPlanningFilter,
  whenFilter: AgendaWhenFilter,
  textFilter: AgendaMatchFilter,
  excludeTextFilter: AgendaExcludeMatchFilter,
  tagFilter: AgendaTagFilter,
  todoFilter: AgendaTodoFilter,
  excludeTagFilter: AgendaExcludeTagFilter,
  excludeTodoFilter: AgendaExcludeTodoFilter,
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
              const dateStr = extractDateFromTimestamp(raw);

              if (dateStr) {
                const itemDate = parseIsoDate(dateStr);
                const inRange = itemDate >= startDate && itemDate <= endDate;
                const isOverdue = itemDate < startDate;
                const wantsOverdue = whenFilter ? whenFilter.has("overdue") : includeOverdue;

                const todo = headline.todo;
                if (!todo) continue;

                const todoBucket = agendaStatusBucketForKeyword(todo);
                if (statusFilter && (!todoBucket || !statusFilter.has(todoBucket))) continue;

                const isDoneLike = todo === "DONE" || todo === "CANCELLED" || todo === "CANCELED";
                const isProgLike = todo === "PROG" || todo === "IN_PROGRESS";

                if (isDoneLike && isOverdue) continue;
                if (!(inRange || (isProgLike && isOverdue) || (!isDoneLike && wantsOverdue && isOverdue))) continue;
                if (!matchesAgendaWhenFilter(itemDate, startDate, whenFilter)) continue;

                const titleText = headline.title
                  .filter((t) => t.type === "Text")
                  .map((t) => t.value)
                  .join("");

                if (!matchesAgendaTextFilter(titleText, textFilter)) continue;
                if (!matchesAgendaExcludeTextFilter(titleText, excludeTextFilter)) continue;
                if (!matchesAgendaTagFilter(headline.tags ?? [], tagFilter)) continue;
                if (!matchesAgendaTodoFilter(todo, todoFilter)) continue;
                if (!matchesAgendaExcludeTagFilter(headline.tags ?? [], excludeTagFilter)) continue;
                if (!matchesAgendaExcludeTodoFilter(todo, excludeTodoFilter)) continue;
                if (planning.kind === "CLOSED") continue;
                if (planningFilter && !planningFilter.has(planning.kind as AgendaPlanningKind)) continue;

                items.push({
                  filePath,
                  lineNumber: 0, // Line numbers not tracked in AST, using 0
                  headline: titleText,
                  todo,
                  date: dateStr,
                  kind: planning.kind,
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

function formatOutput(items: ScheduledItem[], startDate: Date): string {
  if (items.length === 0) {
    return "No scheduled items in range.\n";
  }

  const startIso = startDate.toISOString().slice(0, 10);
  const overdueItems = items.filter((it) => it.date < startIso).sort((a, b) => a.date.localeCompare(b.date));
  const upcomingItems = items.filter((it) => it.date >= startIso).sort((a, b) => a.date.localeCompare(b.date));

  let output = "";

  if (overdueItems.length > 0) {
    output += formatSectionHeader(`OVERDUE (before ${startIso})`);
    output += formatByDate(overdueItems);

    if (upcomingItems.length > 0) {
      output += formatSectionHeader(`UPCOMING (from ${startIso})`);
    }
  }

  output += formatByDate(upcomingItems);
  return output;
}

function formatByDate(items: ScheduledItem[]): string {
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
  const dates = Array.from(byDate.keys()).sort();

  let output = "";
  for (let i = 0; i < dates.length; i++) {
    const date = dates[i];
    const dateHeader = formatDateHeader(date);
    const separator = "═".repeat(dateHeader.length + 2);

    output += `\n${separator}\n`;
    output += ` ${dateHeader}\n`;
    output += `${separator}\n\n`;

    const dayItems = byDate.get(date)!;
    for (const item of dayItems) {
      const status = item.todo || "ITEM";
      output += `  [${status}] ${item.headline} (${item.kind}) ${item.filePath}\n`;
    }

    output += "\n";
  }

  return output;
}

function compareAgendaItems(a: ScheduledItem, b: ScheduledItem, sortOrder: AgendaSortOrder): number {
  const byDate = a.date.localeCompare(b.date);
  if (byDate !== 0) return byDate;

  const compareByKey = (key: AgendaSortKey): number => {
    if (key === "file") {
      const byFile = a.filePath.localeCompare(b.filePath);
      if (byFile !== 0) return byFile;
      return a.lineNumber - b.lineNumber;
    }

    if (key === "headline") {
      return a.headline.localeCompare(b.headline);
    }

    if (key === "todo") {
      return String(a.todo || "").localeCompare(String(b.todo || ""));
    }

    if (key === "kind") {
      return a.kind.localeCompare(b.kind);
    }

    return a.lineNumber - b.lineNumber;
  };

  if (sortOrder && sortOrder.length > 0) {
    for (const key of sortOrder) {
      const cmp = compareByKey(key);
      if (cmp !== 0) return cmp;
    }
  }

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
  let agendaKindFiltersRaw: string[] = [];
  let agendaWhenFiltersRaw: string[] = [];
  let agendaMatchFiltersRaw: string[] = [];
  let agendaExcludeMatchFiltersRaw: string[] = [];
  let agendaTagFiltersRaw: string[] = [];
  let agendaTodoFiltersRaw: string[] = [];
  let agendaExcludeTagFiltersRaw: string[] = [];
  let agendaExcludeTodoFiltersRaw: string[] = [];
  let agendaFileFiltersRaw: string[] = [];
  let agendaExcludeFileFiltersRaw: string[] = [];
  let agendaSortRaw: string[] = [];
  let agendaLimitRaw = "";
  let agendaFromRaw = "";
  let agendaToRaw = "";
  let verboseErrors = false;
  let help = false;

  let archiveFile = "";
  let archivePos = "";
  let archiveApply = false;
  let archiveFormat: "text" | "diff" | "json" = "text";

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

  // Planning editing
  let planAction: "set" | "today" = "set";
  let planFile = "";
  let planLine = 0;
  let planKind: PlanningKindArg | "" = "";
  let planDate = ""; // YYYY-MM-DD
  let planApply = false;
  let planFormat: "text" | "json" | "diff" = "json";

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
        } else if (command === "plan") {
          planFile = args[i]!;
        } else if (command === "id") {
          idFile = args[i]!;
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
          todoStatus = args[i] as TodoStatus;
        }
        i++;
      }
    } else if (arg === "--now") {
      i++;
      if (i < args.length) {
        todoNow = args[i]!;
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
    } else if (arg === "--when") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaWhenFiltersRaw.push(args[i]!);
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
    } else if (arg === "--exclude-todo") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeTodoFiltersRaw.push(args[i]!);
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
    } else if (arg === "--limit") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaLimitRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--date") {
      i++;
      if (i < args.length) {
        planDate = args[i]!;
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
        }
        i++;
      }
    } else if (arg === "--id") {
      i++;
      if (i < args.length) {
        if (command === "id") {
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
        } else if (command === "agenda" && (v === "text" || v === "json")) {
          format = v;
        } else if (command === "todo" && (v === "text" || v === "json" || v === "diff")) {
          todoFormat = v as "text" | "json" | "diff";
        } else if (command === "plan" && (v === "text" || v === "json" || v === "diff")) {
          planFormat = v as "text" | "json" | "diff";
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
    } else if (arg === "--recursive") {
      recursive = true;
      i++;
    } else if (arg === "--no-overdue") {
      includeOverdue = false;
      i++;
    } else if (arg === "--overdue") {
      includeOverdue = true;
      i++;
    } else if (arg === "--archive-file") {
      i++;
      if (i < args.length) {
        archiveFile = args[i];
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
        } else if (command === "todo") {
          todoLine = parseInt(rawPos.split(":")[0]!, 10);
        } else if (command === "plan") {
          planLine = parseInt(rawPos.split(":")[0]!, 10);
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
      } else if (command === "plan") {
        planApply = true;
      } else if (command === "archive") {
        archiveApply = true;
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

  if (help) {
    console.error(
      "Usage: org2 agenda [--dir DIR] [--recursive] [--files FILE ...] [--days N] [--today YYYY-MM-DD] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--format text|json] [--status FILTER[,FILTER...]] [--kind FILTER[,FILTER...]] [--when FILTER[,FILTER...]] [--match TEXT[,TEXT...]] [--exclude-match TEXT[,TEXT...]] [--tag TAG[,TAG...]] [--todo KEYWORD[,KEYWORD...]] [--exclude-tag TAG[,TAG...]] [--exclude-todo KEYWORD[,KEYWORD...]] [--file-match TEXT[,TEXT...]] [--exclude-file TEXT[,TEXT...]] [--sort ORDER[,ORDER...]] [--limit N] [--no-overdue] [--verbose-errors]",
    );
    console.error(
      "       org2 archive --file FILE --pos LINE[:COL] [--archive-file FILE] [--format text|diff|json] [--apply]",
    );
    console.error(
      "       org2 todo [set|toggle] --file FILE (--line N | --pos LINE[:COL]) [--status todo|in_progress|done|canceled] [--now ISO] [--logbook] [--format text|json|diff] [--apply]",
    );
    console.error(
      "       org2 plan set --file FILE (--line N | --pos LINE[:COL]) --kind scheduled|deadline --date YYYY-MM-DD [--format text|json|diff] [--apply]",
      "       org2 plan today --file FILE (--line N | --pos LINE[:COL]) --kind scheduled|deadline [--format text|json|diff] [--apply]",
    );
    console.error(
      "       org2 id [get|ensure] --file FILE [--line N|--pos LINE[:COL]] [--id UUID] [--format text|json|diff] [--apply]",
    );
    console.error(
      "       org2 backlinks --id UUID [--dir DIR] [--recursive] [--files FILE ...] [--format text|json] [--verbose-errors]",
    );
    console.error(
      "       org2 query --id UUID [--dir DIR] [--recursive] [--files FILE ...] [--format text|json] [--verbose-errors]",
    );
    console.error(
      "       org2 fmt [--stdin] [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--config PATH] [--file-match TEXT[,TEXT...]] [--exclude-file TEXT[,TEXT...]] [--check] [--apply] [--format text|json]",
    );
    console.error(
      "       org2 roam db-sync --dir DIR [--recursive] [--format text|json] [--apply]",
    );
    console.error(
      "       org2 roam backlinks --id UUID [--dir DIR] [--recursive] [--files FILE ...] [--format text|json] [--verbose-errors]",
    );
    console.error(
      "       org2 roam node new --dir DIR --title TITLE [--id UUID] [--format text|json] [--apply]",
      "       org2 roam link insert-backlink --file FILE --pos LINE[:COL] --id UUID --title TITLE [--format text|json] [--apply]",
    );
    console.error(
      "       org2 lsp  # start the org2 Language Server (stdio)",
    );
    process.exit(0);
  }

  if (command !== "agenda" && command !== "archive" && command !== "todo" && command !== "plan" && command !== "fmt" && command !== "lsp" && command !== "id" && command !== "backlinks" && command !== "query" && command !== "roam") {
    console.error(
      "Usage: org2 agenda [--dir DIR] [--recursive] [--files FILE ...] [--days N] [--today YYYY-MM-DD] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--format text|json] [--status FILTER[,FILTER...]] [--kind FILTER[,FILTER...]] [--when FILTER[,FILTER...]] [--match TEXT[,TEXT...]] [--exclude-match TEXT[,TEXT...]] [--tag TAG[,TAG...]] [--todo KEYWORD[,KEYWORD...]] [--exclude-tag TAG[,TAG...]] [--exclude-todo KEYWORD[,KEYWORD...]] [--file-match TEXT[,TEXT...]] [--exclude-file TEXT[,TEXT...]] [--sort ORDER[,ORDER...]] [--limit N] [--no-overdue] [--verbose-errors]",
    );
    console.error(
      "       org2 archive --file FILE --pos LINE[:COL] [--archive-file FILE] [--format text|diff|json] [--apply]",
    );
    console.error(
      "       org2 todo [set|toggle] --file FILE (--line N | --pos LINE[:COL]) [--status todo|in_progress|done|canceled] [--now ISO] [--logbook] [--format text|json|diff] [--apply]",
    );
    console.error(
      "       org2 plan set --file FILE (--line N | --pos LINE[:COL]) --kind scheduled|deadline --date YYYY-MM-DD [--format text|json|diff] [--apply]",
      "       org2 plan today --file FILE (--line N | --pos LINE[:COL]) --kind scheduled|deadline [--format text|json|diff] [--apply]",
    );
    console.error(
      "       org2 id [get|ensure] --file FILE [--line N|--pos LINE[:COL]] [--id UUID] [--format text|json|diff] [--apply]", 
    );
    console.error(
      "       org2 backlinks --id UUID [--dir DIR] [--recursive] [--files FILE ...] [--format text|json] [--verbose-errors]",
    );
    console.error(
      "       org2 query --id UUID [--dir DIR] [--recursive] [--files FILE ...] [--format text|json] [--verbose-errors]",
    );
    console.error(
      "       org2 fmt [--stdin] [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--config PATH] [--file-match TEXT[,TEXT...]] [--exclude-file TEXT[,TEXT...]] [--check] [--apply] [--format text|json]",
    );
    console.error(
      "       org2 roam db-sync --dir DIR [--recursive] [--format text|json] [--apply]",
    );
    console.error(
      "       org2 roam backlinks --id UUID [--dir DIR] [--recursive] [--files FILE ...] [--format text|json] [--verbose-errors]",
    );
    console.error(
      "       org2 roam node new --dir DIR --title TITLE [--id UUID] [--format text|json] [--apply]",
      "       org2 roam link insert-backlink --file FILE --pos LINE[:COL] --id UUID --title TITLE [--format text|json] [--apply]",
    );
    console.error(
      "       org2 lsp  # start the org2 Language Server (stdio)",
    );
    process.exit(1);
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
      if (!roamLinkId) {
        console.error("Error: org2 roam link insert-backlink requires --id UUID");
        process.exit(1);
      }
      if (!roamLinkTitle) {
        console.error("Error: org2 roam link insert-backlink requires --title TITLE");
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
      const linkText = `[[id:${roamLinkId}][${roamLinkTitle}]]`;
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
              id: roamLinkId,
              title: roamLinkTitle,
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
    let skippedFileCount = 0;

    for (const filePath of files) {
      try {
        const content = fs.readFileSync(filePath, "utf8");
        backlinks.push(...findBacklinksInText(content, filePath, backlinksId));
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
        console.error("Error: todo set requires --status todo|in_progress|done|canceled");
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

  if (command === "fmt") {
    const formatOne = (rawIn: string): string => {
      const ast = parseOrgToCanonicalAst(rawIn.replace(/\r\n/g, "\n"));
      return printCanonicalAstToOrg(ast);
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

    const parsedFmtFile = parseAgendaFileFilterArgs(fmtFileFiltersRaw);
    const parsedFmtExcludeFile = parseAgendaExcludeFileFilterArgs(fmtExcludeFileFiltersRaw);

    if (fmtFormat === "json" && fmtApply) {
      console.error("Error: fmt --format json does not support --apply");
      process.exit(1);
    }

    if (fmtStdin) {
      if (fmtConfigPath) {
        console.error("Error: fmt --stdin cannot be combined with --config");
        process.exit(1);
      }
      if (parsedFmtFile || parsedFmtExcludeFile) {
        console.error("Error: fmt --stdin cannot be combined with --file-match/--exclude-file");
        process.exit(1);
      }
      if (fmtFormat === "json") {
        console.error("Error: fmt --stdin does not support --format json");
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
      process.stdout.write(formatOne(stdinRaw));
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

    for (const file of fmtFiles) {
      const raw = fs.readFileSync(file, "utf8");
      const out = formatOne(raw);
      fs.writeFileSync(file, out, "utf8");
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

  const parsedAgendaKind = parseAgendaKindFilterArgs(agendaKindFiltersRaw);
  if (parsedAgendaKind.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --kind value(s): ${parsedAgendaKind.invalid.join(", ")}. Allowed: ${AGENDA_KIND_ALLOWED_HINT}`,
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

  const parsedAgendaMatch = parseAgendaMatchFilterArgs(agendaMatchFiltersRaw);
  const parsedAgendaExcludeMatch = parseAgendaExcludeMatchFilterArgs(agendaExcludeMatchFiltersRaw);
  const parsedAgendaTag = parseAgendaTagFilterArgs(agendaTagFiltersRaw);
  const parsedAgendaTodo = parseAgendaTodoFilterArgs(agendaTodoFiltersRaw);
  const parsedAgendaExcludeTag = parseAgendaExcludeTagFilterArgs(agendaExcludeTagFiltersRaw);
  const parsedAgendaExcludeTodo = parseAgendaExcludeTodoFilterArgs(agendaExcludeTodoFiltersRaw);
  const parsedAgendaFile = parseAgendaFileFilterArgs(agendaFileFiltersRaw);
  const parsedAgendaExcludeFile = parseAgendaExcludeFileFilterArgs(agendaExcludeFileFiltersRaw);
  const parsedAgendaSort = parseAgendaSortArgs(agendaSortRaw);
  if (parsedAgendaSort.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --sort value(s): ${parsedAgendaSort.invalid.join(", ")}. Allowed: ${AGENDA_SORT_ALLOWED_HINT}`,
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
    endDate.setDate(endDate.getDate() + days - 1);
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
        parsedAgendaKind.filter,
        parsedAgendaWhen.filter,
        parsedAgendaMatch,
        parsedAgendaExcludeMatch,
        parsedAgendaTag,
        parsedAgendaTodo,
        parsedAgendaExcludeTag,
        parsedAgendaExcludeTodo,
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
  allItems.sort((a, b) => compareAgendaItems(a, b, parsedAgendaSort.sortOrder));

  const outputItems = agendaLimit ? allItems.slice(0, agendaLimit) : allItems;

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
      return Object.keys(byDate)
        .sort()
        .map((date) => ({
          date,
          weekday: formatDateHeader(date).split(" ").slice(1).join(" "),
          items: (byDate[date] ?? []).map((it) => ({
            todo: it.todo,
            headline: it.headline,
            kind: it.kind,
            file: it.filePath,
            line: it.lineNumber,
          })),
        }));
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
  const output = formatOutput(outputItems, startDate);
  process.stdout.write(output);
}

main().catch((err) => {
  console.error("Error:", err instanceof Error ? err.message : err);
  process.exit(1);
});
