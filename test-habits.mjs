import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'org2-habits-'));
try {
  fs.writeFileSync(path.join(dir, 'habits.org'), [
    '* TODO Stretch',
    ':PROPERTIES:',
    ':HABIT: true',
    ':END:',
    'SCHEDULED: <2026-05-26 Tue +1d>',
    ':LOGBOOK:',
    'CLOSED: [2026-05-26 Tue]',
    'CLOSED: [2026-05-25 Mon]',
    ':END:',
    '* TODO Ambiguous habit',
    ':PROPERTIES:',
    ':STYLE: habit',
    ':END:',
    'SCHEDULED: <2026-05-26 Tue>',
    ''
  ].join('\n'));

  const rawAgenda = execFileSync(process.execPath, [
    'dist/cli.js', 'agenda', '--dir', dir, '--from', '2026-05-26', '--to', '2026-05-26', '--format', 'json'
  ], { cwd: process.cwd(), encoding: 'utf8' });
  const agenda = JSON.parse(rawAgenda);
  const stretch = agenda.days.flatMap((day) => day.items).find((item) => item.headline === 'Stretch');
  assert.ok(stretch, 'expected habit agenda row');
  assert.deepEqual(stretch.habit, {
    marker: 'true',
    streak: 2,
    closedDates: ['2026-05-25', '2026-05-26'],
  });

  const rawLint = execFileSync(process.execPath, [
    'dist/cli.js', 'lint', '--dir', dir, '--format', 'json'
  ], { cwd: process.cwd(), encoding: 'utf8' });
  const lint = JSON.parse(rawLint);
  assert.ok(lint.issues.some((issue) => issue.rule === 'habit-missing-repeater'));
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}

console.log('habit agenda and lint tests passed');
