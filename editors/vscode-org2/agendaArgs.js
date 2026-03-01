function toPositiveInt(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return null;
  return Math.floor(n);
}

function buildAgendaCliArgs(options = {}) {
  const {
    scope = 'workspace',
    resolvedFiles = [],
    agendaRoot = process.cwd(),
    recursive = true,
    days = 7,
    startDate = '',
    endDate = '',
    includeOverdue = true,
    statusFilter = 'all',
    excludeStatusFilter = 'all',
    kindFilter = 'all',
    excludeKindFilter = 'all',
    whenFilter = 'all',
    excludeWhenFilter = 'all',
    weekdayFilter = 'all',
    excludeWeekdayFilter = 'all',
    weekFilter = 'all',
    excludeWeekFilter = 'all',
    dayOfMonthFilter = 'all',
    excludeDayOfMonthFilter = 'all',
    monthFilter = 'all',
    excludeMonthFilter = 'all',
    quarterFilter = 'all',
    excludeQuarterFilter = 'all',
    yearFilter = 'all',
    excludeYearFilter = 'all',
    dateFilter = 'all',
    excludeDateFilter = 'all',
    levelFilter = '',
    excludeLevelFilter = '',
    matchFilter = '',
    excludeMatchFilter = '',
    tagFilter = '',
    idFilter = '',
    todoKeywordFilter = '',
    todoOrder = '',
    statusOrder = '',
    kindOrder = '',
    priorityOrder = '',
    tagOrder = '',
    effortOrder = '',
    priorityFilter = '',
    timeFilter = '',
    effortFilter = '',
    propertyFilter = '',
    excludeTagFilter = '',
    excludeIdFilter = '',
    excludeTodoKeywordFilter = '',
    excludePriorityFilter = '',
    excludeTimeFilter = '',
    excludeEffortFilter = '',
    excludePropertyFilter = '',
    fileFilter = '',
    excludeFileFilter = '',
    sortBy = 'default',
    groupBy = 'default',
    dateOrder = 'asc',
    agendaLimit = 0,
    agendaDayLimit = 0,
    agendaGroupLimit = 0,
  } = options;

  const args = ['agenda'];
  let warnEmptyFiles = false;

  if (scope === 'files') {
    if (resolvedFiles.length === 0) {
      warnEmptyFiles = true;
    }
    if (resolvedFiles.length > 0) args.push('--files', ...resolvedFiles);
  } else {
    args.push('--dir', agendaRoot);
    if (recursive) args.push('--recursive');
  }

  args.push('--days', String(days), '--format', 'json');

  if (startDate) args.push('--from', startDate);
  if (endDate) args.push('--to', endDate);
  if (!includeOverdue) args.push('--no-overdue');
  if (statusFilter && statusFilter !== 'all') args.push('--status', statusFilter);
  if (excludeStatusFilter && excludeStatusFilter !== 'all') args.push('--exclude-status', excludeStatusFilter);
  if (kindFilter && kindFilter !== 'all') args.push('--kind', kindFilter);
  if (excludeKindFilter && excludeKindFilter !== 'all') args.push('--exclude-kind', excludeKindFilter);
  if (whenFilter && whenFilter !== 'all') args.push('--when', whenFilter);
  if (excludeWhenFilter && excludeWhenFilter !== 'all') args.push('--exclude-when', excludeWhenFilter);
  if (weekdayFilter && weekdayFilter !== 'all') args.push('--weekday', weekdayFilter);
  if (excludeWeekdayFilter && excludeWeekdayFilter !== 'all') args.push('--exclude-weekday', excludeWeekdayFilter);
  if (weekFilter && weekFilter !== 'all') args.push('--week', weekFilter);
  if (excludeWeekFilter && excludeWeekFilter !== 'all') args.push('--exclude-week', excludeWeekFilter);
  if (dayOfMonthFilter && dayOfMonthFilter !== 'all') args.push('--day-of-month', dayOfMonthFilter);
  if (excludeDayOfMonthFilter && excludeDayOfMonthFilter !== 'all') args.push('--exclude-day-of-month', excludeDayOfMonthFilter);
  if (monthFilter && monthFilter !== 'all') args.push('--month', monthFilter);
  if (excludeMonthFilter && excludeMonthFilter !== 'all') args.push('--exclude-month', excludeMonthFilter);
  if (quarterFilter && quarterFilter !== 'all') args.push('--quarter', quarterFilter);
  if (excludeQuarterFilter && excludeQuarterFilter !== 'all') args.push('--exclude-quarter', excludeQuarterFilter);
  if (yearFilter && yearFilter !== 'all') args.push('--year', yearFilter);
  if (excludeYearFilter && excludeYearFilter !== 'all') args.push('--exclude-year', excludeYearFilter);
  if (dateFilter && dateFilter.toLowerCase() !== 'all') args.push('--date', dateFilter);
  if (excludeDateFilter && excludeDateFilter.toLowerCase() !== 'all') args.push('--exclude-date', excludeDateFilter);
  if (levelFilter) args.push('--level', levelFilter);
  if (excludeLevelFilter) args.push('--exclude-level', excludeLevelFilter);
  if (matchFilter) args.push('--match', matchFilter);
  if (excludeMatchFilter) args.push('--exclude-match', excludeMatchFilter);
  if (tagFilter) args.push('--tag', tagFilter);
  if (idFilter) args.push('--id', idFilter);
  if (todoKeywordFilter) args.push('--todo', todoKeywordFilter);
  if (todoOrder) args.push('--todo-order', todoOrder);
  if (statusOrder) args.push('--status-order', statusOrder);
  if (kindOrder) args.push('--kind-order', kindOrder);
  if (priorityOrder) args.push('--priority-order', priorityOrder);
  if (tagOrder) args.push('--tag-order', tagOrder);
  if (effortOrder) args.push('--effort-order', effortOrder);
  if (priorityFilter) args.push('--priority', priorityFilter);
  if (timeFilter) args.push('--time', timeFilter);
  if (effortFilter) args.push('--effort', effortFilter);
  if (propertyFilter) args.push('--property', propertyFilter);
  if (excludeTagFilter) args.push('--exclude-tag', excludeTagFilter);
  if (excludeIdFilter) args.push('--exclude-id', excludeIdFilter);
  if (excludeTodoKeywordFilter) args.push('--exclude-todo', excludeTodoKeywordFilter);
  if (excludePriorityFilter) args.push('--exclude-priority', excludePriorityFilter);
  if (excludeTimeFilter) args.push('--exclude-time', excludeTimeFilter);
  if (excludeEffortFilter) args.push('--exclude-effort', excludeEffortFilter);
  if (excludePropertyFilter) args.push('--exclude-property', excludePropertyFilter);
  if (fileFilter) args.push('--file-match', fileFilter);
  if (excludeFileFilter) args.push('--exclude-file', excludeFileFilter);
  if (sortBy && sortBy !== 'default') args.push('--sort', sortBy);
  if (groupBy && groupBy !== 'default') args.push('--group', groupBy);

  const dayLimit = toPositiveInt(agendaDayLimit);
  if (dayLimit !== null) args.push('--day-limit', String(dayLimit));

  const groupLimit = toPositiveInt(agendaGroupLimit);
  if (groupLimit !== null && groupBy && groupBy !== 'default') {
    args.push('--group-limit', String(groupLimit));
  }

  if (dateOrder === 'desc') args.push('--date-order', 'desc');

  const limit = toPositiveInt(agendaLimit);
  if (limit !== null) args.push('--limit', String(limit));

  return { args, warnEmptyFiles };
}

module.exports = {
  buildAgendaCliArgs,
};
