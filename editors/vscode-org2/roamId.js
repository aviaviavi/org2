const uuidSource = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
const uuidExactRe = new RegExp(`^(${uuidSource})$`);
const roamIdSchemeRe = new RegExp(`^id:(${uuidSource})$`, 'i');
const roamIdLinkPartsRe = new RegExp(`^\\[\\[id:(${uuidSource})(?:\\]\\[([^\\]\\n]*))?\\]\\]$`, 'i');
const roamUuidAnywhereRe = new RegExp(`(${uuidSource})`, 'i');
const roamIdTokenGlobalRe = /\bid:[^\s\]\[(){}<>,"']+/gi;

function parseRoamIdLink(value) {
  const raw = String(value || '').trim();
  if (!raw) return null;

  const link = roamIdLinkPartsRe.exec(raw);
  if (!link) return null;

  return {
    id: String(link[1] || '').toLowerCase(),
    title: String(link[2] || '').trim(),
  };
}

function extractRoamUuid(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';

  const direct = uuidExactRe.exec(raw);
  if (direct) return direct[1].toLowerCase();

  const idScheme = roamIdSchemeRe.exec(raw);
  if (idScheme) return idScheme[1].toLowerCase();

  const idLink = parseRoamIdLink(raw);
  if (idLink) return idLink.id;

  const any = roamUuidAnywhereRe.exec(raw);
  if (any) return any[1].toLowerCase();

  return '';
}

function sanitizeBacklinkContextLine(value) {
  const raw = String(value || '');
  if (!raw) return '';
  // Normalize full Org ID links first so we don't leave partial brackets.
  // [[id:...][Title]] -> Title
  // [[id:...]] -> (removed)
  const withLinksNormalized = raw.replace(/\[\[\s*id:[^\]\n]+\](?:\[([^\]\n]*)\])?\]\]/gi, (_, desc) => {
    const title = String(desc || '').trim();
    return title;
  });

  const stripped = withLinksNormalized
    .replace(roamIdTokenGlobalRe, '')
    .replace(/\s+([,.;:!?])/g, '$1')
    .replace(/\[\[\s*\]\[(.*?)\]\]/g, '$1')
    .replace(/\[\[\s*\]\]/g, '')
    .replace(/\s{2,}/g, ' ')
    .trim();
  return stripped;
}

function sanitizeBacklinkContextText(value) {
  const raw = String(value || '');
  if (!raw) return '';
  return raw
    .split(/\r?\n/)
    .map((line) => sanitizeBacklinkContextLine(line))
    .filter((line) => line.length > 0)
    .join('\n')
    .trim();
}

module.exports = {
  parseRoamIdLink,
  extractRoamUuid,
  sanitizeBacklinkContextLine,
  sanitizeBacklinkContextText,
};
