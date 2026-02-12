function tryParseJson(value) {
  try {
    return JSON.parse(value);
  } catch {
    return undefined;
  }
}

function normalizeCliOutput(stdout) {
  return String(stdout ?? '')
    .replace(/\uFEFF/g, '') // strip UTF-8 BOM if present
    .replace(/\x00/g, '') // strip stray null bytes from CLI/PTY output
    .replace(/\u001B\[[0-?]*[ -/]*[@-~]/g, '') // strip ANSI CSI sequences
    .replace(/\u001B\][^\u0007]*(?:\u0007|\u001B\\)/g, '') // strip ANSI OSC sequences
    .trim();
}

function parseCliJsonPayload(stdout) {
  const text = normalizeCliOutput(stdout);
  if (!text) return undefined;

  // Common case: stdout is pure JSON.
  const direct = tryParseJson(text);
  if (typeof direct !== 'undefined') return direct;

  // Parse trailing JSON block after noisy prefixes.
  // Walk backwards and parse the first start position whose suffix is valid JSON.
  for (let i = text.length - 1; i >= 0; i--) {
    const ch = text[i];
    if (ch !== '{' && ch !== '[') continue;

    const candidate = text.slice(i).trim();
    const parsed = tryParseJson(candidate);
    if (typeof parsed !== 'undefined') return parsed;
  }

  // Parse JSON block when noisy logs appear *after* JSON output.
  // Try line-bounded blocks from the bottom up so we prefer the latest JSON payload.
  const lines = text.split(/\r?\n/);
  for (let start = lines.length - 1; start >= 0; start--) {
    const firstChar = lines[start].trimStart()[0];
    if (firstChar !== '{' && firstChar !== '[') continue;

    for (let end = lines.length - 1; end >= start; end--) {
      const candidate = lines.slice(start, end + 1).join('\n').trim();
      const parsed = tryParseJson(candidate);
      if (typeof parsed !== 'undefined') return parsed;
    }
  }

  return undefined;
}

function parseChangedFlagFromCliJson(stdout) {
  const payload = parseCliJsonPayload(stdout);
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return undefined;
  return typeof payload.changed === 'boolean' ? payload.changed : undefined;
}

module.exports = {
  parseCliJsonPayload,
  parseChangedFlagFromCliJson,
};
