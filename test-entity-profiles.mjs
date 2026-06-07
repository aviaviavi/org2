import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { compileCorpus } from './dist/corpusCompile.js';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-entities-'));
const companyId = '11111111-1111-1111-1111-111111111111';
const personId = '22222222-2222-2222-2222-222222222222';
fs.writeFileSync(path.join(tmp, 'sonatype.org2'), `#+TITLE: Sonatype\n#+ID: ${companyId}\n#+ROAM_ALIASES: "Sonatype Inc" sona\n:PROPERTIES:\n:ORG2_ENTITY_TYPE: company\n:HQ: Fulton\n:END:\n\n* Details\n:PROPERTIES:\n:HQ: Maryland\n:END:\n`, 'utf8');
fs.writeFileSync(path.join(tmp, 'sonatype-conflict.org2'), `#+TITLE: Sonatype profile mirror\n#+ID: ${companyId}\n:PROPERTIES:\n:ORG2_ENTITY_TYPE: company\n:HQ: Maryland\n:END:\n`, 'utf8');
fs.writeFileSync(path.join(tmp, 'avi.org2'), `#+TITLE: Avi\n#+ID: ${personId}\n:PROPERTIES:\n:ORG2_ENTITY_TYPE: person\n:ORG2_RELATION_ADVISOR_TO: [[id:${companyId}][Sonatype]]\n:END:\n\nAvi advises [[Sonatype Inc]].\n`, 'utf8');
fs.writeFileSync(path.join(tmp, 'meeting.org2'), `#+TITLE: Meeting\n\nTalked with [[sona]] about roadmap provenance.\n`, 'utf8');

const files = fs.readdirSync(tmp).map((name) => path.join(tmp, name));
const corpus = compileCorpus(files, { rootDir: tmp, generatedAt: '2026-06-07T00:00:00Z' });
assert.equal(corpus.stats.entityProfiles, 2);
const sonatype = corpus.entityProfiles.find((profile) => profile.entityId === companyId);
assert.ok(sonatype);
assert.ok(sonatype.aliases.includes('sona'));
assert.ok(sonatype.aliases.includes('Sonatype Inc'));
assert.ok(sonatype.aliases.includes('Sonatype profile mirror'));
assert.equal(sonatype.backlinks.length, 3, 'id/wiki alias backlinks resolve to canonical entity');
assert.equal(sonatype.mentions.length, 2, 'profile preserves alias mention provenance');
assert.ok(sonatype.facts.some((fact) => fact.key === 'HQ' && fact.value === 'Fulton'));
assert.ok(sonatype.facts.some((fact) => fact.key === 'HQ' && fact.value === 'Maryland'));
assert.ok(sonatype.reviewNeeded.some((item) => item.type === 'conflicting-fact' && item.key === 'HQ'));

const json = execFileSync(process.execPath, ['dist/cli.js', 'entity', 'show', 'Sonatype Inc', '--dir', tmp, '--format', 'json'], { encoding: 'utf8' });
const profile = JSON.parse(json);
assert.equal(profile.entityId, companyId);
assert.equal(profile.canonicalName, 'Sonatype');
console.log('entity profiles ok');
