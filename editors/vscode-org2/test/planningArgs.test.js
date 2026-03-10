const test = require('node:test');
const assert = require('node:assert/strict');

const {
  normalizePlanKind,
  normalizePlanDateInput,
  buildPlanCliArgs,
} = require('../planningArgs');

test('normalizePlanKind: supports canonical values and common aliases', () => {
  assert.equal(normalizePlanKind('scheduled'), 'scheduled');
  assert.equal(normalizePlanKind(' SCHEDULE '), 'scheduled');
  assert.equal(normalizePlanKind('deadline'), 'deadline');
  assert.equal(normalizePlanKind('Due'), 'deadline');
  assert.equal(normalizePlanKind(''), '');
  assert.equal(normalizePlanKind('someday'), '');
});

test('normalizePlanDateInput: trims and validates YYYY-MM-DD only', () => {
  assert.equal(normalizePlanDateInput(' 2026-03-10 '), '2026-03-10');
  assert.equal(normalizePlanDateInput('2026/03/10'), '');
  assert.equal(normalizePlanDateInput('2026-3-10'), '');
  assert.equal(normalizePlanDateInput(''), '');
});

test('buildPlanCliArgs: set mode includes date argument', () => {
  const out = buildPlanCliArgs({
    filePath: '/tmp/org2/today.org',
    line: 42,
    kind: 'scheduled',
    useToday: false,
    date: '2026-03-15',
  });

  assert.deepEqual(out, [
    'plan',
    'set',
    '--file',
    '/tmp/org2/today.org',
    '--line',
    '42',
    '--kind',
    'scheduled',
    '--date',
    '2026-03-15',
    '--format',
    'json',
    '--apply',
  ]);
});

test('buildPlanCliArgs: today mode omits date argument', () => {
  const out = buildPlanCliArgs({
    filePath: '/tmp/org2/today.org',
    line: 7,
    kind: 'deadline',
    useToday: true,
    date: '2026-03-15',
  });

  assert.deepEqual(out, [
    'plan',
    'today',
    '--file',
    '/tmp/org2/today.org',
    '--line',
    '7',
    '--kind',
    'deadline',
    '--format',
    'json',
    '--apply',
  ]);
});
