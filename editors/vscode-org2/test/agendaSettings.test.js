const test = require('node:test');
const assert = require('node:assert/strict');

const { resolveAgendaDays, readAgendaCliOptions } = require('../agendaSettings');

function createConfig(values = {}) {
  return {
    get(key, fallback) {
      if (Object.prototype.hasOwnProperty.call(values, key)) {
        return values[key];
      }
      return fallback;
    },
  };
}

test('resolveAgendaDays: today/next/default contracts', () => {
  assert.equal(resolveAgendaDays({ type: 'today' }, 7), 1);
  assert.equal(resolveAgendaDays({ type: 'next', days: 3 }, 7), 3);
  assert.equal(resolveAgendaDays(undefined, 7), 7);
});

test('readAgendaCliOptions: workspace scope keeps defaults and does not resolve file list', () => {
  const calls = [];
  const cfg = createConfig();
  const out = readAgendaCliOptions(
    cfg,
    '/tmp/org',
    undefined,
    (files, root) => {
      calls.push({ files, root });
      return ['/should-not-be-called.org'];
    }
  );

  assert.deepEqual(calls, []);
  assert.equal(out.scope, 'workspace');
  assert.deepEqual(out.resolvedFiles, []);
  assert.equal(out.agendaRoot, '/tmp/org');
  assert.equal(out.recursive, true);
  assert.equal(out.days, 7);
  assert.equal(out.includeOverdue, true);
  assert.equal(out.sortBy, 'default');
  assert.equal(out.groupBy, 'default');
  assert.equal(out.dateOrder, 'asc');
});

test('readAgendaCliOptions: files scope normalizes VSCode settings for CLI argument mapping', () => {
  const cfg = createConfig({
    'agenda.scope': 'files',
    'agenda.files': ['inbox.org', 'work.org2'],
    'agenda.includeOverdue': false,
    'agenda.statusFilter': '  IN_Progress  ',
    'agenda.excludeStatusFilter': ' DONE ',
    'agenda.dateFilter': ' 2026-03-20 ',
    'agenda.excludeDateFilter': ' all ',
    'agenda.todoOrder': ' TODO,WAIT,DONE ',
    'agenda.statusOrder': ' TODO,IN_PROGRESS,DONE ',
    'agenda.tagOrder': ' important,ops ',
    'agenda.timeFilter': ' 09:00-11:00 ',
    'agenda.excludeTimeFilter': ' UNTIMED ',
    'agenda.sortBy': ' Priority,-Headline ',
    'agenda.groupBy': ' Status ',
    'agenda.dateOrder': ' DESC ',
    'agenda.limit': '12',
    'agenda.dayLimit': '3',
    'agenda.groupLimit': '2',
    'agenda.startDate': ' 2026-03-01 ',
    'agenda.endDate': ' 2026-03-31 ',
    'agenda.recursive': false,
  });

  const calls = [];
  const out = readAgendaCliOptions(
    cfg,
    '/tmp/org',
    { type: 'next', days: 14 },
    (files, root) => {
      calls.push({ files, root });
      return ['/tmp/org/inbox.org', '/tmp/org/work.org2'];
    }
  );

  assert.deepEqual(calls, [{ files: ['inbox.org', 'work.org2'], root: '/tmp/org' }]);
  assert.equal(out.scope, 'files');
  assert.deepEqual(out.resolvedFiles, ['/tmp/org/inbox.org', '/tmp/org/work.org2']);
  assert.equal(out.days, 14);
  assert.equal(out.recursive, false);

  assert.equal(out.includeOverdue, false);
  assert.equal(out.statusFilter, 'in_progress');
  assert.equal(out.excludeStatusFilter, 'done');
  assert.equal(out.dateFilter, '2026-03-20');
  assert.equal(out.excludeDateFilter, 'all');
  assert.equal(out.todoOrder, 'TODO,WAIT,DONE');
  assert.equal(out.statusOrder, 'todo,in_progress,done');
  assert.equal(out.tagOrder, 'important,ops');
  assert.equal(out.timeFilter, '09:00-11:00');
  assert.equal(out.excludeTimeFilter, 'untimed');
  assert.equal(out.sortBy, 'priority,-headline');
  assert.equal(out.groupBy, 'status');
  assert.equal(out.dateOrder, 'desc');
  assert.equal(out.agendaLimit, 12);
  assert.equal(out.agendaDayLimit, 3);
  assert.equal(out.agendaGroupLimit, 2);
  assert.equal(out.startDate, '2026-03-01');
  assert.equal(out.endDate, '2026-03-31');
});
