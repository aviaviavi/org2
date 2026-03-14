const test = require('node:test');
const assert = require('node:assert/strict');

const { normalizeTodoStatusValue } = require('../todoStatus');

test('normalizeTodoStatusValue canonicalizes known aliases', () => {
  assert.equal(normalizeTodoStatusValue(' TODO '), 'todo');
  assert.equal(normalizeTodoStatusValue('open'), 'todo');
  assert.equal(normalizeTodoStatusValue('backlog'), 'todo');

  assert.equal(normalizeTodoStatusValue('IN-PROGRESS'), 'in_progress');
  assert.equal(normalizeTodoStatusValue('in progress'), 'in_progress');
  assert.equal(normalizeTodoStatusValue('wip'), 'in_progress');

  assert.equal(normalizeTodoStatusValue('done'), 'done');
  assert.equal(normalizeTodoStatusValue('completed'), 'done');
  assert.equal(normalizeTodoStatusValue('closed'), 'done');

  assert.equal(normalizeTodoStatusValue('canceled'), 'canceled');
  assert.equal(normalizeTodoStatusValue('cancelled'), 'canceled');
  assert.equal(normalizeTodoStatusValue('cancel'), 'canceled');
});

test('normalizeTodoStatusValue returns empty string for unknown values', () => {
  assert.equal(normalizeTodoStatusValue(''), '');
  assert.equal(normalizeTodoStatusValue('active'), '');
  assert.equal(normalizeTodoStatusValue('later maybe'), '');
});
