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
    'agenda.statusFilter': ' In Progress ',
    'agenda.excludeStatusFilter': ' cancelled ',
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
  assert.equal(opts.excludeStatusFilter, 'canceled');
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

test('readAgendaCliOptions normalizes status default sentinel to all', () => {
  const cfg = fakeCfg({
    'agenda.scope': 'workspace',
    'agenda.statusFilter': 'default',
    'agenda.excludeStatusFilter': 'Default',
  });

  const opts = readAgendaCliOptions(cfg, '/tmp/org2', null, () => {
    throw new Error('resolveAgendaFiles should not be called for workspace scope');
  });

  assert.equal(opts.statusFilter, 'all');
  assert.equal(opts.excludeStatusFilter, 'all');
});

test('readAgendaCliOptions treats status none sentinel as no-op when mixed with concrete values', () => {
  const cfg = fakeCfg({
    'agenda.scope': 'workspace',
    'agenda.statusFilter': 'none,done',
    'agenda.excludeStatusFilter': 'none',
  });

  const opts = readAgendaCliOptions(cfg, '/tmp/org2', null, () => {
    throw new Error('resolveAgendaFiles should not be called for workspace scope');
  });

  assert.equal(opts.statusFilter, 'done');
  assert.equal(opts.excludeStatusFilter, 'all');
});

test('readAgendaCliOptions keeps valid status filters when mixed with invalid tokens', () => {
  const cfg = fakeCfg({
    'agenda.scope': 'workspace',
    'agenda.statusFilter': ' todo , unknown , done ',
    'agenda.excludeStatusFilter': ' blocked , made-up ',
  });

  const opts = readAgendaCliOptions(cfg, '/tmp/org2', null, () => {
    throw new Error('resolveAgendaFiles should not be called for workspace scope');
  });

  assert.equal(opts.statusFilter, 'todo,done');
  assert.equal(opts.excludeStatusFilter, 'in_progress');
});

test('readAgendaCliOptions normalizes status-order aliases for stable CLI mapping', () => {
  const cfg = fakeCfg({
    'agenda.scope': 'workspace',
    'agenda.statusOrder': ' none,active,closed,default ',
  });

  const opts = readAgendaCliOptions(cfg, '/tmp/org2', null, () => {
    throw new Error('resolveAgendaFiles should not be called for workspace scope');
  });

  assert.equal(opts.statusOrder, 'todo,in_progress,done,canceled');
});

test('readAgendaCliOptions supports semicolon-separated status filters and status-order', () => {
  const cfg = fakeCfg({
    'agenda.scope': 'workspace',
    'agenda.statusFilter': 'todo;done',
    'agenda.excludeStatusFilter': 'none;cancelled',
    'agenda.statusOrder': 'active;closed',
  });

  const opts = readAgendaCliOptions(cfg, '/tmp/org2', null, () => {
    throw new Error('resolveAgendaFiles should not be called for workspace scope');
  });

  assert.equal(opts.statusFilter, 'todo,done');
  assert.equal(opts.excludeStatusFilter, 'canceled');
  assert.equal(opts.statusOrder, 'todo,in_progress,done,canceled');
});

test('readAgendaCliOptions normalizes date-range boundaries and clears all sentinels', () => {
  const cfg = fakeCfg({
    'agenda.scope': 'workspace',
    'agenda.startDate': ' 2026-03-01 ',
    'agenda.endDate': ' all ',
  });

  const opts = readAgendaCliOptions(cfg, '/tmp/org2', null, () => {
    throw new Error('resolveAgendaFiles should not be called for workspace scope');
  });

  assert.equal(opts.startDate, '2026-03-01');
  assert.equal(opts.endDate, '');
});
