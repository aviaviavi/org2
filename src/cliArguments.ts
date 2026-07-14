export function parseNonNegativeIntegerArgument(raw: string | undefined): number | null {
  if (raw === undefined || !/^\d+$/.test(raw)) return null;

  const value = Number(raw);
  return Number.isSafeInteger(value) ? value : null;
}
