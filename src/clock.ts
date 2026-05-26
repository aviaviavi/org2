import fs from "node:fs";
import path from "node:path";

export type OrgClockInterval = {
  file: string;
  line: number;
  nodeKey: string;
  heading: string;
  level?: number;
  tags: string[];
  project?: string;
  raw: string;
  start: string;
  end: string;
  minutes: number;
};

export type OrgClockIssue = {
  type: "malformed-clock" | "overlapping-clock";
  severity: "warning" | "error";
  file: string;
  line: number;
  nodeKey?: string;
  message: string;
  raw?: string;
  overlapsLine?: number;
};

export type OrgClockSummary = {
  totalMinutes: number;
  byDay: Record<string, number>;
  byHeading: Record<string, number>;
  byTag: Record<string, number>;
  byProject: Record<string, number>;
  byFile: Record<string, number>;
};

export type OrgClockReport = {
  intervals: OrgClockInterval[];
  issues: OrgClockIssue[];
  summary: OrgClockSummary;
};

export function parseClockTimestamp(raw: string): Date | null {
  const match = /[<[\[](\d{4})-(\d{2})-(\d{2})(?:\s+\S+)?\s+(\d{1,2}):(\d{2})[>\]]/.exec(raw);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  if (hour > 23 || minute > 59) return null;
  const date = new Date(Date.UTC(year, month - 1, day, hour, minute));
  return Number.isNaN(date.getTime()) ? null : date;
}

export function parseClockLine(line: string): { start: Date; end: Date; rawRange: string } | null {
  const match = /^\s*CLOCK:\s*(\[[^\]]+\]|<[^>]+>)--(\[[^\]]+\]|<[^>]+>)/.exec(line);
  if (!match) return null;
  const start = parseClockTimestamp(match[1] || "");
  const end = parseClockTimestamp(match[2] || "");
  if (!start || !end || end.getTime() <= start.getTime()) return null;
  return { start, end, rawRange: `${match[1]}--${match[2]}` };
}

function isoMinute(date: Date): string {
  return date.toISOString().slice(0, 16) + "Z";
}

function add(summary: Record<string, number>, key: string | undefined, minutes: number): void {
  const normalized = (key || "").trim() || "(none)";
  summary[normalized] = (summary[normalized] || 0) + minutes;
}

function relativePath(rootDir: string, filePath: string): string {
  const rel = path.relative(rootDir, filePath);
  return (rel && !rel.startsWith("..") ? rel : filePath).replace(/\\/g, "/");
}

function parseHeading(line: string): { level: number; title: string; tags: string[] } | null {
  const match = /^(\*+)\s+(.*?)\s*$/.exec(line);
  if (!match) return null;
  let rest = String(match[2] || "").trim();
  const tagMatch = /\s+(:[A-Za-z0-9_@#%:]+:)\s*$/.exec(rest);
  const tags = tagMatch ? String(tagMatch[1]).split(":").filter(Boolean) : [];
  if (tagMatch) rest = rest.slice(0, tagMatch.index).trim();
  const first = rest.split(/\s+/)[0]?.toUpperCase() || "";
  if (["TODO", "IN_PROGRESS", "DONE", "CANCELED", "CANCELLED"].includes(first)) rest = rest.slice(first.length).trim();
  return { level: match[1]!.length, title: rest, tags };
}

export function extractClockReport(files: string[], opts?: { rootDir?: string }): OrgClockReport {
  const rootDir = path.resolve(opts?.rootDir || process.cwd());
  const intervals: OrgClockInterval[] = [];
  const issues: OrgClockIssue[] = [];

  for (const filePath of Array.from(new Set(files.map((f) => path.resolve(f)))).sort()) {
    const file = relativePath(rootDir, filePath);
    const lines = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n").split("\n");
    let current: { line: number; level: number; title: string; tags: string[]; project?: string } = { line: 1, level: 0, title: path.basename(file), tags: [] };
    const stack: typeof current[] = [];

    for (let i = 0; i < lines.length; i += 1) {
      const line = lines[i] || "";
      const heading = parseHeading(line);
      if (heading) {
        while (stack.length && stack[stack.length - 1]!.level >= heading.level) stack.pop();
        const parentProject = [...stack].reverse().find((h) => h.tags.includes("project"))?.title;
        current = { line: i + 1, ...heading, project: heading.tags.includes("project") ? heading.title : parentProject };
        stack.push(current);
        continue;
      }
      if (!/^\s*CLOCK:/.test(line)) continue;
      const parsed = parseClockLine(line);
      const nodeKey = current.level > 0 ? `heading:${file}:${current.line}` : `file:${file}`;
      if (!parsed) {
        issues.push({ type: "malformed-clock", severity: "error", file, line: i + 1, nodeKey, raw: line, message: "CLOCK entry must contain a valid start/end timestamp range with end after start." });
        continue;
      }
      const minutes = Math.round((parsed.end.getTime() - parsed.start.getTime()) / 60000);
      intervals.push({ file, line: i + 1, nodeKey, heading: current.title, level: current.level || undefined, tags: current.tags, project: current.project, raw: line.trim(), start: isoMinute(parsed.start), end: isoMinute(parsed.end), minutes });
    }
  }

  const byFile = new Map<string, OrgClockInterval[]>();
  for (const interval of intervals) byFile.set(interval.file, [...(byFile.get(interval.file) || []), interval]);
  for (const group of byFile.values()) {
    const sorted = group.slice().sort((a, b) => a.start.localeCompare(b.start));
    for (let i = 1; i < sorted.length; i += 1) {
      const prev = sorted[i - 1]!;
      const curr = sorted[i]!;
      if (curr.start < prev.end) issues.push({ type: "overlapping-clock", severity: "warning", file: curr.file, line: curr.line, nodeKey: curr.nodeKey, overlapsLine: prev.line, raw: curr.raw, message: `CLOCK entry overlaps line ${prev.line}.` });
    }
  }

  const summary: OrgClockSummary = { totalMinutes: 0, byDay: {}, byHeading: {}, byTag: {}, byProject: {}, byFile: {} };
  for (const interval of intervals) {
    summary.totalMinutes += interval.minutes;
    add(summary.byDay, interval.start.slice(0, 10), interval.minutes);
    add(summary.byHeading, interval.heading, interval.minutes);
    add(summary.byProject, interval.project, interval.minutes);
    add(summary.byFile, interval.file, interval.minutes);
    for (const tag of interval.tags) add(summary.byTag, tag, interval.minutes);
  }
  return { intervals, issues, summary };
}
