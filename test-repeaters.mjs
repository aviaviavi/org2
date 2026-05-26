import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { parseOrgToCanonicalAst } from './dist/parser.js';

const ast = parseOrgToCanonicalAst(`* TODO Habit\nSCHEDULED: <2026-05-20 Wed ++1w> DEADLINE: <2026-05-21 Thu .+2d --1d>\n`);
const [headline] = ast.children;
assert.equal(headline.children[0].timestamp.repeater.mode, '++');
assert.equal(headline.children[0].timestamp.repeater.value, 1);
assert.equal(headline.children[0].timestamp.repeater.unit, 'w');
assert.equal(headline.children[1].timestamp.repeater.mode, '.+');
assert.deepEqual(headline.children[1].timestamp.warning, { mode: '--', value: 1, unit: 'd', raw: '--1d' });

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-repeaters-'));
try {
  fs.writeFileSync(path.join(dir, 'agenda.org'), [
    '* TODO Weekly review',
    'SCHEDULED: <2026-05-20 Wed +1w>',
    '* TODO Every other day',
    'DEADLINE: <2026-05-21 Thu .+2d>',
    ''
  ].join('\n'));

  const raw = execFileSync(process.execPath, [
    'dist/cli.js', 'agenda', '--dir', dir, '--from', '2026-05-26', '--to', '2026-05-29', '--format', 'json'
  ], { cwd: process.cwd(), encoding: 'utf8' });
  const agenda = JSON.parse(raw);
  const simplified = agenda.days.flatMap((day) => day.items.map((item) => ({ date: day.date, kind: item.kind, headline: item.headline })));
  assert.deepEqual(simplified, [
    { date: '2026-05-27', kind: 'SCHEDULED', headline: 'Weekly review' },
    { date: '2026-05-27', kind: 'DEADLINE', headline: 'Every other day' },
    { date: '2026-05-29', kind: 'DEADLINE', headline: 'Every other day' },
  ]);
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}

console.log('repeater parser and agenda tests passed');
