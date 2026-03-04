const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function loadPackageKeybindings() {
  const packagePath = path.join(__dirname, '..', 'package.json');
  const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
  return pkg.contributes?.keybindings ?? [];
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

test('power keymap includes agenda status-filter, refile, priority, and heading-level shortcuts', () => {
  const keybindings = loadPackageKeybindings();

  assert.equal(hasPowerBinding(keybindings, 'ctrl+; a s', 'org2.pickAgendaStatusFilter'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; x r', 'org2.refileSubtree'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; t p', 'org2.setPriority'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; h p', 'org2.promoteSubtree'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; h d', 'org2.demoteSubtree'), true);
});

test('power keymap includes formatter check/preview/apply current-file shortcuts', () => {
  const keybindings = loadPackageKeybindings();

  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f c', 'org2.formatCurrentFileCheck'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f p', 'org2.formatCurrentFilePreviewDiff'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f a', 'org2.formatCurrentFileApply'), true);
});
