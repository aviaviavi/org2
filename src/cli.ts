#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { parseOrgToCanonicalAst } from "./parser.js";
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
  endDate: Date
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
                // Check if within range (inclusive)
                if (itemDate >= startDate && itemDate <= endDate) {
                  const titleText = headline.title
                    .filter((t) => t.type === "Text")
                    .map((t) => t.value)
                    .join("");

                  items.push({
                    filePath,
                    lineNumber: 0, // Line numbers not tracked in AST, using 0
                    headline: titleText,
                    todo: headline.todo,
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
  const date = new Date(dateStr);
  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const dayName = days[date.getDay()];
  return `${dateStr} ${dayName}`;
}

function formatOutput(items: ScheduledItem[]): string {
  if (items.length === 0) {
    return "No scheduled items in range.\n";
  }

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
  let days = 1;
  let today = getTodayString();
  let verboseErrors = false;

  // Parse arguments
  let i = 0;
  while (i < args.length) {
    const arg = args[i];

    if (arg === "agenda") {
      command = "agenda";
      i++;
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
    } else if (arg === "--verbose" || arg === "--verbose-errors") {
      verboseErrors = true;
      i++;
    } else {
      i++;
    }
  }

  if (command !== "agenda") {
    console.error(
      "Usage: org2 agenda [--dir DIR] [--files FILE ...] [--days N] [--today YYYY-MM-DD] [--verbose-errors]",
    );
    process.exit(1);
  }

  // Determine files to process
  if (!dir && files.length === 0) {
    console.error("Error: provide either --dir or --files");
    process.exit(1);
  }

  if (dir && files.length === 0) {
    // Collect all .org files in dir
    const entries = fs.readdirSync(dir);
    for (const entry of entries) {
      if (!entry.endsWith(".org")) continue;
      if (entry.startsWith(".#")) continue; // Emacs lockfile
      files.push(path.join(dir, entry));
    }
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
      const items = findScheduledItems(ast, filePath, startDate, endDate);
      allItems.push(...items);
    } catch (err) {
      skippedFileCount += 1;
      if (verboseErrors) {
        console.error(`Error processing ${filePath}:`, err instanceof Error ? err.message : err);
      }
    }
  }

  if (skippedFileCount > 0 && !verboseErrors) {
    console.error(`Skipped ${skippedFileCount} file(s) due to parse errors (use --verbose-errors to see details).`);
  }

  // Sort by date
  allItems.sort((a, b) => a.date.localeCompare(b.date));

  // Output
  const output = formatOutput(allItems);
  process.stdout.write(output);
}

main().catch((err) => {
  console.error("Error:", err instanceof Error ? err.message : err);
  process.exit(1);
});
