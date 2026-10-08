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
    binding.when.includes('celorga.keymap.power') &&
    binding.when.includes("(editorLangId == 'org2' || editorLangId == 'org')")
  );
}

test('power keymap includes agenda status-filter, refile, and priority shortcuts', () => {
  const keybindings = loadPackageKeybindings();

  assert.equal(hasPowerBinding(keybindings, 'ctrl+; a s', 'celorga.pickAgendaStatusFilter'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; x r', 'celorga.refileSubtree'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; t p', 'celorga.setPriority'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; t a', 'celorga.assignTodoToAgent'), true);
});

test('power keymap includes formatter check/preview/apply current-file shortcuts', () => {
  const keybindings = loadPackageKeybindings();

  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f c', 'celorga.formatCurrentFileCheck'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f p', 'celorga.formatCurrentFilePreviewDiff'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f a', 'celorga.formatCurrentFileApply'), true);
});

test('insert list item command is contributed and registered in extension runtime', () => {
  const keybindings = loadPackageKeybindings();
  const packagePath = path.join(__dirname, '..', 'package.json');
  const extensionPath = path.join(__dirname, '..', 'extension.js');
  const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
  const extensionSource = fs.readFileSync(extensionPath, 'utf8');

  assert.equal(
    pkg.contributes?.commands?.some((command) => command.command === 'celorga.insertListItemBelow') ?? false,
    true
  );
  assert.equal(
    keybindings.some((binding) => binding.command === 'celorga.insertListItemBelow'),
    true
  );
  assert.equal(
    extensionSource.includes("registerBrandCommand('celorga.insertListItemBelow'"),
    true
  );
});

test('agent handoff command assigns normal tasks and closes nested approvals', () => {
  const keybindings = loadPackageKeybindings();
  const packagePath = path.join(__dirname, '..', 'package.json');
  const extensionPath = path.join(__dirname, '..', 'extension.js');
  const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
  const extensionSource = fs.readFileSync(extensionPath, 'utf8');

  assert.equal(
    pkg.activationEvents?.includes('onCommand:org2.assignTodoToAgent') ?? false,
    true
  );
  assert.equal(
    pkg.contributes?.commands?.some((command) => command.command === 'celorga.assignTodoToAgent') ?? false,
    true
  );
  assert.equal(
    keybindings.some((binding) => binding.command === 'celorga.assignTodoToAgent'),
    true
  );
  assert.equal(
    extensionSource.includes("registerBrandCommand('celorga.assignTodoToAgent'"),
    true
  );
  assert.equal(extensionSource.includes("runTodoCli('assign', 'OpenClaw'"), true);
  assert.equal(extensionSource.includes("runTodoCli('set', 'done', target"), true);
  assert.equal(extensionSource.includes("findParentSendHeading"), true);
  assert.equal(extensionSource.includes("STATUS: 'approved-to-send'"), true);
  assert.equal(extensionSource.includes("STATUS: 'ready-for-agent'"), true);
  assert.equal(extensionSource.includes('ORG2_AGENT_HANDOFF:'), false);
  assert.equal(extensionSource.includes('ORG2_AGENT_HANDOFF_AT:'), true);
});
