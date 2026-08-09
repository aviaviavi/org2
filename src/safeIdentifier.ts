const SAFE_IDENTIFIER_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

export function safeIdentifier(
  raw: string,
  options: { label?: string; invalidMessage?: (raw: string) => string } = {},
): string {
  const value = String(raw || "").trim();
  if (!SAFE_IDENTIFIER_PATTERN.test(value)) {
    throw new Error(
      options.invalidMessage?.(raw)
      || `${options.label || "id"} must start with an alphanumeric character and contain only letters, numbers, dots, underscores, or dashes`,
    );
  }
  return value;
}
