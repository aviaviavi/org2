const fs = require('node:fs');
const path = require('node:path');

const LINK_LINE_RE = /^\s*#\+LINK:\s*([^\s]+)\s+(.*?)\s*$/i;
const RESERVED_PREFIXES = new Set(['http', 'https', 'mailto', 'file', 'id']);

function normalizePrefix(value) {
  return String(value || '').trim().toLowerCase();
}

function normalizeTemplate(value) {
  return String(value || '').trim();
}

function setIfValid(out, prefixRaw, templateRaw) {
  const prefix = normalizePrefix(prefixRaw);
  const template = normalizeTemplate(templateRaw);
  if (!prefix || !template) return;
  out.set(prefix, template);
}

function buildBuiltInLinkAbbreviations(linearTeam) {
  const out = new Map();
  out.set('gh', 'https://github.com/%s');
  out.set('gl', 'https://gitlab.com/%s');
  out.set('yt', 'https://www.youtube.com/watch?v=%s');
  out.set('wiki', 'https://en.wikipedia.org/wiki/%s');

  const team = String(linearTeam || '').trim();
  if (team) {
    out.set('linear', `https://linear.app/${team}/issue/%s`);
  }

  return out;
}

function collectLinkAbbreviationsFromText(text) {
  const out = new Map();
  for (const line of String(text || '').split(/\r?\n/)) {
    const m = LINK_LINE_RE.exec(line);
    if (!m) continue;
    setIfValid(out, m[1] || '', m[2] || '');
  }
  return out;
}

function collectLinkAbbreviationsFromRecord(record) {
  const out = new Map();
  if (!record || typeof record !== 'object') return out;

  for (const [prefix, template] of Object.entries(record)) {
    setIfValid(out, prefix, template);
  }

  return out;
}

function mergeLinkAbbreviations(sources) {
  const out = new Map();
  for (const source of sources || []) {
    if (!source) continue;
    for (const [prefix, template] of source.entries()) {
      out.set(prefix, template);
    }
  }
  return out;
}

function expandLinkAbbreviationTarget(targetRaw, abbreviations) {
  const target = String(targetRaw || '').trim();
  if (!target) return target;

  const match = /^([A-Za-z][A-Za-z0-9+.-]*):(.*)$/.exec(target);
  if (!match) return target;

  const prefix = normalizePrefix(match[1]);
  if (!prefix || RESERVED_PREFIXES.has(prefix)) return target;

  const suffix = match[2] || '';
  const template = abbreviations && typeof abbreviations.get === 'function'
    ? abbreviations.get(prefix)
    : undefined;
  if (!template) {
    // Safety fallback: make linear:APP-123 clickable even when project/in-file
    // link abbreviations failed to load for any reason.
    if (prefix === 'linear' && suffix) {
      return `https://linear.app/scarf/issue/${suffix}`;
    }
    return target;
  }

  if (template.includes('%s')) {
    return template.replace(/%s/g, suffix);
  }

  return `${template}${suffix}`;
}

function findConfigFile(startDir) {
  let currentDir = path.resolve(startDir);

  for (let i = 0; i < 10; i++) {
    const configPath = path.join(currentDir, 'org2.json');
    if (fs.existsSync(configPath)) {
      return configPath;
    }

    const parentDir = path.dirname(currentDir);
    if (parentDir === currentDir) break;
    currentDir = parentDir;
  }

  return null;
}

function loadProjectLinkAbbreviations(filePath) {
  if (!filePath) return { abbreviations: new Map(), linearTeam: undefined };
  const configPath = findConfigFile(path.dirname(filePath));
  if (!configPath) return { abbreviations: new Map(), linearTeam: undefined };

  try {
    const raw = fs.readFileSync(configPath, 'utf8');
    const cfg = JSON.parse(raw);
    const linearTeam = cfg && cfg.links ? cfg.links.linearTeam : undefined;
    const abbreviations = collectLinkAbbreviationsFromRecord(cfg && cfg.links ? cfg.links.abbreviations : undefined);
    return { abbreviations, linearTeam };
  } catch {
    return { abbreviations: new Map(), linearTeam: undefined };
  }
}

function resolveDocumentLinkAbbreviations(document) {
  const documentText = typeof document.getText === 'function' ? document.getText() : '';
  const filePath = document && document.uri && document.uri.scheme === 'file' ? document.uri.fsPath : '';

  const project = loadProjectLinkAbbreviations(filePath);
  const builtIns = buildBuiltInLinkAbbreviations(project.linearTeam);
  const inFile = collectLinkAbbreviationsFromText(documentText);
  return mergeLinkAbbreviations([builtIns, project.abbreviations, inFile]);
}

module.exports = {
  resolveDocumentLinkAbbreviations,
  expandLinkAbbreviationTarget,
  collectLinkAbbreviationsFromText,
};
