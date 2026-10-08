// Celorga names with their pre-rename Org2 equivalents (docs/rename/celorga.org,
// "Dual names"). Readers accept both spellings and prefer Celorga; writers keep
// the legacy spelling so 0.8.x apps and agents keep understanding prompts.

export const MARKER_PREFIX = "CELORGA_";
export const LEGACY_MARKER_PREFIX = "ORG2_";
export const METHOD_NAMESPACE = "celorga";
export const LEGACY_METHOD_NAMESPACE = "org2";

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function markerSuffix(name) {
  return String(name).replace(/^(?:CELORGA|ORG2)_/i, "");
}

/** `CELORGA_X` then `ORG2_X` for a marker given in either spelling (or bare `X`). */
export function markerNames(name) {
  const suffix = markerSuffix(name);
  return [MARKER_PREFIX + suffix, LEGACY_MARKER_PREFIX + suffix];
}

/**
 * Read a `NAME: value` prompt line, preferring `CELORGA_NAME` over `ORG2_NAME`.
 * `valuePattern` is a regex source with one capture group for the value;
 * `space` is the whitespace allowed around it.
 */
export function markerValue(text, name, valuePattern = "(\\S+)", space = "[ \\t]*") {
  const source = String(text || "");
  for (const marker of markerNames(name)) {
    const value = source.match(new RegExp(`^${escapeRegExp(marker)}:${space}${valuePattern}${space}$`, "mi"))?.[1];
    if (value !== undefined) return value;
  }
  return undefined;
}

/** Whether `text` contains a `CELORGA_NAME: value` or `ORG2_NAME: value` line/substring. */
export function includesMarker(text, name, value) {
  const source = String(text || "");
  return markerNames(name).some((marker) => source.includes(`${marker}: ${value}`));
}

/** `celorga.x.y` then `org2.x.y` for a gateway method or node command in either spelling. */
export function methodNames(name) {
  const suffix = String(name).replace(/^(?:celorga|org2)\./, "");
  return [`${METHOD_NAMESPACE}.${suffix}`, `${LEGACY_METHOD_NAMESPACE}.${suffix}`];
}

/** `celorga:kind:v1` and `org2:kind:v1` are the same record type. */
export function schemaMatches(value, id) {
  if (typeof value !== "string") return false;
  const suffix = String(id).replace(/^(?:org2|celorga):/, "");
  return value === `${METHOD_NAMESPACE}:${suffix}` || value === `${LEGACY_METHOD_NAMESPACE}:${suffix}`;
}
