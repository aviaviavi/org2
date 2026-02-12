const test = require('node:test');
const assert = require('node:assert/strict');

const {
  agendaFileLabel,
  agendaStatusBucket,
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
  assert.equal(agendaStatusBucket('DONE'), 'done');
  assert.equal(agendaStatusBucket('CANCELED'), 'canceled');
  assert.equal(agendaStatusBucket('SOMEDAY'), 'custom');
  assert.equal(agendaStatusBucket(''), 'none');
});
