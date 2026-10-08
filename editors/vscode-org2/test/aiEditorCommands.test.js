const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function loadPackage() {
  return JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'));
}

function loadExtensionSource() {
  return fs.readFileSync(path.join(__dirname, '..', 'extension.js'), 'utf8');
}

function hasPowerBinding(keybindings, key, command) {
  return keybindings.some((binding) =>
    binding.key === key &&
    binding.command === command &&
    typeof binding.when === 'string' &&
    binding.when.includes('celorga.keymap.power') &&
    binding.when.includes("(editorLangId == 'org2' || editorLangId == 'org')")
  );
}

test('new roam node command pre-fills title from active selection', () => {
  const extensionSource = loadExtensionSource();

  assert.equal(extensionSource.includes('getActiveSelectionTextForTitle'), true);
  assert.equal(extensionSource.includes('value: selectedTitle'), true);
  assert.equal(extensionSource.includes('valueSelection: selectedTitle'), true);
});

test('AI review and graph audit editor commands are contributed, activated, and registered', () => {
  const pkg = loadPackage();
  const extensionSource = loadExtensionSource();
  const commands = pkg.contributes?.commands?.map((command) => command.command) ?? [];

  for (const command of [
    'celorga.graphAuditWorkspace',
    'celorga.aiReviewWorkspace',
    'celorga.aiMarkReviewed',
    'celorga.aiMarkRejected',
    'celorga.aiMarkDeferred',
  ]) {
    assert.equal(commands.includes(command), true, `${command} command contribution`);
    assert.equal(pkg.activationEvents.includes(`onCommand:${command}`), true, `${command} activation event`);
    assert.equal(extensionSource.includes(`registerBrandCommand('${command}'`), true, `${command} runtime registration`);
  }
});

test('power keymap includes AI lifecycle, graph audit, and subtree motion shortcuts', () => {
  const keybindings = loadPackage().contributes?.keybindings ?? [];

  assert.equal(hasPowerBinding(keybindings, 'ctrl+; g a', 'celorga.graphAuditWorkspace'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; i v', 'celorga.aiReviewWorkspace'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; i r', 'celorga.aiMarkReviewed'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; i x', 'celorga.aiMarkRejected'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; i d', 'celorga.aiMarkDeferred'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; h left', 'celorga.promoteSubtree'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; h right', 'celorga.demoteSubtree'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; h up', 'celorga.moveSubtreeUp'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; h down', 'celorga.moveSubtreeDown'), true);
});
