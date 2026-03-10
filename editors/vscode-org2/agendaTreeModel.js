const { agendaPriorityRank } = require('./agendaVisuals');

function parseSortFields(sortBy) {
  return String(sortBy || '')
    .split(',')
    .map((v) => String(v || '').trim().toLowerCase())
    .filter(Boolean);
}

function resolvePrioritySortDirection(sortBy) {
  const fields = parseSortFields(sortBy);

  for (const field of fields) {
    if (field === 'priority' || field === 'prio' || field === '+priority' || field === '+prio') {
      return 1;
    }

    if (field === '-priority' || field === '-prio') {
      return -1;
    }

    if (field.startsWith('priority:') || field.startsWith('prio:')) {
      const [, rawDirection] = field.split(':', 2);
      const direction = String(rawDirection || '').trim().toLowerCase();
      if (direction === 'desc' || direction === 'descending') return -1;
      return 1;
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

function sortOverdueItems(items, sortBy) {
  const requestedDirection = resolvePrioritySortDirection(sortBy);
  if (requestedDirection !== 0) {
    return sortByPriorityIfRequested(items, sortBy);
  }

  // Overdue should always surface highest priority first, even when agenda.sortBy
  // is left at default/non-priority ordering.
  return items.slice().sort((a, b) => {
    const delta = agendaPriorityRank(a && a.priority) - agendaPriorityRank(b && b.priority);
    if (delta !== 0) return delta;
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
      items: sortOverdueItems(overdueItems, sortBy),
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

module.exports = { buildAgendaTreeGroupsFromCli, sortByPriorityIfRequested, resolvePrioritySortDirection };
