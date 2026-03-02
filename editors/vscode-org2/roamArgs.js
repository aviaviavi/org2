function buildRoamBacklinksArgs(id, rootDir) {
  return ['roam', 'backlinks', '--id', id, '--dir', rootDir, '--recursive', '--format', 'json'];
}

function buildRoamNodeNewArgs(rootDir, title) {
  return ['roam', 'node', 'new', '--dir', rootDir, '--title', title, '--format', 'json', '--apply'];
}

function buildRoamDbSyncPreviewArgs(rootDir, recursive) {
  const args = ['roam', 'db-sync', '--dir', rootDir, '--format', 'json'];
  if (recursive) args.push('--recursive');
  return args;
}

function buildRoamDbSyncApplyArgs(rootDir, recursive) {
  const args = ['roam', 'db-sync', '--dir', rootDir, '--format', 'json', '--apply'];
  if (recursive) args.push('--recursive');
  return args;
}

module.exports = {
  buildRoamBacklinksArgs,
  buildRoamNodeNewArgs,
  buildRoamDbSyncPreviewArgs,
  buildRoamDbSyncApplyArgs,
};
