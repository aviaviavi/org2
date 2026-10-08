const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  celorgaCommandId,
  legacyCommandId,
  commandAliases,
  createBrandConfiguration,
  affectsBrandConfiguration,
} = require('../brandConfig');

function loadPackage() {
  return JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'));
}

// Minimal WorkspaceConfiguration fake: `defaults` are contributed defaults, `user` are user-set values.
function fakeSection(defaults, user, updates) {
  return {
    get(key, fallback) {
      if (key in user) return user[key];
      if (key in defaults) return defaults[key];
      return fallback;
    },
    has(key) {
      return key in user || key in defaults;
    },
    inspect(key) {
      return { key, defaultValue: defaults[key], globalValue: user[key] };
    },
    async update(key, value, target) {
      updates.push({ key, value, target });
    },
  };
}

function fakeGetConfiguration({ celorga = {}, org2 = {}, defaults = {} }, updates = []) {
  const sections = {
    celorga: fakeSection(defaults, celorga, updates.celorga || (updates.celorga = [])),
    org2: fakeSection(defaults, org2, updates.org2 || (updates.org2 = [])),
  };
  return (section) => sections[section];
}

test('command ids map between celorga.* and legacy org2.*', () => {
  assert.equal(celorgaCommandId('org2.openAgenda'), 'celorga.openAgenda');
  assert.equal(celorgaCommandId('celorga.openAgenda'), 'celorga.openAgenda');
  assert.equal(legacyCommandId('celorga.openAgenda'), 'org2.openAgenda');
  assert.deepEqual(commandAliases('celorga.openAgenda'), ['celorga.openAgenda', 'org2.openAgenda']);
  assert.deepEqual(commandAliases('org2.openAgenda'), ['celorga.openAgenda', 'org2.openAgenda']);
  assert.deepEqual(commandAliases('workbench.action.files.revert'), ['workbench.action.files.revert']);
});

test('settings read celorga.X first, then a user-set org2.X, then the default', () => {
  const defaults = { 'agenda.days': 7, 'agenda.dir': '' };

  const neither = createBrandConfiguration(fakeGetConfiguration({ defaults }));
  assert.equal(neither.get('agenda.days', 1), 7);

  const legacyOnly = createBrandConfiguration(fakeGetConfiguration({ defaults, org2: { 'agenda.days': 14 } }));
  assert.equal(legacyOnly.get('agenda.days', 1), 14);
  assert.equal(legacyOnly.inspect('agenda.days').globalValue, 14);

  const both = createBrandConfiguration(fakeGetConfiguration({ defaults, celorga: { 'agenda.days': 30 }, org2: { 'agenda.days': 14 } }));
  assert.equal(both.get('agenda.days', 1), 30);

  // A celorga.X value equal to the default still wins when the user set it explicitly.
  const explicitDefault = createBrandConfiguration(fakeGetConfiguration({ defaults, celorga: { 'agenda.days': 7 }, org2: { 'agenda.days': 14 } }));
  assert.equal(explicitDefault.get('agenda.days', 1), 7);
});

test('settings updates keep the spelling the user already uses', async () => {
  const updates = {};
  const legacyUser = createBrandConfiguration(fakeGetConfiguration({ org2: { 'agenda.statusFilter': 'done' } }, updates));
  await legacyUser.update('agenda.statusFilter', 'active', 1);
  assert.deepEqual(updates.org2, [{ key: 'agenda.statusFilter', value: 'active', target: 1 }]);
  assert.deepEqual(updates.celorga, []);

  const fresh = {};
  const newUser = createBrandConfiguration(fakeGetConfiguration({}, fresh));
  await newUser.update('agenda.statusFilter', 'active', 1);
  assert.deepEqual(fresh.celorga, [{ key: 'agenda.statusFilter', value: 'active', target: 1 }]);
});

test('configuration changes are detected under either prefix', () => {
  const event = (changed) => ({ affectsConfiguration: (key) => key === changed });
  assert.equal(affectsBrandConfiguration(event('celorga.agenda'), 'agenda'), true);
  assert.equal(affectsBrandConfiguration(event('org2.agenda'), 'agenda'), true);
  assert.equal(affectsBrandConfiguration(event('org2.roam.indexDir'), 'agenda'), false);
});

test('every command is contributed as celorga.X with a hidden org2.X alias', () => {
  const pkg = loadPackage();
  const commands = pkg.contributes.commands.map((entry) => entry.command);
  const hidden = new Map((pkg.contributes.menus.commandPalette || []).map((entry) => [entry.command, entry.when]));
  const modern = commands.filter((id) => id.startsWith('celorga.'));
  const legacy = commands.filter((id) => id.startsWith('org2.'));

  assert.ok(modern.length > 0);
  assert.deepEqual(legacy.map(celorgaCommandId).sort(), [...modern].sort());
  for (const id of legacy) {
    assert.equal(hidden.get(id), 'false', `${id} hidden from the command palette`);
    assert.equal(pkg.activationEvents.includes(`onCommand:${id}`), modern.includes(celorgaCommandId(id)) && pkg.activationEvents.includes(`onCommand:${celorgaCommandId(id)}`), `${id} activation parity`);
  }
  for (const id of modern) assert.equal(hidden.has(id), false, `${id} visible in the command palette`);

  for (const [menu, items] of Object.entries(pkg.contributes.menus)) {
    if (menu === 'commandPalette') continue;
    for (const item of items) assert.match(item.command, /^celorga\./, `${menu} uses celorga ids`);
  }
  for (const binding of pkg.contributes.keybindings) {
    assert.doesNotMatch(binding.command, /^org2\./, `keybinding ${binding.key} uses celorga ids`);
    assert.doesNotMatch(binding.when || '', /config\.org2\./, `keybinding ${binding.key} uses fallback-aware context keys`);
  }
});

test('every extension command registration registers both ids', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'extension.js'), 'utf8');
  assert.equal(/registerCommand\('org2\./.test(source), false, 'no org2-only registrations');
  assert.equal(/getConfiguration\('org2'\)/.test(source), false, 'settings go through the fallback reader');
  const registered = [...source.matchAll(/registerBrandCommand\('([^']+)'/g)].map((match) => match[1]);
  // Contributed before this change without a runtime handler; tracked separately.
  const unregistered = new Set(['celorga.aiRunDraft', 'celorga.aiPromoteDraft']);
  const contributed = loadPackage().contributes.commands.map((entry) => entry.command).filter((id) => id.startsWith('celorga.') && !unregistered.has(id));
  for (const id of contributed) assert.ok(registered.includes(id), `${id} registered at runtime`);
});

test('every org2.X setting has a documented celorga.X twin and a deprecation notice', () => {
  const [modern, legacy] = loadPackage().contributes.configuration;
  assert.equal(modern.title, 'Celorga');
  const modernKeys = Object.keys(modern.properties);
  const legacyKeys = Object.keys(legacy.properties);
  assert.ok(modernKeys.every((key) => key.startsWith('celorga.')));
  assert.deepEqual(legacyKeys.map((key) => key.replace(/^org2\./, 'celorga.')), modernKeys);
  for (const key of legacyKeys) {
    const twin = key.replace(/^org2\./, 'celorga.');
    assert.match(legacy.properties[key].deprecationMessage, new RegExp(twin.replace(/\./g, '\\.')));
    assert.deepEqual(legacy.properties[key].default, modern.properties[twin].default);
    assert.doesNotMatch(modern.properties[twin].description || '', /\borg2\.(agenda|roam|export|crypt|editor)\./, `${twin} description uses celorga names`);
  }
});
