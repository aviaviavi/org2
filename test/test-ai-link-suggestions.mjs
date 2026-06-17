#!/usr/bin/env node

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const repoRoot = process.cwd();

function run(args, cwd = repoRoot) {
  return spawnSync('node', [path.join(repoRoot, 'dist/cli.js'), ...args], {
    cwd,
    encoding: 'utf8',
  });
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-ai-links-'));
const alphaId = '11111111-1111-1111-1111-111111111111';
const projectId = '22222222-2222-2222-2222-222222222222';
fs.writeFileSync(path.join(tmp, 'alpha.org2'), `#+TITLE: Alpha Topic
:PROPERTIES:
:ID: ${alphaId}
:ROAM_ALIASES: alpha initiative
:END:

Alpha Topic is a canonical node.
`, 'utf8');
fs.writeFileSync(path.join(tmp, 'project.org2'), `#+TITLE: Project Phoenix
:PROPERTIES:
:ID: ${projectId}
:END:

Project Phoenix is the represented project node.
`, 'utf8');
fs.writeFileSync(path.join(tmp, 'meeting.org2'), `#+TITLE: Meeting Notes

We discussed the alpha initiative rollout with the Phoenix project.
Beta Squad should review the Migration Plan before launch.
`, 'utf8');

const preview = run(['ai', 'suggest-links', '--dir', tmp, '--format', 'json'], process.cwd());
assert.equal(preview.status, 0, preview.stderr || preview.stdout);
const json = JSON.parse(preview.stdout);
assert.equal(json.$schema, 'org2:ai-link-suggestions:v1');
assert.equal(json.action, 'ai-suggest-links');
assert.equal(json.applied, false);
assert.equal(json.adapter.provider, 'mock');
assert.equal(json.adapter.adapterName, 'local-link-suggester');
assert.ok(json.suggestions.length >= 2);

const alphaSuggestion = json.suggestions.find((suggestion) => suggestion.label.toLowerCase() === 'alpha initiative');
assert.ok(alphaSuggestion, preview.stdout);
assert.equal(alphaSuggestion.kind, 'link');
assert.equal(alphaSuggestion.strategy, 'roam-linkify-exact');
assert.equal(alphaSuggestion.candidate.id, alphaId);
assert.equal(alphaSuggestion.reviewOnly, true);
assert.match(alphaSuggestion.sourceContext, /alpha initiative rollout/);
assert.ok(alphaSuggestion.sourceRefs.some((ref) => ref.file.endsWith('meeting.org2') && ref.line === 3));

const representedSuggestion = json.suggestions.find((suggestion) => suggestion.candidate?.id === projectId);
assert.ok(representedSuggestion, preview.stdout);
assert.equal(representedSuggestion.strategy, 'roam-linkify-represented-node');
assert.match(representedSuggestion.sourceContext, /Phoenix project/);

const entitySuggestion = json.suggestions.find((suggestion) => suggestion.kind === 'entity' && suggestion.label === 'Beta Squad');
assert.ok(entitySuggestion, preview.stdout);
assert.equal(entitySuggestion.strategy, 'entity-extraction');
assert.equal(entitySuggestion.reviewOnly, true);
assert.match(entitySuggestion.reason, /new node or alias/);

const reportPath = path.join(tmp, 'suggestions.org2');
const applied = run(['ai', 'suggest-links', '--dir', tmp, '--out', 'suggestions.org2', '--apply'], tmp);
assert.equal(applied.status, 0, applied.stderr || applied.stdout);
assert.match(applied.stdout, /Wrote review-only AI link\/entity suggestion report/);
const sourceAfter = fs.readFileSync(path.join(tmp, 'meeting.org2'), 'utf8');
assert.doesNotMatch(sourceAfter, /\[\[/, 'suggest-links must not edit canonical notes directly');
const report = fs.readFileSync(reportPath, 'utf8');
assert.match(report, /review-only/);
assert.match(report, /alpha initiative/);

fs.rmSync(tmp, { recursive: true, force: true });
console.log('✓ AI-assisted link/entity suggestions');
