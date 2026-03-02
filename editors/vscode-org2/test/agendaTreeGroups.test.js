const test = require('node:test');
const assert = require('node:assert/strict');

const { buildAgendaTreeGroups } = require('../agendaTreeGroups');

test('buildAgendaTreeGroups: merges all overdue days into one unified Overdue group', () => {
  const data = {
    overdue: [
      {
        date: '2026-01-01',
        weekday: 'Thu',
        items: [{ headline: 'Old A' }],
      },
      {
        date: '2026-01-02',
        weekday: 'Fri',
        items: [{ headline: 'Old B' }],
      },
    ],
    days: [],
  };

  const groups = buildAgendaTreeGroups(data, {
    makeItem: (it, date, bucket) => ({ ...it, date, bucket }),
    makeGroup: (group) => group,
    makeSeparator: (label) => ({ label, separator: true }),
  });

  assert.equal(groups.length, 1);
  assert.equal(groups[0].label, 'Overdue');
  assert.equal(groups[0].isOverdue, true);
  assert.equal(groups[0].items.length, 2);
  assert.deepEqual(
    groups[0].items.map((it) => [it.headline, it.date, it.bucket]),
    [
      ['Old A', '2026-01-01', 'overdue'],
      ['Old B', '2026-01-02', 'overdue'],
    ]
  );
});

test('buildAgendaTreeGroups: keeps upcoming day grouping and separator behavior unchanged', () => {
  const data = {
    overdue: [{ date: '2026-01-01', weekday: 'Thu', items: [{ headline: 'Old' }] }],
    days: [
      { date: '2026-01-03', weekday: 'Sat', items: [{ headline: 'Soon 1' }] },
      { date: '2026-01-04', weekday: 'Sun', items: [{ headline: 'Soon 2' }] },
    ],
  };

  const groups = buildAgendaTreeGroups(data, {
    makeItem: (it, date, bucket) => ({ ...it, date, bucket }),
    makeGroup: (group) => group,
    makeSeparator: (label) => ({ label, separator: true }),
  });

  assert.equal(groups.length, 4);
  assert.equal(groups[0].label, 'Overdue');
  assert.equal(groups[1].separator, true);
  assert.equal(groups[2].label, 'Sat 2026-01-03');
  assert.equal(groups[3].label, 'Sun 2026-01-04');
  assert.deepEqual(groups[2].items.map((it) => it.bucket), ['upcoming']);
  assert.deepEqual(groups[3].items.map((it) => it.bucket), ['upcoming']);
});

test('buildAgendaTreeGroups: preserves overdue item ordering from CLI payload (sort already applied)', () => {
  const data = {
    overdue: [
      {
        date: '2026-01-01',
        weekday: 'Thu',
        items: [{ headline: 'P1 urgent' }, { headline: 'P2 less urgent' }],
      },
      {
        date: '2026-01-02',
        weekday: 'Fri',
        items: [{ headline: 'P3 trailing' }],
      },
    ],
    days: [],
  };

  const groups = buildAgendaTreeGroups(data, {
    makeItem: (it, date, bucket) => ({ ...it, date, bucket }),
    makeGroup: (group) => group,
  });

  assert.deepEqual(
    groups[0].items.map((it) => it.headline),
    ['P1 urgent', 'P2 less urgent', 'P3 trailing']
  );
});
