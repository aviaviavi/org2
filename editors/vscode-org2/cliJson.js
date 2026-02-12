function tryParseJson(value) {
  try {
    return JSON.parse(value);
  } catch {
    return undefined;
  }
}

function parseCliJsonPayload(stdout) {
  const text = String(stdout || '').trim();
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
