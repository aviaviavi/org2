const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const cp = require('child_process');
const {
  agendaFileLabel,
  agendaPriorityRank,
  agendaStatusBucket,
  agendaStatusCue,
  agendaTreeItemLabel,
  agendaUrgencyFromDate,
  extractAgendaPriorityFromHeadline,
  normalizeAgendaPriority,
} = require('./agendaVisuals');
const { buildAgendaTreeGroupsFromCli } = require('./agendaTreeModel');
const { resolveAgendaTargets, orderAgendaTargetsForMutation } = require('./agendaSelection');
const { buildAgendaCliArgs } = require('./agendaArgs');
const { readAgendaCliOptions } = require('./agendaSettings');
const {
  normalizeAgendaStatusFilterValue,
  buildAgendaStatusFilterQuickPickOptions,
} = require('./agendaStatusFilter');
const {
  resolveWorkspaceFormatterPathFilters,
  buildWorkspaceFormatterCommandArgs,
  buildCurrentFileFormatterPreviewArgs,
  buildCurrentFileFormatterCheckArgs,
  buildCurrentFileFormatterApplyArgs,
  buildCurrentFileFormatterStdoutArgs,
} = require('./formatterArgs');
const {
  normalizePlanKind,
  normalizePlanDateInput,
  buildPlanCliArgs,
} = require('./planningArgs');
const {
  buildRoamBacklinksArgs,
  buildRoamNodeNewArgs,
  buildRoamDbSyncPreviewArgs,
  buildRoamDbSyncApplyArgs,
} = require('./roamArgs');
const { normalizeOrgPriorityToken, updateHeadlinePriorityToken } = require('./priorityToken');
const { parseRoamIdScheme, parseRoamIdLink, extractRoamUuid, sanitizeBacklinkContextText } = require('./roamId');
const { resolveDocumentLinkAbbreviations, expandLinkAbbreviationTarget } = require('./linkAbbrev');
const {
  findHeadlineLineAtOrAbove,
  findSubtreeRangeAtOrAbove,
  findHeadingLevelEditTargets,
  findPreviousSiblingSubtreeRange,
  findNextSiblingSubtreeRange,
  findHeadingLinesAtLevel,
} = require('./headingTree');
const { buildInsertedListItemPrefix } = require('./listItem');
const { normalizeTodoStatusValue } = require('./todoStatus');
const {
  findPropertyDrawerStartLines: findPropertyDrawerStartLinesForFolding,
  provideFoldingRanges: provideFoldingRangesForDocument,
} = require('./foldingRanges');

const headingRe = /^(\*+)\s+/;
const listItemRe = /^(\s*)(?:[-+*]|\d+[.)])\s+/;
const propertiesBeginRe = /^\s*:PROPERTIES:\s*$/i;
const drawerEndRe = /^\s*:END:\s*$/i;
const roamIdSchemeRe = /^id:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$/i;

function getSubtreeDocumentRange(document, range) {
  if (!document || !range) return null;
  const startLine = Math.max(0, Math.min(Number(range.startLine) || 0, document.lineCount - 1));
  const endLine = Math.max(startLine, Math.min(Number(range.endLine) || startLine, document.lineCount - 1));
  const start = document.lineAt(startLine).range.start;
  const endLineRange = document.lineAt(endLine);
  const end = endLine < document.lineCount - 1
    ? endLineRange.rangeIncludingLineBreak.end
    : endLineRange.range.end;

  return new vscode.Range(start, end);
}

function findPropertyDrawerStartLines(document) {
  return findPropertyDrawerStartLinesForFolding(document);
}

function provideFoldingRanges(document) {
  return provideFoldingRangesForDocument(document, vscode);
}

function resolveOrg2LinkTarget(rawUrl, document, linkAbbreviations) {
  const url = expandLinkAbbreviationTarget((rawUrl || '').trim(), linkAbbreviations);
  if (!url) return undefined;

  // Org Roam id: links (id:<uuid>) → dispatch to our command.
  // VS Code's default URL handler can't open these.
  const id = parseRoamIdScheme(url);
  if (id) {
    const payload = encodeURIComponent(JSON.stringify([id]));
    return vscode.Uri.parse(`command:org2.roamOpenId?${payload}`);
  }

  // Heuristic: only treat known schemes as directly openable URLs.
  // Unknown schemes (e.g. unresolved link abbreviations like linear:APP-123)
  // should not become dead cmd-click links.
  const schemeMatch = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(url);
  if (schemeMatch) {
    const scheme = String(schemeMatch[1] || '').toLowerCase();
    const openableSchemes = new Set(['https', 'http', 'mailto', 'file', 'vscode']);
    if (openableSchemes.has(scheme)) {
      try {
        return vscode.Uri.parse(url, true);
      } catch (e) {
        return undefined;
      }
    }

    // Looks like a URI scheme but unresolved (e.g. linear:APP-123 without an
    // abbreviation mapping in scope). Do not reinterpret this as a roam-title
    // or filesystem link.
    return undefined;
  }

  // Otherwise treat it as a filesystem path relative to the current document.
  // If no file exists, treat bracket target as a roam-title link target.
  if (document.uri && document.uri.scheme === 'file') {
    const baseDir = path.dirname(document.uri.fsPath);
    const fsPath = path.resolve(baseDir, url);
    try {
      fs.accessSync(fsPath);
      return vscode.Uri.file(fsPath);
    } catch (_) {
      const payload = encodeURIComponent(JSON.stringify([url]));
      return vscode.Uri.parse(`command:org2.roamOpenTitle?${payload}`);
    }
  }

  return undefined;
}

function provideDocumentLinks(document) {
  const links = [];
  const linkAbbreviations = resolveDocumentLinkAbbreviations(document);

  // Org2 links: [[url]] or [[url][desc]]
  const org2LinkRe = /\[\[([^\]\n]+?)(?:\]\[([^\]\n]*)\])?\]\]/g;
  const bareUrlRe = /\bhttps?:\/\/[^\s<>()\[\]{}]+/g;

  for (let line = 0; line < document.lineCount; line++) {
    const text = document.lineAt(line).text;

    for (const re of [org2LinkRe, bareUrlRe]) {
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(text)) !== null) {
        const start = m.index;
        const end = m.index + m[0].length;

        const targetUrl = re === org2LinkRe ? m[1] : m[0];
        const target = resolveOrg2LinkTarget(targetUrl, document, linkAbbreviations);
        if (!target) continue;

        // Keep range as the whole link token. This is what VS Code expects for ctrl/cmd+click.
        links.push(new vscode.DocumentLink(new vscode.Range(line, start, line, end), target));
      }
    }
  }

  return links;
}

class Org2AgendaGroup {
  constructor(label, date, weekday, isOverdue, items) {
    this.label = label;
    this.date = date;
    this.weekday = weekday;
    this.isOverdue = isOverdue;
    this.items = items || [];
  }
}

class Org2AgendaSeparator {
  constructor(label) {
    this.label = label;
  }
}

class Org2AgendaItem {
  constructor({ todo, headline, kind, file, line, date, time, urgency, priority }) {
    this.todo = todo || '';
    this.headline = headline || '';
    this.kind = kind || '';
    this.file = file;
    this.fileLabel = agendaFileLabel(file);
    this.line = typeof line === 'number' ? line : 0;
    this.date = date;
    this.time = typeof time === 'string' ? time.trim() : '';
    this.urgency = urgency || agendaUrgencyFromDate(date);
    this.statusBucket = agendaStatusBucket(todo);
    this.priority = normalizeAgendaPriority(priority) || extractAgendaPriorityFromHeadline(this.headline);
  }
}

class Org2BacklinksFileGroup {
  constructor(file, rootDir, items) {
    this.file = file;
    this.rootDir = rootDir;
    this.items = items || [];
  }
}

class Org2BacklinkItem {
  constructor(entry, rootDir) {
    this.file = String((entry && entry.file) || '');
    this.line = typeof (entry && entry.line) === 'number' ? entry.line : 0;
    this.srcId = String((entry && entry.srcId) || '');
    this.srcTitle = String((entry && entry.srcTitle) || '').trim() || '(untitled)';
    this.context = sanitizeBacklinkContextText(entry && entry.context);
    this.contextLine = this.context ? this.context.split(/\r?\n/).map((s) => s.trim()).find(Boolean) || '' : '';
    this.rootDir = rootDir;
  }
}

class Org2BacklinksProvider {
  constructor(context) {
    this.context = context;
    this._onDidChangeTreeData = new vscode.EventEmitter();
    this.onDidChangeTreeData = this._onDidChangeTreeData.event;

    this.groups = [];
    this.targetId = '';
    this.targetFile = '';
    this.emptyReason = 'Open an Org/Org2 file with a file-level ID to view backlinks.';
    this.lastError = undefined;
    this._loadSeq = 0;
  }

  refresh() {
    this._onDidChangeTreeData.fire();
  }

  clear(reason) {
    this.groups = [];
    this.targetId = '';
    this.targetFile = '';
    this.emptyReason = String(reason || 'Open an Org/Org2 file with a file-level ID to view backlinks.');
    this.lastError = undefined;
    this.refresh();
  }

  async loadForEditor(editor, options = {}) {
    const seq = ++this._loadSeq;
    const focusView = options && options.focusView === true;

    if (!editor || !editor.document) {
      this.clear('Open an Org/Org2 file with a file-level ID to view backlinks.');
      return;
    }

    const doc = editor.document;
    if ((doc.languageId !== 'org2' && doc.languageId !== 'org') || !doc.uri || doc.uri.scheme !== 'file') {
      this.clear('Backlinks are available for file-backed Org/Org2 documents.');
      return;
    }

    const text = doc.getText();
    const cursorLine = editor.selection && editor.selection.active ? editor.selection.active.line : 0;
    const headlineId = findHeadlineLevelIdAtLineInText(text, cursorLine);
    const fileId = extractRoamUuid(findFileLevelIdInText(text) || '');
    const candidateIds = [];
    if (fileId) candidateIds.push(fileId);
    if (headlineId && headlineId !== fileId) candidateIds.push(headlineId);

    if (candidateIds.length === 0) {
      this.groups = [];
      this.targetId = '';
      this.targetFile = doc.uri.fsPath;
      this.emptyReason = 'No roam :ID: found at the current headline or file level.';
      this.lastError = undefined;
      this.refresh();
      return;
    }

    const rootDir = getRoamIndexRootDir();
    let loaded = null;
    for (const candidateId of candidateIds) {
      const result = await loadBacklinksByIdWithContext(this.context, candidateId, rootDir, { quiet: true });
      if (!result) continue;
      loaded = result;
      if (Array.isArray(result.backlinks) && result.backlinks.length > 0) break;
    }
    if (seq !== this._loadSeq) return;

    if (!loaded) {
      this.groups = [];
      this.targetId = candidateIds[0] || '';
      this.targetFile = doc.uri.fsPath;
      this.emptyReason = 'Failed to load backlinks for current file ID.';
      this.lastError = new Error('Failed to load backlinks.');
      this.refresh();
      return;
    }

    const grouped = new Map();
    for (const backlink of loaded.backlinks || []) {
      const file = String(backlink && backlink.file ? backlink.file : '');
      if (!file) continue;
      if (!grouped.has(file)) grouped.set(file, []);
      grouped.get(file).push(new Org2BacklinkItem(backlink, rootDir));
    }

    this.groups = Array.from(grouped.entries())
      .sort((a, b) => String(a[0]).localeCompare(String(b[0])))
      .map(([file, items]) => {
        const sortedItems = items.slice().sort((aItem, bItem) => {
          if (aItem.line !== bItem.line) return aItem.line - bItem.line;
          return aItem.srcTitle.localeCompare(bItem.srcTitle);
        });
        return new Org2BacklinksFileGroup(file, rootDir, sortedItems);
      });
    this.targetId = loaded.id || candidateIds[0] || '';
    this.targetFile = doc.uri.fsPath;
    this.emptyReason = `No backlinks found for id:${this.targetId}.`;
    this.lastError = undefined;
    this.refresh();

    if (focusView) {
      await focusBacklinksView().catch(() => {});
    }
  }

  getTreeItem(element) {
    if (element instanceof Org2BacklinksFileGroup) {
      const count = element.items.length;
      const rel = backlinkRelativePath(element.file, element.rootDir);
      const item = new vscode.TreeItem(`${rel} (${count})`, vscode.TreeItemCollapsibleState.Expanded);
      item.contextValue = 'org2BacklinksFileGroup';
      item.tooltip = element.file;
      item.description = path.basename(element.file);
      return item;
    }

    if (element instanceof Org2BacklinkItem) {
      const primaryLabel = element.contextLine || element.srcTitle;
      const item = new vscode.TreeItem(primaryLabel, vscode.TreeItemCollapsibleState.None);
      const shortId = element.srcId && /^([0-9a-fA-F-]{36})$/.test(element.srcId)
        ? element.srcId.slice(0, 8).toLowerCase()
        : '';
      const descParts = [element.srcTitle, `L${element.line + 1}`];
      if (shortId) descParts.push(shortId);
      item.description = descParts.join(' • ');
      item.contextValue = 'org2BacklinkItem';
      item.command = {
        command: 'org2.openFileAt',
        title: 'Open Backlink',
        arguments: [element.file, element.line],
      };
      const tooltipLines = [
        `**${element.srcTitle}**`,
        '',
        `- File: ${element.file}:${element.line + 1}`,
      ];
      if (shortId) tooltipLines.push(`- Source ID: ${shortId}`);
      if (element.context) {
        tooltipLines.push('');
        tooltipLines.push(element.context);
      }
      item.tooltip = new vscode.MarkdownString(tooltipLines.join('\n'));
      return item;
    }

    const item = new vscode.TreeItem(String(element || 'Org2 backlinks'), vscode.TreeItemCollapsibleState.None);
    item.contextValue = 'org2BacklinksMessage';
    return item;
  }

  async getChildren(element) {
    if (!element) {
      if (this.lastError) return ['Org2 backlinks: failed to load'];
      if (!this.targetId) return [this.emptyReason];
      if (!this.groups.length) return [this.emptyReason];
      return this.groups;
    }

    if (element instanceof Org2BacklinksFileGroup) return element.items;
    return [];
  }
}

function backlinkRelativePath(file, rootDir) {
  const absFile = String(file || '');
  const absRoot = String(rootDir || '');
  if (!absFile) return '(unknown file)';
  if (!absRoot) return path.basename(absFile);
  try {
    const rel = path.relative(absRoot, absFile);
    if (rel && !rel.startsWith('..') && !path.isAbsolute(rel)) return rel;
  } catch (_) {
    // ignore
  }
  return path.basename(absFile);
}

async function loadBacklinksByIdWithContext(context, id, rootDir, options = {}) {
  const quiet = options && options.quiet === true;
  const normalizedId = extractRoamUuid(id);
  if (!normalizedId) {
    if (!quiet) {
      vscode.window.showWarningMessage('Org2: invalid backlink target ID (expected UUID or id:UUID link).');
    }
    return null;
  }

  const backlinksArgs = buildRoamBacklinksArgs(normalizedId, rootDir);
  const { cmd: backlinksCmd, args: backlinksFinalArgs } = resolveOrg2Command(context, backlinksArgs);

  let backlinksOut;
  try {
    backlinksOut = await execFileAsync(backlinksCmd, backlinksFinalArgs, { cwd: rootDir });
  } catch (e) {
    if (!quiet) {
      vscode.window.showErrorMessage(`Org2: failed to load backlinks: ${String(e && e.message ? e.message : e)}`);
    }
    return null;
  }

  let payload;
  try {
    payload = JSON.parse(String((backlinksOut && backlinksOut.stdout) || '').trim());
  } catch (e) {
    if (!quiet) {
      vscode.window.showErrorMessage('Org2: failed to parse org2 backlinks output.');
    }
    return null;
  }

  const backlinks = Array.isArray(payload.backlinks) ? payload.backlinks : [];
  return {
    id: normalizedId,
    backlinks,
    rootDir,
  };
}

function getAgendaUrgencyThemeColor(urgency) {
  if (urgency === 'overdue') return 'errorForeground';
  if (urgency === 'today') return 'list.warningForeground';
  if (urgency === 'upcoming') return 'list.deemphasizedForeground';
  return 'descriptionForeground';
}

function getAgendaStatusThemeColor(statusBucket) {
  if (statusBucket === 'todo') return 'list.warningForeground';
  if (statusBucket === 'inProgress') return 'list.highlightForeground';
  if (statusBucket === 'done') return 'gitDecoration.addedResourceForeground';
  if (statusBucket === 'canceled') return 'gitDecoration.deletedResourceForeground';
  if (statusBucket === 'custom') return 'editorInfo.foreground';
  return 'descriptionForeground';
}

function getAgendaStatusFallbackColor(statusBucket) {
  if (statusBucket === 'todo') return '#d19a66';
  if (statusBucket === 'inProgress') return '#61afef';
  if (statusBucket === 'done') return '#7fbf7f';
  if (statusBucket === 'canceled') return '#9da5b4';
  if (statusBucket === 'custom') return '#c5c9d1';
  return '#9da5b4';
}

function getAgendaStatusStageLabel(statusBucket) {
  if (statusBucket === 'todo') return 'Planned';
  if (statusBucket === 'inProgress') return 'In progress';
  if (statusBucket === 'done') return 'Completed';
  if (statusBucket === 'canceled') return 'Canceled';
  if (statusBucket === 'custom') return 'Custom';
  return 'No status';
}

class Org2AgendaProvider {
  constructor(context) {
    this.context = context;
    this._onDidChangeTreeData = new vscode.EventEmitter();
    this.onDidChangeTreeData = this._onDidChangeTreeData.event;

    this.filter = { type: 'next', days: 7 };
    this.groups = [];
    this.lastError = undefined;
    this.view = null;
  }

  attachView(view) {
    this.view = view || null;
    this.updateViewSummary();
  }

  getSummary() {
    const summary = { total: 0, overdue: 0, today: 0, upcoming: 0 };
    for (const group of this.groups || []) {
      if (!(group instanceof Org2AgendaGroup)) continue;
      for (const item of group.items || []) {
        summary.total += 1;
        if (item.urgency === 'overdue') summary.overdue += 1;
        else if (item.urgency === 'today') summary.today += 1;
        else if (item.urgency === 'upcoming') summary.upcoming += 1;
      }
    }
    return summary;
  }

  updateViewSummary() {
    if (!this.view) return;
    const summary = this.getSummary();
    this.view.title = `Org2 Agenda (${summary.total})`;
    const breakdown = [];
    if (summary.overdue > 0) breakdown.push(`O:${summary.overdue}`);
    if (summary.today > 0) breakdown.push(`T:${summary.today}`);
    if (summary.upcoming > 0) breakdown.push(`U:${summary.upcoming}`);
    this.view.description = breakdown.join(' ');
  }

  refresh() {
    this.updateViewSummary();
    this._onDidChangeTreeData.fire();
  }

  async load() {
    try {
      this.lastError = undefined;
      this.groups = await fetchAgendaGroups(this.context, this.filter);
    } catch (e) {
      this.lastError = e;
      this.groups = [];
    }
    this.refresh();
  }

  getTreeItem(element) {
    if (element instanceof Org2AgendaGroup) {
      const item = new vscode.TreeItem(element.label, vscode.TreeItemCollapsibleState.Expanded);
      item.contextValue = element.isOverdue ? 'org2AgendaGroupOverdue' : 'org2AgendaGroup';
      item.tooltip = `${element.weekday || ''} ${element.date || ''}`.trim();
      return item;
    }

    if (element instanceof Org2AgendaSeparator) {
      const item = new vscode.TreeItem(element.label, vscode.TreeItemCollapsibleState.None);
      item.contextValue = 'org2AgendaSeparator';
      return item;
    }

    if (element instanceof Org2AgendaItem) {
      const rowLabel = agendaTreeItemLabel(element.todo, element.headline, element.statusBucket, element.priority);
      const item = new vscode.TreeItem(rowLabel.label, vscode.TreeItemCollapsibleState.None);
      if (rowLabel.highlights.length) {
        item.label = { label: rowLabel.label, highlights: rowLabel.highlights };
      }

      const parts = [element.fileLabel];
      if (element.time) parts.push(`@${element.time}`);
      if (element.kind) parts.push(element.kind);
      item.description = parts.join(' · ');

      item.iconPath = new vscode.ThemeIcon('circle-filled', new vscode.ThemeColor(getAgendaUrgencyThemeColor(element.urgency)));
      item.contextValue = 'org2AgendaItem';
      item.command = {
        command: 'org2.openAgendaItem',
        title: 'Open',
        arguments: [element],
      };

      const statusColor = getAgendaStatusThemeColor(element.statusBucket);
      const statusFallback = getAgendaStatusFallbackColor(element.statusBucket);
      const statusCue = agendaStatusCue(element.statusBucket);
      const statusStage = getAgendaStatusStageLabel(element.statusBucket);
      const statusKeyword = element.todo ? element.todo : '(no todo keyword)';
      const urgencyLabel = element.urgency || 'unknown';
      item.tooltip = new vscode.MarkdownString(
        [
          `**${element.headline || '(untitled)'}**`,
          '',
          `- File: ${element.file || '(unknown file)'}:${element.line + 1}`,
          `- Schedule urgency: ${urgencyLabel}`,
          ...(element.time ? [`- Scheduled time: ${element.time}`] : []),
          `- TODO status: ${statusCue} <span style="color:var(--vscode-${statusColor.replace('.', '-')}, ${statusFallback});">${statusKeyword}</span> · ${statusStage}`,
        ].join('\n')
      );
      item.tooltip.supportHtml = true;
      return item;
    }

    // Error sentinel
    const errItem = new vscode.TreeItem('Org2 agenda: failed to load', vscode.TreeItemCollapsibleState.None);
    errItem.description = this.lastError ? String(this.lastError.message || this.lastError) : '';
    return errItem;
  }

  async getChildren(element) {
    if (!element) {
      if (this.lastError) return [this.lastError];
      return this.groups;
    }

    if (element instanceof Org2AgendaGroup) {
      return element.items;
    }

    if (element instanceof Org2AgendaSeparator) {
      return [];
    }

    return [];
  }
}

function execFileAsync(cmd, args, opts) {
  return new Promise((resolve, reject) => {
    cp.execFile(cmd, args, { ...opts, maxBuffer: 1024 * 1024 * 20 }, (err, stdout, stderr) => {
      if (err) {
        err.stdout = stdout;
        err.stderr = stderr;
        reject(err);
        return;
      }
      resolve({ stdout, stderr });
    });
  });
}

function getWorkspaceRoot() {
  const wf = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
  return wf ? wf.uri.fsPath : undefined;
}

function resolveAgendaFiles(scopeFiles, cwd) {
  const out = [];
  for (const f of scopeFiles || []) {
    if (!f) continue;
    const s = String(f);
    const abs = path.isAbsolute(s) ? s : path.resolve(cwd, s);
    out.push(abs);
  }
  return out;
}

function resolveOrg2Command(context, args) {
  const cfg = vscode.workspace.getConfiguration('org2');
  const cmd = cfg.get('agenda.command', 'org2');
  const extraArgs = cfg.get('agenda.args', []);

  let finalCmd = cmd;
  let finalArgs = [...extraArgs, ...args];

  // Helpful default for local development: if this extension is checked out inside
  // the org2 repo, run the repo-local CLI instead of relying on a global PATH install.
  if (cmd === 'org2' && !(cfg.get('agenda.args', []).length)) {
    const fs = require('fs');

    const maybeRepoRoot = path.resolve(context.extensionPath, '..', '..');
    const repoCli = path.join(maybeRepoRoot, 'dist', 'cli.js');

    try {
      fs.accessSync(repoCli);
      finalCmd = process.execPath;
      finalArgs = [repoCli, ...args];
    } catch (_) {
      // If not in-repo, fall back to PATH `org2`.
    }
  }

  return { cmd: finalCmd, args: finalArgs };
}

function getAgendaRootDir() {
  const cfg = vscode.workspace.getConfiguration('org2');
  const configured = String(cfg.get('agenda.dir', '') || '').trim();
  if (configured) return configured;
  return getWorkspaceRoot() || process.cwd();
}

function getRoamIndexRootDir() {
  const cfg = vscode.workspace.getConfiguration('org2');
  const configured = String(cfg.get('roam.indexDir', '') || '').trim();
  if (!configured) return getAgendaRootDir();
  if (path.isAbsolute(configured)) return configured;
  return path.resolve(getAgendaRootDir(), configured);
}

function getRoamDailiesRootDir() {
  const cfg = vscode.workspace.getConfiguration('org2');
  const configured = String(cfg.get('roam.dailiesDir', '') || '').trim();
  if (configured) return configured;
  return getRoamIndexRootDir();
}

function getRoamNodesRootDir() {
  const cfg = vscode.workspace.getConfiguration('org2');
  const configured = String(cfg.get('roam.nodesDir', '') || '').trim();
  if (!configured) return getRoamIndexRootDir();
  if (path.isAbsolute(configured)) return configured;
  return path.resolve(getRoamIndexRootDir(), configured);
}

function formatDateYYYYMMDD(d) {
  const yyyy = d.getFullYear();
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}`;
}

function randomUuid() {
  try {
    const crypto = require('crypto');
    return crypto.randomUUID();
  } catch (_) {
    // Fallback: not expected on modern Node, but keep safe.
    return `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  }
}

function computeFileLevelPropertiesDrawerEdit(text) {
  // Ensures a top-of-file :PROPERTIES: drawer with an :ID: entry.
  // Only the file-level drawer (before first heading) counts.

  const lines = String(text || '').split(/\r?\n/);

  const headingLineIdx = lines.findIndex((l) => headingRe.test(l));
  const scanEnd = headingLineIdx === -1 ? lines.length : headingLineIdx;

  let propsStart = -1;
  let propsEnd = -1;

  for (let i = 0; i < scanEnd; i++) {
    if (propertiesBeginRe.test(lines[i])) {
      propsStart = i;
      for (let j = i + 1; j < scanEnd; j++) {
        if (drawerEndRe.test(lines[j])) {
          propsEnd = j;
          break;
        }
      }
      break;
    }
  }

  const idLineRe = /^\s*:ID:\s+.+$/i;

  if (propsStart !== -1 && propsEnd !== -1) {
    // Drawer exists; ensure :ID: line in it.
    for (let i = propsStart + 1; i < propsEnd; i++) {
      if (idLineRe.test(lines[i])) {
        return { changed: false, text };
      }
    }

    const uuid = randomUuid();
    lines.splice(propsStart + 1, 0, `:ID: ${uuid}`);
    return { changed: true, text: lines.join('\n') };
  }

  // No drawer: insert at top (after leading blank lines / comments).
  let insertAt = 0;
  while (insertAt < lines.length && lines[insertAt].trim() === '') insertAt++;

  const uuid = randomUuid();
  const drawer = [':PROPERTIES:', `:ID: ${uuid}`, ':END:', ''];
  lines.splice(insertAt, 0, ...drawer);

  return { changed: true, text: lines.join('\n') };
}

function findFileLevelIdInText(text) {
  const lines = String(text || '').split(/\r?\n/);

  const headingLineIdx = lines.findIndex((l) => headingRe.test(l));
  const scanEnd = headingLineIdx === -1 ? lines.length : headingLineIdx;

  let propsStart = -1;
  let propsEnd = -1;

  for (let i = 0; i < scanEnd; i++) {
    if (propertiesBeginRe.test(lines[i])) {
      propsStart = i;
      for (let j = i + 1; j < scanEnd; j++) {
        if (drawerEndRe.test(lines[j])) {
          propsEnd = j;
          break;
        }
      }
      break;
    }
  }

  if (propsStart === -1 || propsEnd === -1) return undefined;

  for (let i = propsStart + 1; i < propsEnd; i++) {
    const m = /^\s*:ID:\s*(.+?)\s*$/i.exec(lines[i]);
    if (!m) continue;
    const id = (m[1] || '').trim();
    if (id) return id.toLowerCase();
  }

  return undefined;
}

function findHeadlineLevelIdAtLineInText(text, line0) {
  const lines = String(text || '').split(/\r?\n/);
  if (lines.length === 0) return '';

  const clampedLine = Math.max(0, Math.min(Number(line0) || 0, lines.length - 1));

  let headlineLine = -1;
  let headlineLevel = 0;
  for (let i = clampedLine; i >= 0; i -= 1) {
    const m = headingRe.exec(String(lines[i] || ''));
    if (!m) continue;
    headlineLine = i;
    headlineLevel = m[1].length;
    break;
  }
  if (headlineLine < 0) return '';

  let subtreeEnd = lines.length;
  for (let i = headlineLine + 1; i < lines.length; i += 1) {
    const m = headingRe.exec(String(lines[i] || ''));
    if (!m) continue;
    if (m[1].length <= headlineLevel) {
      subtreeEnd = i;
      break;
    }
  }

  let drawerStart = -1;
  for (let i = headlineLine + 1; i < subtreeEnd; i += 1) {
    const raw = String(lines[i] || '');
    const trimmed = raw.trim();
    if (!trimmed) continue;

    if (propertiesBeginRe.test(raw)) {
      drawerStart = i;
    }
    break;
  }
  if (drawerStart < 0) return '';

  for (let i = drawerStart + 1; i < subtreeEnd; i += 1) {
    const raw = String(lines[i] || '');
    if (drawerEndRe.test(raw)) break;
    const m = /^\s*:ID:\s*(\S+)\s*$/i.exec(raw);
    if (!m) continue;
    return extractRoamUuid(String(m[1] || ''));
  }

  return '';
}

async function ensureFileHasTopLevelId(doc) {
  if (!doc || doc.uri.scheme !== 'file') return;

  const before = doc.getText();
  const { changed, text: after } = computeFileLevelPropertiesDrawerEdit(before);
  if (!changed) return;

  const fullRange = new vscode.Range(
    0,
    0,
    doc.lineCount ? doc.lineCount - 1 : 0,
    doc.lineCount ? doc.lineAt(doc.lineCount - 1).text.length : 0
  );

  const edit = new vscode.WorkspaceEdit();
  edit.replace(doc.uri, fullRange, after);
  await vscode.workspace.applyEdit(edit);
  await doc.save();
}

async function openRoamDailyForDateString(dateStr) {
  const root = getRoamDailiesRootDir();
  const fileName = `${dateStr}.org2`;
  const absPath = path.join(root, fileName);
  const uri = vscode.Uri.file(absPath);

  // Ensure directory exists.
  try {
    await vscode.workspace.fs.createDirectory(vscode.Uri.file(root));
  } catch (_) {
    // ignore
  }

  // Create file if missing.
  try {
    await vscode.workspace.fs.stat(uri);
  } catch (_) {
    await vscode.workspace.fs.writeFile(uri, Buffer.from(`* ${dateStr}\n`, 'utf8'));
  }

  const doc = await vscode.workspace.openTextDocument(uri);
  await ensureFileHasTopLevelId(doc);
  await vscode.window.showTextDocument(doc, { preview: false });
}

async function* walkFiles(dir) {
  let entries;
  try {
    entries = await fs.promises.readdir(dir, { withFileTypes: true });
  } catch (_) {
    return;
  }

  for (const ent of entries) {
    if (!ent) continue;
    if (ent.name === '.git' || ent.name === 'node_modules' || ent.name === '.next') continue;

    const abs = path.join(dir, ent.name);
    if (ent.isDirectory()) {
      yield* walkFiles(abs);
    } else if (ent.isFile()) {
      if (abs.endsWith('.org') || abs.endsWith('.org2')) yield abs;
    }
  }
}

function parseOrgTitleFromText(content, filePath) {
  const lines = String(content || '').split(/\r?\n/);
  for (let i = 0; i < Math.min(lines.length, 80); i += 1) {
    const m = /^#\+title:\s*(.*?)\s*$/i.exec(String(lines[i] || '').trim());
    if (m) {
      const title = String(m[1] || '').trim();
      if (title) return title;
    }
  }
  return path.basename(String(filePath || '')).replace(/\.(org2|org)$/i, '');
}

function collectRoamNodesFromText(content, filePath) {
  const lines = String(content || '').split(/\r?\n/);
  const nodes = [];
  const seenIds = new Set();
  const fileTitle = parseOrgTitleFromText(content, filePath);

  const addNode = (idRaw, titleRaw, kind, line0) => {
    const id = extractRoamUuid(String(idRaw || '').trim());
    const title = String(titleRaw || '').trim();
    if (!id || !title) return;
    if (seenIds.has(id)) return;
    seenIds.add(id);
    nodes.push({
      id,
      title,
      file: filePath,
      line0: typeof line0 === 'number' ? line0 : 0,
      kind: kind === 'headline' ? 'headline' : 'file',
    });
  };

  let fileId = extractRoamUuid(findFileLevelIdInText(content) || '');
  if (!fileId) {
    for (let i = 0; i < Math.min(lines.length, 40); i += 1) {
      const m = /^#\+id:\s*(\S+)\s*$/i.exec(String(lines[i] || '').trim());
      if (!m) continue;
      fileId = extractRoamUuid(String(m[1] || '').trim());
      if (fileId) break;
    }
  }
  if (fileId) addNode(fileId, fileTitle, 'file', 0);

  let currentHeadlineTitle = '';
  let currentHeadlineLine = -1;

  for (let i = 0; i < lines.length; i += 1) {
    const line = String(lines[i] || '');
    const hm = /^(\*+)\s+(.*)$/.exec(line);
    if (hm) {
      currentHeadlineLine = i;
      currentHeadlineTitle = String(hm[2] || '')
        .replace(/\s+:[^\s:]+(?::[^\s:]+)*:\s*$/, '')
        .replace(/^(TODO|IN_PROGRESS|DONE|CANCELLED|CANCELED)\s+/i, '')
        .trim();
      continue;
    }

    if (String(line).trim() !== ':PROPERTIES:') continue;

    let belongsToHeadline = false;
    if (currentHeadlineLine >= 0) {
      const prev = String(lines[i - 1] || '').trim();
      if (i - 1 === currentHeadlineLine || (prev === '' && i - 2 === currentHeadlineLine)) {
        belongsToHeadline = true;
      }
    }

    let headlineId = '';
    for (let j = i + 1; j < lines.length; j += 1) {
      const inner = String(lines[j] || '').trim();
      if (inner === ':END:') {
        i = j;
        break;
      }
      const idMatch = /^:ID:\s*(\S+)\s*$/i.exec(inner);
      if (idMatch) {
        headlineId = extractRoamUuid(String(idMatch[1] || '').trim());
      }
    }

    if (belongsToHeadline && headlineId && currentHeadlineTitle) {
      addNode(headlineId, currentHeadlineTitle, 'headline', currentHeadlineLine);
    }
  }

  return nodes;
}

async function collectRoamNodeCandidates(rootDir) {
  const out = [];
  const seenId = new Set();

  for await (const filePath of walkFiles(rootDir)) {
    let text = '';
    try {
      text = await fs.promises.readFile(filePath, 'utf8');
    } catch (_) {
      continue;
    }

    const nodes = collectRoamNodesFromText(text, filePath);
    for (const node of nodes) {
      if (!node || !node.id) continue;
      if (seenId.has(node.id)) continue;
      seenId.add(node.id);
      out.push(node);
    }
  }

  out.sort((a, b) => {
    const t = String(a.title || '').localeCompare(String(b.title || ''));
    if (t !== 0) return t;
    return String(a.file || '').localeCompare(String(b.file || ''));
  });
  return out;
}

async function findFirstIdMatchInDir(rootDir, id) {
  const idRe = new RegExp(`^\\s*:ID:\\s*${id}\\s*$`, 'i');

  for await (const filePath of walkFiles(rootDir)) {
    let text;
    try {
      text = await fs.promises.readFile(filePath, 'utf8');
    } catch (_) {
      continue;
    }

    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      if (idRe.test(lines[i])) return { filePath, line: i };
    }
  }

  return undefined;
}

function getAgendaSourcePriorityToken(item, agendaRoot, fileCache) {
  const fromPayload = normalizeAgendaPriority(item && item.priority);
  if (fromPayload) return fromPayload;

  const fromHeadline = extractAgendaPriorityFromHeadline(item && item.headline);
  if (fromHeadline) return fromHeadline;

  const relFile = String(item && item.file ? item.file : '').trim();
  const line0 = Number(item && item.line);
  if (!relFile || !Number.isInteger(line0) || line0 < 0) return '';

  const absPath = path.isAbsolute(relFile) ? relFile : path.resolve(agendaRoot, relFile);
  let lines = fileCache.get(absPath);
  if (!lines) {
    try {
      lines = fs.readFileSync(absPath, 'utf8').split(/\r?\n/);
    } catch (_) {
      lines = [];
    }
    fileCache.set(absPath, lines);
  }

  const sourceLine = String(lines[line0] || '');
  return extractAgendaPriorityFromHeadline(sourceLine);
}

async function fetchAgendaGroups(context, filter) {
  const cfg = vscode.workspace.getConfiguration('org2');
  const agendaRoot = getAgendaRootDir();

  const agendaOptions = readAgendaCliOptions(cfg, agendaRoot, filter, resolveAgendaFiles);
  const { sortBy } = agendaOptions;

  const { args, warnEmptyFiles } = buildAgendaCliArgs(agendaOptions);

  if (warnEmptyFiles) {
    vscode.window.showWarningMessage("Org2 agenda: org2.agenda.files is empty (set scope to 'workspace' or configure files).");
  }

  const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, args);
  const { stdout } = await execFileAsync(finalCmd, finalArgs, { cwd: agendaRoot });

  let data;
  try {
    data = JSON.parse(stdout);
  } catch (e) {
    const err = new Error('Org2 agenda: failed to parse JSON output.');
    err.cause = e;
    throw err;
  }

  const descriptors = buildAgendaTreeGroupsFromCli(data, sortBy);
  const priorityFileCache = new Map();

  return descriptors.map((entry) => {
    if (entry.type === 'separator') {
      return new Org2AgendaSeparator(entry.label);
    }

    const items = (entry.items || []).map((it) => {
      const resolvedPriority = getAgendaSourcePriorityToken(it, agendaRoot, priorityFileCache);
      return new Org2AgendaItem({
        ...it,
        priority: resolvedPriority,
        date: entry.isOverdue ? (it && it.date) || '' : entry.date,
        urgency: entry.isOverdue ? 'overdue' : agendaUrgencyFromDate(entry.date),
      });
    });
    return new Org2AgendaGroup(entry.label, entry.date, entry.weekday, entry.isOverdue, items);
  });
}

function revealNavigationPosition(editor, pos, source) {
  if (!editor || !pos) return;
  const cfg = vscode.workspace.getConfiguration('org2');
  const isAgendaSource = String(source || '').toLowerCase() === 'agenda';
  const modeSetting = isAgendaSource ? 'editor.navigationRevealFromAgenda' : 'editor.navigationReveal';
  const modeDefault = isAgendaSource ? 'none' : 'outside';
  let mode = String(cfg.get(modeSetting, modeDefault) || modeDefault).toLowerCase();

  // Agenda-specific reveal supports inheriting the non-agenda navigation setting
  // to avoid duplicating preferences.
  if (isAgendaSource && mode === 'default') {
    mode = String(cfg.get('editor.navigationReveal', 'outside') || 'outside').toLowerCase();
  }

  if (mode === 'none') return;

  let revealType = vscode.TextEditorRevealType.Default;
  if (mode === 'center') revealType = vscode.TextEditorRevealType.InCenter;
  if (mode === 'outside') revealType = vscode.TextEditorRevealType.InCenterIfOutsideViewport;
  editor.revealRange(new vscode.Range(pos, pos), revealType);
}

async function focusBacklinksView() {
  await vscode.commands.executeCommand('workbench.view.explorer');
  try {
    await vscode.commands.executeCommand('org2Backlinks.focus');
  } catch (_) {
    // ignore: some VS Code builds may not expose focus command for custom views
  }
}

async function openAgendaItem(item) {
  if (!item || !item.file) return;

  const cwd = getWorkspaceRoot() || process.cwd();
  const abs = path.isAbsolute(item.file) ? item.file : path.resolve(cwd, item.file);

  const uri = vscode.Uri.file(abs);
  const doc = await vscode.workspace.openTextDocument(uri);
  const editor = await vscode.window.showTextDocument(doc, { preview: true });

  const line = Math.max(0, item.line || 0);
  const pos = new vscode.Position(line, 0);
  editor.selection = new vscode.Selection(pos, pos);
  revealNavigationPosition(editor, pos, 'agenda');
}

async function pickAgendaFilter(provider) {
  const cfg = vscode.workspace.getConfiguration('org2');
  const defaultDays = cfg.get('agenda.days', 7);

  const pick = await vscode.window.showQuickPick(
    [
      { label: 'Today', value: { type: 'today', days: 1 } },
      { label: `Next ${defaultDays} days`, value: { type: 'next', days: defaultDays } },
    ],
    { placeHolder: 'Org2 agenda filter' }
  );

  if (!pick) return;
  provider.filter = pick.value;
  await provider.load();
}

async function pickAgendaStatusFilter(provider) {
  const cfg = vscode.workspace.getConfiguration('org2');
  const currentRaw = cfg.get('agenda.statusFilter', 'all');
  const current = normalizeAgendaStatusFilterValue(currentRaw, 'all');
  const options = buildAgendaStatusFilterQuickPickOptions(current);

  const pick = await vscode.window.showQuickPick(options, { placeHolder: 'Org2 agenda TODO status filter' });
  if (!pick) return;

  const target = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders.length > 0
    ? vscode.ConfigurationTarget.Workspace
    : vscode.ConfigurationTarget.Global;
  await cfg.update('agenda.statusFilter', normalizeAgendaStatusFilterValue(pick.value, 'all'), target);
  if (provider) {
    await provider.load();
  }
}

function activate(context) {
  const selector = [{ language: 'org2' }, { language: 'org' }];

  const foldingProvider = {
    provideFoldingRanges(document) {
      return provideFoldingRanges(document);
    },
  };

  context.subscriptions.push(vscode.languages.registerFoldingRangeProvider(selector, foldingProvider));

  const linkProvider = {
    provideDocumentLinks(document) {
      return provideDocumentLinks(document);
    },
  };

  context.subscriptions.push(vscode.languages.registerDocumentLinkProvider(selector, linkProvider));

  async function runFmtWithStdin(args, text, cwd) {
    const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, args);

    return new Promise((resolve, reject) => {
      const child = cp.spawn(finalCmd, finalArgs, { cwd });
      let stdout = '';
      let stderr = '';

      child.stdout.on('data', (d) => {
        stdout += d.toString('utf8');
      });
      child.stderr.on('data', (d) => {
        stderr += d.toString('utf8');
      });
      child.on('error', (err) => {
        reject(err);
      });
      child.on('close', (code) => {
        if (code !== 0) {
          const e = new Error(`org2 fmt failed (code=${code})`);
          e.stderr = stderr;
          e.stdout = stdout;
          e.code = code;
          reject(e);
          return;
        }
        resolve({ stdout, stderr });
      });

      child.stdin.end(text, 'utf8');
    });
  }

  async function formatOrg2Text(text) {
    const cwd = getWorkspaceRoot() || process.cwd();

    try {
      const jsonResult = await runFmtWithStdin(['fmt', '--stdin', '--format', 'json'], text, cwd);
      const parsedJson = parseFormatterStdinJson(jsonResult.stdout);
      if (parsedJson) {
        return parsedJson.formattedText;
      }
    } catch (err) {
      const stdout = String((err && err.stdout) || '');
      const stderr = String((err && err.stderr) || '');
      if (!isFormatterStdinJsonUnsupported(stderr, stdout)) {
        throw err;
      }
    }

    const fallback = await runFmtWithStdin(['fmt', '--stdin'], text, cwd);
    return fallback.stdout;
  }

  const formatterOutput = vscode.window.createOutputChannel('Org2 Formatter');
  context.subscriptions.push(formatterOutput);

  function parseFormatterChangedFiles(stdout) {
    return String(stdout || '')
      .split(/\r?\n/)
      .map((line) => String(line || '').trim())
      .filter(Boolean);
  }

  function parseFormatterCheckJson(stdout) {
    const text = String(stdout || '').trim();
    if (!text) return undefined;

    try {
      const parsed = JSON.parse(text);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return undefined;

      const changed = typeof parsed.changed === 'boolean' ? parsed.changed : undefined;
      const changedFilesRaw = Array.isArray(parsed.changedFiles) ? parsed.changedFiles : undefined;
      if (typeof changed !== 'boolean' || !changedFilesRaw) return undefined;

      const changedFiles = changedFilesRaw
        .map((v) => (typeof v === 'string' ? v.trim() : String(v || '').trim()))
        .filter(Boolean);

      return { changed, changedFiles };
    } catch {
      return undefined;
    }
  }

  function parseFormatterPreviewJson(stdout) {
    const text = String(stdout || '').trim();
    if (!text) return undefined;

    try {
      const parsed = JSON.parse(text);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return undefined;

      const changed = typeof parsed.changed === 'boolean' ? parsed.changed : undefined;
      const file = typeof parsed.file === 'string' ? parsed.file.trim() : '';
      const formattedText = typeof parsed.formattedText === 'string' ? parsed.formattedText : undefined;
      if (typeof changed !== 'boolean' || !file) return undefined;

      return { file, changed, formattedText };
    } catch {
      return undefined;
    }
  }

  function parseFormatterStdinJson(stdout) {
    const text = String(stdout || '').trim();
    if (!text) return undefined;

    try {
      const parsed = JSON.parse(text);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return undefined;

      const changed = typeof parsed.changed === 'boolean' ? parsed.changed : undefined;
      const formattedText = typeof parsed.formattedText === 'string' ? parsed.formattedText : undefined;
      if (typeof changed !== 'boolean' || typeof formattedText !== 'string') return undefined;

      return { changed, formattedText };
    } catch {
      return undefined;
    }
  }

  async function getFormattingDrift(args, cwd) {
    const argsWithFormat = [...args, '--format', 'json'];
    const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, argsWithFormat);

    try {
      const { stdout, stderr } = await execFileAsync(finalCmd, finalArgs, { cwd });
      const parsedJson = parseFormatterCheckJson(stdout);
      if (parsedJson) {
        return { changedFiles: parsedJson.changedFiles, stderr: String(stderr || '').trim() };
      }
      return { changedFiles: parseFormatterChangedFiles(stdout), stderr: String(stderr || '').trim() };
    } catch (err) {
      const exitCodeRaw = err && err.code !== undefined ? Number(err.code) : NaN;
      const exitCode = Number.isFinite(exitCodeRaw) ? exitCodeRaw : null;
      const stdout = String((err && err.stdout) || '');
      const stderr = String((err && err.stderr) || '');

      if (exitCode === 1) {
        const parsedJson = parseFormatterCheckJson(stdout);
        if (parsedJson) {
          return { changedFiles: parsedJson.changedFiles, stderr: stderr.trim() };
        }
        return { changedFiles: parseFormatterChangedFiles(stdout), stderr: stderr.trim() };
      }

      const msg = stderr.trim() || (err instanceof Error ? err.message : String(err));
      throw new Error(`Org2 formatter check failed: ${msg}`);
    }
  }

  function isFormatterStdinJsonUnsupported(stderr, stdout) {
    const text = `${String(stderr || '')}\n${String(stdout || '')}`.toLowerCase();
    if (!text.includes('--format')) return false;
    if (text.includes('does not support --format json')) return true;
    if (text.includes('unknown option') && text.includes('--format')) return true;
    if (text.includes('invalid value for --format')) return true;
    return false;
  }

  function isFormatterApplyJsonUnsupported(stderr, stdout) {
    const text = `${String(stderr || '')}\n${String(stdout || '')}`.toLowerCase();
    if (!text.includes('--format')) return false;
    if (text.includes('does not support --apply')) return true;
    if (text.includes('does not support --format json')) return true;
    if (text.includes('unknown option') && text.includes('--format')) return true;
    if (text.includes('invalid value for --format')) return true;
    return false;
  }

  async function applyFormatting(args, cwd) {
    const argsWithFormat = [...args, '--format', 'json'];
    const { cmd: jsonCmd, args: jsonArgs } = resolveOrg2Command(context, argsWithFormat);

    try {
      const { stdout, stderr } = await execFileAsync(jsonCmd, jsonArgs, { cwd });
      const parsedJson = parseFormatterCheckJson(stdout);
      if (parsedJson) {
        return { changedFiles: parsedJson.changedFiles, stderr: String(stderr || '').trim() };
      }
      return { changedFiles: parseFormatterChangedFiles(stdout), stderr: String(stderr || '').trim() };
    } catch (err) {
      const stdout = String((err && err.stdout) || '');
      const stderr = String((err && err.stderr) || '');
      if (!isFormatterApplyJsonUnsupported(stderr, stdout)) {
        const msg = stderr.trim() || (err instanceof Error ? err.message : String(err));
        throw new Error(`Org2 formatter apply failed: ${msg}`);
      }
    }

    const { cmd: fallbackCmd, args: fallbackArgs } = resolveOrg2Command(context, args);
    const { stdout, stderr } = await execFileAsync(fallbackCmd, fallbackArgs, { cwd });
    return { changedFiles: parseFormatterChangedFiles(stdout), stderr: String(stderr || '').trim() };
  }

  function getWorkspaceFormatterPathFilters(root) {
    const cfg = vscode.workspace.getConfiguration('org2');
    return resolveWorkspaceFormatterPathFilters({
      root,
      fileFilter: cfg.get('formatter.fileFilter', ''),
      excludeFileFilter: cfg.get('formatter.excludeFileFilter', ''),
      configFile: cfg.get('formatter.configFile', ''),
    });
  }

  async function getWorkspaceFormattingDrift(root, pathFilters = {}) {
    const args = buildWorkspaceFormatterCommandArgs({
      root,
      pathFilters,
      mode: 'check',
    });
    return getFormattingDrift(args, root);
  }

  function getActiveFormatterTarget() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || !editor.document) {
      vscode.window.showWarningMessage('Org2: open an org/org2 file first.');
      return undefined;
    }

    const doc = editor.document;
    if (doc.languageId !== 'org2' && doc.languageId !== 'org') {
      vscode.window.showWarningMessage('Org2: formatter commands require an org/org2 editor.');
      return undefined;
    }

    if (!doc.uri || doc.uri.scheme !== 'file') {
      vscode.window.showWarningMessage('Org2: formatter commands require a file-backed document.');
      return undefined;
    }

    return { editor, doc, filePath: path.resolve(doc.uri.fsPath) };
  }

  async function ensureFormatterTargetSaved(doc) {
    if (!doc || !doc.isDirty) return true;

    const confirm = await vscode.window.showWarningMessage(
      'Org2: save this file before running formatter check/apply/preview?',
      { modal: true },
      'Save and Continue'
    );

    if (confirm !== 'Save and Continue') return false;

    const ok = await doc.save();
    if (!ok) {
      vscode.window.showWarningMessage('Org2: could not save file before running formatter command.');
      return false;
    }

    return true;
  }

  async function getCurrentFileFormattingDrift(filePath) {
    const cwd = getWorkspaceRoot() || path.dirname(filePath) || process.cwd();
    const previewArgs = buildCurrentFileFormatterPreviewArgs(filePath);
    const { cmd: previewCmd, args: previewFinalArgs } = resolveOrg2Command(context, previewArgs);

    try {
      const { stdout, stderr } = await execFileAsync(previewCmd, previewFinalArgs, { cwd });
      const parsed = parseFormatterPreviewJson(stdout);
      if (parsed) {
        return {
          changedFiles: parsed.changed ? [parsed.file] : [],
          stderr: String(stderr || '').trim(),
        };
      }
    } catch {
      // Fallback to --check for older CLI versions that don't support fmt preview JSON.
    }

    return getFormattingDrift(buildCurrentFileFormatterCheckArgs(filePath), cwd);
  }

  async function getCurrentFileFormattingPreview(filePath) {
    const cwd = getWorkspaceRoot() || path.dirname(filePath) || process.cwd();
    const previewArgs = buildCurrentFileFormatterPreviewArgs(filePath);
    const { cmd: previewCmd, args: previewFinalArgs } = resolveOrg2Command(context, previewArgs);

    try {
      const { stdout, stderr } = await execFileAsync(previewCmd, previewFinalArgs, { cwd });
      const parsed = parseFormatterPreviewJson(stdout);
      if (parsed && typeof parsed.formattedText === 'string') {
        return {
          changed: parsed.changed,
          formattedText: parsed.formattedText,
          stderr: String(stderr || '').trim(),
        };
      }
    } catch {
      // Fallback for older CLI versions that don't support fmt preview JSON.
    }

    const { cmd: fallbackCmd, args: fallbackArgs } = resolveOrg2Command(context, buildCurrentFileFormatterStdoutArgs(filePath));
    const { stdout, stderr } = await execFileAsync(fallbackCmd, fallbackArgs, { cwd });
    const currentText = fs.readFileSync(filePath, 'utf8').replace(/\r\n/g, '\n');
    return {
      changed: stdout !== currentText,
      formattedText: stdout,
      stderr: String(stderr || '').trim(),
    };
  }

  function renderFormatterDriftReport(changedFiles, stderr, headerText) {
    formatterOutput.clear();
    formatterOutput.appendLine(headerText);
    for (const file of changedFiles) {
      formatterOutput.appendLine(file);
    }
    if (stderr && String(stderr).trim()) {
      formatterOutput.appendLine('');
      formatterOutput.appendLine(String(stderr).trim());
    }
    formatterOutput.show(true);
  }

  async function checkWorkspaceFormattingDrift() {
    const root = getAgendaRootDir();
    const pathFilters = getWorkspaceFormatterPathFilters(root);

    try {
      const { changedFiles, stderr } = await getWorkspaceFormattingDrift(root, pathFilters);
      if (changedFiles.length === 0) {
        vscode.window.showInformationMessage('Org2: workspace formatter check passed.');
        return;
      }

      renderFormatterDriftReport(
        changedFiles,
        stderr,
        `Org2 formatter drift check: ${changedFiles.length} file(s) need formatting.`
      );
      vscode.window.showWarningMessage(
        `Org2: formatting drift in ${changedFiles.length} file(s). See "Org2 Formatter" output.`
      );
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      vscode.window.showErrorMessage(msg);
    }
  }

  async function checkCurrentFileFormattingDrift() {
    const target = getActiveFormatterTarget();
    if (!target) return;

    if (!(await ensureFormatterTargetSaved(target.doc))) return;

    const displayPath = path.basename(target.filePath);

    try {
      const { changedFiles, stderr } = await getCurrentFileFormattingDrift(target.filePath);
      if (changedFiles.length === 0) {
        vscode.window.showInformationMessage(`Org2: ${displayPath} has no formatter drift.`);
        return;
      }

      const changedCount = Math.max(1, changedFiles.length);
      renderFormatterDriftReport(
        changedFiles,
        stderr,
        `Org2 formatter drift check: ${displayPath} needs formatting.`
      );
      vscode.window.showWarningMessage(
        `Org2: formatting drift in ${changedCount} file(s). See "Org2 Formatter" output.`
      );
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      vscode.window.showErrorMessage(msg);
    }
  }

  async function previewCurrentFileFormattingDiff() {
    const target = getActiveFormatterTarget();
    if (!target) return;

    if (!(await ensureFormatterTargetSaved(target.doc))) return;

    const displayPath = path.basename(target.filePath);

    try {
      const preview = await getCurrentFileFormattingPreview(target.filePath);
      if (!preview.changed) {
        vscode.window.showInformationMessage(`Org2: ${displayPath} has no formatter drift.`);
        return;
      }

      const formattedDoc = await vscode.workspace.openTextDocument({
        language: target.doc.languageId === 'org' ? 'org' : 'org2',
        content: preview.formattedText,
      });

      await vscode.commands.executeCommand(
        'vscode.diff',
        target.doc.uri,
        formattedDoc.uri,
        `Org2 Formatter Preview: ${displayPath} (formatted)`
      );

      if (preview.stderr) {
        formatterOutput.clear();
        formatterOutput.appendLine(`Org2 formatter preview: ${displayPath}`);
        formatterOutput.appendLine('');
        formatterOutput.appendLine(preview.stderr);
        formatterOutput.show(true);
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      vscode.window.showErrorMessage(msg);
    }
  }

  async function applyWorkspaceFormatting() {
    const root = getAgendaRootDir();
    const pathFilters = getWorkspaceFormatterPathFilters(root);

    let changedFiles = [];
    try {
      const drift = await getWorkspaceFormattingDrift(root, pathFilters);
      changedFiles = drift.changedFiles;

      if (changedFiles.length === 0) {
        vscode.window.showInformationMessage('Org2: workspace already formatted.');
        return;
      }

      renderFormatterDriftReport(
        changedFiles,
        drift.stderr,
        `Org2 formatter apply preview: ${changedFiles.length} file(s) will be formatted.`
      );
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      vscode.window.showErrorMessage(msg);
      return;
    }

    const confirm = await vscode.window.showWarningMessage(
      `Org2: format ${changedFiles.length} workspace file(s) now?`,
      { modal: true },
      'Format Workspace'
    );

    if (confirm !== 'Format Workspace') return;

    const applyArgs = buildWorkspaceFormatterCommandArgs({
      root,
      pathFilters,
      mode: 'apply',
    });
    try {
      const applyResult = await applyFormatting(applyArgs, root);
      const appliedFiles = applyResult.changedFiles.length > 0 ? applyResult.changedFiles : changedFiles;
      formatterOutput.appendLine('');
      formatterOutput.appendLine(`Applied formatter to ${appliedFiles.length} file(s).`);
      if (applyResult.stderr) {
        formatterOutput.appendLine('');
        formatterOutput.appendLine(applyResult.stderr);
      }
      formatterOutput.show(true);
      vscode.window.showInformationMessage(
        `Org2: formatted ${appliedFiles.length} workspace file(s). See "Org2 Formatter" output.`
      );
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      vscode.window.showErrorMessage(msg);
    }
  }

  async function applyCurrentFileFormatting() {
    const target = getActiveFormatterTarget();
    if (!target) return;

    if (!(await ensureFormatterTargetSaved(target.doc))) return;

    const displayPath = path.basename(target.filePath);

    let changedFiles = [];
    try {
      const drift = await getCurrentFileFormattingDrift(target.filePath);
      changedFiles = drift.changedFiles;

      if (changedFiles.length === 0) {
        vscode.window.showInformationMessage(`Org2: ${displayPath} is already formatted.`);
        return;
      }

      renderFormatterDriftReport(
        changedFiles,
        drift.stderr,
        `Org2 formatter apply preview: ${displayPath} will be formatted.`
      );
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      vscode.window.showErrorMessage(msg);
      return;
    }

    const confirm = await vscode.window.showWarningMessage(
      `Org2: format ${displayPath} now?`,
      { modal: true },
      'Format File'
    );

    if (confirm !== 'Format File') return;

    const cfg = vscode.workspace.getConfiguration('org2');
    const restoreSelectionAfterCliApply = cfg.get('editor.restoreSelectionAfterCliApply', true) ? true : false;
    const refreshAfterCliApply = cfg.get('editor.refreshAfterCliApply', true) ? true : false;
    const skipRefreshWhenInSync = cfg.get('editor.skipRefreshWhenInSync', true) ? true : false;
    const allowGlobalRefreshFallback = cfg.get('editor.allowGlobalRefreshFallback', false) ? true : false;

    const activeEditorBefore = vscode.window.activeTextEditor;
    const activeUriBefore = activeEditorBefore && activeEditorBefore.document ? activeEditorBefore.document.uri.toString() : '';
    const selectionBefore =
      activeEditorBefore && activeEditorBefore.selection
        ? new vscode.Selection(activeEditorBefore.selection.start, activeEditorBefore.selection.end)
        : undefined;

    const cwd = getWorkspaceRoot() || path.dirname(target.filePath) || process.cwd();
    const applyArgs = buildCurrentFileFormatterApplyArgs(target.filePath);

    try {
      const applyResult = await applyFormatting(applyArgs, cwd);

      if (refreshAfterCliApply) {
        await refreshFileFromDisk(target.filePath, {
          selection: restoreSelectionAfterCliApply ? selectionBefore : undefined,
          activeUri: activeUriBefore,
          skipIfInSync: skipRefreshWhenInSync,
          allowGlobalFallback: allowGlobalRefreshFallback,
        });
      }

      const appliedFiles = applyResult.changedFiles.length > 0 ? applyResult.changedFiles : changedFiles;
      const changedCount = Math.max(1, appliedFiles.length);
      formatterOutput.appendLine('');
      formatterOutput.appendLine(`Applied formatter to ${changedCount} file(s).`);
      if (applyResult.stderr) {
        formatterOutput.appendLine('');
        formatterOutput.appendLine(applyResult.stderr);
      }
      formatterOutput.show(true);
      vscode.window.showInformationMessage(
        `Org2: formatted ${displayPath}. See "Org2 Formatter" output.`
      );
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      vscode.window.showErrorMessage(msg);
    }
  }

  function getHtmlExportStyleArgs() {
    const cfg = vscode.workspace.getConfiguration('org2');
    const stylesheetsRaw = String(cfg.get('export.stylesheets', '') || '');
    const includeDefaultStyle = cfg.get('export.includeDefaultStyle', true) ? true : false;
    const includeToc = cfg.get('export.includeToc', false) ? true : false;
    const tocDepthRaw = Number(cfg.get('export.tocDepth', 0));
    const tocDepth = Number.isFinite(tocDepthRaw) ? Math.trunc(tocDepthRaw) : 0;
    const includeHeadlineNumbers = cfg.get('export.numberHeadings', false) ? true : false;
    const headlineNumberDepthRaw = Number(cfg.get('export.numberHeadingsDepth', 0));
    const headlineNumberDepth = Number.isFinite(headlineNumberDepthRaw) ? Math.trunc(headlineNumberDepthRaw) : 0;
    const rewriteFileLinks = cfg.get('export.rewriteFileLinks', false) ? true : false;
    const stylesheets = Array.from(
      new Set(
        stylesheetsRaw
          .split(/[\n,]/)
          .map((value) => String(value || '').trim())
          .filter((value) => value.length > 0)
      )
    );

    const args = [];
    for (const href of stylesheets) {
      args.push('--css', href);
    }
    if (!includeDefaultStyle) {
      args.push('--no-default-style');
    }
    if (tocDepth > 0) {
      args.push('--toc-depth', String(tocDepth));
    } else if (includeToc) {
      args.push('--toc');
    }
    if (headlineNumberDepth > 0) {
      args.push('--number-headings-depth', String(headlineNumberDepth));
    } else if (includeHeadlineNumbers) {
      args.push('--number-headings');
    }
    if (rewriteFileLinks) {
      args.push('--rewrite-file-links');
    }
    return args;
  }

  async function exportCurrentFileHtml() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) return;

    const doc = editor.document;
    if (!doc || doc.uri.scheme !== 'file') {
      vscode.window.showWarningMessage('Org2: HTML export requires a file-backed document.');
      return;
    }

    if (doc.languageId !== 'org2' && doc.languageId !== 'org') {
      vscode.window.showWarningMessage('Org2: HTML export only supports Org/Org2 files.');
      return;
    }

    if (doc.isDirty) {
      const ok = await doc.save();
      if (!ok) {
        vscode.window.showWarningMessage('Org2: could not save file before HTML export.');
        return;
      }
    }

    const filePath = doc.uri.fsPath;
    const cwd = getWorkspaceRoot() || path.dirname(filePath) || process.cwd();
    const exportStyleArgs = getHtmlExportStyleArgs();

    const previewArgs = ['export', 'html', '--file', filePath, ...exportStyleArgs, '--format', 'json'];
    const { cmd: previewCmd, args: previewFinalArgs } = resolveOrg2Command(context, previewArgs);

    let previewPayload;
    try {
      const { stdout } = await execFileAsync(previewCmd, previewFinalArgs, { cwd });
      previewPayload = JSON.parse(String(stdout || '').trim());
    } catch (e) {
      const stderr = e && e.stderr ? String(e.stderr).trim() : '';
      const extra = stderr ? `\n${stderr}` : '';
      vscode.window.showErrorMessage(`Org2: HTML export preview failed: ${String(e && e.message ? e.message : e)}${extra}`);
      return;
    }

    const htmlText = typeof previewPayload.html === 'string' ? previewPayload.html : '';
    const outputPathRaw = typeof previewPayload.outputPath === 'string' ? previewPayload.outputPath : '';

    if (!htmlText) {
      vscode.window.showErrorMessage('Org2: HTML export preview returned no html output.');
      return;
    }

    const previewDoc = await vscode.workspace.openTextDocument({ language: 'html', content: htmlText });
    await vscode.window.showTextDocument(previewDoc, { preview: true, preserveFocus: false });

    const outputPath = path.isAbsolute(outputPathRaw) ? outputPathRaw : path.resolve(cwd, outputPathRaw || `${filePath}.html`);
    const confirm = await vscode.window.showInformationMessage(
      `Org2: write HTML export to ${path.basename(outputPath)}?`,
      { modal: true },
      'Write HTML'
    );

    if (confirm !== 'Write HTML') return;

    const applyArgs = ['export', 'html', '--file', filePath, '--out', outputPath, ...exportStyleArgs, '--format', 'json', '--apply'];
    const { cmd: applyCmd, args: applyFinalArgs } = resolveOrg2Command(context, applyArgs);

    let applyPayload;
    try {
      const { stdout } = await execFileAsync(applyCmd, applyFinalArgs, { cwd });
      applyPayload = JSON.parse(String(stdout || '').trim());
    } catch (e) {
      const stderr = e && e.stderr ? String(e.stderr).trim() : '';
      const extra = stderr ? `\n${stderr}` : '';
      vscode.window.showErrorMessage(`Org2: HTML export write failed: ${String(e && e.message ? e.message : e)}${extra}`);
      return;
    }

    const appliedOutRaw = typeof applyPayload.outputPath === 'string' ? applyPayload.outputPath : outputPath;
    const appliedOutPath = path.isAbsolute(appliedOutRaw) ? appliedOutRaw : path.resolve(cwd, appliedOutRaw);

    try {
      const exportedDoc = await vscode.workspace.openTextDocument(vscode.Uri.file(appliedOutPath));
      await vscode.window.showTextDocument(exportedDoc, { preview: false });
    } catch {
      // It's fine if VS Code can't open the output path immediately.
    }

    vscode.window.showInformationMessage(`Org2: exported HTML to ${path.basename(appliedOutPath)}.`);
  }

  async function exportWorkspaceHtml() {
    const workspaceRoot = getAgendaRootDir();
    if (!workspaceRoot) {
      vscode.window.showWarningMessage('Org2: set org2.agenda.dir or open a workspace folder before workspace export.');
      return;
    }

    const cfg = vscode.workspace.getConfiguration('org2');
    const outputDirConfigRaw = String(cfg.get('export.outputDir', '_site') || '_site').trim();
    const outputDirConfig = outputDirConfigRaw || '_site';
    const outputDir = path.isAbsolute(outputDirConfig)
      ? outputDirConfig
      : path.resolve(workspaceRoot, outputDirConfig);
    const indexFileConfig = String(cfg.get('export.indexFile', 'index.html') || '').trim();
    const indexTitleConfig = String(cfg.get('export.indexTitle', 'Org2 Export Index') || '').trim();
    const exportStyleArgs = getHtmlExportStyleArgs();

    const previewArgs = ['export', 'html', '--dir', workspaceRoot, '--recursive', '--out-dir', outputDir, ...exportStyleArgs, '--format', 'json'];
    if (indexFileConfig) {
      previewArgs.push('--index', indexFileConfig);
      if (indexTitleConfig) {
        previewArgs.push('--index-title', indexTitleConfig);
      }
    }
    const { cmd: previewCmd, args: previewFinalArgs } = resolveOrg2Command(context, previewArgs);

    let previewPayload;
    try {
      const { stdout } = await execFileAsync(previewCmd, previewFinalArgs, { cwd: workspaceRoot });
      previewPayload = JSON.parse(String(stdout || '').trim());
    } catch (e) {
      const stderr = e && e.stderr ? String(e.stderr).trim() : '';
      const extra = stderr ? `\n${stderr}` : '';
      vscode.window.showErrorMessage(`Org2: workspace HTML export preview failed: ${String(e && e.message ? e.message : e)}${extra}`);
      return;
    }

    const exported = Array.isArray(previewPayload && previewPayload.exported) ? previewPayload.exported : [];
    const countRaw = Number(previewPayload && previewPayload.count);
    const count = Number.isFinite(countRaw) && countRaw >= 0 ? countRaw : exported.length;

    if (count <= 0) {
      vscode.window.showInformationMessage('Org2: no Org/Org2 files found for workspace HTML export.');
      return;
    }

    const confirm = await vscode.window.showWarningMessage(
      `Org2: export ${count} Org file(s) to HTML under ${outputDir}?`,
      { modal: true },
      'Export Workspace HTML'
    );

    if (confirm !== 'Export Workspace HTML') return;

    const applyArgs = [...previewArgs, '--apply'];
    const { cmd: applyCmd, args: applyFinalArgs } = resolveOrg2Command(context, applyArgs);

    let applyPayload;
    try {
      const { stdout } = await execFileAsync(applyCmd, applyFinalArgs, { cwd: workspaceRoot });
      applyPayload = JSON.parse(String(stdout || '').trim());
    } catch (e) {
      const stderr = e && e.stderr ? String(e.stderr).trim() : '';
      const extra = stderr ? `\n${stderr}` : '';
      vscode.window.showErrorMessage(`Org2: workspace HTML export failed: ${String(e && e.message ? e.message : e)}${extra}`);
      return;
    }

    const appliedExported = Array.isArray(applyPayload && applyPayload.exported) ? applyPayload.exported : [];
    const appliedCountRaw = Number(applyPayload && applyPayload.count);
    const appliedCount = Number.isFinite(appliedCountRaw) && appliedCountRaw >= 0 ? appliedCountRaw : appliedExported.length;

    const indexPayload = applyPayload && typeof applyPayload.index === 'object' && applyPayload.index
      ? applyPayload.index
      : null;
    const indexOutputRaw = indexPayload && typeof indexPayload.outputPath === 'string'
      ? indexPayload.outputPath
      : '';

    const firstOutputRaw = indexOutputRaw || (
      appliedExported[0] && typeof appliedExported[0].outputPath === 'string'
        ? appliedExported[0].outputPath
        : ''
    );

    if (firstOutputRaw) {
      const firstOutputPath = path.isAbsolute(firstOutputRaw)
        ? firstOutputRaw
        : path.resolve(workspaceRoot, firstOutputRaw);
      try {
        const exportedDoc = await vscode.workspace.openTextDocument(vscode.Uri.file(firstOutputPath));
        await vscode.window.showTextDocument(exportedDoc, { preview: true, preserveFocus: true });
      } catch {
        // It's fine if VS Code can't open the first output file immediately.
      }
    }

    const indexSuffix = indexOutputRaw ? ` (index: ${path.basename(indexOutputRaw)})` : '';
    vscode.window.showInformationMessage(`Org2: exported ${appliedCount} workspace Org file(s) to HTML${indexSuffix}.`);
  }

  const formattingProvider = {
    async provideDocumentFormattingEdits(document) {
      const text = document.getText();
      try {
        const formatted = await formatOrg2Text(text);
        const fullRange = new vscode.Range(
          0,
          0,
          document.lineCount ? document.lineCount - 1 : 0,
          document.lineCount ? document.lineAt(document.lineCount - 1).text.length : 0
        );
        return [vscode.TextEdit.replace(fullRange, formatted)];
      } catch (err) {
        const msg = err && err.stderr ? String(err.stderr).trim() : (err instanceof Error ? err.message : String(err));
        vscode.window.showWarningMessage(`Org2: format failed: ${msg}`);
        return [];
      }
    },
  };

  context.subscriptions.push(vscode.languages.registerDocumentFormattingEditProvider(selector, formattingProvider));

  context.subscriptions.push(
    vscode.workspace.onWillSaveTextDocument((e) => {
      const doc = e.document;
      if (!doc) return;
      if (doc.languageId !== 'org2' && doc.languageId !== 'org') return;

      const cfg = vscode.workspace.getConfiguration('org2');
      const enabled = cfg.get('formatOnSave', true);
      if (!enabled) return;

      e.waitUntil(
        (async () => {
          try {
            const formatted = await formatOrg2Text(doc.getText());
            const fullRange = new vscode.Range(
              0,
              0,
              doc.lineCount ? doc.lineCount - 1 : 0,
              doc.lineCount ? doc.lineAt(doc.lineCount - 1).text.length : 0
            );
            return [vscode.TextEdit.replace(fullRange, formatted)];
          } catch (_) {
            return [];
          }
        })()
      );
    })
  );

  // Agenda view
  const agendaProvider = new Org2AgendaProvider(context);
  const agendaView = vscode.window.createTreeView('org2Agenda', {
    treeDataProvider: agendaProvider,
    showCollapseAll: true,
    canSelectMany: true,
  });
  agendaProvider.attachView(agendaView);
  context.subscriptions.push(agendaView);

  const backlinksProvider = new Org2BacklinksProvider(context);
  const backlinksView = vscode.window.createTreeView('org2Backlinks', {
    treeDataProvider: backlinksProvider,
    showCollapseAll: true,
  });
  context.subscriptions.push(backlinksView);

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.openAgenda', async () => {
      await vscode.commands.executeCommand('workbench.view.explorer');
      await agendaProvider.load();
      if (agendaProvider.groups[0]) {
        agendaView.reveal(agendaProvider.groups[0], { focus: true, expand: true }).catch(() => {});
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.refreshAgenda', async () => {
      await agendaProvider.load();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.openBacklinks', async () => {
      await focusBacklinksView();
      await backlinksProvider.loadForEditor(vscode.window.activeTextEditor, { focusView: false });
      if (backlinksProvider.groups[0]) {
        backlinksView.reveal(backlinksProvider.groups[0], { focus: true, expand: true }).catch(() => {});
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.refreshBacklinks', async () => {
      await backlinksProvider.loadForEditor(vscode.window.activeTextEditor, { focusView: false });
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.formatWorkspaceCheck', async () => {
      await checkWorkspaceFormattingDrift();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.formatWorkspaceApply', async () => {
      await applyWorkspaceFormatting();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.formatCurrentFileCheck', async () => {
      await checkCurrentFileFormattingDrift();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.formatCurrentFilePreviewDiff', async () => {
      await previewCurrentFileFormattingDiff();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.formatCurrentFileApply', async () => {
      await applyCurrentFileFormatting();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.exportCurrentFileHtml', async () => {
      await exportCurrentFileHtml();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.exportWorkspaceHtml', async () => {
      await exportWorkspaceHtml();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.pickAgendaFilter', async () => {
      await pickAgendaFilter(agendaProvider);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.pickAgendaStatusFilter', async () => {
      await pickAgendaStatusFilter(agendaProvider);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.openAgendaItem', async (item) => {
      await openAgendaItem(item);
    })
  );

  function resolveAgendaItemPath(item) {
    const agendaRoot = getAgendaRootDir();
    const s = String(item && item.file ? item.file : '');
    if (!s) return undefined;
    return path.isAbsolute(s) ? s : path.resolve(agendaRoot, s);
  }

  function findOpenDocumentForPath(absPath) {
    if (!absPath) return undefined;
    const needle = path.resolve(absPath);
    for (const d of vscode.workspace.textDocuments || []) {
      if (d && d.uri && d.uri.scheme === 'file') {
        const p = path.resolve(d.uri.fsPath);
        if (p === needle) return d;
      }
    }
    return undefined;
  }

  async function isOpenDocumentSyncedWithDisk(filePath) {
    const openDoc = findOpenDocumentForPath(filePath);
    if (!openDoc || openDoc.isDirty) return false;
    try {
      const diskText = await fs.promises.readFile(filePath, 'utf8');
      return openDoc.getText() === diskText;
    } catch {
      return false;
    }
  }

  async function refreshFileFromDisk(filePath, options) {
    const opts = options || {};
    const allowGlobalFallback = opts.allowGlobalFallback === true;
    if (opts.skipIfInSync && (await isOpenDocumentSyncedWithDisk(filePath))) {
      return;
    }

    const targetUri = vscode.Uri.file(filePath);
    const activeEditor = vscode.window.activeTextEditor;
    const isActiveTarget = !!(
      activeEditor &&
      activeEditor.document &&
      activeEditor.document.uri &&
      activeEditor.document.uri.scheme === 'file' &&
      path.resolve(activeEditor.document.uri.fsPath) === path.resolve(filePath)
    );

    if (isActiveTarget) {
      const previousSelection = opts.selection || activeEditor.selection;
      try {
        // Revert only the target editor to avoid global side-effects.
        await vscode.commands.executeCommand('workbench.action.files.revertResource', targetUri);
      } catch {
        if (allowGlobalFallback) {
          // Optional fallback for older VS Code versions.
          await vscode.commands.executeCommand('workbench.action.files.revert');
        }
      }

      if (previousSelection) {
        const editorAfter = vscode.window.activeTextEditor;
        const activeUriBefore = String(opts.activeUri || '');
        const shouldRestoreSelection =
          !activeUriBefore ||
          // Only restore if the same target editor was active when the command started.
          // If focus changed while CLI work was running, avoid forcing selection writes
          // into an editor the user is no longer actively navigating.
          activeUriBefore === targetUri.toString();

        if (
          shouldRestoreSelection &&
          editorAfter &&
          editorAfter.document &&
          editorAfter.document.uri.toString() === targetUri.toString()
        ) {
          const maxLine = Math.max(0, editorAfter.document.lineCount - 1);
          const clampPos = (pos) => {
            const line = Math.min(Math.max(pos.line, 0), maxLine);
            const maxChar = editorAfter.document.lineAt(line).text.length;
            const ch = Math.min(Math.max(pos.character, 0), maxChar);
            return new vscode.Position(line, ch);
          };
          const nextSel = new vscode.Selection(clampPos(previousSelection.start), clampPos(previousSelection.end));
          const sel = editorAfter.selection;
          const selectionChanged =
            !sel ||
            !sel.start ||
            !sel.end ||
            !sel.start.isEqual(nextSel.start) ||
            !sel.end.isEqual(nextSel.end);

          // Avoid no-op selection writes: in folded files, even setting the same
          // selection can trigger unwanted auto-expansion in some VS Code flows.
          if (selectionChanged) {
            editorAfter.selection = nextSel;
          }
          // Avoid forcing a reveal here; revealing after a CLI apply+refresh can
          // unexpectedly expand folds around the cursor in some navigation flows.
        }
      }
      return;
    }

    try {
      await vscode.commands.executeCommand('workbench.action.files.revertResource', targetUri);
    } catch {
      if (allowGlobalFallback) {
        await vscode.commands.executeCommand('workbench.action.files.revert');
      }
    }
  }

  function parseChangedFlagFromCliJson(stdout) {
    const text = String(stdout || '').trim();
    if (!text) return undefined;

    const readChanged = (obj) => {
      if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return undefined;
      return typeof obj.changed === 'boolean' ? obj.changed : undefined;
    };

    // Common case: stdout is pure JSON.
    try {
      const changed = readChanged(JSON.parse(text));
      if (typeof changed === 'boolean') return changed;
    } catch {
      // Fall through to line-by-line parsing.
    }

    // Some org2 invocations can emit extra informational lines before JSON.
    // Parse trailing JSON lines and accept the last explicit boolean `changed`.
    const lines = text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.length > 0)
      .reverse();

    for (const line of lines) {
      if (!(line.startsWith('{') && line.endsWith('}'))) continue;
      try {
        const changed = readChanged(JSON.parse(line));
        if (typeof changed === 'boolean') return changed;
      } catch {
        // Ignore non-JSON lines.
      }
    }

    return undefined;
  }

  async function runSetPriority(priority, item, options = {}) {
    const normalizedPriority = normalizeOrgPriorityToken(priority);

    let filePath;
    let line0;
    let editor;
    let doc;

    if (item && item.file) {
      filePath = resolveAgendaItemPath(item);
      line0 = typeof item.line === 'number' ? item.line : 0;

      const openDoc = findOpenDocumentForPath(filePath);
      if (openDoc && openDoc.isDirty) {
        vscode.window.showWarningMessage('Org2: please save the file before setting priority from the agenda.');
        return;
      }

      doc = await vscode.workspace.openTextDocument(vscode.Uri.file(filePath));
      editor = await vscode.window.showTextDocument(doc, { preview: true, preserveFocus: true });
    } else {
      editor = vscode.window.activeTextEditor;
      if (!editor) return;

      doc = editor.document;
      if (!doc || doc.uri.scheme !== 'file') {
        vscode.window.showWarningMessage('Org2: setting priority requires a file-backed document.');
        return;
      }

      filePath = doc.uri.fsPath;
      line0 = editor.selection && editor.selection.active ? editor.selection.active.line : 0;
    }

    const headlineLine = findHeadlineLineAtOrAbove(doc, line0);
    if (headlineLine < 0) {
      vscode.window.showWarningMessage('Org2: move cursor to a headline before setting priority.');
      return;
    }

    const currentLine = doc.lineAt(headlineLine).text;
    const updated = updateHeadlinePriorityToken(currentLine, normalizedPriority);
    if (!updated.changed) return;

    const edit = new vscode.WorkspaceEdit();
    edit.replace(
      doc.uri,
      new vscode.Range(headlineLine, 0, headlineLine, currentLine.length),
      updated.lineText
    );

    const applied = await vscode.workspace.applyEdit(edit);
    if (!applied) {
      vscode.window.showWarningMessage('Org2: failed to update priority token.');
      return;
    }

    if (doc.isDirty) {
      await doc.save();
    }

    if (!options.skipAgendaReload && item instanceof Org2AgendaItem) {
      await agendaProvider.load();
    }
  }

  async function runTodoCli(action, status, item, options = {}) {
    let filePath;
    let line;

    if (item && item.file) {
      filePath = resolveAgendaItemPath(item);
      line = typeof item.line === 'number' ? item.line + 1 : 1;

      const openDoc = findOpenDocumentForPath(filePath);
      if (openDoc && openDoc.isDirty) {
        vscode.window.showWarningMessage('Org2: please save the file before updating todo status from the agenda.');
        return;
      }
    } else {
      const editor = vscode.window.activeTextEditor;
      if (!editor) return;

      const doc = editor.document;
      if (!doc || doc.uri.scheme !== 'file') {
        vscode.window.showWarningMessage('Org2: todo status requires a file-backed document.');
        return;
      }

      if (doc.isDirty) {
        const ok = await doc.save();
        if (!ok) {
          vscode.window.showWarningMessage('Org2: could not save file before updating todo status.');
          return;
        }
      }

      filePath = doc.uri.fsPath;
      line = editor.selection && editor.selection.active ? editor.selection.active.line + 1 : 1;
    }

    const cfg = vscode.workspace.getConfiguration('org2');
    const writeTodoLogbook = cfg.get('todo.writeTransitionLogbook', false) ? true : false;
    const restoreSelectionAfterCliApply = cfg.get('editor.restoreSelectionAfterCliApply', true) ? true : false;
    const refreshAfterCliApply = cfg.get('editor.refreshAfterCliApply', true) ? true : false;
    const skipRefreshWhenInSync = cfg.get('editor.skipRefreshWhenInSync', true) ? true : false;
    const allowGlobalRefreshFallback = cfg.get('editor.allowGlobalRefreshFallback', false) ? true : false;

    const args = ['todo', action, '--file', String(filePath), '--line', String(line), '--format', 'json', '--apply'];
    if (action === 'set' && status) args.push('--status', status);
    if (writeTodoLogbook) args.push('--logbook');

    const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, args);

    const activeEditorBefore = item ? undefined : vscode.window.activeTextEditor;
    const activeUriBefore = activeEditorBefore && activeEditorBefore.document ? activeEditorBefore.document.uri.toString() : '';
    const selectionBefore =
      activeEditorBefore && activeEditorBefore.selection
        ? new vscode.Selection(activeEditorBefore.selection.start, activeEditorBefore.selection.end)
        : undefined;

    try {
      const { stdout } = await execFileAsync(finalCmd, finalArgs, { cwd: getAgendaRootDir() });
      const changed = parseChangedFlagFromCliJson(stdout);

      if (refreshAfterCliApply && changed !== false) {
        // Reload target file only (avoid global revert side-effects).
        await refreshFileFromDisk(filePath, {
          selection: restoreSelectionAfterCliApply ? selectionBefore : undefined,
          activeUri: activeUriBefore,
          skipIfInSync: skipRefreshWhenInSync,
          allowGlobalFallback: allowGlobalRefreshFallback,
        });
      }

      // If this was invoked from an agenda row action, refresh the agenda view so
      // TODO/status edits are reflected immediately.
      if (item instanceof Org2AgendaItem && changed !== false && !options.skipAgendaReload) {
        await agendaProvider.load();
      }
    } catch (e) {
      vscode.window.showErrorMessage(`Org2: todo update failed: ${String(e && e.message ? e.message : e)}`);
    }
  }

  async function runPlanCli(kind, item, options = {}) {
    let filePath;
    let line;

    if (item && item.file) {
      filePath = resolveAgendaItemPath(item);
      line = typeof item.line === 'number' ? item.line + 1 : 1;

      const openDoc = findOpenDocumentForPath(filePath);
      if (openDoc && openDoc.isDirty) {
        vscode.window.showWarningMessage('Org2: please save the file before updating planning from the agenda.');
        return;
      }
    } else {
      const editor = vscode.window.activeTextEditor;
      if (!editor) return;

      const doc = editor.document;
      if (!doc || doc.uri.scheme !== 'file') {
        vscode.window.showWarningMessage('Org2: planning update requires a file-backed document.');
        return;
      }

      if (doc.isDirty) {
        const ok = await doc.save();
        if (!ok) {
          vscode.window.showWarningMessage('Org2: could not save file before updating planning.');
          return;
        }
      }

      filePath = doc.uri.fsPath;
      line = editor.selection && editor.selection.active ? editor.selection.active.line + 1 : 1;
    }

    const cfg = vscode.workspace.getConfiguration('org2');
    const restoreSelectionAfterCliApply = cfg.get('editor.restoreSelectionAfterCliApply', true) ? true : false;
    const refreshAfterCliApply = cfg.get('editor.refreshAfterCliApply', true) ? true : false;
    const skipRefreshWhenInSync = cfg.get('editor.skipRefreshWhenInSync', true) ? true : false;
    const allowGlobalRefreshFallback = cfg.get('editor.allowGlobalRefreshFallback', false) ? true : false;
    const normalizedKind = normalizePlanKind(kind);
    if (!normalizedKind) {
      vscode.window.showWarningMessage('Org2: invalid planning kind (expected scheduled or deadline).');
      return;
    }

    const useToday = options.useToday ? true : false;
    const dateOverrideRaw = typeof options.dateOverride === 'string' ? options.dateOverride : '';
    const dateOverride = normalizePlanDateInput(dateOverrideRaw);
    if (dateOverrideRaw && !dateOverride) {
      vscode.window.showWarningMessage('Org2: invalid planning date override (expected YYYY-MM-DD).');
      return;
    }
    const skipAgendaReload = options.skipAgendaReload ? true : false;

    let date = '';
    if (dateOverride) {
      date = dateOverride;
    } else if (!useToday) {
      const input = await promptPlanDate(normalizedKind);
      if (!input) return;
      date = input;
    }

    const args = buildPlanCliArgs({
      filePath: String(filePath),
      line: String(line),
      kind: normalizedKind,
      useToday,
      date,
    });

    const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, args);

    const activeEditorBefore = item ? undefined : vscode.window.activeTextEditor;
    const activeUriBefore = activeEditorBefore && activeEditorBefore.document ? activeEditorBefore.document.uri.toString() : '';
    const selectionBefore =
      activeEditorBefore && activeEditorBefore.selection
        ? new vscode.Selection(activeEditorBefore.selection.start, activeEditorBefore.selection.end)
        : undefined;

    try {
      const { stdout } = await execFileAsync(finalCmd, finalArgs, { cwd: getAgendaRootDir() });
      const changed = parseChangedFlagFromCliJson(stdout);

      if (refreshAfterCliApply && changed !== false) {
        await refreshFileFromDisk(filePath, {
          selection: restoreSelectionAfterCliApply ? selectionBefore : undefined,
          activeUri: activeUriBefore,
          skipIfInSync: skipRefreshWhenInSync,
          allowGlobalFallback: allowGlobalRefreshFallback,
        });
      }

      // Keep agenda rows in sync after agenda-invoked planning updates.
      if (item instanceof Org2AgendaItem && changed !== false && !skipAgendaReload) {
        await agendaProvider.load();
      }
    } catch (e) {
      vscode.window.showErrorMessage(`Org2: planning update failed: ${String(e && e.message ? e.message : e)}`);
    }
  }

  async function runCryptCli(action, item) {
    const normalizedAction = String(action || '').trim().toLowerCase();
    if (!(normalizedAction === 'encrypt' || normalizedAction === 'decrypt')) {
      vscode.window.showWarningMessage('Org2: invalid crypt action (expected encrypt or decrypt).');
      return;
    }

    let filePath;
    let line;

    if (item && item.file) {
      filePath = resolveAgendaItemPath(item);
      line = typeof item.line === 'number' ? item.line + 1 : 1;

      const openDoc = findOpenDocumentForPath(filePath);
      if (openDoc && openDoc.isDirty) {
        vscode.window.showWarningMessage('Org2: please save the file before running org-crypt from the agenda.');
        return;
      }
    } else {
      const editor = vscode.window.activeTextEditor;
      if (!editor) return;

      const doc = editor.document;
      if (!doc || doc.uri.scheme !== 'file') {
        vscode.window.showWarningMessage('Org2: org-crypt requires a file-backed document.');
        return;
      }

      if (doc.isDirty) {
        const ok = await doc.save();
        if (!ok) {
          vscode.window.showWarningMessage('Org2: could not save file before running org-crypt.');
          return;
        }
      }

      filePath = doc.uri.fsPath;
      line = editor.selection && editor.selection.active ? editor.selection.active.line + 1 : 1;
    }

    const passphraseInput = await vscode.window.showInputBox({
      prompt: `Org2: crypt ${normalizedAction} subtree (passphrase)`,
      password: true,
      ignoreFocusOut: true,
      validateInput: (v) => (String(v || '').trim().length > 0 ? undefined : 'Passphrase is required'),
    });
    if (!passphraseInput) return;
    const passphrase = String(passphraseInput);

    const cfg = vscode.workspace.getConfiguration('org2');
    const restoreSelectionAfterCliApply = cfg.get('editor.restoreSelectionAfterCliApply', true) ? true : false;
    const refreshAfterCliApply = cfg.get('editor.refreshAfterCliApply', true) ? true : false;
    const skipRefreshWhenInSync = cfg.get('editor.skipRefreshWhenInSync', true) ? true : false;
    const allowGlobalRefreshFallback = cfg.get('editor.allowGlobalRefreshFallback', false) ? true : false;

    const args = [
      'crypt',
      normalizedAction,
      '--file',
      String(filePath),
      '--line',
      String(line),
      '--passphrase',
      passphrase,
      '--format',
      'json',
      '--apply',
    ];
    const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, args);

    const activeEditorBefore = item ? undefined : vscode.window.activeTextEditor;
    const activeUriBefore = activeEditorBefore && activeEditorBefore.document ? activeEditorBefore.document.uri.toString() : '';
    const selectionBefore =
      activeEditorBefore && activeEditorBefore.selection
        ? new vscode.Selection(activeEditorBefore.selection.start, activeEditorBefore.selection.end)
        : undefined;

    try {
      const { stdout } = await execFileAsync(finalCmd, finalArgs, { cwd: getAgendaRootDir() });
      const changed = parseChangedFlagFromCliJson(stdout);

      if (refreshAfterCliApply && changed !== false) {
        await refreshFileFromDisk(filePath, {
          selection: restoreSelectionAfterCliApply ? selectionBefore : undefined,
          activeUri: activeUriBefore,
          skipIfInSync: skipRefreshWhenInSync,
          allowGlobalFallback: allowGlobalRefreshFallback,
        });
      }

      if (item instanceof Org2AgendaItem && changed !== false) {
        await agendaProvider.load();
      }
    } catch (e) {
      vscode.window.showErrorMessage(`Org2: crypt ${normalizedAction} failed: ${String(e && e.message ? e.message : e)}`);
    }
  }

  async function runArchiveCli(item, options = {}) {
    let filePath;
    let line;

    if (item && item.file) {
      filePath = resolveAgendaItemPath(item);
      line = typeof item.line === 'number' ? item.line + 1 : 1;

      const openDoc = findOpenDocumentForPath(filePath);
      if (openDoc && openDoc.isDirty) {
        vscode.window.showWarningMessage('Org2: please save the file before archiving from the agenda.');
        return;
      }
    } else {
      const editor = vscode.window.activeTextEditor;
      if (!editor) return;

      const doc = editor.document;
      if (!doc || doc.uri.scheme !== 'file') {
        vscode.window.showWarningMessage('Org2: archiving requires a file-backed document.');
        return;
      }

      if (doc.isDirty) {
        const ok = await doc.save();
        if (!ok) {
          vscode.window.showWarningMessage('Org2: could not save file before archiving.');
          return;
        }
      }

      filePath = doc.uri.fsPath;
      line = editor.selection && editor.selection.active ? editor.selection.active.line + 1 : 1;
    }

    const cfg = vscode.workspace.getConfiguration('org2');
    const restoreSelectionAfterCliApply = cfg.get('editor.restoreSelectionAfterCliApply', true) ? true : false;
    const refreshAfterCliApply = cfg.get('editor.refreshAfterCliApply', true) ? true : false;
    const skipRefreshWhenInSync = cfg.get('editor.skipRefreshWhenInSync', true) ? true : false;
    const allowGlobalRefreshFallback = cfg.get('editor.allowGlobalRefreshFallback', false) ? true : false;
    const skipAgendaReload = options.skipAgendaReload ? true : false;

    const activeEditorBefore = item ? undefined : vscode.window.activeTextEditor;
    const activeUriBefore = activeEditorBefore && activeEditorBefore.document ? activeEditorBefore.document.uri.toString() : '';
    const selectionBefore =
      activeEditorBefore && activeEditorBefore.selection
        ? new vscode.Selection(activeEditorBefore.selection.start, activeEditorBefore.selection.end)
        : undefined;

    const ok = await vscode.window.showWarningMessage(
      `Org2: archive subtree at line ${line}? (This will edit the file on disk)`,
      { modal: true },
      'Archive'
    );
    if (ok !== 'Archive') return;

    // Preview the edit as a diff, then ask before applying.
    const previewArgs = ['archive', '--file', String(filePath), '--pos', String(line), '--format', 'diff'];
    const { cmd: previewCmd, args: previewFinalArgs } = resolveOrg2Command(context, previewArgs);

    try {
      const { stdout } = await execFileAsync(previewCmd, previewFinalArgs, { cwd: getAgendaRootDir() });
      const diffText = String(stdout || '').trimEnd();

      if (!diffText) {
        vscode.window.showInformationMessage('Org2: nothing to archive.');
        return;
      }

      const doc = await vscode.workspace.openTextDocument({ language: 'diff', content: diffText + '\n' });
      await vscode.window.showTextDocument(doc, { preview: true, preserveFocus: false });

      const applyOk = await vscode.window.showWarningMessage(
        `Org2: apply archive edit at line ${line}?`,
        { modal: true },
        'Apply'
      );
      if (applyOk !== 'Apply') return;

      const applyArgs = ['archive', '--file', String(filePath), '--pos', String(line), '--apply'];
      const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, applyArgs);
      await execFileAsync(finalCmd, finalArgs, { cwd: getAgendaRootDir() });

      if (refreshAfterCliApply) {
        await refreshFileFromDisk(filePath, {
          selection: restoreSelectionAfterCliApply ? selectionBefore : undefined,
          activeUri: activeUriBefore,
          skipIfInSync: skipRefreshWhenInSync,
          allowGlobalFallback: allowGlobalRefreshFallback,
        });
      }

      // Keep agenda rows in sync after agenda-invoked archive edits.
      if (item instanceof Org2AgendaItem && !skipAgendaReload) {
        await agendaProvider.load();
      }
    } catch (e) {
      const stderr = e && e.stderr ? String(e.stderr).trim() : '';
      const extra = stderr ? `\n${stderr}` : '';
      vscode.window.showErrorMessage(
        `Org2: archive failed: ${String(e && e.message ? e.message : e)}${extra}`
      );
    }
  }

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.archiveSubtree', async (item) => {
      await applyArchiveSubtreeCommand(item);
    })
  );

  async function runRefileCli(item, options = {}) {
    let filePath;
    let line;

    if (item && item.file) {
      filePath = resolveAgendaItemPath(item);
      line = typeof item.line === 'number' ? item.line + 1 : 1;

      const openDoc = findOpenDocumentForPath(filePath);
      if (openDoc && openDoc.isDirty) {
        vscode.window.showWarningMessage('Org2: please save the file before refiling from the agenda.');
        return;
      }
    } else {
      const editor = vscode.window.activeTextEditor;
      if (!editor) return;

      const doc = editor.document;
      if (!doc || doc.uri.scheme !== 'file') {
        vscode.window.showWarningMessage('Org2: refiling requires a file-backed document.');
        return;
      }

      if (doc.isDirty) {
        const ok = await doc.save();
        if (!ok) {
          vscode.window.showWarningMessage('Org2: could not save file before refiling.');
          return;
        }
      }

      filePath = doc.uri.fsPath;
      line = editor.selection && editor.selection.active ? editor.selection.active.line + 1 : 1;
    }

    const cfg = vscode.workspace.getConfiguration('org2');
    const restoreSelectionAfterCliApply = cfg.get('editor.restoreSelectionAfterCliApply', true) ? true : false;
    const refreshAfterCliApply = cfg.get('editor.refreshAfterCliApply', true) ? true : false;
    const skipRefreshWhenInSync = cfg.get('editor.skipRefreshWhenInSync', true) ? true : false;
    const allowGlobalRefreshFallback = cfg.get('editor.allowGlobalRefreshFallback', false) ? true : false;
    const skipAgendaReload = options.skipAgendaReload ? true : false;

    const activeEditorBefore = item ? undefined : vscode.window.activeTextEditor;
    const activeUriBefore = activeEditorBefore && activeEditorBefore.document ? activeEditorBefore.document.uri.toString() : '';
    const selectionBefore =
      activeEditorBefore && activeEditorBefore.selection
        ? new vscode.Selection(activeEditorBefore.selection.start, activeEditorBefore.selection.end)
        : undefined;

    const sourcePath = path.resolve(String(filePath));

    let candidatePaths = [];
    try {
      const roots = vscode.workspace.workspaceFolders || [];
      if (roots.length > 0) {
        const found = await vscode.workspace.findFiles('**/*.{org,org2}', '**/{.git,node_modules,.org2}/**', 500);
        candidatePaths = found.map((uri) => uri.fsPath);
      }
    } catch (_) {
      // Fall back to source-only picker.
    }

    if (!candidatePaths.includes(sourcePath)) {
      candidatePaths.push(sourcePath);
    }

    candidatePaths = Array.from(new Set(candidatePaths.map((p) => path.resolve(String(p))))).sort((a, b) => a.localeCompare(b));

    const workspaceRoot = getWorkspaceRoot();
    const destinationPick = await vscode.window.showQuickPick(
      candidatePaths.map((candidate) => ({
        label: workspaceRoot ? path.relative(workspaceRoot, candidate) || path.basename(candidate) : path.basename(candidate),
        description: candidate === sourcePath ? 'Current file' : '',
        detail: candidate,
        filePath: candidate,
      })),
      {
        placeHolder: 'Org2: refile subtree destination file',
        matchOnDescription: true,
        matchOnDetail: true,
      }
    );
    if (!destinationPick) return;

    const destinationPath = path.resolve(String(destinationPick.filePath || ''));
    if (!destinationPath) return;

    const openDestinationDoc = findOpenDocumentForPath(destinationPath);
    if (openDestinationDoc && openDestinationDoc.isDirty) {
      vscode.window.showWarningMessage('Org2: please save the destination file before refiling.');
      return;
    }

    let destinationText = '';
    try {
      destinationText = fs.existsSync(destinationPath)
        ? fs.readFileSync(destinationPath, 'utf8').replace(/\r\n/g, '\n')
        : '';
    } catch (e) {
      vscode.window.showErrorMessage(`Org2: could not read destination file: ${String(e && e.message ? e.message : e)}`);
      return;
    }

    const headingPicks = [{
      label: 'Append to end of file',
      description: path.basename(destinationPath),
      detail: destinationPath,
      line1: 0,
    }];

    const destinationLines = destinationText.split('\n');
    for (let idx = 0; idx < destinationLines.length; idx++) {
      const lineText = destinationLines[idx] || '';
      const m = /^(\*+)\s+(.*)$/.exec(lineText);
      if (!m) continue;
      const title = String(m[2] || '').trim() || '(untitled heading)';
      headingPicks.push({
        label: `${m[1]} ${title}`,
        description: `Line ${idx + 1}`,
        detail: destinationPath,
        line1: idx + 1,
      });
    }

    const headingPick = await vscode.window.showQuickPick(headingPicks, {
      placeHolder: 'Org2: insert location in destination file',
      matchOnDescription: true,
      matchOnDetail: false,
    });
    if (!headingPick) return;

    const destinationHeadingLine1 = headingPick.line1 > 0 ? String(headingPick.line1) : '';

    const previewArgs = ['refile', '--file', sourcePath, '--pos', String(line), '--to-file', destinationPath, '--format', 'diff'];
    if (destinationHeadingLine1) {
      previewArgs.push('--to-pos', destinationHeadingLine1);
    }

    const { cmd: previewCmd, args: previewFinalArgs } = resolveOrg2Command(context, previewArgs);

    try {
      const { stdout } = await execFileAsync(previewCmd, previewFinalArgs, { cwd: getAgendaRootDir() });
      const diffText = String(stdout || '').trimEnd();

      if (!diffText) {
        vscode.window.showInformationMessage('Org2: nothing to refile.');
        return;
      }

      const diffDoc = await vscode.workspace.openTextDocument({ language: 'diff', content: diffText + '\n' });
      await vscode.window.showTextDocument(diffDoc, { preview: true, preserveFocus: false });

      const applyOk = await vscode.window.showWarningMessage(
        `Org2: apply refile edit to ${path.basename(destinationPath)}?`,
        { modal: true },
        'Apply'
      );
      if (applyOk !== 'Apply') return;

      const applyArgs = ['refile', '--file', sourcePath, '--pos', String(line), '--to-file', destinationPath, '--format', 'json', '--apply'];
      if (destinationHeadingLine1) {
        applyArgs.push('--to-pos', destinationHeadingLine1);
      }

      const { cmd: applyCmd, args: applyFinalArgs } = resolveOrg2Command(context, applyArgs);
      const { stdout: applyOut } = await execFileAsync(applyCmd, applyFinalArgs, { cwd: getAgendaRootDir() });
      const changed = parseChangedFlagFromCliJson(applyOut);

      if (refreshAfterCliApply && changed !== false) {
        await refreshFileFromDisk(sourcePath, {
          selection: restoreSelectionAfterCliApply ? selectionBefore : undefined,
          activeUri: activeUriBefore,
          skipIfInSync: skipRefreshWhenInSync,
          allowGlobalFallback: allowGlobalRefreshFallback,
        });

        if (path.resolve(destinationPath) !== path.resolve(sourcePath)) {
          await refreshFileFromDisk(destinationPath, {
            skipIfInSync: skipRefreshWhenInSync,
            allowGlobalFallback: allowGlobalRefreshFallback,
          });
        }
      }

      if (item instanceof Org2AgendaItem && changed !== false && !skipAgendaReload) {
        await agendaProvider.load();
      }

      vscode.window.showInformationMessage(
        `Org2: refiled subtree to ${path.basename(destinationPath)}${destinationHeadingLine1 ? ` (line ${destinationHeadingLine1})` : ''}.`
      );
    } catch (e) {
      const stderr = e && e.stderr ? String(e.stderr).trim() : '';
      const extra = stderr ? `\n${stderr}` : '';
      vscode.window.showErrorMessage(`Org2: refile failed: ${String(e && e.message ? e.message : e)}${extra}`);
    }
  }

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.refileSubtree', async (item) => {
      await applyRefileSubtreeCommand(item);
    })
  );

  async function runShiftSubtreeLevels(step) {
    const delta = Number(step);
    if (!Number.isInteger(delta) || delta === 0) return;

    const editor = vscode.window.activeTextEditor;
    if (!editor || !editor.document) return;

    const doc = editor.document;
    if (doc.languageId !== 'org2' && doc.languageId !== 'org') {
      vscode.window.showWarningMessage('Org2: heading level commands are only available for Org/Org2 files.');
      return;
    }

    const subtreeRange = findSubtreeRangeAtOrAbove(doc, editor.selection && editor.selection.active ? editor.selection.active.line : 0);
    if (!subtreeRange) {
      vscode.window.showWarningMessage('Org2: place cursor on a headline to adjust subtree heading levels.');
      return;
    }

    if (delta < 0 && subtreeRange.level <= 1) {
      vscode.window.showInformationMessage('Org2: top-level headings cannot be promoted further.');
      return;
    }

    const targets = findHeadingLevelEditTargets(doc, subtreeRange);
    if (targets.length === 0) {
      vscode.window.showInformationMessage('Org2: no headings found in subtree.');
      return;
    }

    const edit = new vscode.WorkspaceEdit();
    for (const target of targets) {
      const nextLevel = target.level + delta;
      if (nextLevel < 1) {
        vscode.window.showInformationMessage('Org2: cannot promote heading above level 1.');
        return;
      }

      const updated = `${'*'.repeat(nextLevel)}${target.text.slice(target.level)}`;
      edit.replace(
        doc.uri,
        new vscode.Range(target.line, 0, target.line, target.text.length),
        updated
      );
    }

    const applied = await vscode.workspace.applyEdit(edit);
    if (!applied) {
      vscode.window.showErrorMessage('Org2: failed to update subtree heading levels.');
      return;
    }
  }

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.promoteSubtree', async () => {
      await runShiftSubtreeLevels(-1);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.demoteSubtree', async () => {
      await runShiftSubtreeLevels(1);
    })
  );

  async function runMoveSubtree(direction) {
    const delta = Number(direction);
    if (delta !== -1 && delta !== 1) return;

    const editor = vscode.window.activeTextEditor;
    if (!editor || !editor.document) return;

    const doc = editor.document;
    if (doc.languageId !== 'org2' && doc.languageId !== 'org') {
      vscode.window.showWarningMessage('Org2: subtree move commands are only available for Org/Org2 files.');
      return;
    }

    const subtreeRange = findSubtreeRangeAtOrAbove(doc, editor.selection && editor.selection.active ? editor.selection.active.line : 0);
    if (!subtreeRange) {
      vscode.window.showWarningMessage('Org2: place cursor on a headline to move a subtree.');
      return;
    }

    const siblingRange = delta < 0
      ? findPreviousSiblingSubtreeRange(doc, subtreeRange)
      : findNextSiblingSubtreeRange(doc, subtreeRange);

    if (!siblingRange) {
      vscode.window.showInformationMessage(
        delta < 0
          ? 'Org2: subtree is already the first sibling.'
          : 'Org2: subtree is already the last sibling.'
      );
      return;
    }

    const subtreeDocRange = getSubtreeDocumentRange(doc, subtreeRange);
    const siblingDocRange = getSubtreeDocumentRange(doc, siblingRange);
    if (!subtreeDocRange || !siblingDocRange) return;

    const subtreeText = doc.getText(subtreeDocRange);
    const siblingText = doc.getText(siblingDocRange);

    const replacementRange = getSubtreeDocumentRange(doc, {
      startLine: Math.min(subtreeRange.startLine, siblingRange.startLine),
      endLine: Math.max(subtreeRange.endLine, siblingRange.endLine),
    });
    if (!replacementRange) return;

    const replacementText = delta < 0
      ? `${subtreeText}${siblingText}`
      : `${siblingText}${subtreeText}`;

    const edit = new vscode.WorkspaceEdit();
    edit.replace(doc.uri, replacementRange, replacementText);

    const applied = await vscode.workspace.applyEdit(edit);
    if (!applied) {
      vscode.window.showErrorMessage('Org2: failed to move subtree.');
      return;
    }

    const siblingLineCount = siblingRange.endLine - siblingRange.startLine + 1;
    const movedStartLine = delta < 0
      ? siblingRange.startLine
      : subtreeRange.startLine + siblingLineCount;

    const movedCursor = new vscode.Position(Math.max(0, movedStartLine), 0);
    editor.selection = new vscode.Selection(movedCursor, movedCursor);
    editor.revealRange(new vscode.Range(movedCursor, movedCursor), vscode.TextEditorRevealType.InCenterIfOutsideViewport);
  }

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.moveSubtreeUp', async () => {
      await runMoveSubtree(-1);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.moveSubtreeDown', async () => {
      await runMoveSubtree(1);
    })
  );

  async function runCaptureCli() {
    const cfg = vscode.workspace.getConfiguration('org2');
    const defaultFileRaw = String(cfg.get('capture.defaultFile', '') || '').trim();
    const defaultTemplateRaw = String(cfg.get('capture.defaultTemplate', 'note') || 'note').trim().toLowerCase();
    const defaultTemplate = defaultTemplateRaw === 'task' ? 'task' : 'note';
    const defaultTodoKeywordRaw = String(cfg.get('capture.defaultTodoKeyword', 'TODO') || 'TODO').trim().toUpperCase();
    const captureUseSelectionAsBody = cfg.get('capture.useSelectionAsBody', true) ? true : false;

    const restoreSelectionAfterCliApply = cfg.get('editor.restoreSelectionAfterCliApply', true) ? true : false;
    const refreshAfterCliApply = cfg.get('editor.refreshAfterCliApply', true) ? true : false;
    const skipRefreshWhenInSync = cfg.get('editor.skipRefreshWhenInSync', true) ? true : false;
    const allowGlobalRefreshFallback = cfg.get('editor.allowGlobalRefreshFallback', false) ? true : false;

    const workspaceRoot = getWorkspaceRoot() || getAgendaRootDir() || process.cwd();
    const resolveCapturePath = (value) => {
      const raw = String(value || '').trim();
      if (!raw) return '';
      return path.isAbsolute(raw) ? path.resolve(raw) : path.resolve(workspaceRoot, raw);
    };

    const activeEditor = vscode.window.activeTextEditor;
    const activeDoc = activeEditor && activeEditor.document ? activeEditor.document : null;
    const activeFilePath =
      activeDoc && activeDoc.uri && activeDoc.uri.scheme === 'file' && (activeDoc.languageId === 'org2' || activeDoc.languageId === 'org')
        ? path.resolve(activeDoc.uri.fsPath)
        : '';

    const selectedCaptureBody =
      captureUseSelectionAsBody && activeEditor && activeDoc && !activeEditor.selection.isEmpty
        ? String(activeDoc.getText(activeEditor.selection) || '').replace(/\r\n/g, '\n').trim()
        : '';

    const configuredDefaultPath = resolveCapturePath(defaultFileRaw);

    let candidatePaths = [];
    try {
      if (vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders.length > 0) {
        const found = await vscode.workspace.findFiles('**/*.{org,org2}', '**/{.git,node_modules,.org2}/**', 500);
        candidatePaths = found.map((uri) => path.resolve(uri.fsPath));
      }
    } catch (_) {
      // Fall back to active/configured paths below.
    }

    if (activeFilePath) candidatePaths.push(activeFilePath);
    if (configuredDefaultPath) candidatePaths.push(configuredDefaultPath);

    candidatePaths = Array.from(new Set(candidatePaths.filter(Boolean))).sort((a, b) => a.localeCompare(b));

    const preferredPath = configuredDefaultPath || activeFilePath || '';
    if (preferredPath) {
      candidatePaths = [preferredPath, ...candidatePaths.filter((value) => value !== preferredPath)];
    }

    const captureFilePick = await vscode.window.showQuickPick(
      [
        {
          label: '$(edit) Enter custom capture file path…',
          description: '',
          detail: defaultFileRaw || activeFilePath || workspaceRoot,
          customPath: true,
        },
        ...candidatePaths.map((candidate) => ({
          label: path.relative(workspaceRoot, candidate) || path.basename(candidate),
          description: candidate === activeFilePath ? 'Current file' : candidate === configuredDefaultPath ? 'Configured default' : '',
          detail: candidate,
          filePath: candidate,
        })),
      ],
      {
        placeHolder: 'Org2: capture target file',
        matchOnDescription: true,
        matchOnDetail: true,
      }
    );

    if (!captureFilePick) return;

    let captureFilePath = '';
    if (captureFilePick.customPath) {
      const customPathRaw = await vscode.window.showInputBox({
        prompt: 'Org2: capture file path',
        value: defaultFileRaw || activeFilePath || path.join(workspaceRoot, 'inbox.org2'),
        placeHolder: '/path/to/inbox.org2',
        validateInput: (v) => (String(v || '').trim() ? undefined : 'Capture file path is required'),
      });
      if (customPathRaw === undefined) return;
      captureFilePath = resolveCapturePath(customPathRaw);
    } else {
      captureFilePath = path.resolve(String(captureFilePick.filePath || ''));
    }

    if (!captureFilePath) {
      vscode.window.showWarningMessage('Org2: capture file path is required.');
      return;
    }

    const templateOptions = [
      { label: 'Note', description: '* Title + CAPTURED timestamp', value: 'note' },
      { label: 'Task', description: '* TODO Title + CAPTURED timestamp', value: 'task' },
    ];
    const templatePicks = defaultTemplate === 'task'
      ? [templateOptions[1], templateOptions[0]]
      : [templateOptions[0], templateOptions[1]];

    const templatePick = await vscode.window.showQuickPick(templatePicks, {
      placeHolder: 'Org2: capture template',
      matchOnDescription: true,
    });
    if (!templatePick) return;

    const titleRaw = await vscode.window.showInputBox({
      prompt: 'Org2: capture title',
      placeHolder: templatePick.value === 'task' ? 'Ship onboarding copy' : 'Call notes',
      validateInput: (v) => (String(v || '').trim() ? undefined : 'Capture title is required'),
    });
    if (titleRaw === undefined) return;

    const captureTitle = String(titleRaw || '').trim();
    if (!captureTitle) {
      vscode.window.showWarningMessage('Org2: capture title is required.');
      return;
    }

    const todoKeywordOptions = ['TODO', 'IN_PROGRESS', 'DONE', 'CANCELED', 'CANCELLED'];
    let captureTodoKeyword = 'TODO';
    if (templatePick.value === 'task') {
      const normalizedDefaultTodo = todoKeywordOptions.includes(defaultTodoKeywordRaw) ? defaultTodoKeywordRaw : 'TODO';
      const todoPickOrder = [
        normalizedDefaultTodo,
        ...todoKeywordOptions.filter((keyword) => keyword !== normalizedDefaultTodo),
      ];
      const todoPick = await vscode.window.showQuickPick(
        todoPickOrder.map((keyword) => ({ label: keyword, value: keyword })),
        { placeHolder: 'Org2: capture task TODO keyword' }
      );
      if (!todoPick) return;
      captureTodoKeyword = todoPick.value;
    }

    const previewArgs = ['capture', '--file', captureFilePath, '--template', templatePick.value, '--title', captureTitle, '--format', 'diff'];
    if (templatePick.value === 'task') {
      previewArgs.push('--todo', captureTodoKeyword);
    }
    if (selectedCaptureBody) {
      previewArgs.push('--body', selectedCaptureBody);
    }

    const { cmd: previewCmd, args: previewFinalArgs } = resolveOrg2Command(context, previewArgs);
    const cwd = getWorkspaceRoot() || path.dirname(captureFilePath) || process.cwd();

    let diffText = '';
    try {
      const { stdout } = await execFileAsync(previewCmd, previewFinalArgs, { cwd });
      diffText = String(stdout || '').trimEnd();
    } catch (e) {
      const stderr = e && e.stderr ? String(e.stderr).trim() : '';
      const extra = stderr ? `\n${stderr}` : '';
      vscode.window.showErrorMessage(`Org2: capture preview failed: ${String(e && e.message ? e.message : e)}${extra}`);
      return;
    }

    if (!diffText) {
      vscode.window.showInformationMessage('Org2: capture preview produced no changes.');
      return;
    }

    const diffDoc = await vscode.workspace.openTextDocument({ language: 'diff', content: diffText + '\n' });
    await vscode.window.showTextDocument(diffDoc, { preview: true, preserveFocus: false });

    const applyOk = await vscode.window.showWarningMessage(
      `Org2: capture ${templatePick.value} in ${path.basename(captureFilePath)}?`,
      { modal: true },
      'Capture'
    );
    if (applyOk !== 'Capture') return;

    const applyArgs = ['capture', '--file', captureFilePath, '--template', templatePick.value, '--title', captureTitle, '--format', 'json', '--apply'];
    if (templatePick.value === 'task') {
      applyArgs.push('--todo', captureTodoKeyword);
    }
    if (selectedCaptureBody) {
      applyArgs.push('--body', selectedCaptureBody);
    }

    const { cmd: applyCmd, args: applyFinalArgs } = resolveOrg2Command(context, applyArgs);

    let applyPayload;
    try {
      const { stdout } = await execFileAsync(applyCmd, applyFinalArgs, { cwd });
      applyPayload = JSON.parse(String(stdout || '').trim());
    } catch (e) {
      const stderr = e && e.stderr ? String(e.stderr).trim() : '';
      const extra = stderr ? `\n${stderr}` : '';
      vscode.window.showErrorMessage(`Org2: capture failed: ${String(e && e.message ? e.message : e)}${extra}`);
      return;
    }

    const changed = applyPayload && typeof applyPayload.changed === 'boolean' ? applyPayload.changed : true;
    const headingLine1Raw = Number(applyPayload && applyPayload.headingLine1);
    const headingLine1 = Number.isFinite(headingLine1Raw) && headingLine1Raw > 0 ? Math.floor(headingLine1Raw) : 1;

    const isActiveTarget = activeDoc && activeDoc.uri && activeDoc.uri.scheme === 'file'
      ? path.resolve(activeDoc.uri.fsPath) === path.resolve(captureFilePath)
      : false;

    const selectionBefore =
      isActiveTarget && activeEditor && activeEditor.selection
        ? new vscode.Selection(activeEditor.selection.start, activeEditor.selection.end)
        : undefined;
    const activeUriBefore = isActiveTarget && activeEditor && activeEditor.document
      ? activeEditor.document.uri.toString()
      : '';

    if (refreshAfterCliApply && changed !== false) {
      await refreshFileFromDisk(captureFilePath, {
        selection: restoreSelectionAfterCliApply ? selectionBefore : undefined,
        activeUri: activeUriBefore,
        skipIfInSync: skipRefreshWhenInSync,
        allowGlobalFallback: allowGlobalRefreshFallback,
      });
    }

    try {
      const targetDoc = await vscode.workspace.openTextDocument(vscode.Uri.file(captureFilePath));
      const targetEditor = await vscode.window.showTextDocument(targetDoc, { preview: false });
      const maxLine = Math.max(0, targetDoc.lineCount - 1);
      const targetPos = new vscode.Position(Math.min(Math.max(headingLine1 - 1, 0), maxLine), 0);
      targetEditor.selection = new vscode.Selection(targetPos, targetPos);
      revealNavigationPosition(targetEditor, targetPos);
    } catch {
      // It's fine if VS Code cannot open/reveal the target file immediately.
    }

    vscode.window.showInformationMessage(
      `Org2: captured ${templatePick.value} in ${path.basename(captureFilePath)} (line ${headingLine1}).`
    );
  }

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.captureQuickEntry', async () => {
      await runCaptureCli();
    })
  );

  // Roam dailies navigation (open or create YYYY-MM-DD.org2)
  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamDailiesGotoToday', async () => {
      await openRoamDailyForDateString(formatDateYYYYMMDD(new Date()));
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamDailiesGotoYesterday', async () => {
      const d = new Date();
      d.setDate(d.getDate() - 1);
      await openRoamDailyForDateString(formatDateYYYYMMDD(d));
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamDailiesGotoTomorrow', async () => {
      const d = new Date();
      d.setDate(d.getDate() + 1);
      await openRoamDailyForDateString(formatDateYYYYMMDD(d));
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamDailiesGotoDate', async () => {
      const date = await vscode.window.showInputBox({
        prompt: 'Org2: Roam dailies — go to date (YYYY-MM-DD)',
        placeHolder: 'YYYY-MM-DD',
        validateInput: (v) => (/^\d{4}-\d{2}-\d{2}$/.test((v || '').trim()) ? undefined : 'Expected YYYY-MM-DD'),
      });
      if (!date) return;
      await openRoamDailyForDateString(String(date).trim());
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamNodeNew', async () => {
      const titleRaw = await vscode.window.showInputBox({
        prompt: 'Org2: Roam — new node title',
        placeHolder: 'Node title',
        validateInput: (v) => (String(v || '').trim() ? undefined : 'Title is required'),
      });
      if (titleRaw === undefined) return;

      const title = String(titleRaw || '').trim();
      if (!title) {
        vscode.window.showWarningMessage('Org2: node title is required.');
        return;
      }

      const root = getRoamNodesRootDir();
      const args = buildRoamNodeNewArgs(root, title);
      const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, args);

      let out;
      try {
        out = await vscode.window.withProgress(
          { location: vscode.ProgressLocation.Notification, title: 'Org2: Creating roam node', cancellable: false },
          async () => await execFileAsync(finalCmd, finalArgs, { cwd: root })
        );
      } catch (e) {
        const stderr = e && e.stderr ? String(e.stderr).trim() : '';
        const extra = stderr ? `\n${stderr}` : '';
        vscode.window.showErrorMessage(`Org2: failed to create roam node: ${String(e && e.message ? e.message : e)}${extra}`);
        return;
      }

      let payload;
      try {
        payload = JSON.parse(String((out && out.stdout) || '').trim());
      } catch (e) {
        vscode.window.showErrorMessage('Org2: failed to parse org2 roam node output.');
        return;
      }

      const file = typeof payload.file === 'string' ? payload.file : '';
      if (!file) {
        vscode.window.showErrorMessage('Org2: roam node output missing file path.');
        return;
      }

      const uri = vscode.Uri.file(file);
      const doc = await vscode.workspace.openTextDocument(uri);
      await vscode.window.showTextDocument(doc, { preview: false });
      vscode.window.showInformationMessage(`Org2: created roam node ${path.basename(file)}.`);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamCopyIdLink', async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) return;

      const doc = editor.document;
      if (!doc || doc.uri.scheme !== 'file') {
        vscode.window.showWarningMessage('Org2: copying an ID link requires a file-backed document.');
        return;
      }

      if (doc.isDirty) {
        const ok = await doc.save();
        if (!ok) {
          vscode.window.showWarningMessage('Org2: could not save file before copying ID link.');
          return;
        }
      }

      const cursorLine = editor.selection.active.line;
      const findHeadingTitleAtOrAboveLine = (line0) => {
        const start = Math.min(Math.max(Number(line0) || 0, 0), doc.lineCount - 1);
        for (let i = start; i >= 0; i -= 1) {
          const text = doc.lineAt(i).text;
          const m = headingRe.exec(text);
          if (m) return text.replace(/^\*+\s+/, '').trim();
        }
        return null;
      };

      // Prefer headline-level IDs (at/above cursor) if we're in a heading context;
      // fall back to file-level IDs.
      const args = [
        'id',
        'ensure',
        '--file',
        String(doc.uri.fsPath),
        '--line',
        String(cursorLine + 1),
        '--apply',
        '--format',
        'json',
      ];
      const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, args);

      let out;
      try {
        out = await execFileAsync(finalCmd, finalArgs, { cwd: getRoamIndexRootDir() });
      } catch (e) {
        vscode.window.showErrorMessage(`Org2: failed to ensure ID: ${String(e && e.message ? e.message : e)}`);
        return;
      }

      let payload;
      try {
        payload = JSON.parse(String((out && out.stdout) || '').trim());
      } catch (e) {
        vscode.window.showErrorMessage('Org2: failed to parse org2 id ensure output.');
        return;
      }

      const id = typeof payload.id === 'string' ? payload.id : '';
      if (!/^([0-9a-fA-F-]{36})$/.test(id)) {
        vscode.window.showErrorMessage('Org2: org2 id ensure did not return a valid UUID.');
        return;
      }

      const kind = payload.kind === 'headline' ? 'headline' : 'file';
      const title =
        kind === 'headline'
          ? findHeadingTitleAtOrAboveLine(cursorLine) || path.basename(doc.uri.fsPath).replace(/\.(org2|org)$/i, '')
          : path.basename(doc.uri.fsPath).replace(/\.(org2|org)$/i, '');

      const link = `[[id:${id.toLowerCase()}][${title}]]`;

      // If we inserted an ID, the CLI wrote to disk. Refresh the editor view.
      try {
        await vscode.commands.executeCommand('workbench.action.files.revert');
      } catch (e) {
        // ignore
      }

      await vscode.env.clipboard.writeText(link);
      vscode.window.showInformationMessage('Org2: copied ID link to clipboard.');
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamCopyIdLinkById', async (id) => {
      const initial = typeof id === 'string' ? String(id).trim() : '';
      let rawInput = initial;
      let uuid = extractRoamUuid(rawInput);

      if (!uuid) {
        const editor = vscode.window.activeTextEditor;
        const selectionText =
          editor && editor.selection && !editor.selection.isEmpty
            ? editor.document.getText(editor.selection)
            : '';
        if (extractRoamUuid(selectionText)) {
          rawInput = String(selectionText || '').trim();
          uuid = extractRoamUuid(rawInput);
        }
      }

      if (!uuid) {
        const input = await vscode.window.showInputBox({
          prompt: 'Org2: Roam — copy ID link for target ID',
          placeHolder: 'UUID, id:UUID, or [[id:UUID][title]]',
          value: rawInput,
          validateInput: (v) => (extractRoamUuid(v) ? undefined : 'Expected UUID or id:UUID link'),
        });
        if (input === undefined) return;
        rawInput = String(input || '').trim();
        uuid = extractRoamUuid(rawInput);
      }

      if (!uuid) {
        vscode.window.showWarningMessage('Org2: invalid ID input (expected UUID or id:UUID link).');
        return;
      }

      const parsedLink = parseRoamIdLink(rawInput);
      let title = parsedLink && parsedLink.title ? parsedLink.title : '';
      if (!title) {
        title = await suggestRoamLinkTitleById(uuid, getRoamIndexRootDir());
      }
      if (!title) title = uuid.slice(0, 8);

      const link = `[[id:${uuid}][${title}]]`;
      await vscode.env.clipboard.writeText(link);
      vscode.window.showInformationMessage(`Org2: copied ID link for id:${uuid}.`);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamInsertBacklink', async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) return;

      const doc = editor.document;
      if (!doc || doc.uri.scheme !== 'file') {
        vscode.window.showWarningMessage('Org2: inserting a backlink requires a file-backed document.');
        return;
      }

      if (doc.isDirty) {
        const ok = await doc.save();
        if (!ok) {
          vscode.window.showWarningMessage('Org2: could not save file before inserting backlink.');
          return;
        }
      }

      const root = getRoamIndexRootDir();
      const selected = editor.selection && !editor.selection.isEmpty ? doc.getText(editor.selection) : '';
      const selectedQuery = String(selected || '').trim().replace(/\s+/g, ' ');
      let chosen = null;

      let candidates = [];
      try {
        candidates = await vscode.window.withProgress(
          { location: vscode.ProgressLocation.Notification, title: 'Org2: indexing roam nodes', cancellable: false },
          async () => collectRoamNodeCandidates(root)
        );
      } catch (e) {
        candidates = [];
      }

      if (Array.isArray(candidates) && candidates.length > 0) {
        const loweredQuery = selectedQuery.toLowerCase();
        const ranked = candidates.slice().sort((a, b) => {
          const aTitle = String(a.title || '').toLowerCase();
          const bTitle = String(b.title || '').toLowerCase();
          const aStarts = loweredQuery && aTitle.startsWith(loweredQuery) ? 1 : 0;
          const bStarts = loweredQuery && bTitle.startsWith(loweredQuery) ? 1 : 0;
          if (aStarts !== bStarts) return bStarts - aStarts;
          const aIncludes = loweredQuery && aTitle.includes(loweredQuery) ? 1 : 0;
          const bIncludes = loweredQuery && bTitle.includes(loweredQuery) ? 1 : 0;
          if (aIncludes !== bIncludes) return bIncludes - aIncludes;
          return aTitle.localeCompare(bTitle);
        });

        const picks = ranked.map((node) => {
          let rel = path.basename(node.file || '');
          try {
            const maybeRel = path.relative(root, node.file || '');
            if (maybeRel && !maybeRel.startsWith('..') && !path.isAbsolute(maybeRel)) rel = maybeRel;
          } catch (_) {
            // ignore
          }
          const shortId = node.id ? String(node.id).slice(0, 8) : '';
          return {
            label: String(node.title || '').trim() || '(untitled)',
            description: `${node.kind === 'headline' ? 'headline' : 'file'} · ${rel}`,
            detail: `${shortId}${typeof node.line0 === 'number' ? ` · L${node.line0 + 1}` : ''}`,
            node,
          };
        });

        const pick = await vscode.window.showQuickPick(picks, {
          placeHolder: 'Org2: Roam — insert backlink target (type to search node title)',
          matchOnDescription: true,
          matchOnDetail: true,
        });
        if (!pick) return;
        chosen = pick.node;
      }

      let id = '';
      let title = '';

      if (chosen) {
        id = String(chosen.id || '').trim().toLowerCase();
        title = String(chosen.title || '').trim();
      } else {
        // Fallback for empty/missing index: preserve previous manual flow.
        const idInput = await vscode.window.showInputBox({
          prompt: 'Org2: Roam — insert backlink target (ID fallback)',
          placeHolder: 'UUID, id:UUID, or [[id:UUID][title]]',
          value: extractRoamUuid(selected) ? String(selected).trim() : '',
          validateInput: (v) => (extractRoamUuid(v) ? undefined : 'Expected UUID or id:UUID link'),
        });
        if (idInput === undefined) return;

        id = extractRoamUuid(idInput);
        if (!id) {
          vscode.window.showWarningMessage('Org2: invalid ID input (expected UUID or id:UUID link).');
          return;
        }

        const parsedLink = parseRoamIdLink(idInput);
        title = (parsedLink && parsedLink.title ? parsedLink.title : '') || await suggestRoamLinkTitleById(id, root) || id.slice(0, 8);
      }

      const linkText = `[[${title}]]`;
      const currentSelection =
        editor.selection && !editor.selection.isEmpty
          ? new vscode.Selection(editor.selection.start, editor.selection.end)
          : null;

      let changed = false;
      await editor.edit((editBuilder) => {
        if (currentSelection) {
          editBuilder.replace(new vscode.Range(currentSelection.start, currentSelection.end), linkText);
        } else {
          editBuilder.insert(editor.selection.active, linkText);
        }
      }).then((ok) => {
        changed = !!ok;
      });

      if (!changed) {
        vscode.window.showWarningMessage('Org2: failed to insert backlink.');
        return;
      }

      await doc.save();
      vscode.window.showInformationMessage('Org2: inserted backlink.');
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.openFileAt', async (file, line0) => {
      try {
        const abs = path.isAbsolute(String(file || '')) ? String(file || '') : path.resolve(getWorkspaceRoot() || process.cwd(), String(file || ''));
        const uri = vscode.Uri.file(abs);
        const doc = await vscode.workspace.openTextDocument(uri);
        const editor = await vscode.window.showTextDocument(doc, { preview: true });

        const line = Math.max(0, Number(line0) || 0);
        const pos = new vscode.Position(line, 0);
        editor.selection = new vscode.Selection(pos, pos);
        revealNavigationPosition(editor, pos);
      } catch (e) {
        vscode.window.showErrorMessage(`Org2: failed to open file: ${String(e && e.message ? e.message : e)}`);
      }
    })
  );

  function formatBacklinkMeta(file, line0, srcId, rootDir) {
    let relPath = path.basename(file);
    try {
      const rel = path.relative(rootDir, file);
      if (rel && !rel.startsWith('..') && !path.isAbsolute(rel)) {
        relPath = rel;
      }
    } catch (_) {
      // ignore
    }

    const shortId = /^([0-9a-fA-F-]{36})$/.test(srcId) ? srcId.slice(0, 8).toLowerCase() : '';
    const meta = `${relPath}:${line0 + 1}${shortId ? ` • ${shortId}` : ''}`;
    return { relPath, meta };
  }

  async function suggestRoamLinkTitleById(id, rootDir) {
    const normalizedId = extractRoamUuid(id);
    if (!normalizedId) return '';

    try {
      const queryArgs = ['query', '--id', normalizedId, '--dir', rootDir, '--recursive', '--format', 'json'];
      const { cmd: queryCmd, args: queryFinalArgs } = resolveOrg2Command(context, queryArgs);
      const { stdout: queryOut } = await execFileAsync(queryCmd, queryFinalArgs, { cwd: rootDir });
      const payload = JSON.parse(String(queryOut || '').trim());
      const results = Array.isArray(payload.results) ? payload.results : [];
      const first = results[0] || null;
      if (!first) return '';

      const title = String(first.title || '').trim();
      if (title) return title;

      const file = String(first.file || '').trim();
      if (file) return path.basename(file).replace(/\.(org2|org)$/i, '');
    } catch (_) {
      // ignore; caller falls back
    }

    return '';
  }

  async function loadBacklinksById(id, rootDir, options = {}) {
    return loadBacklinksByIdWithContext(context, id, rootDir, options);
  }

  async function loadBacklinksForActiveEditor() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) return null;

    const doc = editor.document;
    if (!doc || doc.uri.scheme !== 'file') {
      vscode.window.showWarningMessage('Org2: showing backlinks requires a file-backed document.');
      return null;
    }

    if (doc.isDirty) {
      const ok = await doc.save();
      if (!ok) {
        vscode.window.showWarningMessage('Org2: could not save file before loading backlinks.');
        return null;
      }
    }

    const rootDir = getRoamIndexRootDir();
    const cursor = editor.selection.active;

    const ensureArgs = [
      'id',
      'ensure',
      '--file',
      String(doc.uri.fsPath),
      '--line',
      String(cursor.line + 1),
      '--apply',
      '--format',
      'json',
    ];
    const { cmd: ensureCmd, args: ensureFinalArgs } = resolveOrg2Command(context, ensureArgs);

    let ensureOut;
    try {
      ensureOut = await execFileAsync(ensureCmd, ensureFinalArgs, { cwd: rootDir });
    } catch (e) {
      vscode.window.showErrorMessage(`Org2: failed to ensure ID: ${String(e && e.message ? e.message : e)}`);
      return null;
    }

    let ensurePayload;
    try {
      ensurePayload = JSON.parse(String((ensureOut && ensureOut.stdout) || '').trim());
    } catch (e) {
      vscode.window.showErrorMessage('Org2: failed to parse org2 id ensure output.');
      return null;
    }

    const id = typeof ensurePayload.id === 'string' ? ensurePayload.id : '';
    if (!/^([0-9a-fA-F-]{36})$/.test(id)) {
      vscode.window.showErrorMessage('Org2: org2 id ensure did not return a valid UUID.');
      return null;
    }
    const ensuredKind = ensurePayload.kind === 'headline' ? 'headline' : 'file';

    // If we inserted an ID, the CLI wrote to disk. Refresh the editor view.
    try {
      await vscode.commands.executeCommand('workbench.action.files.revert');
    } catch (_) {
      // ignore
    }

    const loaded = await loadBacklinksById(id.toLowerCase(), rootDir);
    if (!loaded) return null;

    return {
      ...loaded,
      ensuredKind,
    };
  }

  async function pickAndOpenBacklinkSource(loaded, options = {}) {
    const id = String((loaded && loaded.id) || '');
    const backlinks = Array.isArray(loaded && loaded.backlinks) ? loaded.backlinks : [];
    const rootDir = String((loaded && loaded.rootDir) || '');

    if (!backlinks.length) {
      vscode.window.showInformationMessage(`Org2: no backlinks found for id:${id}.`);
      return;
    }

    const picks = backlinks
      .map((b) => {
        const file = String(b.file || '');
        const line0 = typeof b.line === 'number' ? b.line : 0;
        if (!file) return null;

        const srcTitle = String(b.srcTitle || '(untitled)');
        const srcId = typeof b.srcId === 'string' ? b.srcId : '';
        const { meta } = formatBacklinkMeta(file, line0, srcId, rootDir);
        const contextText = sanitizeBacklinkContextText(b.context);
        const firstContextLine = contextText ? contextText.split(/\r?\n/)[0] : '';

        return {
          label: srcTitle,
          description: meta,
          detail: firstContextLine || (srcId ? `id:${srcId.toLowerCase()}` : ''),
          file,
          line0,
        };
      })
      .filter(Boolean);

    if (!picks.length) {
      vscode.window.showInformationMessage('Org2: backlinks found, but no openable source locations were returned.');
      return;
    }

    const defaultPlaceHolder = `Org2: open backlink source for id:${id} (${picks.length} found)`;
    const pick = await vscode.window.showQuickPick(picks, {
      placeHolder: typeof options.placeHolder === 'string' && options.placeHolder.trim() ? options.placeHolder.trim() : defaultPlaceHolder,
      matchOnDescription: true,
      matchOnDetail: true,
    });
    if (!pick) return;

    await vscode.commands.executeCommand('org2.openFileAt', pick.file, pick.line0);
  }

  async function resolveRoamUuidInput(initial, prompt) {
    let uuid = extractRoamUuid(initial);

    if (!uuid) {
      const editor = vscode.window.activeTextEditor;
      const selectionText =
        editor && editor.selection && !editor.selection.isEmpty
          ? editor.document.getText(editor.selection)
          : '';
      uuid = extractRoamUuid(selectionText);
    }

    if (!uuid) {
      const input = await vscode.window.showInputBox({
        prompt,
        placeHolder: 'UUID, id:UUID, or [[id:UUID][title]]',
        value: typeof initial === 'string' ? initial : '',
        validateInput: (v) => (extractRoamUuid(v) ? undefined : 'Expected UUID or id:UUID link'),
      });
      if (input === undefined) return null;
      uuid = extractRoamUuid(input);
    }

    return uuid || '';
  }

  async function showBacklinksDocument(loaded, options = {}) {
    const id = String((loaded && loaded.id) || '');
    const backlinks = Array.isArray(loaded && loaded.backlinks) ? loaded.backlinks : [];
    const rootDir = String((loaded && loaded.rootDir) || '');
    const scopeLabel =
      typeof options.scopeLabel === 'string' && options.scopeLabel.trim() ? options.scopeLabel.trim() : 'target';

    if (backlinks.length === 0) {
      vscode.window.showInformationMessage(`Org2: no backlinks found for id:${id}.`);
      return;
    }

    const lines = [];
    lines.push(`#+TITLE: Backlinks (${backlinks.length})`);
    lines.push('');
    lines.push(`* Backlinks for id:${id} (${scopeLabel})`);
    lines.push('');

    for (const b of backlinks) {
      const file = String(b.file || '');
      const line0 = typeof b.line === 'number' ? b.line : 0;
      const srcTitle = String(b.srcTitle || '(untitled)');
      const srcId = typeof b.srcId === 'string' ? b.srcId : '';
      const { meta } = formatBacklinkMeta(file, line0, srcId, rootDir);

      const payload = encodeURIComponent(JSON.stringify([file, line0]));
      const cmdUrl = `command:org2.openFileAt?${payload}`;

      lines.push(`- [[${cmdUrl}][${srcTitle}]] :: ${meta}`);

      const contextText = sanitizeBacklinkContextText(b.context);
      if (contextText) {
        for (const ln of contextText.split(/\r?\n/)) {
          lines.push(`  ${ln}`);
        }
      }

      if (srcId) {
        lines.push(`  id:${srcId.toLowerCase()}`);
      }

      lines.push('');
    }

    const content = lines.join('\n');
    const viewDoc = await vscode.workspace.openTextDocument({ language: 'org2', content });
    await vscode.window.showTextDocument(viewDoc, { preview: true });
  }

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamOpenBacklink', async () => {
      const loaded = await loadBacklinksForActiveEditor();
      if (!loaded) return;

      await pickAndOpenBacklinkSource(loaded, {
        placeHolder: `Org2: open backlink source for current ${loaded.ensuredKind} (${loaded.backlinks.length} found)`,
      });
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamOpenBacklinkById', async (id) => {
      const uuid = await resolveRoamUuidInput(id, 'Org2: Roam — open backlink source for ID');
      if (uuid === null) return;
      if (!uuid) {
        vscode.window.showWarningMessage('Org2: invalid ID input (expected UUID or id:UUID link).');
        return;
      }

      const loaded = await loadBacklinksById(uuid, getRoamIndexRootDir());
      if (!loaded) return;

      await pickAndOpenBacklinkSource(loaded);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamShowBacklinks', async () => {
      const loaded = await loadBacklinksForActiveEditor();
      if (!loaded) return;

      await showBacklinksDocument(loaded, {
        scopeLabel: `${loaded.ensuredKind}-level`,
      });
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamShowBacklinksById', async (id) => {
      const uuid = await resolveRoamUuidInput(id, 'Org2: Roam — show backlinks for ID');
      if (uuid === null) return;
      if (!uuid) {
        vscode.window.showWarningMessage('Org2: invalid ID input (expected UUID or id:UUID link).');
        return;
      }

      const loaded = await loadBacklinksById(uuid, getRoamIndexRootDir());
      if (!loaded) return;

      await showBacklinksDocument(loaded, {
        scopeLabel: 'prompt/link target',
      });
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamDbSync', async () => {
      const root = getRoamIndexRootDir();
      if (!root) {
        vscode.window.showWarningMessage('Org2: no Roam index dir configured (set org2.roam.indexDir or org2.agenda.dir, or open a workspace).');
        return;
      }

      const cfg = vscode.workspace.getConfiguration('org2');
      const recursive = cfg.get('agenda.recursive', true) ? true : false;

      const previewArgs = buildRoamDbSyncPreviewArgs(root, recursive);

      const { cmd: previewCmd, args: previewFinalArgs } = resolveOrg2Command(context, previewArgs);

      let previewOut;
      try {
        previewOut = await vscode.window.withProgress(
          { location: vscode.ProgressLocation.Notification, title: 'Org2: Roam DB Sync (scan)', cancellable: false },
          async () => await execFileAsync(previewCmd, previewFinalArgs, { cwd: root })
        );
      } catch (e) {
        const stderr = e && e.stderr ? String(e.stderr).trim() : '';
        const extra = stderr ? `\n${stderr}` : '';
        vscode.window.showErrorMessage(`Org2: roam db-sync scan failed: ${String(e && e.message ? e.message : e)}${extra}`);
        return;
      }

      let payload;
      try {
        payload = JSON.parse(String((previewOut && previewOut.stdout) || '').trim());
      } catch (e) {
        vscode.window.showErrorMessage('Org2: failed to parse org2 roam db-sync output.');
        return;
      }

      const missing = Array.isArray(payload.missingFileIds) ? payload.missingFileIds : [];
      if (missing.length === 0) {
        vscode.window.showInformationMessage('Org2: roam db-sync — all scanned files already have file-level IDs.');
        return;
      }

      const listText = missing.map((p) => String(p)).join('\n') + '\n';
      const doc = await vscode.workspace.openTextDocument({ language: 'text', content: listText });
      await vscode.window.showTextDocument(doc, { preview: true, preserveFocus: false });

      const ok = await vscode.window.showWarningMessage(
        `Org2: add file-level IDs to ${missing.length} file(s)? (This will edit files on disk)`,
        { modal: true },
        'Apply'
      );
      if (ok !== 'Apply') return;

      const applyArgs = buildRoamDbSyncApplyArgs(root, recursive);
      const { cmd: applyCmd, args: applyFinalArgs } = resolveOrg2Command(context, applyArgs);

      let applyOut;
      try {
        applyOut = await vscode.window.withProgress(
          { location: vscode.ProgressLocation.Notification, title: 'Org2: Roam DB Sync (apply)', cancellable: false },
          async () => await execFileAsync(applyCmd, applyFinalArgs, { cwd: root })
        );
      } catch (e) {
        const stderr = e && e.stderr ? String(e.stderr).trim() : '';
        const extra = stderr ? `\n${stderr}` : '';
        vscode.window.showErrorMessage(`Org2: roam db-sync apply failed: ${String(e && e.message ? e.message : e)}${extra}`);
        return;
      }

      let applyPayload;
      try {
        applyPayload = JSON.parse(String((applyOut && applyOut.stdout) || '').trim());
      } catch (e) {
        vscode.window.showErrorMessage('Org2: failed to parse org2 roam db-sync apply output.');
        return;
      }

      const appliedCount = typeof applyPayload.appliedCount === 'number' ? applyPayload.appliedCount : 0;
      vscode.window.showInformationMessage(`Org2: roam db-sync — applied IDs to ${appliedCount} file(s).`);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamOpenId', async (id) => {
      const initial = typeof id === 'string' ? String(id) : '';
      let uuid = extractRoamUuid(initial);

      if (!uuid) {
        const editor = vscode.window.activeTextEditor;
        const selectionText =
          editor && editor.selection && !editor.selection.isEmpty
            ? editor.document.getText(editor.selection)
            : '';
        uuid = extractRoamUuid(selectionText);
      }

      if (!uuid) {
        const input = await vscode.window.showInputBox({
          prompt: 'Org2: Roam — open ID link',
          placeHolder: 'UUID, id:UUID, or [[id:UUID][title]]',
          value: initial,
          validateInput: (v) => (extractRoamUuid(v) ? undefined : 'Expected UUID or id:UUID link'),
        });
        if (input === undefined) return;
        uuid = extractRoamUuid(input);
      }

      if (!uuid) {
        vscode.window.showWarningMessage('Org2: invalid ID input (expected UUID or id:UUID link).');
        return;
      }

      const root = getRoamIndexRootDir();

      // Prefer the CLI query (supports file-level + headline IDs, and can return multiple matches).
      let results = [];
      try {
        const queryArgs = ['query', '--id', uuid, '--dir', root, '--recursive', '--format', 'json'];
        const { cmd: queryCmd, args: queryFinalArgs } = resolveOrg2Command(context, queryArgs);
        const { stdout: queryOut } = await execFileAsync(queryCmd, queryFinalArgs, { cwd: root });
        const payload = JSON.parse(String(queryOut || '').trim());
        results = Array.isArray(payload.results) ? payload.results : [];
      } catch (_) {
        // Ignore and fall back to scan-based lookup below.
      }

      // Fallback: slow scan for :ID: lines (kept for robustness if the CLI query fails).
      if (!results.length) {
        const found = await findFirstIdMatchInDir(root, uuid);
        if (!found) {
          vscode.window.showWarningMessage(`Org2: ID not found: ${uuid}`);
          return;
        }
        results = [{ file: found.filePath, line: found.line, title: path.basename(found.filePath) }];
      }

      const picks = results.map((r) => {
        const file = String(r.file || '');
        const line0 = typeof r.line === 'number' ? r.line : 0;
        const title = String(r.title || path.basename(file) || '(untitled)');
        return {
          label: title,
          description: `${path.basename(file)}:${line0 + 1}`,
          file,
          line0,
        };
      });

      const pick =
        picks.length === 1
          ? picks[0]
          : await vscode.window.showQuickPick(picks, {
              placeHolder: `Org2: open ID (${picks.length} matches)`,
              matchOnDescription: true,
            });
      if (!pick) return;

      const uri = vscode.Uri.file(String(pick.file));
      const doc = await vscode.workspace.openTextDocument(uri);
      const editor = await vscode.window.showTextDocument(doc, { preview: true });
      const pos = new vscode.Position(Math.max(0, pick.line0 || 0), 0);
      editor.selection = new vscode.Selection(pos, pos);
      revealNavigationPosition(editor, pos);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamOpenTitle', async (title) => {
      const initial = typeof title === 'string' ? String(title).trim() : '';
      let query = initial;

      if (!query) {
        const input = await vscode.window.showInputBox({
          prompt: 'Org2: Roam — open node by title',
          placeHolder: 'Node title',
          validateInput: (v) => (String(v || '').trim() ? undefined : 'Title is required'),
        });
        if (input === undefined) return;
        query = String(input || '').trim();
      }

      if (!query) return;

      const root = getRoamIndexRootDir();
      let candidates = [];
      try {
        candidates = await collectRoamNodeCandidates(root);
      } catch (_) {
        candidates = [];
      }

      if (!Array.isArray(candidates) || candidates.length === 0) {
        vscode.window.showWarningMessage('Org2: no roam nodes found to resolve title link.');
        return;
      }

      const normalize = (s) => String(s || '').replace(/\s+/g, ' ').trim().toLowerCase();
      const needle = normalize(query);
      const exact = candidates.filter((node) => normalize(node.title) === needle);
      const matches = exact.length ? exact : candidates.filter((node) => normalize(node.title).includes(needle));

      if (!matches.length) {
        vscode.window.showWarningMessage(`Org2: no roam node found for title "${query}".`);
        return;
      }

      const openNode = async (node) => {
        const uri = vscode.Uri.file(String(node.file || ''));
        const doc = await vscode.workspace.openTextDocument(uri);
        const editor = await vscode.window.showTextDocument(doc, { preview: true });
        const pos = new vscode.Position(Math.max(0, Number(node.line0) || 0), 0);
        editor.selection = new vscode.Selection(pos, pos);
        revealNavigationPosition(editor, pos);
      };

      if (matches.length === 1) {
        await openNode(matches[0]);
        return;
      }

      const picks = matches.map((node) => {
        let rel = path.basename(String(node.file || ''));
        try {
          const maybeRel = path.relative(root, String(node.file || ''));
          if (maybeRel && !maybeRel.startsWith('..') && !path.isAbsolute(maybeRel)) rel = maybeRel;
        } catch (_) {
          // ignore
        }
        return {
          label: String(node.title || '').trim() || '(untitled)',
          description: `${node.kind === 'headline' ? 'headline' : 'file'} · ${rel}`,
          detail: node.id ? String(node.id).slice(0, 8) : '',
          node,
        };
      });

      const pick = await vscode.window.showQuickPick(picks, {
        placeHolder: `Org2: choose node for "${query}"`,
        matchOnDescription: true,
        matchOnDetail: true,
      });
      if (!pick) return;
      await openNode(pick.node);
    })
  );

  function getSelectedAgendaItems() {
    return agendaView && Array.isArray(agendaView.selection)
      ? agendaView.selection.filter((x) => x instanceof Org2AgendaItem)
      : [];
  }

  function resolveAgendaMutationTargets(item) {
    const targets = resolveAgendaTargets(getSelectedAgendaItems(), item instanceof Org2AgendaItem ? item : undefined);
    return orderAgendaTargetsForMutation(targets);
  }

  async function promptPlanDate(kind) {
    const normalizedKind = normalizePlanKind(kind);
    const input = await vscode.window.showInputBox({
      prompt: `Org2: set ${String(normalizedKind || kind || '').toUpperCase()} (YYYY-MM-DD)`,
      placeHolder: 'YYYY-MM-DD',
      validateInput: (v) => (normalizePlanDateInput(v) ? undefined : 'Expected YYYY-MM-DD'),
    });
    if (!input) return '';
    return normalizePlanDateInput(input);
  }

  async function applyToggleTodoCommand(item) {
    const targets = resolveAgendaMutationTargets(item);
    if (targets.length > 1) {
      for (const target of targets) {
        await runTodoCli('toggle', undefined, target, { skipAgendaReload: true });
      }
      await agendaProvider.load();
      return;
    }
    await runTodoCli('toggle', undefined, targets[0] || item);
  }

  async function applyArchiveSubtreeCommand(item) {
    const targets = resolveAgendaMutationTargets(item);
    if (targets.length > 1) {
      for (const target of targets) {
        await runArchiveCli(target, { skipAgendaReload: true });
      }
      await agendaProvider.load();
      return;
    }
    await runArchiveCli(targets[0] || item);
  }

  async function applyRefileSubtreeCommand(item) {
    const targets = resolveAgendaMutationTargets(item);
    if (targets.length > 1) {
      for (const target of targets) {
        await runRefileCli(target, { skipAgendaReload: true });
      }
      await agendaProvider.load();
      return;
    }
    await runRefileCli(targets[0] || item);
  }

  async function applyPlanCommand(kind, item, options = {}) {
    const targets = resolveAgendaMutationTargets(item);
    if (targets.length > 1) {
      const runOptions = { ...options };
      const dateOverrideRaw = typeof runOptions.dateOverride === 'string' ? runOptions.dateOverride : '';
      const normalizedDateOverride = normalizePlanDateInput(dateOverrideRaw);
      if (dateOverrideRaw && !normalizedDateOverride) {
        vscode.window.showWarningMessage('Org2: invalid planning date override (expected YYYY-MM-DD).');
        return;
      }

      if (normalizedDateOverride) {
        runOptions.dateOverride = normalizedDateOverride;
      } else if (!runOptions.useToday) {
        const pickedDate = await promptPlanDate(kind);
        if (!pickedDate) return;
        runOptions.dateOverride = pickedDate;
      }

      for (const target of targets) {
        await runPlanCli(kind, target, { ...runOptions, skipAgendaReload: true });
      }
      await agendaProvider.load();
      return;
    }

    await runPlanCli(kind, targets[0] || item, options);
  }

  const applySetTodoStatus = async (status, item) => {
    const requested = String(status || '').trim().toLowerCase();
    const targets = resolveAgendaMutationTargets(item);
    const runSet = async (resolvedStatus) => {
      if (targets.length > 1) {
        for (const target of targets) {
          await runTodoCli('set', resolvedStatus, target, { skipAgendaReload: true });
        }
        await agendaProvider.load();
        return;
      }
      await runTodoCli('set', resolvedStatus, targets[0] || item);
    };

    const normalizedRequested = normalizeTodoStatusValue(requested);
    if (normalizedRequested) {
      await runSet(normalizedRequested);
      return;
    }

    const pick = await vscode.window.showQuickPick(
      [
        { label: 'TODO', value: 'todo' },
        { label: 'IN_PROGRESS', value: 'in_progress' },
        { label: 'DONE', value: 'done' },
        { label: 'CANCELED', value: 'canceled' },
      ],
      { placeHolder: 'Org2: set todo status' }
    );
    if (!pick) return;
    await runSet(pick.value);
  };

  async function insertListItemBelow() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) return;

    const doc = editor.document;
    const line = editor.selection && editor.selection.active ? editor.selection.active.line : 0;
    const lineText = doc.lineAt(line).text;

    const prefix = buildInsertedListItemPrefix(lineText);

    const insertPos = doc.lineAt(line).range.end;
    const ok = await editor.edit((editBuilder) => {
      editBuilder.insert(insertPos, `\n${prefix}`);
    });
    if (!ok) return;

    const target = new vscode.Position(line + 1, prefix.length);
    editor.selection = new vscode.Selection(target, target);
    editor.revealRange(new vscode.Range(target, target));
  }

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.toggleTodo', async (item) => {
      await applyToggleTodoCommand(item);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.insertListItemBelow', async () => {
      await insertListItemBelow();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setTodoStatus', async (argOrItem, maybeItem) => {
      const requested = argOrItem && typeof argOrItem === 'object' && Object.prototype.hasOwnProperty.call(argOrItem, 'status')
        ? argOrItem.status
        : '';
      const item = requested ? maybeItem : argOrItem;
      await applySetTodoStatus(requested, item);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setPriority', async (argOrItem, maybeItem) => {
      const requested = argOrItem && typeof argOrItem === 'object' && Object.prototype.hasOwnProperty.call(argOrItem, 'priority')
        ? argOrItem.priority
        : '';
      const item = requested !== '' ? maybeItem : argOrItem;

      let priority = normalizeOrgPriorityToken(requested);
      if (requested === '' || (!priority && requested !== '')) {
        const pick = await vscode.window.showQuickPick(
          [
            { label: 'Priority A', value: 'A' },
            { label: 'Priority B', value: 'B' },
            { label: 'Priority C', value: 'C' },
            { label: 'Clear priority', value: '' },
          ],
          { placeHolder: 'Org2: set headline priority' }
        );
        if (!pick) return;
        priority = normalizeOrgPriorityToken(pick.value);
      }

      const targets = resolveAgendaMutationTargets(item);
      if (targets.length > 1) {
        for (const target of targets) {
          await runSetPriority(priority, target, { skipAgendaReload: true });
        }
        await agendaProvider.load();
        return;
      }

      await runSetPriority(priority, targets[0] || item);
    })
  );

  context.subscriptions.push(vscode.commands.registerCommand('org2.setTodoTODO', async (item) => applySetTodoStatus('todo', item)));
  context.subscriptions.push(vscode.commands.registerCommand('org2.setTodoInProgress', async (item) => applySetTodoStatus('in_progress', item)));
  context.subscriptions.push(vscode.commands.registerCommand('org2.setTodoDone', async (item) => applySetTodoStatus('done', item)));
  context.subscriptions.push(vscode.commands.registerCommand('org2.setTodoCanceled', async (item) => applySetTodoStatus('canceled', item)));

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setScheduled', async (item) => {
      await applyPlanCommand('scheduled', item);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setDeadline', async (item) => {
      await applyPlanCommand('deadline', item);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setScheduledToday', async (item) => {
      await applyPlanCommand('scheduled', item, { useToday: true });
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setScheduledTomorrow', async (item) => {
      const d = new Date();
      d.setDate(d.getDate() + 1);
      await applyPlanCommand('scheduled', item, { dateOverride: formatDateYYYYMMDD(d) });
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setScheduledNextWeek', async (item) => {
      const d = new Date();
      // "Next week" means the upcoming Monday, not "in 7 days".
      const weekday = d.getDay(); // 0=Sun, 1=Mon, ... 6=Sat
      const daysUntilMonday = (8 - weekday) % 7 || 7;
      d.setDate(d.getDate() + daysUntilMonday);
      await applyPlanCommand('scheduled', item, { dateOverride: formatDateYYYYMMDD(d) });
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setScheduledNextMonth', async (item) => {
      const d = new Date();
      d.setMonth(d.getMonth() + 1);
      await applyPlanCommand('scheduled', item, { dateOverride: formatDateYYYYMMDD(d) });
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setDeadlineToday', async (item) => {
      await applyPlanCommand('deadline', item, { useToday: true });
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.cryptDecryptSubtree', async (item) => {
      await runCryptCli('decrypt', item);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.cryptEncryptSubtree', async (item) => {
      await runCryptCli('encrypt', item);
    })
  );

  // Style [[url][desc]] links for readability without changing underlying text layout.
  const org2LinkDescDecoration = vscode.window.createTextEditorDecorationType({
    color: new vscode.ThemeColor('textLink.foreground'),
    textDecoration: 'underline',
  });
  const org2LinkRawDecoration = vscode.window.createTextEditorDecorationType({
    opacity: '0.65',
  });

  const org2TodoStateDecoration = vscode.window.createTextEditorDecorationType({
    fontWeight: '700',
    borderRadius: '3px',
    padding: '0 4px',
  });

  function updateTodoStateDecorations(editor) {
    if (!editor) return;
    const doc = editor.document;
    if (!doc) return;
    if (doc.languageId !== 'org2' && doc.languageId !== 'org') return;

    const options = [];
    const re = /^(\*+)\s+([A-Z][A-Z0-9_\-]*)\b/;

    for (let line = 0; line < doc.lineCount; line++) {
      const text = doc.lineAt(line).text;
      const m = re.exec(text);
      if (!m) continue;

      const state = (m[2] || '').toUpperCase();
      const statusBucket = agendaStatusBucket(state);
      if (statusBucket !== 'todo' && statusBucket !== 'inProgress' && statusBucket !== 'done' && statusBucket !== 'canceled') {
        continue;
      }

      const start = m[1].length + 1;
      const end = start + m[2].length;
      const palette = statusBucket === 'todo'
        ? { color: '#111111', backgroundColor: '#ffcc66', border: '1px solid rgba(0,0,0,0.25)' }
        : statusBucket === 'inProgress'
          ? { color: '#ffffff', backgroundColor: '#2563eb', border: '1px solid rgba(255,255,255,0.22)' }
          : { color: '#052e16', backgroundColor: '#86efac', border: '1px solid rgba(0,0,0,0.22)' };

      options.push({
        range: new vscode.Range(line, start, line, end),
        renderOptions: palette,
      });
    }

    editor.setDecorations(org2TodoStateDecoration, options);
  }

  function updateLinkDecorations(editor) {
    if (!editor) return;
    const doc = editor.document;
    if (!doc) return;
    if (doc.languageId !== 'org2' && doc.languageId !== 'org') return;

    const cfg = vscode.workspace.getConfiguration('org2');
    const renderDescribedLinks = cfg.get('links.renderDescriptions', false);
    const renderMode = String(cfg.get('links.renderDescriptionsMode', 'safe') || 'safe').toLowerCase();
    if (!renderDescribedLinks) {
      editor.setDecorations(org2LinkDescDecoration, []);
      editor.setDecorations(org2LinkRawDecoration, []);
      return;
    }

    const descOptions = [];
    const rawOptions = [];
    // Only match described links: [[url][desc]]
    const org2LinkDescRe = /\[\[([^\]\n]+?)\]\[([^\]\n]*)\]\]/g;

    for (let line = 0; line < doc.lineCount; line++) {
      const text = doc.lineAt(line).text;
      org2LinkDescRe.lastIndex = 0;
      let m;
      while ((m = org2LinkDescRe.exec(text)) !== null) {
        const start = m.index;
        const end = m.index + m[0].length;
        const rawUrl = m[1];
        const desc = m[2] || '';

        if (!desc.trim()) continue;

        if (renderMode !== 'full') {
          // safe/full currently share layout-safe styling behavior.
        }

        const target = resolveOrg2LinkTarget(rawUrl, doc);
        const hover = target
          ? new vscode.MarkdownString(`[${desc}](${target.toString(true)})`)
          : new vscode.MarkdownString(desc);
        hover.isTrusted = true;

        const descStart = start + 2 + rawUrl.length + 2; // [[url][
        const descEnd = descStart + desc.length;
        if (descEnd <= end - 2) {
          descOptions.push({
            range: new vscode.Range(line, descStart, line, descEnd),
            hoverMessage: hover,
          });
        }

        // Dim only the raw URL portion inside [[url][desc]] to make description stand out.
        const rawStart = start + 2;
        const rawEnd = rawStart + rawUrl.length;
        if (rawEnd <= end) {
          rawOptions.push({
            range: new vscode.Range(line, rawStart, line, rawEnd),
            hoverMessage: hover,
          });
        }
      }
    }

    editor.setDecorations(org2LinkDescDecoration, descOptions);
    editor.setDecorations(org2LinkRawDecoration, rawOptions);
  }

  // Fold headings + :PROPERTIES: drawers by default (once per document URI).
  const autoFoldedForDoc = new Set();

  const maybeAutoFold = async (editor) => {
    if (!editor) return;
    const doc = editor.document;
    if (!doc) return;
    if (doc.languageId !== 'org2' && doc.languageId !== 'org') return;

    const key = doc.uri.toString();
    if (autoFoldedForDoc.has(key)) return;

    const cfg = vscode.workspace.getConfiguration('org2');
    const maxLevel = cfg.get('folding.autoFoldMaxHeadingLevel', 1);
    const foldPropertyDrawers = cfg.get('folding.autoFoldPropertyDrawers', true);

    const startLines = [
      ...findHeadingLinesAtLevel(doc, maxLevel),
      ...(foldPropertyDrawers ? findPropertyDrawerStartLines(doc) : []),
    ];

    // Mark before folding to avoid repeated attempts on rapid focus changes.
    autoFoldedForDoc.add(key);

    if (startLines.length === 0) return;

    // Defer folding slightly to allow VS Code to compute folding ranges.
    setTimeout(() => {
      vscode.commands.executeCommand('editor.fold', { selectionLines: startLines });
    }, 0);
  };

  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor((editor) => {
      maybeAutoFold(editor);
      updateLinkDecorations(editor);
      updateTodoStateDecorations(editor);
      backlinksProvider.loadForEditor(editor, { focusView: false }).catch(() => {});
    })
  );

  // If folding-related configuration changes, allow auto-folding to run again.
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (
        e.affectsConfiguration('org2.folding.autoFoldMaxHeadingLevel') ||
        e.affectsConfiguration('org2.folding.autoFoldPropertyDrawers')
      ) {
        autoFoldedForDoc.clear();
        vscode.window.visibleTextEditors.forEach((ed) => maybeAutoFold(ed));
      }
      if (
        e.affectsConfiguration('org2.roam.indexDir') ||
        e.affectsConfiguration('org2.roam.dailiesDir') ||
        e.affectsConfiguration('org2.roam.nodesDir') ||
        e.affectsConfiguration('org2.agenda.dir')
      ) {
        backlinksProvider.loadForEditor(vscode.window.activeTextEditor, { focusView: false }).catch(() => {});
      }
      if (
        e.affectsConfiguration('org2.links.renderDescriptions') ||
        e.affectsConfiguration('org2.links.renderDescriptionsMode')
      ) {
        vscode.window.visibleTextEditors.forEach((ed) => updateLinkDecorations(ed));
      }
    })
  );

  // Also attempt folding for already-visible editors at activation.
  vscode.window.visibleTextEditors.forEach((ed) => {
    maybeAutoFold(ed);
    updateLinkDecorations(ed);
    updateTodoStateDecorations(ed);
  });
  backlinksProvider.loadForEditor(vscode.window.activeTextEditor, { focusView: false }).catch(() => {});

  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument((doc) => {
      const editor = vscode.window.visibleTextEditors.find((e) => e.document === doc);
      if (editor) {
        maybeAutoFold(editor);
        updateLinkDecorations(editor);
        updateTodoStateDecorations(editor);
      }
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((doc) => {
      const active = vscode.window.activeTextEditor;
      if (!active || !active.document) return;
      if (active.document.uri.toString() !== doc.uri.toString()) return;
      backlinksProvider.loadForEditor(active, { focusView: false }).catch(() => {});
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeTextDocument((e) => {
      const editor = vscode.window.visibleTextEditors.find((ed) => ed.document === e.document);
      if (editor) {
        updateLinkDecorations(editor);
        updateTodoStateDecorations(editor);
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.rerunAutoFold', () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) {
        vscode.window.showInformationMessage('Org2: no active editor');
        return;
      }
      const doc = editor.document;
      if (!doc) return;

      autoFoldedForDoc.delete(doc.uri.toString());
      maybeAutoFold(editor);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.debugFoldingRanges', () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) {
        vscode.window.showInformationMessage('Org2: no active editor');
        return;
      }
      const doc = editor.document;
      const ranges = provideFoldingRanges(doc);
      const preview = ranges
        .slice(0, 12)
        .map((r) => `[${r.start + 1}-${r.end + 1}]`)
        .join(' ');

      vscode.window.showInformationMessage(
        `Org2: folding ranges=${ranges.length}${preview ? ' ' + preview : ''}`
      );
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.debugListLinks', () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) {
        vscode.window.showInformationMessage('Org2: no active editor');
        return;
      }
      const doc = editor.document;
      const links = provideDocumentLinks(doc);

      const out = vscode.window.createOutputChannel('Org2');
      out.appendLine(`Found ${links.length} links in ${doc.uri.toString()}`);
      for (const l of links) {
        out.appendLine(
          `- L${l.range.start.line + 1}:${l.range.start.character}-${l.range.end.character} -> ${
            l.target ? l.target.toString(true) : '(no target)'
          }`
        );
      }
      out.show(true);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.toggleFoldHere', () => {
      // Use the built-in fold toggle at the cursor.
      vscode.commands.executeCommand('editor.toggleFold');
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
