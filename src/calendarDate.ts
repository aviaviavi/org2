export type IsoCalendarDate = {
  year: number;
  month: number;
  day: number;
  date: Date;
};

const ORG_WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;

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
