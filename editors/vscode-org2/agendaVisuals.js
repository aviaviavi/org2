const path = require('path');

function parseDateYmd(value) {
  const s = String(value || '').trim();
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  if (!m) return undefined;

  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) return undefined;

  return new Date(year, month - 1, day);
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function agendaUrgencyFromDate(dateStr, now) {
  const d = parseDateYmd(dateStr);
  if (!d) return 'unknown';

  const today = startOfDay(now || new Date());
  const target = startOfDay(d);

  if (target.getTime() < today.getTime()) return 'overdue';
  if (target.getTime() === today.getTime()) return 'today';
  return 'upcoming';
}

function agendaStatusBucket(todoKeyword) {
  const key = String(todoKeyword || '').trim().toUpperCase();
  if (!key) return 'none';

  if (['DONE', 'COMPLETED'].includes(key)) return 'done';
  if (['CANCELED', 'CANCELLED'].includes(key)) return 'canceled';
  if (['IN_PROGRESS', 'DOING', 'STARTED', 'WAITING', 'BLOCKED', 'NEXT'].includes(key)) return 'inProgress';
  if (['TODO', 'OPEN', 'BACKLOG'].includes(key)) return 'todo';
  return 'custom';
}

function agendaStatusCue(statusBucket) {
  if (statusBucket === 'todo') return '[T]';
  if (statusBucket === 'inProgress') return '[~]';
  if (statusBucket === 'done') return '[✓]';
  if (statusBucket === 'canceled') return '[×]';
  if (statusBucket === 'custom') return '[?]';
  return '[·]';
}

function agendaTreeItemLabel(todoKeyword, headline, statusBucket) {
  const todo = String(todoKeyword || '').trim();
  const title = String(headline || '').trim();
  const bucket = statusBucket || agendaStatusBucket(todoKeyword);
  const cue = agendaStatusCue(bucket);

  if (!todo && !title) {
    return { label: `${cue} (untitled)`, highlights: [] };
  }

  if (!todo) {
    return { label: `${cue} ${title}`, highlights: [] };
  }

  const body = `${todo}${title ? ` ${title}` : ''}`;
  const label = `${cue} ${body}`;
  // Keep the cue readable but highlight only the TODO keyword segment.
  const todoStart = cue.length + 1;
  return {
    label,
    highlights: [[todoStart, todoStart + todo.length]],
  };
}

function agendaFileLabel(filePath) {
  const s = String(filePath || '').trim();
  if (!s) return '(unknown file)';
  return path.basename(s);
}

module.exports = {
  agendaFileLabel,
  agendaStatusBucket,
  agendaStatusCue,
  agendaTreeItemLabel,
  agendaUrgencyFromDate,
};
