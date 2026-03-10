function parseAgendaLineNumber(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.max(0, Math.trunc(value));
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return Math.max(0, Math.trunc(parsed));
  }
  return undefined;
}

function agendaItemIdentityKey(item) {
  if (!item || typeof item !== 'object') return '';
  const file = String(item.file || '').trim();
  const line = parseAgendaLineNumber(item.line);
  if (!file || typeof line !== 'number') return '';
  return `${file}::${line}`;
}

function resolveAgendaTargets(selectedItems, item) {
  const selected = Array.isArray(selectedItems) ? selectedItems : [];

  if (item && typeof item === 'object') {
    if (selected.length > 1) {
      const itemKey = agendaItemIdentityKey(item);
      const inSelection = itemKey
        ? selected.some((candidate) => agendaItemIdentityKey(candidate) === itemKey)
        : selected.includes(item);
      if (inSelection) return selected;
    }
    return [item];
  }

  if (selected.length > 0) return selected;
  return [];
}

function orderAgendaTargetsForMutation(items) {
  const targets = Array.isArray(items) ? items.filter((item) => item && typeof item === 'object') : [];

  return [...targets].sort((a, b) => {
    const fileA = String(a.file || '').trim();
    const fileB = String(b.file || '').trim();
    const fileCmp = fileA.localeCompare(fileB);
    if (fileCmp !== 0) return fileCmp;

    const lineA = parseAgendaLineNumber(a.line);
    const lineB = parseAgendaLineNumber(b.line);
    if (typeof lineA === 'number' && typeof lineB === 'number' && lineA !== lineB) {
      // Apply file-local edits from bottom to top so line shifts never invalidate
      // yet-to-run targets in the same file.
      return lineB - lineA;
    }
    if (typeof lineA === 'number') return -1;
    if (typeof lineB === 'number') return 1;

    const headlineA = String(a.headline || '').trim();
    const headlineB = String(b.headline || '').trim();
    const headlineCmp = headlineA.localeCompare(headlineB);
    if (headlineCmp !== 0) return headlineCmp;

    return 0;
  });
}

module.exports = { parseAgendaLineNumber, agendaItemIdentityKey, resolveAgendaTargets, orderAgendaTargetsForMutation };
