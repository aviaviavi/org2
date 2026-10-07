const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function loadExtensionLocalRequires() {
  const extensionPath = path.join(__dirname, '..', 'extension.js');
  const source = fs.readFileSync(extensionPath, 'utf8');
  const requireRe = /require\(\s*['"]\.\/([^'"\n]+)['"]\s*\)/g;
  const modules = new Set();

  let match;
  while ((match = requireRe.exec(source)) !== null) {
    const mod = String(match[1] || '').trim();
    if (!mod) continue;
    modules.add(mod.endsWith('.js') ? mod : `${mod}.js`);
  }

  return modules;
}

function loadPackageFilesAllowlist() {
  const packagePath = path.join(__dirname, '..', 'package.json');
  const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
  return new Set(pkg.files || []);
}

test('packaged extension files include all extension.js local runtime modules', () => {
  const localRuntimeModules = loadExtensionLocalRequires();
  const packageFiles = loadPackageFilesAllowlist();

  for (const moduleFile of localRuntimeModules) {
    assert.equal(
      packageFiles.has(moduleFile),
      true,
      `package.json files[] is missing required runtime module: ${moduleFile}`
    );

    const modulePath = path.join(__dirname, '..', moduleFile);
    assert.equal(
      fs.existsSync(modulePath),
      true,
      `required runtime module is missing on disk: ${moduleFile}`
    );
  }
});

test('org prose disables VS Code Unicode highlight boxes by default', () => {
  const packagePath = path.join(__dirname, '..', 'package.json');
  const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
  const defaults = pkg.contributes.configurationDefaults || {};

  for (const language of ['[org2]', '[org]']) {
    assert.equal(defaults[language]?.['editor.unicodeHighlight.nonBasicASCII'], false);
    assert.equal(defaults[language]?.['editor.unicodeHighlight.invisibleCharacters'], false);
    assert.equal(defaults[language]?.['editor.unicodeHighlight.ambiguousCharacters'], false);
  }
});


test('extension uses the Celorga brand while keeping compatibility identifiers', () => {
  const packagePath = path.join(__dirname, '..', 'package.json');
  const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));

  assert.equal(pkg.displayName, 'Celorga');
  assert.equal(pkg.name, 'org2-vscode');
  assert.equal(pkg.publisher, 'AviPress');
  assert.equal(pkg.contributes.configuration.title, 'Celorga');
  assert.ok(pkg.keywords.includes('celorga'));

  const language = pkg.contributes.languages.find((entry) => entry.id === 'org2');
  assert.ok(language, 'language id org2 must remain registered');
  assert.equal(language.aliases[0], 'Celorga Org');
  assert.ok(language.aliases.includes('org2'));
  assert.deepEqual(language.extensions, ['.org', '.org2']);

  for (const command of pkg.contributes.commands) {
    assert.match(command.command, /^org2\./);
    assert.match(command.title, /^Celorga: /);
  }
  for (const view of pkg.contributes.views.explorer) {
    assert.match(view.id, /^org2/);
    assert.match(view.name, /^Celorga /);
  }
});
