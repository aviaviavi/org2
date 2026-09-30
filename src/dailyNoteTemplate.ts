import fs from "node:fs";
import path from "node:path";
import type { Org2Config } from "./config.js";
import { resolveRoamDailiesRootDir } from "./config.js";

/**
 * Corpus-relative daily-note path templates such as
 * `journal/{YYYY}/{MM}/{YYYY}-{MM}-{DD}-wind-down.md`.
 *
 * Tokens are Moment/Obsidian-style names in braces and always render in
 * English with a Gregorian calendar. The macOS app implements the same
 * renderer in DailyNoteTemplate.swift; both share
 * test/fixtures/daily-note-templates.json.
 */

export const DAILY_NOTE_TEMPLATE_TOKENS = ["YYYY", "YY", "MMMM", "MMM", "MM", "M", "DD", "D", "dddd", "ddd"] as const;
export type DailyNoteTemplateToken = (typeof DAILY_NOTE_TEMPLATE_TOKENS)[number];

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

export type DailyNoteDate = { year: number; month: number; day: number };

export function dailyNoteDateFromIso(value: string): DailyNoteDate {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) throw new Error(`Invalid date: ${value}. Use YYYY-MM-DD.`);
  const date = { year: Number(match[1]), month: Number(match[2]), day: Number(match[3]) };
  if (!isValidDate(date)) throw new Error(`Invalid date: ${value}.`);
  return date;
}

export function dailyNoteDateToIso(date: DailyNoteDate): string {
  return `${String(date.year).padStart(4, "0")}-${pad2(date.month)}-${pad2(date.day)}`;
}

export function localDailyNoteDate(now: Date = new Date(), offsetDays = 0): DailyNoteDate {
  const shifted = new Date(now.getFullYear(), now.getMonth(), now.getDate() + offsetDays, 12);
  return { year: shifted.getFullYear(), month: shifted.getMonth() + 1, day: shifted.getDate() };
}

function pad2(value: number): string {
  return String(value).padStart(2, "0");
}

function isValidDate(date: DailyNoteDate): boolean {
  if (!Number.isInteger(date.year) || date.year < 1 || date.year > 9999) return false;
  if (!Number.isInteger(date.month) || date.month < 1 || date.month > 12) return false;
  const days = new Date(Date.UTC(date.year, date.month, 0)).getUTCDate();
  return Number.isInteger(date.day) && date.day >= 1 && date.day <= days;
}

function weekday(date: DailyNoteDate): number {
  return new Date(Date.UTC(date.year, date.month - 1, date.day)).getUTCDay();
}

function renderToken(token: DailyNoteTemplateToken, date: DailyNoteDate): string {
  switch (token) {
    case "YYYY": return String(date.year).padStart(4, "0");
    case "YY": return pad2(date.year % 100);
    case "MMMM": return MONTHS[date.month - 1];
    case "MMM": return MONTHS[date.month - 1].slice(0, 3);
    case "MM": return pad2(date.month);
    case "M": return String(date.month);
    case "DD": return pad2(date.day);
    case "D": return String(date.day);
    case "dddd": return WEEKDAYS[weekday(date)];
    case "ddd": return WEEKDAYS[weekday(date)].slice(0, 3);
  }
}

const TOKEN_PATTERN = /\{([^{}]*)\}/g;

/** Returns a user-facing problem, or null when the template is usable. */
export function dailyNoteTemplateProblem(template: string): string | null {
  const value = template.trim();
  if (!value) return "The daily note format is empty.";
  if (value.includes("\0")) return "The daily note format contains a NUL character.";
  if (value.startsWith("/") || value.startsWith("~") || /^[A-Za-z]:[\\/]/.test(value)) {
    return "The daily note format must be relative to the corpus folder.";
  }
  if (value.includes("\\")) return "Use / to separate folders in the daily note format.";
  const segments = value.split("/");
  if (segments.some((segment) => segment === "" || segment === "." || segment === "..")) {
    return "The daily note format cannot contain empty, . or .. folder names.";
  }
  const tokens = new Set<string>();
  for (const match of value.matchAll(TOKEN_PATTERN)) {
    if (!(DAILY_NOTE_TEMPLATE_TOKENS as readonly string[]).includes(match[1])) {
      return `Unknown date token {${match[1]}}. Use ${DAILY_NOTE_TEMPLATE_TOKENS.map((token) => `{${token}}`).join(", ")}.`;
    }
    tokens.add(match[1]);
  }
  if (value.replace(TOKEN_PATTERN, "").match(/[{}]/)) return "The daily note format has an unmatched { or }.";
  if (!tokens.has("DD") && !tokens.has("D")) return "The daily note format needs a day token: {DD} or {D}.";
  if (!["MM", "M", "MMM", "MMMM"].some((token) => tokens.has(token))) {
    return "The daily note format needs a month token: {MM}, {M}, {MMM}, or {MMMM}.";
  }
  const basename = segments[segments.length - 1];
  if (basename.replace(TOKEN_PATTERN, "x").startsWith(".")) return "The daily note filename cannot start with a dot.";
  return null;
}

export function renderDailyNoteTemplate(template: string, date: DailyNoteDate): string {
  const problem = dailyNoteTemplateProblem(template);
  if (problem) throw new Error(problem);
  return template.trim().replace(TOKEN_PATTERN, (_, token: DailyNoteTemplateToken) => renderToken(token, date));
}

export function configuredDailyNoteTemplate(config: Org2Config | null | undefined): string | null {
  const value = config?.roam?.dailyFileTemplate;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

/**
 * The daily note path for `date`. A valid `roam.dailyFileTemplate` wins;
 * otherwise the legacy `roam.dailiesDir/YYYY-MM-DD.{org,org2}` rule applies.
 */
export function resolveDailyNotePath(config: Org2Config | null | undefined, baseDir: string, date: DailyNoteDate): string {
  const template = configuredDailyNoteTemplate(config);
  if (template && !dailyNoteTemplateProblem(template)) {
    return path.resolve(baseDir, renderDailyNoteTemplate(template, date));
  }
  const directory = resolveRoamDailiesRootDir(config || {}, baseDir);
  const baseName = dailyNoteDateToIso(date);
  for (const extension of ["org", "org2"]) {
    const candidate = path.join(directory, `${baseName}.${extension}`);
    if (fs.existsSync(candidate)) return candidate;
  }
  return path.join(directory, `${baseName}.org`);
}

// ---------------------------------------------------------------------------
// Inference from an example file

export type DailyNoteTemplateCandidate = {
  template: string;
  /** The date the example file represents under this template. */
  date: string;
  /** Whether the template names a year; yearless templates reuse one file per calendar day. */
  hasYear: boolean;
};

type Role = "YYYY" | "YY" | "MM" | "M" | "DD" | "D" | "MMM" | "MMMM" | "ddd" | "dddd";

type TokenOption = {
  text: string;
  parts: Array<{ role: Role; value: number }>;
};

type PathToken = { text: string; segment: number; options: TokenOption[] };

function numericOptions(text: string): TokenOption[] {
  const n = (from: number, to: number) => Number(text.slice(from, to));
  const options: TokenOption[] = [];
  const add = (template: string, parts: Array<{ role: Role; value: number }>) => options.push({ text: template, parts });
  switch (text.length) {
    case 1:
      add("{M}", [{ role: "M", value: n(0, 1) }]);
      add("{D}", [{ role: "D", value: n(0, 1) }]);
      break;
    case 2:
      // Padded tokens come first: a two-digit day such as 29 most likely
      // belongs to a zero-padded format.
      add("{MM}", [{ role: "MM", value: n(0, 2) }]);
      add("{DD}", [{ role: "DD", value: n(0, 2) }]);
      if (!text.startsWith("0")) {
        add("{M}", [{ role: "M", value: n(0, 2) }]);
        add("{D}", [{ role: "D", value: n(0, 2) }]);
      }
      add("{YY}", [{ role: "YY", value: n(0, 2) }]);
      break;
    case 4:
      add("{YYYY}", [{ role: "YYYY", value: n(0, 4) }]);
      add("{MM}{DD}", [{ role: "MM", value: n(0, 2) }, { role: "DD", value: n(2, 4) }]);
      add("{DD}{MM}", [{ role: "DD", value: n(0, 2) }, { role: "MM", value: n(2, 4) }]);
      break;
    case 6:
      add("{YY}{MM}{DD}", [{ role: "YY", value: n(0, 2) }, { role: "MM", value: n(2, 4) }, { role: "DD", value: n(4, 6) }]);
      break;
    case 8:
      add("{YYYY}{MM}{DD}", [{ role: "YYYY", value: n(0, 4) }, { role: "MM", value: n(4, 6) }, { role: "DD", value: n(6, 8) }]);
      add("{MM}{DD}{YYYY}", [{ role: "MM", value: n(0, 2) }, { role: "DD", value: n(2, 4) }, { role: "YYYY", value: n(4, 8) }]);
      add("{DD}{MM}{YYYY}", [{ role: "DD", value: n(0, 2) }, { role: "MM", value: n(2, 4) }, { role: "YYYY", value: n(4, 8) }]);
      break;
  }
  return options.filter((option) => option.parts.every(({ role, value }) => {
    if (role === "YYYY") return value >= 1900 && value <= 2200;
    if (role === "MM" || role === "M") return value >= 1 && value <= 12;
    if (role === "DD" || role === "D") return value >= 1 && value <= 31;
    return true;
  }));
}

function alphaOptions(text: string): TokenOption[] {
  const options: TokenOption[] = [];
  MONTHS.forEach((name, index) => {
    if (text === name) options.push({ text: "{MMMM}", parts: [{ role: "MMMM", value: index + 1 }] });
    else if (text === name.slice(0, 3)) options.push({ text: "{MMM}", parts: [{ role: "MMM", value: index + 1 }] });
  });
  WEEKDAYS.forEach((name, index) => {
    if (text === name) options.push({ text: "{dddd}", parts: [{ role: "dddd", value: index }] });
    else if (text === name.slice(0, 3)) options.push({ text: "{ddd}", parts: [{ role: "ddd", value: index }] });
  });
  return options;
}

function tokenizePath(relativePath: string): PathToken[] {
  const tokens: PathToken[] = [];
  const segments = relativePath.split("/");
  segments.forEach((segment, segmentIndex) => {
    // The final extension is never a date.
    const isBasename = segmentIndex === segments.length - 1;
    const extensionIndex = isBasename ? segment.lastIndexOf(".") : -1;
    const stem = extensionIndex > 0 ? segment.slice(0, extensionIndex) : segment;
    const extension = extensionIndex > 0 ? segment.slice(extensionIndex) : "";
    for (const match of stem.matchAll(/\d+|[A-Za-z]+|[^A-Za-z\d]+/g)) {
      const text = match[0];
      const options = /^\d+$/.test(text) ? numericOptions(text) : /^[A-Za-z]+$/.test(text) ? alphaOptions(text) : [];
      tokens.push({ text, segment: segmentIndex, options });
    }
    if (extension) tokens.push({ text: extension, segment: segmentIndex, options: [] });
    if (segmentIndex < segments.length - 1) tokens.push({ text: "/", segment: segmentIndex, options: [] });
  });
  return tokens;
}

type Assignment = { year?: number; yy?: number; month?: number; day?: number; weekday?: number };

function merge(state: Assignment, parts: TokenOption["parts"]): Assignment | null {
  const next = { ...state };
  for (const { role, value } of parts) {
    const key: keyof Assignment = role === "YYYY" ? "year" : role === "YY" ? "yy" : role === "ddd" || role === "dddd" ? "weekday"
      : role === "DD" || role === "D" ? "day" : "month";
    if (next[key] !== undefined && next[key] !== value) return null;
    next[key] = value;
  }
  if (next.year !== undefined && next.yy !== undefined && next.year % 100 !== next.yy) return null;
  return next;
}

function nearestYear(month: number, day: number, reference: DailyNoteDate, yy?: number): number | null {
  const candidates: number[] = [];
  if (yy !== undefined) {
    const century = Math.floor(reference.year / 100) * 100;
    candidates.push(century - 100 + yy, century + yy, century + 100 + yy);
  } else {
    candidates.push(reference.year - 1, reference.year, reference.year + 1);
  }
  const referenceTime = Date.UTC(reference.year, reference.month - 1, reference.day);
  let best: { year: number; distance: number } | null = null;
  for (const year of candidates) {
    if (!isValidDate({ year, month, day })) continue;
    const distance = Math.abs(Date.UTC(year, month - 1, day) - referenceTime);
    if (!best || distance < best.distance) best = { year, distance };
  }
  return best?.year ?? null;
}

/**
 * Infers daily-note templates from one example path relative to the corpus.
 * Candidates are ordered best first and each renders back to the example.
 */
export function inferDailyNoteTemplates(relativePath: string, reference: DailyNoteDate = localDailyNoteDate()): DailyNoteTemplateCandidate[] {
  const normalized = relativePath.split(path.sep).join("/").replace(/^\.\/+/, "");
  if (!normalized || normalized.startsWith("/") || normalized.split("/").includes("..")) {
    throw new Error("Choose a daily note inside the corpus folder.");
  }
  if (normalized.includes("{") || normalized.includes("}")) return [];
  const tokens = tokenizePath(normalized);
  const lastSegment = normalized.split("/").length - 1;
  const referenceTime = Date.UTC(reference.year, reference.month - 1, reference.day);
  const scored: Array<DailyNoteTemplateCandidate & { score: number; order: number }> = [];
  let order = 0;
  let explored = 0;

  const visit = (index: number, state: Assignment, rendered: string[], dateInBasename: boolean, literalNumbers: string[]): void => {
    if (++explored > 50_000) return;
    if (index === tokens.length) {
      if (state.day === undefined || state.month === undefined) return;
      const year = state.year ?? nearestYear(state.month, state.day, reference, state.yy);
      if (year === null) return;
      const date = { year, month: state.month, day: state.day };
      if (!isValidDate(date)) return;
      if (state.weekday !== undefined && weekday(date) !== state.weekday) return;
      const template = rendered.join("");
      if (dailyNoteTemplateProblem(template)) return;
      if (renderDailyNoteTemplate(template, date) !== normalized) return;
      const distanceDays = Math.abs(Date.UTC(date.year, date.month - 1, date.day) - referenceTime) / 86_400_000;
      const hasYear = state.year !== undefined || state.yy !== undefined;
      // A literal number that spells part of the date (a 09 month folder)
      // almost certainly should have been a token.
      const dateSpellings = new Set([String(date.year), pad2(date.year % 100), pad2(date.month), String(date.month), pad2(date.day), String(date.day)]);
      const missedParts = literalNumbers.filter((text) => dateSpellings.has(text)).length;
      const score = (state.year !== undefined ? 40 : state.yy !== undefined ? 15 : 0)
        + (dateInBasename ? 30 : 0)
        - literalNumbers.length * 4
        - missedParts * 12
        - (/\{(MM|DD)\}/.test(template) && /\{(M|D)\}/.test(template) ? 2 : 0)
        - Math.min(distanceDays, 3650) / 30;
      scored.push({ template, date: dailyNoteDateToIso(date), hasYear, score, order: order++ });
      return;
    }
    const token = tokens[index];
    const isNumeric = /^\d+$/.test(token.text);
    for (const option of token.options) {
      const next = merge(state, option.parts);
      if (!next) continue;
      const touchesDayOrMonth = option.parts.some(({ role }) => !["YYYY", "YY", "ddd", "dddd"].includes(role));
      visit(index + 1, next, [...rendered, option.text], dateInBasename || (touchesDayOrMonth && token.segment === lastSegment), literalNumbers);
    }
    visit(index + 1, state, [...rendered, token.text], dateInBasename, isNumeric ? [...literalNumbers, token.text] : literalNumbers);
  };
  visit(0, {}, [], false, []);

  scored.sort((a, b) => b.score - a.score || a.order - b.order);
  // Mixed zero-padding ({MM} with {D}) only fits the example by accident, so
  // offer it only when nothing consistent does.
  const mixesPadding = (template: string) => /\{(MM|DD)\}/.test(template) && /\{(M|D)\}/.test(template);
  const consistent = scored.filter((candidate) => !mixesPadding(candidate.template));
  const seen = new Set<string>();
  const candidates: DailyNoteTemplateCandidate[] = [];
  for (const { template, date, hasYear } of consistent.length ? consistent : scored) {
    if (seen.has(template)) continue;
    seen.add(template);
    candidates.push({ template, date, hasYear });
    if (candidates.length === 5) break;
  }
  return candidates;
}
