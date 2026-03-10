const test = require('node:test');
const assert = require('node:assert/strict');

const {
  normalizeAgendaStatusFilterValue,
  buildAgendaStatusFilterQuickPickOptions,
} = require('../agendaStatusFilter');

test('normalizeAgendaStatusFilterValue canonicalizes aliases and separators', () => {
  assert.equal(normalizeAgendaStatusFilterValue(' In-Progress '), 'in_progress');
  assert.equal(normalizeAgendaStatusFilterValue('wip'), 'in_progress');
  assert.equal(normalizeAgendaStatusFilterValue('completed'), 'done');
  assert.equal(normalizeAgendaStatusFilterValue('cancelled'), 'canceled');
  assert.equal(normalizeAgendaStatusFilterValue('CLOSED'), 'closed');
  assert.equal(normalizeAgendaStatusFilterValue(' actionable '), 'actionable');
  assert.equal(normalizeAgendaStatusFilterValue(''), 'all');
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
