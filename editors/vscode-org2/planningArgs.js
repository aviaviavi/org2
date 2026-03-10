function normalizePlanKind(value) {
  const raw = String(value || '').trim().toLowerCase();
  if (raw === 'scheduled' || raw === 'schedule') return 'scheduled';
  if (raw === 'deadline' || raw === 'due') return 'deadline';
  return '';
}

function normalizePlanDateInput(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  return /^\d{4}-\d{2}-\d{2}$/.test(raw) ? raw : '';
}

function buildPlanCliArgs(options = {}) {
  const {
    filePath = '',
    line = 1,
    kind = 'scheduled',
    useToday = false,
    date = '',
  } = options;

  const args = [
    'plan',
    useToday ? 'today' : 'set',
    '--file',
    String(filePath),
    '--line',
    String(line),
    '--kind',
    String(kind),
  ];

  if (!useToday) {
    args.push('--date', String(date));
  }

  args.push('--format', 'json', '--apply');
  return args;
}

module.exports = {
  normalizePlanKind,
  normalizePlanDateInput,
  buildPlanCliArgs,
};
