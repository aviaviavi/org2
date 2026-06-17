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

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-ai-review-'));
fs.mkdirSync(path.join(tmp, 'views'), { recursive: true });
fs.writeFileSync(
  path.join(tmp, 'views', 'candidate.org2'),
  `#+TITLE: Candidate memory update
:PROPERTIES:
:ORG2_ARTIFACT_ROLE: generated-summary
:ORG2_REVIEW_STATUS: review-required
:ORG2_AI_JOB_ID: candidate-job
:ORG2_AI_TASK: summarize-meeting
:ORG2_PROVENANCE: file:raw/team-sync.org2
:END:
* Generated meeting summary
** TODO items
* TODO Follow up with Alice [[file:raw/team-sync.org2::2][raw/team-sync.org2:2]]
`,
  'utf8',
);
fs.writeFileSync(
  path.join(tmp, 'views', 'rejected.org2'),
  `#+TITLE: Rejected candidate
:PROPERTIES:
:ORG2_REVIEW_STATUS: rejected
:END:
`,
  'utf8',
);

const listed = run(['ai', 'review', '--dir', 'views', '--format', 'json'], tmp);
assert.equal(listed.status, 0, listed.stderr || listed.stdout);
const listedJson = JSON.parse(listed.stdout);
assert.equal(listedJson.count, 1);
assert.equal(listedJson.items[0].file, 'views/candidate.org2');
assert.equal(listedJson.items[0].status, 'review-required');
assert.equal(listedJson.items[0].jobId, 'candidate-job');
assert.deepEqual(listedJson.items[0].todos, ['Follow up with Alice [[file:raw/team-sync.org2::2][raw/team-sync.org2:2]]']);
assert.ok(listedJson.items[0].sources.includes('raw/team-sync.org2'));

const preview = run(['ai', 'review', '--file', 'views/candidate.org2', '--status', 'deferred'], tmp);
assert.equal(preview.status, 0, preview.stderr || preview.stdout);
assert.match(preview.stdout, /Would mark views\/candidate\.org2 as deferred/);
let draft = fs.readFileSync(path.join(tmp, 'views', 'candidate.org2'), 'utf8');
assert.match(draft, /:ORG2_REVIEW_STATUS: review-required/);

const applied = run(['ai', 'review', '--file', 'views/candidate.org2', '--status', 'reviewed', '--apply', '--format', 'json'], tmp);
assert.equal(applied.status, 0, applied.stderr || applied.stdout);
const appliedJson = JSON.parse(applied.stdout);
assert.equal(appliedJson.applied, true);
assert.equal(appliedJson.status, 'reviewed');
draft = fs.readFileSync(path.join(tmp, 'views', 'candidate.org2'), 'utf8');
assert.match(draft, /:ORG2_REVIEW_STATUS: reviewed/);

const empty = run(['ai', 'review', '--dir', 'views'], tmp);
assert.equal(empty.status, 0, empty.stderr || empty.stdout);
assert.match(empty.stdout, /No generated artifacts pending review/);

fs.rmSync(tmp, { recursive: true, force: true });
console.log('✓ AI review workflow');
