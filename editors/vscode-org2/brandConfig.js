// Celorga names with the pre-rename `org2.*` names as working aliases
// (docs/rename/celorga.org, "Dual names"). Commands are registered under both
// ids. Settings read `celorga.X` when the user set it, otherwise `org2.X` when
// the user set that, otherwise the contributed default.

const CONFIG_SECTION = 'celorga';
const LEGACY_CONFIG_SECTION = 'org2';
const COMMAND_PREFIX = 'celorga.';
const LEGACY_COMMAND_PREFIX = 'org2.';

function celorgaCommandId(id) {
  const value = String(id);
  return value.startsWith(LEGACY_COMMAND_PREFIX) ? COMMAND_PREFIX + value.slice(LEGACY_COMMAND_PREFIX.length) : value;
}

function legacyCommandId(id) {
  const value = String(id);
  return value.startsWith(COMMAND_PREFIX) ? LEGACY_COMMAND_PREFIX + value.slice(COMMAND_PREFIX.length) : value;
}

/** Both command ids, Celorga first. */
function commandAliases(id) {
  const modern = celorgaCommandId(id);
  const legacy = legacyCommandId(id);
  return modern === legacy ? [modern] : [modern, legacy];
}

function isUserSet(inspected) {
  if (!inspected) return false;
  return [
    inspected.globalValue,
    inspected.workspaceValue,
    inspected.workspaceFolderValue,
    inspected.globalLanguageValue,
    inspected.workspaceLanguageValue,
    inspected.workspaceFolderLanguageValue,
  ].some((value) => value !== undefined);
}

/**
 * A WorkspaceConfiguration-like view over `celorga.*` with `org2.*` fallback.
 * `getConfiguration(section, scope)` is `vscode.workspace.getConfiguration`.
 */
function createBrandConfiguration(getConfiguration, scope) {
  const modern = getConfiguration(CONFIG_SECTION, scope);
  const legacy = getConfiguration(LEGACY_CONFIG_SECTION, scope);
  const inspectOf = (cfg, key) => (cfg && typeof cfg.inspect === 'function' ? cfg.inspect(key) : undefined);
  const sourceFor = (key) => {
    if (isUserSet(inspectOf(modern, key))) return modern;
    if (isUserSet(inspectOf(legacy, key))) return legacy;
    return modern;
  };
  return {
    get(key, defaultValue) {
      const source = sourceFor(key);
      return arguments.length >= 2 ? source.get(key, defaultValue) : source.get(key);
    },
    has(key) {
      return modern.has(key) || legacy.has(key);
    },
    inspect(key) {
      return inspectOf(sourceFor(key), key);
    },
    // Update whichever spelling the user already uses; new values go to celorga.X.
    update(key, value, target, overrideInLanguage) {
      const source = !isUserSet(inspectOf(modern, key)) && isUserSet(inspectOf(legacy, key)) ? legacy : modern;
      return source.update(key, value, target, overrideInLanguage);
    },
  };
}

/** True when a configuration change touches `celorga.<key>` or `org2.<key>`. */
function affectsBrandConfiguration(event, key) {
  return event.affectsConfiguration(`${CONFIG_SECTION}.${key}`) || event.affectsConfiguration(`${LEGACY_CONFIG_SECTION}.${key}`);
}

module.exports = {
  CONFIG_SECTION,
  LEGACY_CONFIG_SECTION,
  COMMAND_PREFIX,
  LEGACY_COMMAND_PREFIX,
  celorgaCommandId,
  legacyCommandId,
  commandAliases,
  isUserSet,
  createBrandConfiguration,
  affectsBrandConfiguration,
};
