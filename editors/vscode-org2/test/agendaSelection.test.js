const test = require('node:test');
const assert = require('node:assert/strict');

const { resolveAgendaTargets } = require('../agendaSelection');

test('resolveAgendaTargets uses full selection when invoked item matches by file+line', () => {
  const selected = [
    { file: '/tmp/a.org', line: 10, headline: 'first' },
    { file: '/tmp/b.org', line: 22, headline: 'second' },
  ];

  const invoked = { file: '/tmp/b.org', line: 22, headline: 'second (different object)' };
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
