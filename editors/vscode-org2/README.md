# Org2 (VS Code)

Minimal VS Code language support for Org2.

## Features

- File association for `*.org` and `*.org2`
- Syntax highlighting (headings, directives, blocks, drawers, properties, planning keywords, lists, checkboxes, timestamps, emphasis, links, tables)
- Folding provider for headings, list items, and `:PROPERTIES:` drawers
- Auto-fold on open/activation (configurable):
  - `org2.folding.autoFoldMaxHeadingLevel` (number; default 1; 0 = off)
  - `org2.folding.autoFoldPropertyDrawers` (boolean; default true)
- Clickable links (via VS Code document links):
  - `[[url]]`
  - `[[url][desc]]`
  - bare `https://...` URLs
- Quick capture command with diff preview + apply confirmation (plus optional selection-as-body capture) (`Org2: Capture Quick Entry`)
- HTML export commands for the active file and workspace (`Org2: Export Current File to HTML`, `Org2: Export Workspace Org Files to HTML`)
- LSP go-to-definition + go-to-declaration + go-to-type-definition + go-to-implementation for Org file/id links, including file `::search` suffix targets (`textDocument/definition` + `textDocument/declaration` + `textDocument/typeDefinition` + `textDocument/implementation`)
- LSP hover tooltips for Org links, TODO keywords, and planning keywords (`SCHEDULED:` / `DEADLINE:`)
- LSP signature help for planning timestamps (`textDocument/signatureHelp` with active/inactive timestamp forms)
- LSP completion for TODO/planning keywords, timestamps, and Org ID/file link targets (`textDocument/completion`)
- LSP document highlights for in-file ID/file references under cursor
- LSP rename for Org ID links (`[[id:...]]`), `:ID:` property values, and matching file-link targets
- LSP workspace file-rename edits for Org file links (`workspace/willRenameFiles`)
- LSP quick-fix code actions for parser whitespace issues (CRLF line endings and tab characters)
- LSP document formatting (`textDocument/formatting`) for canonical Org table/layout alignment
- LSP range formatting (`textDocument/rangeFormatting`) for selection-scoped canonical Org cleanup
- LSP on-type formatting (`textDocument/onTypeFormatting`) for table-aware canonical alignment while typing (`|`/newline triggers)
- LSP selection ranges (`textDocument/selectionRange`) for nested semantic expand-selection behavior
- LSP semantic tokens (`textDocument/semanticTokens/full`) for TODO/planning/property/link-target highlighting
- LSP backlink code lenses (`textDocument/codeLens`) on `:ID:` properties (click runs `org2.roamShowBacklinksById`)
- LSP linked editing ranges (`textDocument/linkedEditingRange`) for synchronized Org ID edits across `[[id:...]]` links/`:ID:` properties and matching file-link targets
- LSP document colors (`textDocument/documentColor` + `textDocument/colorPresentation`) for Org hex literals (`#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`)
- LSP inlay hints (`textDocument/inlayHint`) for unlabeled Org ID/file links (`[[id:...]]`, `[[file:...]]`) using resolved heading/title metadata
- LSP call hierarchy for Org ID/file links (`textDocument/prepareCallHierarchy` + `callHierarchy/incomingCalls` + `callHierarchy/outgoingCalls`)

## Link rendering note (best-effort)

The extension attempts to render described links of the form `[[url][desc]]` so they *look* like just `desc` using VS Code decorations.

Limitation: VS Code decorations cannot truly replace/collapse the underlying text width, so the original `[[url][desc]]` token is hidden (transparent) and `desc` is drawn as a prefix. This means the line still takes up the original character width even though you only see `desc`.

## TODO status editing (MVP)

The extension can toggle/set TODO keywords on the current headline via the `org2` CLI.

- Command: **Org2: Toggle Todo Status** (`org2.toggleTodo`)
- Command: **Org2: Set Todo Status** (`org2.setTodoStatus`)
- Direct commands: `org2.setTodoTODO`, `org2.setTodoInProgress`, `org2.setTodoDone`, `org2.setTodoCanceled`
- Default keybinding: `ctrl+alt+t`
- Also available in the editor right-click context menu.

Implementation detail: the extension saves the file (if needed), runs `org2 todo toggle|set --file ... --line ... --apply` (and adds `--logbook` when `org2.todo.writeTransitionLogbook` is enabled), then refreshes the buffer from disk. By default it restores the prior cursor/selection; this can be disabled with `org2.editor.restoreSelectionAfterCliApply` if your setup still auto-expands folds. You can also disable the explicit refresh (`org2.editor.refreshAfterCliApply`) to rely on VS Code file watching and avoid refresh-triggered fold churn. With refresh enabled, `org2.editor.skipRefreshWhenInSync` (default true) avoids unnecessary `revertResource` calls when the open document already matches disk after CLI apply, and `org2.editor.allowGlobalRefreshFallback` (default false) controls whether Org2 may fall back to global `workbench.action.files.revert` on older VS Code builds.

## Planning + capture + archiving + refile + export (MVP)

The extension can edit planning keywords, run quick capture, archive subtrees, refile subtrees, and export HTML via the `org2` CLI.

- Command: **Org2: Set Scheduled** (`org2.setScheduled`) → prompts for `YYYY-MM-DD`
- Command: **Org2: Set Scheduled to Today** (`org2.setScheduledToday`) → no date prompt
- Command: **Org2: Set Deadline** (`org2.setDeadline`) → prompts for `YYYY-MM-DD`
- Command: **Org2: Set Deadline to Today** (`org2.setDeadlineToday`) → no date prompt
- Command: **Org2: Capture Quick Entry** (`org2.captureQuickEntry`) → pick file/template/title, optionally include current selection as body text, preview diff, then apply
- Command: **Org2: Archive Subtree** (`org2.archiveSubtree`) → shows a diff preview, then asks for confirmation
- Command: **Org2: Refile Subtree** (`org2.refileSubtree`) → pick destination file/heading, preview diff, then apply
- Command: **Org2: Export Current File to HTML** (`org2.exportCurrentFileHtml`) → preview generated HTML, then optionally write to disk
- Command: **Org2: Export Workspace Org Files to HTML** (`org2.exportWorkspaceHtml`) → preview batch export count, then optionally write HTML for all workspace Org files (and an optional generated index page)

Implementation detail: the extension saves the file (if needed).
- Planning edits run `org2 plan set ... --apply`.
- Quick capture runs `org2 capture ... --format diff` first to preview the append, then `org2 capture ... --apply --format json` if confirmed, and can pass active-selection text as `--body` when `org2.capture.useSelectionAsBody` is enabled.
- Archiving runs `org2 archive ... --format diff` first to generate a preview, then `org2 archive ... --apply` if confirmed.
- Refile runs `org2 refile ... --format diff` for preview, then `org2 refile ... --apply --format json` if confirmed.
- Current-file HTML export runs `org2 export html --file ... --format json` for preview and `org2 export html --file ... --out ... --apply --format json` when writing, plus optional export flags from settings (`--css` / `--no-default-style` / `--toc` / `--toc-depth` / `--number-headings` / `--number-headings-depth` / `--rewrite-file-links`).
- Workspace HTML export runs `org2 export html --dir <agenda-root> --recursive --out-dir <org2.export.outputDir> --format json` for preview, adds optional `--index/--index-title` and export flags (`--css` / `--no-default-style` / `--toc` / `--toc-depth` / `--number-headings` / `--number-headings-depth` / `--rewrite-file-links`) from settings, and adds `--apply` when writing.
- Exported HTML maps `#+AUTHOR`, `#+DATE`, `#+SUBTITLE`, `#+DESCRIPTION`, and `#+KEYWORDS` into standard HTML `<meta>` tags, respects `#+LANGUAGE` for `<html lang="...">`, injects `#+HTML_HEAD` / `#+HTML_HEAD_EXTRA` snippets into `<head>`, prepends a document title/subtitle header when `#+SUBTITLE` is present, treats `#+OPTIONS: toc:t` like passing `--toc` and `#+OPTIONS: toc:N` like `--toc-depth N` (auto TOC + heading anchors), treats `#+OPTIONS: num:t` like passing `--number-headings` and `#+OPTIONS: num:N` like `--number-headings-depth N`, emits heading anchor IDs for `--toc`, `--toc-depth`, `--rewrite-file-links`, and in-document `[[* Heading]]` / `[[#custom-id]]` links (including `:CUSTOM_ID:` targets), and uses cleaned default labels (`Heading` / `custom-id`) when those in-document links omit descriptions.
Afterward, the extension refreshes edited files from disk (unless `org2.editor.refreshAfterCliApply` is disabled). Agenda-invoked archive/refile edits also refresh the agenda view immediately.

## Agenda (MVP)

The extension can show an *agenda* view powered by the `org2` CLI.

### Usage

1. Ensure `org2` is available:
   - If you have this repo checked out and built, the extension will *try* to fall back to running `node <repo>/dist/cli.js`.
   - Otherwise install/provide `org2` on your `PATH`, or configure `org2.agenda.command` + `org2.agenda.args`.
2. Run the command: **`Org2: Open Agenda`**.
3. Use the view title buttons:
   - **Refresh** (`Org2: Refresh Agenda`)
   - **Filter** (`Org2: Agenda Filter`) → Today / Next N days

### Settings

- `org2.agenda.scope`: `workspace` (scan workspace folder recursively) or `files`
- `org2.agenda.files`: list of files when scope=`files`
- `org2.agenda.days`: default window (used for “Next N days”)
- `org2.agenda.startDate`: optional start-date override (`YYYY-MM-DD`) for agenda range calculations
- `org2.agenda.endDate`: optional end-date override (`YYYY-MM-DD`) for agenda range calculations
- `org2.agenda.limit`: max rows to render after sorting (`0` = unlimited)
- `org2.agenda.includeOverdue`: include overdue items
- `org2.agenda.statusFilter`: filter by TODO state bucket (`all`, `active`, `actionable`, `open`, `todo`, `in_progress`, `done`, `canceled`, `closed`, `custom`)
- `org2.agenda.excludeStatusFilter`: exclude TODO state buckets (`all`, `active`, `actionable`, `open`, `todo`, `in_progress`, `done`, `canceled`, `closed`, `custom`)
- `org2.agenda.kindFilter`: filter by planning kind (`all`, `scheduled`, `deadline`)
- `org2.agenda.excludeKindFilter`: exclude rows by planning kind (`all`, `scheduled`, `deadline`)
- `org2.agenda.whenFilter`: filter by time bucket (`all`, `overdue`, `today`, `upcoming`)
- `org2.agenda.matchFilter`: filter by headline text (case-insensitive; comma-separated terms use OR matching)
- `org2.agenda.excludeMatchFilter`: exclude rows by headline text (case-insensitive; comma-separated terms use OR matching)
- `org2.agenda.tagFilter`: filter by headline tags (case-insensitive exact tag match; comma-separated tags use OR matching)
- `org2.agenda.todoKeywordFilter`: filter by exact TODO keyword (case-insensitive; comma-separated keywords use OR matching)
- `org2.agenda.priorityFilter`: filter by Org priority marker (for example `A,B` or `[#A],[#B]`, case-insensitive)
- `org2.agenda.effortFilter`: filter by `:EFFORT:` property value (case-insensitive exact match; comma-separated terms use OR matching, e.g. `0:30,30m,1h`)
- `org2.agenda.excludeTagFilter`: exclude rows by headline tags (case-insensitive exact tag match; comma-separated tags use OR matching)
- `org2.agenda.excludeTodoKeywordFilter`: exclude rows by exact TODO keyword (case-insensitive; comma-separated keywords use OR matching)
- `org2.agenda.excludePriorityFilter`: exclude rows by Org priority marker (for example `A,B` or `[#A],[#B]`, case-insensitive)
- `org2.agenda.excludeEffortFilter`: exclude rows by `:EFFORT:` property value (case-insensitive exact match; comma-separated terms use OR matching)
- `org2.agenda.fileFilter`: keep rows whose source file path contains any comma-separated term (case-insensitive substring match)
- `org2.agenda.excludeFileFilter`: hide rows whose source file path contains any comma-separated term (case-insensitive substring match)
- `org2.formatter.fileFilter`: limit workspace formatter check/apply commands to files whose paths contain any comma-separated term (case-insensitive substring match)
- `org2.formatter.excludeFileFilter`: exclude files from workspace formatter check/apply commands when paths contain any comma-separated term (case-insensitive substring match)
- `org2.formatter.configFile`: optional `org2.json` path for workspace formatter commands; when set, workspace check/apply uses `org2 fmt --config <path>` instead of scanning `org2.agenda.dir` recursively
- `org2.capture.defaultFile`: optional default target file for `Org2: Capture Quick Entry`; absolute paths are used directly, relative paths resolve against `org2.agenda.dir`/workspace root
- `org2.capture.defaultTemplate`: default template ordering (`note` or `task`) for `Org2: Capture Quick Entry`
- `org2.capture.defaultTodoKeyword`: default TODO keyword ordering for task captures (`TODO`, `IN_PROGRESS`, `DONE`, `CANCELED`, `CANCELLED`)
- `org2.capture.useSelectionAsBody`: when true (default), pass the active editor selection as capture body text (`--body`) in `Org2: Capture Quick Entry`
- `org2.export.outputDir`: output directory for `Org2: Export Workspace Org Files to HTML`; absolute paths are used directly, relative paths resolve against `org2.agenda.dir`/workspace root
- `org2.export.indexFile`: optional workspace export index file path (`index.html` by default); empty disables index generation; relative paths resolve inside `org2.export.outputDir`
- `org2.export.indexTitle`: title used for generated workspace export index pages (`Org2 Export Index` by default)
- `org2.export.stylesheets`: optional comma/newline-separated stylesheet URLs/paths passed to HTML export commands as repeated `--css` flags
- `org2.export.includeDefaultStyle`: when true (default), keep Org2's built-in inline stylesheet; disable to export with external CSS only (`--no-default-style`)
- `org2.export.includeToc`: when true, include a generated table of contents with heading anchor links in exported HTML (`--toc`)
- `org2.export.tocDepth`: optional TOC depth limit; values `>0` pass `--toc-depth N` (and enable TOC automatically), `0` keeps full-depth behavior
- `org2.export.numberHeadings`: when true, prefix exported headings (and TOC entries when present) with generated section numbers (`--number-headings`)
- `org2.export.numberHeadingsDepth`: optional heading-number depth limit; values `>0` pass `--number-headings-depth N` (and enable heading numbers automatically), `0` keeps full-depth numbering behavior
- `org2.export.rewriteFileLinks`: when true, rewrite Org file links (`file:*.org`, `*.org2`) to `.html` hrefs in exported output and emit heading anchor IDs (including `:CUSTOM_ID:` targets) for rewritten `::* Heading` / `::#custom-id` links (`--rewrite-file-links`)
- `org2.agenda.sortBy`: optional per-day sort order (`default`, or comma-separated keys like `file,headline,todo,priority,effort,kind,tags,line`); prefix a key with `-` (or suffix with `:desc`) for descending order
- `org2.agenda.dateOrder`: overall date ordering for agenda groups (`asc` oldest-first or `desc` newest-first)
- `org2.agenda.recursive`: when scope=`workspace`, whether to scan recursively (default true)
- `org2.roam.dailiesDir`: optional root directory for Roam dailies (`YYYY-MM-DD.org2`); defaults to `org2.roam.indexDir`, then `org2.agenda.dir`, then workspace root
- `org2.roam.indexDir`: optional root directory for Roam ID/query/backlinks/db-sync operations; absolute paths are used directly, relative paths resolve against `org2.agenda.dir`/workspace root
- `org2.roam.nodesDir`: optional directory for `Org2: Roam — New Node`; absolute paths are used directly, relative paths resolve against `org2.roam.indexDir` (or `org2.agenda.dir`/workspace root)
- `org2.agenda.command`: command used to run org2 (default: `org2`)
- `org2.agenda.args`: extra args prefixed before `agenda` (advanced)
- `org2.todo.writeTransitionLogbook`: when true, TODO status updates include `--logbook` (default false)
- `org2.editor.restoreSelectionAfterCliApply`: when true (default), TODO/planning/archive apply commands restore your prior selection after file refresh; set false to minimize fold auto-expansion side-effects in some VS Code setups.
- `org2.editor.refreshAfterCliApply`: when true (default), TODO/planning/archive apply commands force a targeted file refresh from disk (`todo`/`plan` only refresh when CLI output reports an actual change); set false to rely on VS Code file watching and avoid refresh-related fold churn.
- `org2.editor.skipRefreshWhenInSync`: when true (default) and refresh-after-apply is enabled, the extension skips explicit refresh if the open editor already matches on-disk content after CLI apply.
- `org2.editor.allowGlobalRefreshFallback`: when false (default), Org2 will not fall back to global `workbench.action.files.revert` if target-file `revertResource` is unavailable; enable only if you need compatibility with older VS Code builds and accept broader refresh side-effects.
- `org2.editor.navigationReveal`: controls reveal behavior after Org2 non-agenda navigation commands (backlinks/open-file/open-id). `outside` (default) only recenters when the target is offscreen, `default` uses normal VS Code reveal, `center` always recenters, and `none` skips forced reveals to reduce fold auto-expansion side-effects.
- `org2.editor.navigationRevealFromAgenda`: controls reveal behavior when opening agenda items. `none` (default) avoids forced reveal calls to minimize fold churn; `default` inherits `org2.editor.navigationReveal`; `outside`/`center` apply agenda-specific recentering.

### Agenda visuals

- Each agenda item now shows its source filename in the item description.
- Agenda items use a minimal urgency color dot:
  - overdue → error color
  - due today → warning color
  - coming up → deemphasized/neutral color
- TODO status is visually differentiated with **both** color and a compact non-color cue prefix:
  - `[T]` planned (TODO/open/backlog)
  - `[~]` in progress (in_progress/doing/started/waiting/blocked/next)
  - `[✓]` completed (done/completed)
  - `[×]` canceled (canceled/cancelled)
  - `[?]` custom keyword, `[·]` no keyword
- Status color now uses semantic VS Code theme tokens (with fallback palette in tooltip rendering):
  - planned → `list.warningForeground`
  - in progress → `list.highlightForeground`
  - completed → `gitDecoration.addedResourceForeground`
  - canceled → `gitDecoration.deletedResourceForeground`

All visuals remain theme-aware (`ThemeColor`) and keep urgency dots for schedule urgency.

### Click-through

Agenda items are clickable; clicking opens the source file at the line reported by the org2 CLI.

### Formatter commands

- `Org2: Formatter — Check Workspace Drift` runs `org2 fmt --dir <agenda-root> --recursive --check --format json` and reports drift in the `Org2 Formatter` output channel. If `org2.formatter.configFile` is set, it uses `org2 fmt --config <path> --check --format json` instead. When configured, it also passes `--file-match <org2.formatter.fileFilter>` and/or `--exclude-file <org2.formatter.excludeFileFilter>`.
- `Org2: Formatter — Apply Workspace Formatting` first runs the same drift check, previews the file list, then asks for confirmation before applying `org2 fmt --dir <agenda-root> --recursive --apply --format json` (or `org2 fmt --config <path> --apply --format json` when `org2.formatter.configFile` is set), with the same optional workspace file filters (fallback: plain `--apply` for older CLIs).
- `Org2: Formatter — Check Current File Drift` runs `org2 fmt --file <active-file> --format json` (prompts to save first when needed) and reports drift in the same output channel (fallback: `--check --format json` for older CLIs).
- `Org2: Formatter — Preview Current File Diff` uses `org2 fmt --file <active-file> --format json` to open a side-by-side VS Code diff against formatted output without mutating the file (fallback: plain `org2 fmt --file <active-file>` output for older CLIs).
- `Org2: Formatter — Apply Current File Formatting` previews current-file drift via the same JSON payload, asks for confirmation, then runs `org2 fmt --file <active-file> --apply --format json` (fallback: plain `--apply` for older CLIs).

## Command reference (VS Code)

Quick command palette index (`Cmd/Ctrl+Shift+P`):

- Agenda
  - `Org2: Open Agenda` (`org2.openAgenda`)
  - `Org2: Refresh Agenda` (`org2.refreshAgenda`)
  - `Org2: Formatter — Check Workspace Drift` (`org2.formatWorkspaceCheck`)
  - `Org2: Formatter — Apply Workspace Formatting` (`org2.formatWorkspaceApply`)
  - `Org2: Formatter — Check Current File Drift` (`org2.formatCurrentFileCheck`)
  - `Org2: Formatter — Preview Current File Diff` (`org2.formatCurrentFilePreviewDiff`)
  - `Org2: Formatter — Apply Current File Formatting` (`org2.formatCurrentFileApply`)
  - `Org2: Export Current File to HTML` (`org2.exportCurrentFileHtml`)
  - `Org2: Export Workspace Org Files to HTML` (`org2.exportWorkspaceHtml`)
  - `Org2: Agenda Filter` (`org2.pickAgendaFilter`)
- TODO + planning
  - `Org2: Toggle Todo Status` (`org2.toggleTodo`)
  - `Org2: Set Todo Status` (`org2.setTodoStatus`)
  - `Org2: Set Todo → TODO` (`org2.setTodoTODO`)
  - `Org2: Set Todo → IN_PROGRESS` (`org2.setTodoInProgress`)
  - `Org2: Set Todo → DONE` (`org2.setTodoDone`)
  - `Org2: Set Todo → CANCELED` (`org2.setTodoCanceled`)
  - `Org2: Set SCHEDULED` (`org2.setScheduled`)
  - `Org2: Set SCHEDULED to Today` (`org2.setScheduledToday`)
  - `Org2: Set DEADLINE` (`org2.setDeadline`)
  - `Org2: Set DEADLINE to Today` (`org2.setDeadlineToday`)
  - `Org2: Capture Quick Entry` (`org2.captureQuickEntry`)
  - `Org2: Archive Subtree` (`org2.archiveSubtree`)
  - `Org2: Refile Subtree` (`org2.refileSubtree`)
- Roam
  - `Org2: Roam Dailies — Go to Today` (`org2.roamDailiesGotoToday`)
  - `Org2: Roam Dailies — Go to Yesterday` (`org2.roamDailiesGotoYesterday`)
  - `Org2: Roam Dailies — Go to Tomorrow` (`org2.roamDailiesGotoTomorrow`)
  - `Org2: Roam Dailies — Go to Date` (`org2.roamDailiesGotoDate`)
  - `Org2: Roam — New Node` (`org2.roamNodeNew`)
  - `Org2: Roam — Copy ID Link (Current Heading/File)` (`org2.roamCopyIdLink`)
  - `Org2: Roam — Copy ID Link (Prompt/Link)` (`org2.roamCopyIdLinkById`)
  - `Org2: Roam — Insert Backlink (Prompt/Link)` (`org2.roamInsertBacklink`)
  - `Org2: Roam — Open ID (Prompt/Link)` (`org2.roamOpenId`)
  - `Org2: Roam — Show Backlinks (Current Heading/File)` (`org2.roamShowBacklinks`)
  - `Org2: Roam — Show Backlinks (Prompt/Link)` (`org2.roamShowBacklinksById`)
  - `Org2: Roam — Open Backlink Source (Current Heading/File)` (`org2.roamOpenBacklink`)
  - `Org2: Roam — Open Backlink Source (Prompt/Link)` (`org2.roamOpenBacklinkById`)
  - `Org2: Roam — DB Sync (Ensure File IDs)` (`org2.roamDbSync`)
  - Open-ID input accepts raw UUIDs, `id:UUID`, and full `[[id:UUID][desc]]` text; when invoked without an argument it prompts.
  - Copy ID Link (Prompt/Link) accepts raw UUIDs, `id:UUID`, and `[[id:UUID][desc]]` input (or selected text), and reuses `[[id:...][desc]]` link text or `org2 query --id` as the copied link title.
  - Insert-Backlink target input accepts the same UUID/id-link formats, and pre-fills the backlink title from an `[[id:...][desc]]` target (or from `org2 query --id` when possible).
  - Show Backlinks now scopes to the current heading when possible (falls back to file-level IDs when no heading context exists).
  - Show Backlinks (Prompt/Link) accepts raw UUIDs, `id:UUID`, and `[[id:UUID][desc]]` input (or selected text), then opens a backlinks report for that explicit target ID.
  - Open Backlink Source (Current Heading/File) uses the same heading/file scope, then offers a quick pick of backlink sources (title + file:line + context snippet) for one-step navigation.
  - Open Backlink Source (Prompt/Link) accepts raw UUIDs, `id:UUID`, and `[[id:UUID][desc]]` input (or selected text), then opens a source pick list for that explicit target ID.
- Folding + debug
  - `Org2: Re-run Auto-Fold` (`org2.rerunAutoFold`)
  - `Org2: Toggle Fold Here` (`org2.toggleFoldHere`)
  - `Org2: Debug Folding Ranges` (`org2.debugFoldingRanges`)
  - `Org2: Debug List Links` (`org2.debugListLinks`)

## Keyboard shortcuts

Default direct bindings:

- `ctrl+alt+t` → `Org2: Toggle Todo Status`
- `ctrl+alt+o` → `Org2: Toggle Fold Here`
- `ctrl+alt+d` → `Org2: Debug Folding Ranges`

Power keymap (enabled by default via `org2.keymap.power: true`):

- Prefix chord: `cmd+;` on macOS, `ctrl+;` on Linux/Windows
- Then one mnemonic key (or namespace chord):
  - `s` → Set SCHEDULED (prompt)
  - `s t` → Set SCHEDULED to Today
  - `d` → Set DEADLINE (prompt)
  - `d t` → Set DEADLINE to Today
  - `x` → Archive Subtree
  - `c q` → Capture Quick Entry
  - `p h` → Export Current File to HTML
  - `p w` → Export Workspace Org Files to HTML
  - `1` → Fold to heading level 1 (`editor.foldLevel1`)
  - `2` → Fold to heading level 2 (`editor.foldLevel2`)
  - `3` → Fold to heading level 3 (`editor.foldLevel3`)
  - `4` → Fold to heading level 4 (`editor.foldLevel4`)
- Agenda namespace (`cmd/ctrl+; a ...`):
  - `a o` → Open Agenda
  - `a r` → Refresh Agenda
  - `a f` → Agenda Filter
- Roam namespace (`cmd/ctrl+; r ...`):
  - `r b` → Roam Show Backlinks
  - `r h` → Roam Show Backlinks (Prompt/Link)
  - `r l` → Roam Copy ID Link (Current Heading/File)
  - `r c` → Roam Copy ID Link (Prompt/Link)
  - `r i` → Roam Insert Backlink
  - `r o` → Roam Open ID
  - `r p` → Roam Open Backlink Source (Current Heading/File)
  - `r g` → Roam Open Backlink Source (Prompt/Link)
  - `r t` → Roam Dailies: Today
  - `r y` → Roam Dailies: Yesterday
  - `r m` → Roam Dailies: Tomorrow
  - `r d` → Roam Dailies: Go to Date
  - `r n` → Roam New Node
  - `r s` → Roam DB Sync
- TODO namespace (`cmd/ctrl+; t ...`):
  - `t t` → Set TODO
  - `t i` → Set IN_PROGRESS
  - `t d` → Set DONE
  - `t c` → Set CANCELED

Note: heading promote/demote/set-level commands are not yet exposed by Org2 VS Code commands, so `cmd/ctrl+; 1/2/3/4` are currently wired to VS Code’s closest built-in heading-level operation: fold-to-level.

All defaults are scoped to `org`/`org2` editors.

### VSCodeVim note

The power keymap uses `cmd/ctrl` chords (not bare leader keys), so it remains reliable even when VSCodeVim is enabled in normal mode.

Optional folded-navigation helper: set `org2.vim.visibleLineNavigation: true` to remap `j/k` to VS Code `cursorDown/cursorUp` in Org/Org2 buffers while VSCodeVim Normal mode is active. This makes movement follow *visible* lines across folds.

## Debugging

- `Org2: Debug Folding Ranges`
- `Org2: Debug List Links` (prints detected links for the active editor in the `Org2` output channel)

## Notes

This is intentionally small and TextMate-based. The repo also contains a Tree-sitter grammar in `tree-sitter-org2/` for future richer editor integrations.
