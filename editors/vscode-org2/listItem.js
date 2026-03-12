const listItemPrefixRe = /^(\s*)([-+*]|\d+[.)])(\s+)(\[(?: |x|X|-)\]\s+)?/;

function normalizeInsertedListMarker(marker) {
  if (!marker) return '-';
  if (!/^\d+[.)]$/.test(marker)) return marker;
  return marker.endsWith(')') ? '1)' : '1.';
}

function buildInsertedListItemPrefix(lineText) {
  const text = typeof lineText === 'string' ? lineText : '';
  const listMatch = text.match(listItemPrefixRe);
  if (!listMatch) return '';

  const indent = listMatch[1] || '';
  const marker = normalizeInsertedListMarker(listMatch[2] || '-');
  const spacing = listMatch[3] || ' ';
  const hasCheckbox = Boolean(listMatch[4]);
  return `${indent}${marker}${spacing}${hasCheckbox ? '[ ] ' : ''}`;
}

module.exports = {
  normalizeInsertedListMarker,
  buildInsertedListItemPrefix,
};
