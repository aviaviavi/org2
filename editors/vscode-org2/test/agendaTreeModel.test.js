const test = require('node:test');
const assert = require('node:assert/strict');

const { buildAgendaTreeGroupsFromCli } = require('../agendaTreeModel');

test('buildAgendaTreeGroupsFromCli merges all overdue days into one Overdue section', () => {
  const groups = buildAgendaTreeGroupsFromCli(
    {
      overdue: [
        { date: '2026-03-01', weekday: 'Sun', items: [{ headline: 'old 1' }] },
        { date: '2026-03-02', weekday: 'Mon', items: [{ headline: 'old 2' }] },
      ],
      days: [{ date: '2026-03-03', weekday: 'Tue', items: [{ headline: 'next' }] }],
    },
    'default'
  );

  assert.equal(groups[0].type, 'group');
  assert.equal(groups[0].label, 'Overdue');
  assert.equal(groups[0].isOverdue, true);
  assert.equal(groups[0].items.length, 2);

  assert.equal(groups[1].type, 'separator');
  assert.equal(groups[2].label, 'Tue 2026-03-03');
});

test('buildAgendaTreeGroupsFromCli applies priority ordering within section when requested', () => {
  const groups = buildAgendaTreeGroupsFromCli(
    {
      overdue: [],
      days: [
        {
          date: '2026-03-03',
          weekday: 'Tue',
          items: [
            { headline: 'b item', priority: 'B' },
            { headline: 'none item' },
            { headline: 'a item', priority: 'A' },
            { headline: 'c item', priority: 'C' },
          ],
        },
      ],
    },
    'priority'
  );

  assert.deepEqual(
    groups[0].items.map((item) => item.headline),
    ['a item', 'b item', 'c item', 'none item']
  );
});
