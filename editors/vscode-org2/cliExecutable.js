const fs = require('fs');
const path = require('path');

const LEGACY_CLI = 'org2';
const PREFERRED_CLI = 'celorga';

function isExecutableFile(filePath) {
  try {
    const stat = fs.statSync(filePath);
    if (!stat.isFile()) return false;
    if (process.platform === 'win32') return true;
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch (_) {
    return false;
  }
}

function findExecutableOnPath(name, options = {}) {
  const env = options.env || process.env;
  const platform = options.platform || process.platform;
  const isExecutable = options.isExecutable || isExecutableFile;
  const pathValue = String(env.PATH || env.Path || '');
  if (!pathValue) return null;

  const delimiter = platform === 'win32' ? ';' : ':';
  const extensions = platform === 'win32'
    ? ['', ...String(env.PATHEXT || '.COM;.EXE;.BAT;.CMD').split(';').filter(Boolean)]
    : [''];
  const join = platform === 'win32' ? path.win32.join : path.posix.join;

  for (const dir of pathValue.split(delimiter)) {
    if (!dir) continue;
    for (const ext of extensions) {
      const candidate = join(dir, name + ext);
      if (isExecutable(candidate)) return candidate;
    }
  }
  return null;
}

// The `org2.agenda.command` default is the `org2` compatibility alias. When the
// user has not configured a command explicitly, prefer the `celorga` executable
// if it is installed and fall back to `org2` otherwise.
function resolveDefaultCliExecutable(configuredCommand, options = {}) {
  const command = String(configuredCommand || '').trim() || LEGACY_CLI;
  if (command !== LEGACY_CLI || options.explicitlyConfigured) return command;
  const find = options.findExecutable || findExecutableOnPath;
  return find(PREFERRED_CLI, options) ? PREFERRED_CLI : LEGACY_CLI;
}

function isExplicitlyConfigured(inspected) {
  if (!inspected) return false;
  return [
    inspected.globalValue,
    inspected.workspaceValue,
    inspected.workspaceFolderValue,
    inspected.globalLanguageValue,
    inspected.workspaceLanguageValue,
    inspected.workspaceFolderLanguageValue
  ].some((value) => value !== undefined);
}

module.exports = {
  LEGACY_CLI,
  PREFERRED_CLI,
  findExecutableOnPath,
  isExplicitlyConfigured,
  resolveDefaultCliExecutable
};
