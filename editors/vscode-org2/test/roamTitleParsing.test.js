const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('extension roam node collection routes headline parsing through shared roam-title helper', () => {
  const extensionPath = path.join(__dirname, '..', 'extension.js');
  const source = fs.readFileSync(extensionPath, 'utf8');

  assert.match(source, /parseHeadlineTitleForRoam,\s*\n\}\s*=\s*require\('\.\/agendaVisuals'\);/);

  const fnMatch = /function collectRoamNodesFromText\(content, filePath\) \{([\s\S]*?)\n\}/.exec(source);
  assert.ok(fnMatch, 'collectRoamNodesFromText should exist in extension.js');
  assert.match(fnMatch[1], /currentHeadlineTitle = parseHeadlineTitleForRoam\(String\(hm\[2\] \|\| ''\)\);/);
});
