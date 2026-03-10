const test = require('node:test');
const assert = require('node:assert/strict');

const { parseAgendaLineNumber, resolveAgendaTargets, orderAgendaTargetsForMutation } = require('../agendaSelection');

test('resolveAgendaTargets uses full selection when invoked item matches by file+line', () => {
  const selected = [
    { file: '/tmp/a.org', line: 10, headline: 'first' },
    { file: '/tmp/b.org', line: 22, headline: 'second' },
  ];

  const invoked = { file: '/tmp/b.org', line: 22, headline: 'second (different object)' };
  const out = resolveAgendaTargets(selected, invoked);
  assert.equal(out, selected);
});

test('resolveAgendaTargets matches string line values for right-click item identity checks', () => {
  const selected = [{ file: '/tmp/a.org', line: 10 }, { file: '/tmp/b.org', line: 22 }];
  const invoked = { file: '/tmp/b.org', line: '22' };
  const out = resolveAgendaTargets(selected, invoked);
  assert.equal(out, selected);
});

test('resolveAgendaTargets falls back to single invoked item when not in selection', () => {
  const selected = [
    { file: '/tmp/a.org', line: 10 },
    { file: '/tmp/b.org', line: 22 },
  ];

  const invoked = { file: '/tmp/c.org', line: 22 };
  const out = resolveAgendaTargets(selected, invoked);
  assert.deepEqual(out, [invoked]);
});

test('resolveAgendaTargets uses selection for keyboard-invoked bulk actions', () => {
  const selected = [{ file: '/tmp/a.org', line: 10 }, { file: '/tmp/b.org', line: 22 }];
  assert.equal(resolveAgendaTargets(selected, undefined), selected);
});

test('orderAgendaTargetsForMutation sorts by file and descending line for deterministic bulk edits', () => {
  const selected = [
    { file: '/tmp/a.org', line: 4, headline: 'A' },
    { file: '/tmp/b.org', line: 2, headline: 'B' },
    { file: '/tmp/a.org', line: 12, headline: 'C' },
  ];

  const ordered = orderAgendaTargetsForMutation(selected);
  assert.deepEqual(ordered, [selected[2], selected[0], selected[1]]);
  assert.deepEqual(selected, [
    { file: '/tmp/a.org', line: 4, headline: 'A' },
    { file: '/tmp/b.org', line: 2, headline: 'B' },
    { file: '/tmp/a.org', line: 12, headline: 'C' },
  ]);
});

test('parseAgendaLineNumber accepts finite numeric and string values', () => {
  assert.equal(parseAgendaLineNumber(7), 7);
  assert.equal(parseAgendaLineNumber('9'), 9);
  assert.equal(parseAgendaLineNumber(' 10 '), 10);
  assert.equal(parseAgendaLineNumber(''), undefined);
  assert.equal(parseAgendaLineNumber('abc'), undefined);
});
