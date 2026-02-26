const test = require('node:test');
const assert = require('node:assert/strict');

const {
  agendaFileLabel,
  agendaStatusBucket,
  agendaStatusCue,
  agendaTreeItemLabel,
  agendaUrgencyFromDate,
} = require('../agendaVisuals');

test('agendaFileLabel returns basename with fallback', () => {
  assert.equal(agendaFileLabel('/tmp/notes/work.org2'), 'work.org2');
  assert.equal(agendaFileLabel(''), '(unknown file)');
});

test('agendaUrgencyFromDate buckets by day', () => {
  const now = new Date(2026, 1, 11, 20, 0, 0); // 2026-02-11 local
  assert.equal(agendaUrgencyFromDate('2026-02-10', now), 'overdue');
  assert.equal(agendaUrgencyFromDate('2026-02-11', now), 'today');
  assert.equal(agendaUrgencyFromDate('2026-02-12', now), 'upcoming');
  assert.equal(agendaUrgencyFromDate('not-a-date', now), 'unknown');
});

test('agendaStatusBucket maps common TODO states', () => {
  assert.equal(agendaStatusBucket('TODO'), 'todo');
  assert.equal(agendaStatusBucket('IN_PROGRESS'), 'inProgress');
  assert.equal(agendaStatusBucket('in-progress'), 'inProgress');
  assert.equal(agendaStatusBucket('PROG'), 'inProgress');
  assert.equal(agendaStatusBucket('DONE'), 'done');
  assert.equal(agendaStatusBucket('CANCELLED'), 'canceled');
  assert.equal(agendaStatusBucket('CANCELED'), 'canceled');
  assert.equal(agendaStatusBucket('SOMEDAY'), 'custom');
  assert.equal(agendaStatusBucket(''), 'none');
});

test('agendaStatusCue provides compact non-color status cues', () => {
  assert.equal(agendaStatusCue('todo'), '[T]');
  assert.equal(agendaStatusCue('inProgress'), '[~]');
  assert.equal(agendaStatusCue('done'), '[✓]');
  assert.equal(agendaStatusCue('canceled'), '[×]');
  assert.equal(agendaStatusCue('custom'), '[?]');
  assert.equal(agendaStatusCue('none'), '[·]');
});

test('agendaTreeItemLabel adds cue and highlights TODO keyword segment', () => {
  assert.deepEqual(agendaTreeItemLabel('TODO', 'Write tests'), {
    label: '[T] TODO Write tests',
    highlights: [[4, 8]],
  });

  assert.deepEqual(agendaTreeItemLabel('SOMEDAY', 'Refactor parser'), {
    label: '[?] SOMEDAY Refactor parser',
    highlights: [[4, 11]],
  });
});

test('agendaTreeItemLabel handles missing status and title readably', () => {
  assert.deepEqual(agendaTreeItemLabel('', 'Plain scheduled note'), {
    label: '[·] Plain scheduled note',
    highlights: [],
  });

  assert.deepEqual(agendaTreeItemLabel('', ''), {
    label: '[·] (untitled)',
    highlights: [],
  });
});
