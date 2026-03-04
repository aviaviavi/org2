const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function loadPackageJson() {
  const packagePath = path.join(__dirname, '..', 'package.json');
  return JSON.parse(fs.readFileSync(packagePath, 'utf8'));
}

function loadPackageKeybindings() {
  return loadPackageJson().contributes?.keybindings ?? [];
}

function hasPowerBinding(keybindings, key, command) {
  return keybindings.some((binding) =>
    binding.key === key &&
    binding.command === command &&
    typeof binding.when === 'string' &&
    binding.when.includes('config.org2.keymap.power') &&
    binding.when.includes("(editorLangId == 'org2' || editorLangId == 'org')")
  );
}

test('power keymap includes agenda status-filter, refile, priority, and heading/subtree shortcuts', () => {
  const keybindings = loadPackageKeybindings();

  assert.equal(hasPowerBinding(keybindings, 'ctrl+; a s', 'org2.pickAgendaStatusFilter'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; x r', 'org2.refileSubtree'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; t p', 'org2.setPriority'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; h p', 'org2.promoteSubtree'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; h d', 'org2.demoteSubtree'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; h u', 'org2.moveSubtreeUp'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; h n', 'org2.moveSubtreeDown'), true);
});

test('power keymap includes formatter check/preview/apply current-file shortcuts', () => {
  const keybindings = loadPackageKeybindings();

  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f c', 'org2.formatCurrentFileCheck'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f p', 'org2.formatCurrentFilePreviewDiff'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f a', 'org2.formatCurrentFileApply'), true);
});

test('package contributes subtree move commands and activation events', () => {
  const pkg = loadPackageJson();

  const activationEvents = pkg.activationEvents ?? [];
  assert.equal(activationEvents.includes('onCommand:org2.moveSubtreeUp'), true);
  assert.equal(activationEvents.includes('onCommand:org2.moveSubtreeDown'), true);

  const commands = pkg.contributes?.commands ?? [];
  const commandIds = new Set(commands.map((command) => command.command));
  assert.equal(commandIds.has('org2.moveSubtreeUp'), true);
  assert.equal(commandIds.has('org2.moveSubtreeDown'), true);
});
