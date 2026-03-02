function buildAgendaTreeGroups(data, helpers) {
  const groups = [];
  const overdueItems = [];

  const makeItem = helpers && typeof helpers.makeItem === 'function'
    ? helpers.makeItem
    : (item) => item;
  const makeGroup = helpers && typeof helpers.makeGroup === 'function'
    ? helpers.makeGroup
    : (group) => group;
  const makeSeparator = helpers && typeof helpers.makeSeparator === 'function'
    ? helpers.makeSeparator
    : (label) => ({ label });

  const overdueDays = Array.isArray(data && data.overdue) ? data.overdue : [];
  const upcomingDays = Array.isArray(data && data.days) ? data.days : [];

  for (const day of overdueDays) {
    const date = day && day.date ? day.date : '';
    for (const item of (day && Array.isArray(day.items) ? day.items : [])) {
      overdueItems.push(makeItem(item, date, 'overdue'));
    }
  }

  if (overdueItems.length > 0) {
    groups.push(
      makeGroup({
        label: 'Overdue',
        date: '',
        weekday: '',
        isOverdue: true,
        items: overdueItems,
      })
    );
  }

  if (overdueItems.length > 0 && upcomingDays.length > 0) {
    groups.push(makeSeparator('──────── Upcoming ────────'));
  }

  for (const day of upcomingDays) {
    const date = day && day.date ? day.date : '';
    const weekday = day && day.weekday ? day.weekday : '';
    const items = (day && Array.isArray(day.items) ? day.items : []).map((item) => makeItem(item, date, 'upcoming'));
    const label = `${weekday} ${date}`.trim();

    groups.push(
      makeGroup({
        label,
        date,
        weekday,
        isOverdue: false,
        items,
      })
    );
  }

  return groups;
}

module.exports = {
  buildAgendaTreeGroups,
};
