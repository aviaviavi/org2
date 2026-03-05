function agendaItemIdentityKey(item) {
  if (!item || typeof item !== 'object') return '';
  const file = String(item.file || '').trim();
  const line = typeof item.line === 'number' ? String(item.line) : '';
  if (!file || line === '') return '';
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

module.exports = { agendaItemIdentityKey, resolveAgendaTargets };
