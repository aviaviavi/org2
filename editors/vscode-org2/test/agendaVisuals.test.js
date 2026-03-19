const test = require('node:test');
const assert = require('node:assert/strict');

const {
  agendaFileLabel,
  agendaPriorityRank,
  agendaStatusBucket,
  agendaStatusCue,
  agendaTreeItemLabel,
  agendaUrgencyFromDate,
  extractAgendaPriorityFromHeadline,
  hasRecognizedHeadlineTodoKeyword,
  normalizeAgendaPriority,
  parseHeadlineTitleForRoam,
  stripHeadlineTodoKeyword,
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

test('agendaStatusBucket maps common TODO states and aliases', () => {
  assert.equal(agendaStatusBucket('TODO'), 'todo');
  assert.equal(agendaStatusBucket('OPEN'), 'todo');
  assert.equal(agendaStatusBucket('BACKLOG'), 'todo');

  assert.equal(agendaStatusBucket('IN_PROGRESS'), 'inProgress');
  assert.equal(agendaStatusBucket('in-progress'), 'inProgress');
  assert.equal(agendaStatusBucket('INPROGRESS'), 'inProgress');
  assert.equal(agendaStatusBucket('PROG'), 'inProgress');
  assert.equal(agendaStatusBucket('WIP'), 'inProgress');
  assert.equal(agendaStatusBucket('WAIT'), 'inProgress');
  assert.equal(agendaStatusBucket('BLOCKED'), 'inProgress');
  assert.equal(agendaStatusBucket('ON-HOLD'), 'inProgress');
  assert.equal(agendaStatusBucket('PAUSED'), 'inProgress');

  assert.equal(agendaStatusBucket('DONE'), 'done');
  assert.equal(agendaStatusBucket('COMPLETE'), 'done');
  assert.equal(agendaStatusBucket('COMPLETED'), 'done');
  assert.equal(agendaStatusBucket('FINISH'), 'done');
  assert.equal(agendaStatusBucket('FINISHED'), 'done');
  assert.equal(agendaStatusBucket('CLOSED'), 'done');
  assert.equal(agendaStatusBucket('RESOLVED'), 'done');

  assert.equal(agendaStatusBucket('CANCELLED'), 'canceled');
  assert.equal(agendaStatusBucket('CANCELED'), 'canceled');
  assert.equal(agendaStatusBucket('SOMEDAY'), 'custom');
  assert.equal(agendaStatusBucket(''), 'none');
});

test('roam headline title parsing strips recognized TODO aliases only', () => {
  assert.equal(hasRecognizedHeadlineTodoKeyword('BACKLOG'), true);
  assert.equal(hasRecognizedHeadlineTodoKeyword('WAIT'), true);
  assert.equal(hasRecognizedHeadlineTodoKeyword('COMPLETED'), true);
  assert.equal(hasRecognizedHeadlineTodoKeyword('CANCELLED'), true);
  assert.equal(hasRecognizedHeadlineTodoKeyword('SOMEDAY'), false);

  assert.equal(stripHeadlineTodoKeyword('BACKLOG Ship parser'), 'Ship parser');
  assert.equal(stripHeadlineTodoKeyword('WAIT On review'), 'On review');
  assert.equal(stripHeadlineTodoKeyword('COMPLETED Shipped'), 'Shipped');
  assert.equal(stripHeadlineTodoKeyword('CANCELLED Duplicate'), 'Duplicate');
  assert.equal(stripHeadlineTodoKeyword('SOMEDAY Maybe later'), 'SOMEDAY Maybe later');

  assert.equal(parseHeadlineTitleForRoam('* BACKLOG Ship parser :tag:'), 'Ship parser');
  assert.equal(parseHeadlineTitleForRoam('** WAIT On review :blocked:'), 'On review');
  assert.equal(parseHeadlineTitleForRoam('*** COMPLETED Shipped cleanly'), 'Shipped cleanly');
  assert.equal(parseHeadlineTitleForRoam('* CANCELLED Duplicate :archived:'), 'Duplicate');
  assert.equal(parseHeadlineTitleForRoam('* SOMEDAY Maybe later :idea:'), 'SOMEDAY Maybe later');
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

test('agendaTreeItemLabel renders explicit priority token before TODO keyword', () => {
  assert.deepEqual(agendaTreeItemLabel('TODO', 'Write tests', 'todo', 'A'), {
    label: '[T] [#A] TODO Write tests',
    highlights: [[9, 13]],
  });
});

test('agendaTreeItemLabel can infer priority from headline token', () => {
  assert.deepEqual(agendaTreeItemLabel('TODO', '[#B] Plan launch'), {
    label: '[T] [#B] TODO Plan launch',
    highlights: [[9, 13]],
  });
});

test('agendaTreeItemLabel renders inferred priority for non-todo rows', () => {
  assert.deepEqual(agendaTreeItemLabel('', '[#C] Plain scheduled note'), {
    label: '[·] [#C] Plain scheduled note',
    highlights: [],
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

test('priority helpers normalize and rank A/B/C before unprioritized', () => {
  assert.equal(normalizeAgendaPriority('a'), 'A');
  assert.equal(normalizeAgendaPriority('[#b]'), 'B');
  assert.equal(normalizeAgendaPriority('Z'), '');

  assert.equal(extractAgendaPriorityFromHeadline('TODO [#C] follow up'), 'C');
  assert.equal(extractAgendaPriorityFromHeadline('TODO follow up'), '');

  assert.deepEqual(['', 'C', 'A', 'B'].sort((a, b) => agendaPriorityRank(a) - agendaPriorityRank(b)), ['A', 'B', 'C', '']);
});
