const todoKeywordStartRe = /^([A-Z][A-Z0-9_\-]*)(\s+)(.*)$/;
const headlinePriorityStartRe = /^\[#([A-Z0-9])\](?:\s+|$)/i;

function normalizeOrgPriorityToken(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';

  const bracketed = /^\[#([A-Z0-9])\]$/i.exec(raw);
  if (bracketed) return String(bracketed[1] || '').toUpperCase();

  if (/^[A-Z0-9]$/i.test(raw)) return raw.toUpperCase();
  return '';
}

function updateHeadlinePriorityToken(lineText, priorityToken) {
  const normalizedPriority = normalizeOrgPriorityToken(priorityToken);
  const heading = /^(\*+\s+)(.*)$/.exec(String(lineText || ''));
  if (!heading) return { changed: false, lineText: String(lineText || '') };

  const prefix = heading[1];
  const rest = heading[2] || '';

  let lead = '';
  let body = rest;
  const todoStart = todoKeywordStartRe.exec(rest);
  if (todoStart) {
    lead = `${todoStart[1]} `;
    body = todoStart[3] || '';
  }

  const trimmedBody = String(body || '').trimStart();
  const withoutPriority = trimmedBody.replace(headlinePriorityStartRe, '').trimStart();

  const priorityPart = normalizedPriority ? `[#${normalizedPriority}]` : '';
  const middleParts = [lead];
  if (priorityPart) {
    middleParts.push(priorityPart);
    if (withoutPriority) middleParts.push(' ');
  }
  middleParts.push(withoutPriority);

  const updated = `${prefix}${middleParts.join('')}`.trimEnd();
  return { changed: updated !== lineText, lineText: updated };
}

module.exports = { normalizeOrgPriorityToken, updateHeadlinePriorityToken };
