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
  const raw = String(todoKeyword || '').trim().toUpperCase();
  if (!raw) return 'none';
  const key = raw.replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '');

  if (['DONE', 'COMPLETE', 'COMPLETED', 'FINISH', 'FINISHED', 'CLOSED', 'RESOLVED'].includes(key)) return 'done';
  if (['CANCELED', 'CANCELLED'].includes(key)) return 'canceled';
  if (['PROG', 'IN_PROGRESS', 'INPROGRESS', 'DOING', 'STARTED', 'WAITING', 'WAIT', 'BLOCKED', 'NEXT', 'WIP', 'HOLD', 'ON_HOLD', 'ONHOLD', 'PAUSED', 'PAUSE'].includes(key)) return 'inProgress';
  if (['TODO', 'OPEN', 'BACKLOG'].includes(key)) return 'todo';
  return 'custom';
}

function hasRecognizedHeadlineTodoKeyword(value) {
  const bucket = agendaStatusBucket(value);
  return bucket === 'todo' || bucket === 'inProgress' || bucket === 'done' || bucket === 'canceled';
}

function stripHeadlineTodoKeyword(headline) {
  const text = String(headline || '').trim();
  if (!text) return '';

  const match = /^(\S+)\s+(.+)$/.exec(text);
  if (!match) return text;
  if (!hasRecognizedHeadlineTodoKeyword(match[1])) return text;
  return String(match[2] || '').trim();
}

function stripHeadlinePriorityCookie(headline) {
  return String(headline || '')
    .replace(/^\s*\[#([A-Z0-9])\]\s+/, '')
    .trim();
}

function parseHeadlineTitleForRoam(line) {
  const withoutStars = String(line || '').trim().replace(/^\*+\s+/, '');
  const withoutTags = withoutStars.replace(/\s+:[^\s:]+(?::[^\s:]+)*:\s*$/, '').trim();
  return stripHeadlinePriorityCookie(stripHeadlineTodoKeyword(withoutTags));
}

function agendaStatusCue(statusBucket) {
  if (statusBucket === 'todo') return '[T]';
  if (statusBucket === 'inProgress') return '[~]';
  if (statusBucket === 'done') return '[✓]';
  if (statusBucket === 'canceled') return '[×]';
  if (statusBucket === 'custom') return '[?]';
  return '[·]';
}

function normalizeAgendaPriority(value) {
  const raw = String(value || '').trim().toUpperCase();
  if (!raw) return '';
  const token = raw.replace(/[^A-Z]/g, '');
  if (token === 'A' || token === 'B' || token === 'C') return token;
  return '';
}

function extractAgendaPriorityFromHeadline(headline) {
  const text = String(headline || '');
  const match = /\[#([A-Z])\]/.exec(text);
  return normalizeAgendaPriority(match ? match[1] : '');
}

function agendaPriorityRank(value) {
  const priority = normalizeAgendaPriority(value);
  if (priority === 'A') return 0;
  if (priority === 'B') return 1;
  if (priority === 'C') return 2;
  return 3;
}

function agendaTreeItemLabel(todoKeyword, headline, statusBucket, priorityToken) {
  const todo = String(todoKeyword || '').trim();
  const rawTitle = String(headline || '').trim();
  const bucket = statusBucket || agendaStatusBucket(todoKeyword);
  const cue = agendaStatusCue(bucket);

  const explicitPriority = normalizeAgendaPriority(priorityToken);
  const inferredPriority = extractAgendaPriorityFromHeadline(rawTitle);
  const resolvedPriority = explicitPriority || inferredPriority;
  const priorityPrefix = resolvedPriority ? `[#${resolvedPriority}] ` : '';
  const title = rawTitle.replace(/\s*\[#([A-Z])\]\s*/i, ' ').replace(/\s+/g, ' ').trim();

  if (!todo && !title) {
    return { label: `${cue} ${priorityPrefix}(untitled)`, highlights: [] };
  }

  if (!todo) {
    return { label: `${cue} ${priorityPrefix}${title}`, highlights: [] };
  }

  const body = `${todo}${title ? ` ${title}` : ''}`;
  const label = `${cue} ${priorityPrefix}${body}`;
  // Keep the cue readable but highlight only the TODO keyword segment.
  const todoStart = cue.length + 1 + priorityPrefix.length;
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
  agendaPriorityRank,
  agendaStatusBucket,
  agendaStatusCue,
  agendaTreeItemLabel,
  agendaUrgencyFromDate,
  extractAgendaPriorityFromHeadline,
  hasRecognizedHeadlineTodoKeyword,
  normalizeAgendaPriority,
  parseHeadlineTitleForRoam,
  stripHeadlinePriorityCookie,
  stripHeadlineTodoKeyword,
};
