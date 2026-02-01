#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { parseOrgToCanonicalAst } from "./parser.js";
import { printCanonicalAstToOrg } from "./printer.js";
import { findConfigFile, loadConfig, resolveFilesFromConfig } from "./config.js";
import { updateTodoInFile, type TodoStatus } from "./todo.js";
import { planningKindFromArg, updatePlanningInFile, type PlanningKindArg } from "./planning.js";
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
  lineNumber: number;
  headline: string;
  todo: string | undefined;
  date: string;
  kind: string;
}

function findScheduledItems(
  ast: DocumentNode,
  filePath: string,
  startDate: Date,
  endDate: Date,
  includeOverdue: boolean
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
                if ((includeOverdue && isOverdue) || inRange) {
                  const todo = headline.todo;
                  if (!todo) continue;
                  if (todo === "DONE" || todo === "CANCELLED" || todo === "CANCELED") continue;

                  const titleText = headline.title
                    .filter((t) => t.type === "Text")
                    .map((t) => t.value)
                    .join("");

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
  let verboseErrors = false;

  let archiveFile = "";
  let archivePos = "";
  let archiveApply = false;
  let archiveFormat: "text" | "diff" = "text";

  // Todo status editing
  let todoAction: "set" | "toggle" = "toggle";
  let todoFile = "";
  let todoLine = 0;
  let todoStatus: TodoStatus | "" = "";
  let todoApply = false;
  let todoFormat: "text" | "json" = "json";
  let todoNow = ""; // ISO string

  // Planning editing
  let planAction: "set" = "set";
  let planFile = "";
  let planLine = 0;
  let planKind: PlanningKindArg | "" = "";
  let planDate = ""; // YYYY-MM-DD
  let planApply = false;
  let planFormat: "text" | "json" = "json";

  // Formatter
  let fmtStdin = false;
  let fmtApply = false;

  // Parse arguments
  let i = 0;
  while (i < args.length) {
    const arg = args[i];

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
      // Optional subcommand (reserved; currently only 'set')
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "set") {
          planAction = "set";
          i++;
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
        }
        i++;
      }
    } else if (arg === "--status") {
      i++;
      if (i < args.length) {
        todoStatus = args[i] as TodoStatus;
        i++;
      }
    } else if (arg === "--now") {
      i++;
      if (i < args.length) {
        todoNow = args[i]!;
        i++;
      }
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
    } else if (arg === "--kind") {
      i++;
      if (i < args.length) {
        planKind = args[i] as PlanningKindArg;
        i++;
      }
    } else if (arg === "--date") {
      i++;
      if (i < args.length) {
        planDate = args[i]!;
        i++;
      }
    } else if (arg === "--format") {
      i++;
      if (i < args.length) {
        const v = args[i];
        if (command === "archive" && (v === "text" || v === "diff")) {
          archiveFormat = v as "text" | "diff";
        } else if (command === "agenda" && (v === "text" || v === "json")) {
          format = v;
        } else if (command === "todo" && (v === "text" || v === "json")) {
          todoFormat = v;
        } else if (command === "plan" && (v === "text" || v === "json")) {
          planFormat = v;
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
        // - todo/plan only use the line component
        if (command === "archive") {
          archivePos = rawPos;
        } else if (command === "todo") {
          todoLine = parseInt(rawPos.split(":")[0]!, 10);
        } else if (command === "plan") {
          planLine = parseInt(rawPos.split(":")[0]!, 10);
        }
        i++;
      }
    } else if (arg === "--stdin") {
      fmtStdin = true;
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
      }
      i++;
    } else if (arg === "--verbose" || arg === "--verbose-errors") {
      verboseErrors = true;
      i++;
    } else {
      i++;
    }
  }

  if (command !== "agenda" && command !== "archive" && command !== "todo" && command !== "plan" && command !== "fmt" && command !== "lsp") {
    console.error(
      "Usage: org2 agenda [--dir DIR] [--recursive] [--files FILE ...] [--days N] [--today YYYY-MM-DD] [--format text|json] [--no-overdue] [--verbose-errors]",
    );
    console.error(
      "       org2 archive --file FILE --pos LINE[:COL] [--archive-file FILE] [--format text|diff] [--apply]",
    );
    console.error(
      "       org2 todo [set|toggle] --file FILE (--line N | --pos LINE[:COL]) [--status todo|in_progress|done|canceled] [--now ISO] [--format text|json] [--apply]",
    );
    console.error(
      "       org2 plan set --file FILE (--line N | --pos LINE[:COL]) --kind scheduled|deadline --date YYYY-MM-DD [--format text|json] [--apply]",
    );
    console.error(
      "       org2 fmt [--stdin] [--file FILE|--files FILE ...] [--apply]",
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

    const res = updateTodoInFile({
      filePath: todoFile,
      lineNumber: todoLine,
      ...(todoAction === "toggle" ? { toggle: true } : { status: todoStatus as TodoStatus }),
      ...(nowDate ? { now: nowDate } : {}),
      apply: todoApply,
    });

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
    if (!planDate) {
      console.error("Error: plan requires --date YYYY-MM-DD");
      process.exit(1);
    }

    const res = updatePlanningInFile({
      filePath: planFile,
      lineNumber: planLine,
      kind: planningKindFromArg(planKind as PlanningKindArg),
      date: planDate,
      apply: planApply,
    });

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

    if (fmtStdin) {
      const stdinRaw = fs.readFileSync(0, "utf8");
      process.stdout.write(formatOne(stdinRaw));
      return;
    }

    if (files.length === 0) {
      console.error("Error: fmt requires --stdin or at least one file via --file/--files");
      process.exit(1);
    }

    if (!fmtApply) {
      if (files.length !== 1) {
        console.error("Error: fmt without --apply requires exactly one file (use --apply for multiple)");
        process.exit(1);
      }
      const raw = fs.readFileSync(files[0]!, "utf8");
      process.stdout.write(formatOne(raw));
      return;
    }

    for (const file of files) {
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
        if (!entry.name.endsWith(".org")) continue;
        if (entry.name.startsWith(".#")) continue; // Emacs lockfile
        out.push(fullPath);
      }
      return out;
    };

    files = listOrgFiles(dir);
  }

  // Parse date range
  const startDate = parseIsoDate(today);
  const endDate = new Date(startDate);
  endDate.setDate(endDate.getDate() + days - 1);

  // Process files
  const allItems: ScheduledItem[] = [];
  let skippedFileCount = 0;

  for (const filePath of files) {
    try {
      const content = fs.readFileSync(filePath, "utf8");
      const normalized = content.replace(/\r\n/g, "\n");
      const ast = parseOrgToCanonicalAst(normalized);
      const items = findScheduledItems(ast, filePath, startDate, endDate, includeOverdue);
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

  // Sort by date
  allItems.sort((a, b) => a.date.localeCompare(b.date));

  if (format === "json") {
    const startIso = startDate.toISOString().slice(0, 10);
    const endIso = endDate.toISOString().slice(0, 10);

    const overdue = allItems.filter((it) => it.date < startIso);
    const upcoming = allItems.filter((it) => it.date >= startIso);

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
      range: { start: startIso, end: endIso, days },
      overdue: group(overdue),
      days: group(upcoming),
      skippedFiles: skippedFileCount,
    };

    process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
    return;
  }

  // Output text
  const output = formatOutput(allItems, startDate);
  process.stdout.write(output);
}

main().catch((err) => {
  console.error("Error:", err instanceof Error ? err.message : err);
  process.exit(1);
});
