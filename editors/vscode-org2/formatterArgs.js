const path = require('path');

function normalizeOptionalString(value) {
  return String(value || '').trim();
}

function resolveWorkspaceFormatterPathFilters(options = {}) {
  const {
    root = process.cwd(),
    fileFilter = '',
    excludeFileFilter = '',
    configFile = '',
  } = options;

  const normalizedRoot = String(root || process.cwd());
  const normalizedFileFilter = normalizeOptionalString(fileFilter);
  const normalizedExcludeFileFilter = normalizeOptionalString(excludeFileFilter);
  const configFileRaw = normalizeOptionalString(configFile);
  const resolvedConfigFile = configFileRaw
    ? (path.isAbsolute(configFileRaw) ? configFileRaw : path.resolve(normalizedRoot, configFileRaw))
    : '';

  return {
    fileFilter: normalizedFileFilter,
    excludeFileFilter: normalizedExcludeFileFilter,
    configFile: resolvedConfigFile,
  };
}

function buildWorkspaceFormatterCommandArgs(options = {}) {
  const {
    root = process.cwd(),
    pathFilters = {},
    mode = 'check',
  } = options;

  const args = ['fmt'];

  if (pathFilters.configFile) {
    args.push('--config', pathFilters.configFile);
  } else {
    args.push('--dir', root, '--recursive');
  }

  if (mode === 'check') {
    args.push('--check');
  } else if (mode === 'apply') {
    args.push('--apply');
  }

  if (pathFilters.fileFilter) args.push('--file-match', pathFilters.fileFilter);
  if (pathFilters.excludeFileFilter) args.push('--exclude-file', pathFilters.excludeFileFilter);

  return args;
}

function buildCurrentFileFormatterPreviewArgs(filePath) {
  return ['fmt', '--file', filePath, '--format', 'json'];
}

function buildCurrentFileFormatterCheckArgs(filePath) {
  return ['fmt', '--file', filePath, '--check'];
}

function buildCurrentFileFormatterApplyArgs(filePath) {
  return ['fmt', '--file', filePath, '--apply'];
}

function buildCurrentFileFormatterStdoutArgs(filePath) {
  return ['fmt', '--file', filePath];
}

module.exports = {
  resolveWorkspaceFormatterPathFilters,
  buildWorkspaceFormatterCommandArgs,
  buildCurrentFileFormatterPreviewArgs,
  buildCurrentFileFormatterCheckArgs,
  buildCurrentFileFormatterApplyArgs,
  buildCurrentFileFormatterStdoutArgs,
};
