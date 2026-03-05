const test = require('node:test');
const assert = require('node:assert/strict');

const { readAgendaCliOptions } = require('../agendaSettings');

function fakeCfg(values = {}) {
  return {
    get(key, fallback) {
      return Object.prototype.hasOwnProperty.call(values, key) ? values[key] : fallback;
    },
  };
}

test('readAgendaCliOptions resolves file scope + next filter days', () => {
  const cfg = fakeCfg({
    'agenda.scope': 'files',
    'agenda.files': ['notes.org2'],
    'agenda.days': 7,
    'agenda.sortBy': ' PRioRity:desc ',
    'agenda.statusFilter': ' In_Progress ',
  });

  const opts = readAgendaCliOptions(cfg, '/tmp/org2', { type: 'next', days: 3 }, (files, root) => {
    assert.deepEqual(files, ['notes.org2']);
    assert.equal(root, '/tmp/org2');
    return ['notes.org2'];
  });

  assert.equal(opts.scope, 'files');
  assert.deepEqual(opts.resolvedFiles, ['notes.org2']);
  assert.equal(opts.days, 3);
  assert.equal(opts.sortBy, 'priority:desc');
  assert.equal(opts.statusFilter, 'in_progress');
});

test('readAgendaCliOptions resolves today filter to one day', () => {
  const cfg = fakeCfg({
    'agenda.scope': 'workspace',
    'agenda.days': 30,
  });

  const opts = readAgendaCliOptions(cfg, '/tmp/org2', { type: 'today' }, () => {
    throw new Error('resolveAgendaFiles should not be called for workspace scope');
  });

  assert.equal(opts.scope, 'workspace');
  assert.deepEqual(opts.resolvedFiles, []);
  assert.equal(opts.days, 1);
});
