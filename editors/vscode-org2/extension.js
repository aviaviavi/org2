const vscode = require('vscode');
const path = require('path');

const headingRe = /^(\*+)\s+/;
const listItemRe = /^(\s*)(?:[-+*]|\d+[.)])\s+/;
const propertiesBeginRe = /^\s*:PROPERTIES:\s*$/i;
const drawerEndRe = /^\s*:END:\s*$/i;

function findTopLevelHeadingLines(document) {
  const starts = [];
  for (let i = 0; i < document.lineCount; i++) {
    const text = document.lineAt(i).text;
    const m = headingRe.exec(text);
    if (m && m[1].length === 1) starts.push(i);
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

    const startLines = [...findTopLevelHeadingLines(doc), ...findPropertyDrawerStartLines(doc)];

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
