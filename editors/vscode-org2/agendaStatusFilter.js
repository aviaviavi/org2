const AGENDA_STATUS_VALUES = [
  'all',
  'active',
  'actionable',
  'open',
  'todo',
  'in_progress',
  'done',
  'canceled',
  'closed',
  'custom',
];

function normalizeStatusToken(raw) {
  return String(raw || '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
}

function normalizeAgendaStatusFilterValue(raw, fallback = 'all') {
  const token = normalizeStatusToken(raw);
  if (!token) return fallback;

  if (token === 'all') return 'all';
  if (token === 'active') return 'active';
  if (token === 'actionable') return 'actionable';
  if (token === 'open' || token === 'backlog') return 'open';
  if (token === 'todo') return 'todo';
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
  ) return 'in_progress';
  if (
    token === 'done' ||
    token === 'complete' ||
    token === 'completed' ||
    token === 'finish' ||
    token === 'finished' ||
    token === 'resolved'
  ) return 'done';
  if (token === 'canceled' || token === 'cancelled' || token === 'cancel') return 'canceled';
  if (token === 'closed') return 'closed';
  if (token === 'custom') return 'custom';

  return fallback;
}

function buildAgendaStatusFilterQuickPickOptions(currentRaw) {
  const current = normalizeAgendaStatusFilterValue(currentRaw, 'all');
  const withCurrent = (value) => (current === value ? 'Current' : '');
  return [
    { label: 'All statuses', value: 'all', description: withCurrent('all') },
    { label: 'Active (TODO + In progress)', value: 'active', description: withCurrent('active') },
    { label: 'Actionable (active + custom)', value: 'actionable', description: withCurrent('actionable') },
    { label: 'Open', value: 'open', description: withCurrent('open') },
    { label: 'TODO', value: 'todo', description: withCurrent('todo') },
    { label: 'In progress', value: 'in_progress', description: withCurrent('in_progress') },
    { label: 'Done', value: 'done', description: withCurrent('done') },
    { label: 'Canceled', value: 'canceled', description: withCurrent('canceled') },
    { label: 'Closed (done + canceled)', value: 'closed', description: withCurrent('closed') },
    { label: 'Custom TODO keywords', value: 'custom', description: withCurrent('custom') },
  ];
}

module.exports = {
  AGENDA_STATUS_VALUES,
  normalizeAgendaStatusFilterValue,
  buildAgendaStatusFilterQuickPickOptions,
};
