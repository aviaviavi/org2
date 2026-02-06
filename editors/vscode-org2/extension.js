const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const cp = require('child_process');

const headingRe = /^(\*+)\s+/;
const listItemRe = /^(\s*)(?:[-+*]|\d+[.)])\s+/;
const propertiesBeginRe = /^\s*:PROPERTIES:\s*$/i;
const drawerEndRe = /^\s*:END:\s*$/i;

function findHeadingLinesAtLevel(document, level) {
  if (typeof level !== 'number' || level <= 0) return [];

  const starts = [];
  for (let i = 0; i < document.lineCount; i++) {
    const text = document.lineAt(i).text;
    const m = headingRe.exec(text);
    if (m && m[1].length === level) starts.push(i);
  }
  return starts;
}

function findPropertyDrawerStartLines(document) {
  const starts = [];
  const lineCount = document.lineCount;

  let inProperties = false;
  for (let i = 0; i < lineCount; i++) {
    const text = document.lineAt(i).text;

    if (!inProperties && propertiesBeginRe.test(text)) {
      inProperties = true;
      starts.push(i);
      continue;
    }

    if (inProperties && drawerEndRe.test(text)) {
      inProperties = false;
    }
  }

  return starts;
}

function provideFoldingRanges(document) {
  const lineCount = document.lineCount;
  const folds = [];

  const headingStack = [];
  const listStack = [];

  // :PROPERTIES: drawers only (do not fold arbitrary drawers).
  const propertiesStack = [];

  const flushStackTo = (stack, endLine) => {
    while (stack.length > 0) {
      const top = stack.pop();
      if (endLine > top.startLine) {
        folds.push(new vscode.FoldingRange(top.startLine, endLine, top.kind));
      }
    }
  };

  const closeHeadingsToLevel = (level, endLine) => {
    while (headingStack.length > 0 && headingStack[headingStack.length - 1].level >= level) {
      const top = headingStack.pop();
      const foldEnd = endLine;
      if (foldEnd > top.startLine) {
        folds.push(new vscode.FoldingRange(top.startLine, foldEnd, vscode.FoldingRangeKind.Region));
      }
    }
  };

  const closeListsToIndent = (indent, endLine) => {
    while (listStack.length > 0 && listStack[listStack.length - 1].indent >= indent) {
      const top = listStack.pop();
      if (endLine > top.startLine) {
        folds.push(new vscode.FoldingRange(top.startLine, endLine, vscode.FoldingRangeKind.Region));
      }
    }
  };

  const closePropertiesTo = (endLine) => {
    while (propertiesStack.length > 0) {
      const top = propertiesStack.pop();
      if (endLine > top.startLine) {
        folds.push(new vscode.FoldingRange(top.startLine, endLine, vscode.FoldingRangeKind.Region));
      }
    }
  };

  for (let i = 0; i < lineCount; i++) {
    const text = document.lineAt(i).text;

    // Property drawer folding (:PROPERTIES: ... :END:)
    if (propertiesBeginRe.test(text)) {
      propertiesStack.push({ startLine: i, kind: vscode.FoldingRangeKind.Region });
      continue;
    }
    if (drawerEndRe.test(text) && propertiesStack.length > 0) {
      const top = propertiesStack.pop();
      if (i > top.startLine) {
        folds.push(new vscode.FoldingRange(top.startLine, i, vscode.FoldingRangeKind.Region));
      }
      continue;
    }

    const headingMatch = headingRe.exec(text);
    if (headingMatch) {
      flushStackTo(listStack, i - 1);
      const level = headingMatch[1].length;
      closeHeadingsToLevel(level, i - 1);
      headingStack.push({ level, startLine: i, kind: vscode.FoldingRangeKind.Region });
      continue;
    }

    const listMatch = listItemRe.exec(text);
    if (listMatch) {
      const indent = listMatch[1].length;

      // If a list starts at or above a previous list indent, close previous list folds.
      closeListsToIndent(indent, i - 1);
      listStack.push({ indent, startLine: i, kind: vscode.FoldingRangeKind.Region });
      continue;
    }

    // Close list folds when leaving list indentation (blank lines included).
    if (text.trim().length === 0) {
      continue;
    }

    // Non-list content at indentation 0 closes any top-level lists.
    if (!/^\s+/.test(text)) {
      closeListsToIndent(0, i - 1);
    }
  }

  flushStackTo(listStack, lineCount - 1);
  closeHeadingsToLevel(1, lineCount - 1);
  closePropertiesTo(lineCount - 1);

  return folds;
}

function resolveOrg2LinkTarget(rawUrl, document) {
  const url = (rawUrl || '').trim();
  if (!url) return undefined;

  // Org Roam id: links (id:<uuid>) → dispatch to our command.
  // VS Code's default URL handler can't open these.
  const idMatch = /^id:([0-9a-fA-F-]{36})$/.exec(url);
  if (idMatch) {
    const id = idMatch[1].toLowerCase();
    const payload = encodeURIComponent(JSON.stringify([id]));
    return vscode.Uri.parse(`command:org2.roamOpenId?${payload}`);
  }

  // Heuristic: if it looks like it has a scheme, let VS Code/URI parser handle it.
  // Examples: https://..., http://..., mailto:..., file:..., vscode:...
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(url)) {
    try {
      return vscode.Uri.parse(url, true);
    } catch (e) {
      return undefined;
    }
  }

  // Otherwise treat it as a filesystem path relative to the current document.
  if (document.uri && document.uri.scheme === 'file') {
    const baseDir = path.dirname(document.uri.fsPath);
    const fsPath = path.resolve(baseDir, url);
    return vscode.Uri.file(fsPath);
  }

  return undefined;
}

function provideDocumentLinks(document) {
  const links = [];

  // Org2 links: [[url]] or [[url][desc]]
  const org2LinkRe = /\[\[([^\]\n]+?)\](?:\[([^\]\n]*)\])?\]\]/g;
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
        const target = resolveOrg2LinkTarget(targetUrl, document);
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
  constructor({ todo, headline, kind, file, line, date }) {
    this.todo = todo || '';
    this.headline = headline || '';
    this.kind = kind || '';
    this.file = file;
    this.line = typeof line === 'number' ? line : 0;
    this.date = date;
  }
}

class Org2AgendaProvider {
  constructor(context) {
    this.context = context;
    this._onDidChangeTreeData = new vscode.EventEmitter();
    this.onDidChangeTreeData = this._onDidChangeTreeData.event;

    this.filter = { type: 'next', days: 7 };
    this.groups = [];
    this.lastError = undefined;
  }

  refresh() {
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
      const label = `${element.todo ? element.todo + ' ' : ''}${element.headline}`.trim() || '(untitled)';
      const item = new vscode.TreeItem(label, vscode.TreeItemCollapsibleState.None);
      item.description = element.kind;
      item.contextValue = 'org2AgendaItem';
      item.command = {
        command: 'org2.openAgendaItem',
        title: 'Open',
        arguments: [element],
      };
      item.tooltip = `${element.file}:${element.line + 1}`;
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

function getRoamDailiesRootDir() {
  const cfg = vscode.workspace.getConfiguration('org2');
  const configured = String(cfg.get('roam.dailiesDir', '') || '').trim();
  if (configured) return configured;
  return getAgendaRootDir();
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

async function fetchAgendaGroups(context, filter) {
  const cfg = vscode.workspace.getConfiguration('org2');
  const cwd = getWorkspaceRoot() || process.cwd();
  const agendaRoot = getAgendaRootDir();

  const scope = cfg.get('agenda.scope', 'workspace');
  const files = cfg.get('agenda.files', []);
  const includeOverdue = cfg.get('agenda.includeOverdue', true);
  const defaultDays = cfg.get('agenda.days', 7);

  const days = filter && filter.type === 'today' ? 1 : (filter && filter.type === 'next' ? filter.days : defaultDays);

  const args = ['agenda'];
  if (scope === 'files') {
    const resolved = resolveAgendaFiles(files, agendaRoot);
    if (resolved.length === 0) {
      vscode.window.showWarningMessage("Org2 agenda: org2.agenda.files is empty (set scope to 'workspace' or configure files).");
    }
    if (resolved.length > 0) args.push('--files', ...resolved);
  } else {
    const recursive = cfg.get('agenda.recursive', true);
    args.push('--dir', agendaRoot);
    if (recursive) args.push('--recursive');
  }

  args.push('--days', String(days), '--format', 'json');
  if (!includeOverdue) args.push('--no-overdue');

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

  const groups = [];
  const pushDay = (d, isOverdue) => {
    const items = (d.items || []).map(
      (it) =>
        new Org2AgendaItem({
          ...it,
          date: d.date,
        })
    );
    const label = `${d.weekday || ''} ${d.date || ''}`.trim();
    groups.push(new Org2AgendaGroup(isOverdue ? `Overdue: ${label}` : label, d.date, d.weekday, isOverdue, items));
  };

  const hasOverdue = Array.isArray(data.overdue) && data.overdue.length > 0;
  const hasUpcoming = Array.isArray(data.days) && data.days.length > 0;

  if (hasOverdue) {
    for (const d of data.overdue) pushDay(d, true);
  }

  if (hasOverdue && hasUpcoming) {
    groups.push(new Org2AgendaSeparator('──────── Upcoming ────────'));
  }

  if (hasUpcoming) {
    for (const d of data.days) pushDay(d, false);
  }

  return groups;
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
  editor.revealRange(new vscode.Range(pos, pos), vscode.TextEditorRevealType.InCenter);
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

  async function formatOrg2Text(text) {
    const cwd = getWorkspaceRoot() || process.cwd();
    const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, ['fmt', '--stdin']);

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
          reject(e);
          return;
        }
        resolve(stdout);
      });

      child.stdin.end(text, 'utf8');
    });
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
  });
  context.subscriptions.push(agendaView);

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
    vscode.commands.registerCommand('org2.pickAgendaFilter', async () => {
      await pickAgendaFilter(agendaProvider);
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

  async function runTodoCli(action, status, item) {
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

    const args = ['todo', action, '--file', String(filePath), '--line', String(line), '--format', 'json', '--apply'];
    if (action === 'set' && status) args.push('--status', status);

    const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, args);

    try {
      await execFileAsync(finalCmd, finalArgs, { cwd: getAgendaRootDir() });
      // Reload from disk to show changes made by the CLI.
      await vscode.commands.executeCommand('workbench.action.files.revert');
    } catch (e) {
      vscode.window.showErrorMessage(`Org2: todo update failed: ${String(e && e.message ? e.message : e)}`);
    }
  }

  async function runPlanCli(kind, item) {
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

    const date = await vscode.window.showInputBox({
      prompt: `Org2: set ${kind.toUpperCase()} (YYYY-MM-DD)`,
      placeHolder: 'YYYY-MM-DD',
      validateInput: (v) => (/^\d{4}-\d{2}-\d{2}$/.test((v || '').trim()) ? undefined : 'Expected YYYY-MM-DD'),
    });
    if (!date) return;

    const args = [
      'plan',
      'set',
      '--file',
      String(filePath),
      '--line',
      String(line),
      '--kind',
      kind,
      '--date',
      String(date).trim(),
      '--format',
      'json',
      '--apply',
    ];

    const cwd = getWorkspaceRoot() || process.cwd();
    const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, args);

    try {
      await execFileAsync(finalCmd, finalArgs, { cwd: getAgendaRootDir() });
      await vscode.commands.executeCommand('workbench.action.files.revert');
    } catch (e) {
      vscode.window.showErrorMessage(`Org2: planning update failed: ${String(e && e.message ? e.message : e)}`);
    }
  }

  async function runArchiveCli(item) {
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
      await vscode.commands.executeCommand('workbench.action.files.revert');
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
      await runArchiveCli(item);
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
        out = await execFileAsync(finalCmd, finalArgs, { cwd: getAgendaRootDir() });
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

      const id = await vscode.window.showInputBox({
        prompt: 'Org2: Roam — insert backlink (id:...)',
        placeHolder: 'UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)',
        validateInput: (v) => {
          const s = String(v || '').trim();
          return /^([0-9a-fA-F-]{36})$/.test(s) ? undefined : 'Expected a UUID';
        },
      });
      if (!id) return;

      const title = await vscode.window.showInputBox({
        prompt: 'Org2: Roam — backlink title',
        placeHolder: 'Link text',
        value: '',
      });
      if (title === undefined) return;

      const cursor = editor.selection.active;
      const pos = `${cursor.line + 1}:${cursor.character}`;

      const args = [
        'roam',
        'link',
        'insert-backlink',
        '--file',
        String(doc.uri.fsPath),
        '--pos',
        String(pos),
        '--id',
        String(id).trim().toLowerCase(),
        '--title',
        String(title),
        '--format',
        'json',
        '--apply',
      ];

      const { cmd: finalCmd, args: finalArgs } = resolveOrg2Command(context, args);

      let out;
      try {
        out = await execFileAsync(finalCmd, finalArgs, { cwd: getAgendaRootDir() });
      } catch (e) {
        vscode.window.showErrorMessage(`Org2: failed to insert backlink: ${String(e && e.message ? e.message : e)}`);
        return;
      }

      try {
        JSON.parse(String((out && out.stdout) || '').trim());
      } catch (e) {
        vscode.window.showErrorMessage('Org2: failed to parse org2 roam link output.');
        return;
      }

      // CLI wrote to disk; refresh the editor view.
      try {
        await vscode.commands.executeCommand('workbench.action.files.revert');
      } catch (e) {
        // ignore
      }

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
        editor.revealRange(new vscode.Range(pos, pos), vscode.TextEditorRevealType.InCenter);
      } catch (e) {
        vscode.window.showErrorMessage(`Org2: failed to open file: ${String(e && e.message ? e.message : e)}`);
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamShowBacklinks', async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) return;

      const doc = editor.document;
      if (!doc || doc.uri.scheme !== 'file') {
        vscode.window.showWarningMessage('Org2: showing backlinks requires a file-backed document.');
        return;
      }

      if (doc.isDirty) {
        const ok = await doc.save();
        if (!ok) {
          vscode.window.showWarningMessage('Org2: could not save file before loading backlinks.');
          return;
        }
      }

      const cursorLine = editor.selection.active.line;
      const ensureArgs = [
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
      const { cmd: ensureCmd, args: ensureFinalArgs } = resolveOrg2Command(context, ensureArgs);

      let ensureOut;
      try {
        ensureOut = await execFileAsync(ensureCmd, ensureFinalArgs, { cwd: getAgendaRootDir() });
      } catch (e) {
        vscode.window.showErrorMessage(`Org2: failed to ensure ID: ${String(e && e.message ? e.message : e)}`);
        return;
      }

      let ensurePayload;
      try {
        ensurePayload = JSON.parse(String((ensureOut && ensureOut.stdout) || '').trim());
      } catch (e) {
        vscode.window.showErrorMessage('Org2: failed to parse org2 id ensure output.');
        return;
      }

      const id = typeof ensurePayload.id === 'string' ? ensurePayload.id : '';
      if (!/^([0-9a-fA-F-]{36})$/.test(id)) {
        vscode.window.showErrorMessage('Org2: org2 id ensure did not return a valid UUID.');
        return;
      }

      // If we inserted an ID, the CLI wrote to disk. Refresh the editor view.
      try {
        await vscode.commands.executeCommand('workbench.action.files.revert');
      } catch (_) {
        // ignore
      }

      const backlinksArgs = ['roam', 'backlinks', '--id', id.toLowerCase(), '--dir', getAgendaRootDir(), '--recursive', '--format', 'json'];
      const { cmd: backlinksCmd, args: backlinksFinalArgs } = resolveOrg2Command(context, backlinksArgs);

      let backlinksOut;
      try {
        backlinksOut = await execFileAsync(backlinksCmd, backlinksFinalArgs, { cwd: getAgendaRootDir() });
      } catch (e) {
        vscode.window.showErrorMessage(`Org2: failed to load backlinks: ${String(e && e.message ? e.message : e)}`);
        return;
      }

      let payload;
      try {
        payload = JSON.parse(String((backlinksOut && backlinksOut.stdout) || '').trim());
      } catch (e) {
        vscode.window.showErrorMessage('Org2: failed to parse org2 backlinks output.');
        return;
      }

      const backlinks = Array.isArray(payload.backlinks) ? payload.backlinks : [];
      if (backlinks.length === 0) {
        vscode.window.showInformationMessage('Org2: no backlinks found.');
        return;
      }

      const rootDir = getAgendaRootDir();

      const lines = [];
      lines.push(`#+TITLE: Backlinks (${backlinks.length})`);
      lines.push('');
      lines.push(`* Backlinks for id:${id.toLowerCase()}`);
      lines.push('');

      for (const b of backlinks) {
        const file = String(b.file || '');
        const line0 = typeof b.line === 'number' ? b.line : 0;
        const srcTitle = String(b.srcTitle || '(untitled)');

        let relPath = path.basename(file);
        try {
          const rel = path.relative(rootDir, file);
          if (rel && !rel.startsWith('..') && !path.isAbsolute(rel)) {
            relPath = rel;
          }
        } catch (_) {
          // ignore
        }

        const payload = encodeURIComponent(JSON.stringify([file, line0]));
        const cmdUrl = `command:org2.openFileAt?${payload}`;

        const srcId = typeof b.srcId === 'string' ? b.srcId : '';
        const shortId = /^([0-9a-fA-F-]{36})$/.test(srcId) ? srcId.slice(0, 8).toLowerCase() : '';
        const meta = `${relPath}:${line0 + 1}${shortId ? ` • ${shortId}` : ''}`;

        lines.push(`- [[${cmdUrl}][${srcTitle}]] :: ${meta}`);

        const contextText = String(b.context || '').trim();
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
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.roamDbSync', async () => {
      const root = getAgendaRootDir();
      if (!root) {
        vscode.window.showWarningMessage('Org2: no agenda root dir configured (set org2.agenda.dir or open a workspace).');
        return;
      }

      const cfg = vscode.workspace.getConfiguration('org2');
      const recursive = cfg.get('agenda.recursive', true) ? true : false;

      const previewArgs = ['roam', 'db-sync', '--dir', root, '--format', 'json'];
      if (recursive) previewArgs.push('--recursive');

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

      const applyArgs = ['roam', 'db-sync', '--dir', root, '--format', 'json', '--apply'];
      if (recursive) applyArgs.push('--recursive');
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
      const raw = (typeof id === 'string' ? id : '').trim();
      const m = /^([0-9a-fA-F-]{36})$/.exec(raw);
      if (!m) {
        vscode.window.showWarningMessage('Org2: invalid id link (expected UUID).');
        return;
      }

      const root = getAgendaRootDir();
      const uuid = m[1].toLowerCase();

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
          vscode.window.showWarningMessage(`Org2: ID not found: ${m[1]}`);
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
      editor.revealRange(new vscode.Range(pos, pos), vscode.TextEditorRevealType.InCenter);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.toggleTodo', async (item) => {
      await runTodoCli('toggle', undefined, item);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setTodoStatus', async () => {
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
      await runTodoCli('set', pick.value);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setScheduled', async (item) => {
      await runPlanCli('scheduled', item);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('org2.setDeadline', async (item) => {
      await runPlanCli('deadline', item);
    })
  );

  // Render [[url][desc]] links as "desc" (best-effort) using decorations.
  // Note: VS Code decorations cannot truly replace/collapse text width, so we hide
  // the underlying link token and draw the description as a prefix.
  const org2LinkDescDecoration = vscode.window.createTextEditorDecorationType({
    color: 'rgba(0,0,0,0)',
    textDecoration: 'none',
  });

  function updateLinkDecorations(editor) {
    if (!editor) return;
    const doc = editor.document;
    if (!doc) return;
    if (doc.languageId !== 'org2' && doc.languageId !== 'org') return;

    const options = [];
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

        const target = resolveOrg2LinkTarget(rawUrl, doc);
        const hover = target
          ? new vscode.MarkdownString(`[${desc}](${target.toString(true)})`)
          : new vscode.MarkdownString(desc);
        hover.isTrusted = true;

        options.push({
          range: new vscode.Range(line, start, line, end),
          hoverMessage: hover,
          renderOptions: {
            before: {
              contentText: desc,
              color: new vscode.ThemeColor('textLink.foreground'),
              textDecoration: 'underline',
            },
          },
        });
      }
    }

    editor.setDecorations(org2LinkDescDecoration, options);
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
    })
  );

  // Also attempt folding for already-visible editors at activation.
  vscode.window.visibleTextEditors.forEach((ed) => {
    maybeAutoFold(ed);
    updateLinkDecorations(ed);
  });

  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument((doc) => {
      const editor = vscode.window.visibleTextEditors.find((e) => e.document === doc);
      if (editor) {
        maybeAutoFold(editor);
        updateLinkDecorations(editor);
      }
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeTextDocument((e) => {
      const editor = vscode.window.visibleTextEditors.find((ed) => ed.document === e.document);
      if (editor) updateLinkDecorations(editor);
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
