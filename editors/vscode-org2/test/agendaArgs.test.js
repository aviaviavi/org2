const test = require('node:test');
const assert = require('node:assert/strict');

const { buildAgendaCliArgs } = require('../agendaArgs');

test('buildAgendaCliArgs: workspace scope keeps baseline agenda invocation and omits default-only flags', () => {
  const out = buildAgendaCliArgs({
    scope: 'workspace',
    agendaRoot: '/tmp/org',
    recursive: true,
    days: 7,
    includeOverdue: true,
    groupBy: 'default',
    agendaGroupLimit: 9,
  });

  assert.equal(out.warnEmptyFiles, false);
  assert.deepEqual(out.args, ['agenda', '--dir', '/tmp/org', '--recursive', '--days', '7', '--format', 'json']);
});

test('buildAgendaCliArgs: files scope emits warning marker when configured file list resolves empty', () => {
  const out = buildAgendaCliArgs({
    scope: 'files',
    resolvedFiles: [],
    days: 3,
  });

  assert.equal(out.warnEmptyFiles, true);
  assert.deepEqual(out.args, ['agenda', '--days', '3', '--format', 'json']);
});

test('buildAgendaCliArgs: maps non-default agenda filters and ordering into CLI args (CLI↔VSCode contract)', () => {
  const out = buildAgendaCliArgs({
    scope: 'files',
    resolvedFiles: ['/tmp/a.org', '/tmp/b.org2'],
    days: 14,
    startDate: '2026-03-01',
    endDate: '2026-03-31',
    includeOverdue: false,
    statusFilter: 'todo',
    excludeStatusFilter: 'done',
    weekFilter: 'w10',
    dateFilter: '2026-03-10',
    excludeDateFilter: '2026-03-11',
    todoOrder: 'TODO,DONE',
    statusOrder: 'todo,done',
    timeFilter: '09:00-11:00',
    excludeTimeFilter: 'untimed',
    sortBy: 'priority,-headline',
    groupBy: 'status',
    agendaDayLimit: 5,
    agendaGroupLimit: 2,
    dateOrder: 'desc',
    agendaLimit: 20,
  });

  assert.equal(out.warnEmptyFiles, false);
  assert.deepEqual(out.args, [
    'agenda',
    '--files',
    '/tmp/a.org',
    '/tmp/b.org2',
    '--days',
    '14',
    '--format',
    'json',
    '--from',
    '2026-03-01',
    '--to',
    '2026-03-31',
    '--no-overdue',
    '--status',
    'todo',
    '--exclude-status',
    'done',
    '--week',
    'w10',
    '--date',
    '2026-03-10',
    '--exclude-date',
    '2026-03-11',
    '--todo-order',
    'TODO,DONE',
    '--status-order',
    'todo,done',
    '--time',
    '09:00-11:00',
    '--exclude-time',
    'untimed',
    '--sort',
    'priority,-headline',
    '--group',
    'status',
    '--day-limit',
    '5',
    '--group-limit',
    '2',
    '--date-order',
    'desc',
    '--limit',
    '20',
  ]);
});
