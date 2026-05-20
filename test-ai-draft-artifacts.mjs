#!/usr/bin/env node

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

function run(args, cwd) {
  return spawnSync('node', [path.resolve('dist/cli.js'), ...args], {
    cwd,
    encoding: 'utf8',
  });
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-ai-draft-'));
fs.mkdirSync(path.join(tmp, 'notes'), { recursive: true });
fs.writeFileSync(
  path.join(tmp, 'notes', 'meeting.org2'),
  `#+TITLE: Team Sync\n* Team Sync\nAlice decided to ship the parser cleanup on Friday.\nBob will update the release checklist before launch.\nThe group noted that Search Alpha needs follow-up evidence.\n`,
  'utf8',
);

const job = {
  schemaVersion: 'org2-ai-job/v1',
  id: 'team-sync-summary',
  description: 'Summarize the team sync as a reviewable draft.',
  input: { files: ['notes/*.org2'] },
  task: {
    type: 'summarize-meeting',
    template: 'meeting-summary@v1',
    instructions: 'Summarize decisions, actions, and open questions with citations.',
  },
  adapter: { name: 'local-test', model: 'deterministic-fixture' },
  output: { target: 'views', path: 'views/team-sync-summary.org2' },
  provenance: {
    requireSourceRefs: true,
    promptTemplateVersion: 'meeting-summary@v1',
    recordModelMetadata: true,
    recordGeneratedAt: true,
  },
  review: { policy: 'require-approval', reviewer: 'human' },
};
fs.writeFileSync(path.join(tmp, 'job.json'), JSON.stringify(job, null, 2), 'utf8');

const preview = run(['ai', 'run', '--job', 'job.json'], tmp);
assert.equal(preview.status, 0, preview.stderr || preview.stdout);
assert.match(preview.stdout, /Would write generated draft artifact/);
assert.match(preview.stdout, /ORG2_AI_JOB_ID: team-sync-summary/);
assert.match(preview.stdout, /ORG2_REVIEW_STATUS: review-required/);
assert.match(preview.stdout, /file:notes\/meeting\.org2/);
assert.equal(fs.existsSync(path.join(tmp, 'views', 'team-sync-summary.org2')), false);

const inlinePreview = run(['ai', 'run', '--task', 'summarize-meeting', '--file', 'notes/meeting.org2', '--out', 'views/inline-summary.org2', '--format', 'json'], tmp);
assert.equal(inlinePreview.status, 0, inlinePreview.stderr || inlinePreview.stdout);
const inlinePreviewJson = JSON.parse(inlinePreview.stdout);
assert.equal(inlinePreviewJson.applied, false);
assert.match(inlinePreviewJson.artifact, /Task: =summarize-meeting=/);
assert.match(inlinePreviewJson.artifact, /Generated meeting summary/);
assert.match(inlinePreviewJson.artifact, /\*\* Summary/);
assert.match(inlinePreviewJson.artifact, /ORG2_PROMPT_TEMPLATE: meeting-summary@v1/);
assert.equal(fs.existsSync(path.join(tmp, 'views', 'inline-summary.org2')), false);

const applied = run(['ai', 'run', '--job', 'job.json', '--apply', '--format', 'json'], tmp);
assert.equal(applied.status, 0, applied.stderr || applied.stdout);
const appliedJson = JSON.parse(applied.stdout);
assert.equal(appliedJson.applied, true);
const draftPath = path.join(tmp, 'views', 'team-sync-summary.org2');
let draft = fs.readFileSync(draftPath, 'utf8');
assert.match(draft, /:ORG2_PROMPT_TEMPLATE: meeting-summary@v1/);
assert.match(draft, /\[\[file:notes\/meeting\.org2::2\]\[notes\/meeting\.org2:2\]\]/);
assert.match(draft, /\* Generated meeting summary/);
assert.match(draft, /\*\* Summary/);
assert.match(draft, /Alice decided to ship the parser cleanup/);
assert.match(draft, /\*\* TODO items/);
assert.match(draft, /TODO The group noted that Search Alpha needs follow-up evidence/);
assert.match(draft, /\* Source excerpts/);
assert.match(draft, /Adapter invocation: =mock-/);

const lint = run(['lint', '--file', 'views/team-sync-summary.org2', '--format', 'json'], tmp);
assert.equal(lint.status, 0, lint.stderr || lint.stdout);
const lintJson = JSON.parse(lint.stdout);
assert.ok(lintJson.issues.some((issue) => issue.rule === 'artifact-generated-unreviewed'));

const blockedPromote = run(['ai', 'promote', '--file', 'views/team-sync-summary.org2', '--to-file', 'notes/canonical.org2'], tmp);
assert.equal(blockedPromote.status, 1);
assert.match(blockedPromote.stderr, /must have ORG2_REVIEW_STATUS reviewed/);

fs.writeFileSync(draftPath, draft.replace(':ORG2_REVIEW_STATUS: review-required', ':ORG2_REVIEW_STATUS: reviewed'), 'utf8');
const promotePreview = run(['ai', 'promote', '--file', 'views/team-sync-summary.org2', '--to-file', 'notes/canonical.org2'], tmp);
assert.equal(promotePreview.status, 0, promotePreview.stderr || promotePreview.stdout);
assert.match(promotePreview.stdout, /Would append reviewed artifact body/);
assert.equal(fs.existsSync(path.join(tmp, 'notes', 'canonical.org2')), false);

const promoted = run(['ai', 'promote', '--file', 'views/team-sync-summary.org2', '--to-file', 'notes/canonical.org2', '--apply', '--format', 'json'], tmp);
assert.equal(promoted.status, 0, promoted.stderr || promoted.stdout);
const promotedJson = JSON.parse(promoted.stdout);
assert.equal(promotedJson.applied, true);
const canonical = fs.readFileSync(path.join(tmp, 'notes', 'canonical.org2'), 'utf8');
assert.match(canonical, /#\+TITLE: Summarize the team sync as a reviewable draft\./);
assert.doesNotMatch(canonical, /:ORG2_ARTIFACT_ROLE:/);
draft = fs.readFileSync(draftPath, 'utf8');
assert.match(draft, /:ORG2_REVIEW_STATUS: promoted/);

fs.rmSync(tmp, { recursive: true, force: true });
console.log('✓ AI draft artifact workflow');
