const test = require('node:test');
const assert = require('node:assert/strict');

const {
  normalizeAgendaStatusFilterValue,
  normalizeAgendaStatusOrderValue,
  buildAgendaStatusFilterQuickPickOptions,
} = require('../agendaStatusFilter');

test('normalizeAgendaStatusFilterValue canonicalizes aliases and separators', () => {
  assert.equal(normalizeAgendaStatusFilterValue(' In-Progress '), 'in_progress');
  assert.equal(normalizeAgendaStatusFilterValue('wip'), 'in_progress');
  assert.equal(normalizeAgendaStatusFilterValue('completed'), 'done');
  assert.equal(normalizeAgendaStatusFilterValue('cancelled'), 'canceled');
  assert.equal(normalizeAgendaStatusFilterValue('CLOSED'), 'closed');
  assert.equal(normalizeAgendaStatusFilterValue(' actionable '), 'actionable');
  assert.equal(normalizeAgendaStatusFilterValue('default'), 'all');
  assert.equal(normalizeAgendaStatusFilterValue(''), 'all');
});

test('normalizeAgendaStatusOrderValue canonicalizes aliases, expands macros, and drops default sentinel', () => {
  assert.equal(normalizeAgendaStatusOrderValue('active,closed'), 'todo,in_progress,done,canceled');
  assert.equal(normalizeAgendaStatusOrderValue(' default , completed, cancelled '), 'done,canceled');
  assert.equal(normalizeAgendaStatusOrderValue(' none , completed, cancelled '), 'done,canceled');
  assert.equal(normalizeAgendaStatusOrderValue('all,todo,custom'), 'todo,in_progress,done,canceled,custom');
  assert.equal(normalizeAgendaStatusOrderValue('In Progress, todo, in-progress, blocked'), 'in_progress,todo');
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
