export type IsoCalendarDate = {
  year: number;
  month: number;
  day: number;
  date: Date;
};

const ORG_WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;

export type OrgTimestampDelimiter = "<" | "[";

export function parseIsoCalendarDate(raw: string): IsoCalendarDate | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw);
  if (!match) return null;

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(0);
  date.setUTCHours(0, 0, 0, 0);
  date.setUTCFullYear(year, month - 1, day);

  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  ) {
    return null;
  }

  return { year, month, day, date };
}

export function formatOrgDateTimestamp(raw: string): string | null {
  const parsed = parseIsoCalendarDate(raw);
  if (!parsed) return null;
  return `<${raw} ${ORG_WEEKDAYS[parsed.date.getUTCDay()]}>`;
}

export function formatLocalOrgDate(date: Date): string {
  const year = String(date.getFullYear()).padStart(4, "0");
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day} ${ORG_WEEKDAYS[date.getDay()]}`;
}

export function formatLocalOrgTimestamp(
  date: Date,
  options: { delimiter?: OrgTimestampDelimiter; includeTime?: boolean } = {},
): string {
  const delimiter = options.delimiter ?? "<";
  const closingDelimiter = delimiter === "<" ? ">" : "]";
  const time = options.includeTime
    ? ` ${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`
    : "";
  return `${delimiter}${formatLocalOrgDate(date)}${time}${closingDelimiter}`;
}
