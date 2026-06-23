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

test('power keymap includes agenda status-filter, refile, and priority shortcuts', () => {
  const keybindings = loadPackageKeybindings();

  assert.equal(hasPowerBinding(keybindings, 'ctrl+; a s', 'org2.pickAgendaStatusFilter'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; x r', 'org2.refileSubtree'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; t p', 'org2.setPriority'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; t a', 'org2.assignTodoToAgent'), true);
});

test('power keymap includes formatter check/preview/apply current-file shortcuts', () => {
  const keybindings = loadPackageKeybindings();

  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f c', 'org2.formatCurrentFileCheck'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f p', 'org2.formatCurrentFilePreviewDiff'), true);
  assert.equal(hasPowerBinding(keybindings, 'ctrl+; f a', 'org2.formatCurrentFileApply'), true);
});

test('insert list item command is contributed and registered in extension runtime', () => {
  const keybindings = loadPackageKeybindings();
  const packagePath = path.join(__dirname, '..', 'package.json');
  const extensionPath = path.join(__dirname, '..', 'extension.js');
  const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
  const extensionSource = fs.readFileSync(extensionPath, 'utf8');

  assert.equal(
    pkg.contributes?.commands?.some((command) => command.command === 'org2.insertListItemBelow') ?? false,
    true
  );
  assert.equal(
    keybindings.some((binding) => binding.command === 'org2.insertListItemBelow'),
    true
  );
  assert.equal(
    extensionSource.includes("registerCommand('org2.insertListItemBelow'"),
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
    pkg.contributes?.commands?.some((command) => command.command === 'org2.assignTodoToAgent') ?? false,
    true
  );
  assert.equal(
    keybindings.some((binding) => binding.command === 'org2.assignTodoToAgent'),
    true
  );
  assert.equal(
    extensionSource.includes("registerCommand('org2.assignTodoToAgent'"),
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
