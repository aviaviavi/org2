function normalizeTodoStatusValue(rawValue) {
  const raw = String(rawValue || '').trim();
  if (!raw) return '';

  const token = raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');

  if (token === 'todo' || token === 'open' || token === 'backlog') return 'todo';
  if (
    token === 'in_progress' ||
    token === 'inprogress' ||
    token === 'prog' ||
    token === 'doing' ||
    token === 'started' ||
    token === 'waiting' ||
    token === 'blocked' ||
    token === 'next' ||
    token === 'wip'
  ) {
    return 'in_progress';
  }
  if (
    token === 'done' ||
    token === 'complete' ||
    token === 'completed' ||
    token === 'finish' ||
    token === 'finished' ||
    token === 'closed' ||
    token === 'resolved'
  ) {
    return 'done';
  }
  if (token === 'canceled' || token === 'cancelled' || token === 'cancel') return 'canceled';

  return '';
}

module.exports = {
  normalizeTodoStatusValue,
};
