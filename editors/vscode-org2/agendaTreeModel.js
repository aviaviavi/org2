const { agendaPriorityRank } = require('./agendaVisuals');

function resolvePrioritySortDirection(sortBy) {
  const fields = String(sortBy || '')
    .split(',')
    .map((v) => String(v || '').trim().toLowerCase())
    .filter(Boolean);

  for (const field of fields) {
    let token = field;
    let direction = 1;

    if (token.startsWith('-')) {
      direction = -1;
      token = token.slice(1).trim();
    }

    const m = token.match(/^([a-z_]+)(?::(asc|desc))?$/);
    if (!m) continue;

    const key = m[1];
    if (m[2] === 'desc') direction = -1;
    if (m[2] === 'asc') direction = 1;

    if (key === 'priority' || key === 'prio') {
      return direction;
    }
  }

  return 0;
}

function sortByPriorityIfRequested(items, sortBy) {
  const direction = resolvePrioritySortDirection(sortBy);
  if (direction === 0) return items.slice();

  return items.slice().sort((a, b) => {
    const delta = agendaPriorityRank(a && a.priority) - agendaPriorityRank(b && b.priority);
    if (delta !== 0) return delta * direction;
    return 0;
  });
}

function buildAgendaTreeGroupsFromCli(data, sortBy) {
  const overdueDays = Array.isArray(data && data.overdue) ? data.overdue : [];
  const upcomingDays = Array.isArray(data && data.days) ? data.days : [];

  const groups = [];

  if (overdueDays.length > 0) {
    const overdueItems = [];
    for (const d of overdueDays) {
      overdueItems.push(...(Array.isArray(d && d.items) ? d.items : []));
    }
    groups.push({
      type: 'group',
      label: 'Overdue',
      date: '',
      weekday: '',
      isOverdue: true,
      items: sortByPriorityIfRequested(overdueItems, sortBy),
    });
  }

  if (overdueDays.length > 0 && upcomingDays.length > 0) {
    groups.push({ type: 'separator', label: '──────── Upcoming ────────' });
  }

  for (const d of upcomingDays) {
    groups.push({
      type: 'group',
      label: `${d.weekday || ''} ${d.date || ''}`.trim(),
      date: d && d.date,
      weekday: d && d.weekday,
      isOverdue: false,
      items: sortByPriorityIfRequested(Array.isArray(d && d.items) ? d.items : [], sortBy),
    });
  }

  return groups;
}

module.exports = { buildAgendaTreeGroupsFromCli, sortByPriorityIfRequested };
