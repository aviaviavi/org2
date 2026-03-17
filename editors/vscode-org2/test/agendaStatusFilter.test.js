const test = require('node:test');
const assert = require('node:assert/strict');

const {
  normalizeAgendaStatusFilterValue,
  normalizeAgendaStatusOrderValue,
  buildAgendaStatusFilterQuickPickOptions,
} = require('../agendaStatusFilter');

test('normalizeAgendaStatusFilterValue canonicalizes aliases, supports comma lists, and drops invalid tokens', () => {
  assert.equal(normalizeAgendaStatusFilterValue(' In-Progress '), 'in_progress');
  assert.equal(normalizeAgendaStatusFilterValue('wip'), 'in_progress');
  assert.equal(normalizeAgendaStatusFilterValue('completed'), 'done');
  assert.equal(normalizeAgendaStatusFilterValue('cancelled'), 'canceled');
  assert.equal(normalizeAgendaStatusFilterValue('CLOSED'), 'closed');
  assert.equal(normalizeAgendaStatusFilterValue(' actionable '), 'actionable');
  assert.equal(normalizeAgendaStatusFilterValue('todo,unknown,done,made-up'), 'todo,done');
  assert.equal(normalizeAgendaStatusFilterValue('todo;done'), 'todo,done');
  assert.equal(normalizeAgendaStatusFilterValue(['In Progress;cancelled']), 'in_progress,canceled');
  assert.equal(normalizeAgendaStatusFilterValue(['In Progress', 'cancelled']), 'in_progress,canceled');
  assert.equal(normalizeAgendaStatusFilterValue('all,done'), 'all');
  assert.equal(normalizeAgendaStatusFilterValue('default'), 'all');
  assert.equal(normalizeAgendaStatusFilterValue('none'), 'all');
  assert.equal(normalizeAgendaStatusFilterValue('none,done'), 'done');
  assert.equal(normalizeAgendaStatusFilterValue(''), 'all');
  assert.equal(normalizeAgendaStatusFilterValue('wat'), 'all');
});

test('normalizeAgendaStatusOrderValue canonicalizes aliases, expands macros, and drops default sentinel', () => {
  assert.equal(normalizeAgendaStatusOrderValue('active,closed'), 'todo,in_progress,done,canceled');
  assert.equal(normalizeAgendaStatusOrderValue('active;closed'), 'todo,in_progress,done,canceled');
  assert.equal(normalizeAgendaStatusOrderValue(' default , completed, cancelled '), 'done,canceled');
  assert.equal(normalizeAgendaStatusOrderValue(' none , completed, cancelled '), 'done,canceled');
  assert.equal(normalizeAgendaStatusOrderValue('all,todo,custom'), 'todo,in_progress,done,canceled,custom');
  assert.equal(normalizeAgendaStatusOrderValue('In Progress, todo, in-progress, blocked'), 'in_progress,todo');
  assert.equal(normalizeAgendaStatusOrderValue('todo,unknown,done,made-up'), 'todo,done');
  assert.equal(normalizeAgendaStatusOrderValue(''), '');
});

test('buildAgendaStatusFilterQuickPickOptions includes full status set and marks current', () => {
  const options = buildAgendaStatusFilterQuickPickOptions('In Progress');
  const values = options.map((opt) => opt.value);

  assert.deepEqual(values, [
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
  ]);

  const current = options.filter((opt) => opt.description === 'Current').map((opt) => opt.value);
  assert.deepEqual(current, ['in_progress']);
});
