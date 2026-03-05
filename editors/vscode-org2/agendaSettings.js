function readAgendaCliOptions(cfg, agendaRoot, filter, resolveAgendaFiles) {
  const scope = cfg.get('agenda.scope', 'workspace');
  const files = cfg.get('agenda.files', []);
  const includeOverdue = cfg.get('agenda.includeOverdue', true);
  const statusFilter = String(cfg.get('agenda.statusFilter', 'all') || 'all').trim().toLowerCase();
  const excludeStatusFilter = String(cfg.get('agenda.excludeStatusFilter', 'all') || 'all').trim().toLowerCase();
  const kindFilter = String(cfg.get('agenda.kindFilter', 'all') || 'all').trim().toLowerCase();
  const excludeKindFilter = String(cfg.get('agenda.excludeKindFilter', 'all') || 'all').trim().toLowerCase();
  const whenFilter = String(cfg.get('agenda.whenFilter', 'all') || 'all').trim().toLowerCase();
  const excludeWhenFilter = String(cfg.get('agenda.excludeWhenFilter', 'all') || 'all').trim().toLowerCase();
  const weekdayFilter = String(cfg.get('agenda.weekdayFilter', 'all') || 'all').trim().toLowerCase();
  const excludeWeekdayFilter = String(cfg.get('agenda.excludeWeekdayFilter', 'all') || 'all').trim().toLowerCase();
  const weekFilter = String(cfg.get('agenda.weekFilter', 'all') || 'all').trim().toLowerCase();
  const excludeWeekFilter = String(cfg.get('agenda.excludeWeekFilter', 'all') || 'all').trim().toLowerCase();
  const dayOfMonthFilter = String(cfg.get('agenda.dayOfMonthFilter', 'all') || 'all').trim().toLowerCase();
  const excludeDayOfMonthFilter = String(cfg.get('agenda.excludeDayOfMonthFilter', 'all') || 'all').trim().toLowerCase();
  const monthFilter = String(cfg.get('agenda.monthFilter', 'all') || 'all').trim().toLowerCase();
  const excludeMonthFilter = String(cfg.get('agenda.excludeMonthFilter', 'all') || 'all').trim().toLowerCase();
  const quarterFilter = String(cfg.get('agenda.quarterFilter', 'all') || 'all').trim().toLowerCase();
  const excludeQuarterFilter = String(cfg.get('agenda.excludeQuarterFilter', 'all') || 'all').trim().toLowerCase();
  const yearFilter = String(cfg.get('agenda.yearFilter', 'all') || 'all').trim().toLowerCase();
  const excludeYearFilter = String(cfg.get('agenda.excludeYearFilter', 'all') || 'all').trim().toLowerCase();
  const dateFilter = String(cfg.get('agenda.dateFilter', 'all') || 'all').trim();
  const excludeDateFilter = String(cfg.get('agenda.excludeDateFilter', 'all') || 'all').trim();
  const levelFilter = String(cfg.get('agenda.levelFilter', '') || '').trim();
  const excludeLevelFilter = String(cfg.get('agenda.excludeLevelFilter', '') || '').trim();
  const matchFilter = String(cfg.get('agenda.matchFilter', '') || '').trim();
  const excludeMatchFilter = String(cfg.get('agenda.excludeMatchFilter', '') || '').trim();
  const tagFilter = String(cfg.get('agenda.tagFilter', '') || '').trim();
  const idFilter = String(cfg.get('agenda.idFilter', '') || '').trim();
  const todoKeywordFilter = String(cfg.get('agenda.todoKeywordFilter', '') || '').trim();
  const todoOrder = String(cfg.get('agenda.todoOrder', '') || '').trim();
  const statusOrder = String(cfg.get('agenda.statusOrder', '') || '').trim().toLowerCase();
  const kindOrder = String(cfg.get('agenda.kindOrder', '') || '').trim().toLowerCase();
  const priorityOrder = String(cfg.get('agenda.priorityOrder', '') || '').trim();
  const tagOrder = String(cfg.get('agenda.tagOrder', '') || '').trim().toLowerCase();
  const effortOrder = String(cfg.get('agenda.effortOrder', '') || '').trim().toLowerCase();
  const priorityFilter = String(cfg.get('agenda.priorityFilter', '') || '').trim();
  const timeFilter = String(cfg.get('agenda.timeFilter', '') || '').trim().toLowerCase();
  const effortFilter = String(cfg.get('agenda.effortFilter', '') || '').trim();
  const propertyFilter = String(cfg.get('agenda.propertyFilter', '') || '').trim();
  const excludeTagFilter = String(cfg.get('agenda.excludeTagFilter', '') || '').trim();
  const excludeIdFilter = String(cfg.get('agenda.excludeIdFilter', '') || '').trim();
  const excludeTodoKeywordFilter = String(cfg.get('agenda.excludeTodoKeywordFilter', '') || '').trim();
  const excludePriorityFilter = String(cfg.get('agenda.excludePriorityFilter', '') || '').trim();
  const excludeTimeFilter = String(cfg.get('agenda.excludeTimeFilter', '') || '').trim().toLowerCase();
  const excludeEffortFilter = String(cfg.get('agenda.excludeEffortFilter', '') || '').trim();
  const excludePropertyFilter = String(cfg.get('agenda.excludePropertyFilter', '') || '').trim();
  const fileFilter = String(cfg.get('agenda.fileFilter', '') || '').trim();
  const excludeFileFilter = String(cfg.get('agenda.excludeFileFilter', '') || '').trim();
  const sortBy = String(cfg.get('agenda.sortBy', 'default') || 'default').trim().toLowerCase();
  const groupBy = String(cfg.get('agenda.groupBy', 'default') || 'default').trim().toLowerCase();
  const dateOrder = String(cfg.get('agenda.dateOrder', 'asc') || 'asc').trim().toLowerCase();
  const agendaLimit = Number(cfg.get('agenda.limit', 0) || 0);
  const agendaDayLimit = Number(cfg.get('agenda.dayLimit', 0) || 0);
  const agendaGroupLimit = Number(cfg.get('agenda.groupLimit', 0) || 0);
  const startDate = String(cfg.get('agenda.startDate', '') || '').trim();
  const endDate = String(cfg.get('agenda.endDate', '') || '').trim();
  const defaultDays = cfg.get('agenda.days', 7);

  const days = filter && filter.type === 'today' ? 1 : (filter && filter.type === 'next' ? filter.days : defaultDays);

  const resolvedFiles = scope === 'files' ? resolveAgendaFiles(files, agendaRoot) : [];
  const recursive = cfg.get('agenda.recursive', true);

  return {
    scope,
    resolvedFiles,
    agendaRoot,
    recursive,
    days,
    startDate,
    endDate,
    includeOverdue,
    statusFilter,
    excludeStatusFilter,
    kindFilter,
    excludeKindFilter,
    whenFilter,
    excludeWhenFilter,
    weekdayFilter,
    excludeWeekdayFilter,
    weekFilter,
    excludeWeekFilter,
    dayOfMonthFilter,
    excludeDayOfMonthFilter,
    monthFilter,
    excludeMonthFilter,
    quarterFilter,
    excludeQuarterFilter,
    yearFilter,
    excludeYearFilter,
    dateFilter,
    excludeDateFilter,
    levelFilter,
    excludeLevelFilter,
    matchFilter,
    excludeMatchFilter,
    tagFilter,
    idFilter,
    todoKeywordFilter,
    todoOrder,
    statusOrder,
    kindOrder,
    priorityOrder,
    tagOrder,
    effortOrder,
    priorityFilter,
    timeFilter,
    effortFilter,
    propertyFilter,
    excludeTagFilter,
    excludeIdFilter,
    excludeTodoKeywordFilter,
    excludePriorityFilter,
    excludeTimeFilter,
    excludeEffortFilter,
    excludePropertyFilter,
    fileFilter,
    excludeFileFilter,
    sortBy,
    groupBy,
    dateOrder,
    agendaLimit,
    agendaDayLimit,
    agendaGroupLimit,
  };
}

module.exports = {
  readAgendaCliOptions,
};
