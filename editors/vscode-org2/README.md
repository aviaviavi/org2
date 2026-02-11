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

## Planning + archiving (MVP)

The extension can edit planning keywords and archive subtrees via the `org2` CLI.

- Command: **Org2: Set Scheduled** (`org2.setScheduled`) → prompts for `YYYY-MM-DD`
- Command: **Org2: Set Scheduled to Today** (`org2.setScheduledToday`) → no date prompt
- Command: **Org2: Set Deadline** (`org2.setDeadline`) → prompts for `YYYY-MM-DD`
- Command: **Org2: Set Deadline to Today** (`org2.setDeadlineToday`) → no date prompt
- Command: **Org2: Archive Subtree** (`org2.archiveSubtree`) → shows a diff preview, then asks for confirmation

Implementation detail: the extension saves the file (if needed).
- Planning edits run `org2 plan set ... --apply`.
- Archiving runs `org2 archive ... --format diff` first to generate a preview, then `org2 archive ... --apply` if confirmed.
Afterward, the extension refreshes the buffer from disk (unless `org2.editor.refreshAfterCliApply` is disabled).

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
- `org2.agenda.includeOverdue`: include overdue items
- `org2.agenda.recursive`: when scope=`workspace`, whether to scan recursively (default true)
- `org2.agenda.command`: command used to run org2 (default: `org2`)
- `org2.agenda.args`: extra args prefixed before `agenda` (advanced)
- `org2.todo.writeTransitionLogbook`: when true, TODO status updates include `--logbook` (default false)
- `org2.editor.restoreSelectionAfterCliApply`: when true (default), TODO/planning apply commands restore your prior selection after file refresh; set false to minimize fold auto-expansion side-effects in some VS Code setups.
- `org2.editor.refreshAfterCliApply`: when true (default), TODO/planning apply commands force a targeted file refresh from disk; set false to rely on VS Code file watching and avoid refresh-related fold churn.
- `org2.editor.skipRefreshWhenInSync`: when true (default) and refresh-after-apply is enabled, the extension skips explicit refresh if the open editor already matches on-disk content after CLI apply.
- `org2.editor.allowGlobalRefreshFallback`: when false (default), Org2 will not fall back to global `workbench.action.files.revert` if target-file `revertResource` is unavailable; enable only if you need compatibility with older VS Code builds and accept broader refresh side-effects.
- `org2.editor.navigationReveal`: controls reveal behavior after Org2 navigation commands (agenda/backlinks/open-file/open-id). `default` (default) uses normal VS Code reveal, `center` preserves old center-on-jump behavior, and `none` skips forced reveals to reduce fold auto-expansion side-effects.

### Click-through

Agenda items are clickable; clicking opens the source file at the line reported by the org2 CLI.

## Command reference (VS Code)

Quick command palette index (`Cmd/Ctrl+Shift+P`):

- Agenda
  - `Org2: Open Agenda` (`org2.openAgenda`)
  - `Org2: Refresh Agenda` (`org2.refreshAgenda`)
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
  - `Org2: Archive Subtree` (`org2.archiveSubtree`)
- Roam
  - `Org2: Roam Dailies — Go to Today` (`org2.roamDailiesGotoToday`)
  - `Org2: Roam Dailies — Go to Yesterday` (`org2.roamDailiesGotoYesterday`)
  - `Org2: Roam Dailies — Go to Tomorrow` (`org2.roamDailiesGotoTomorrow`)
  - `Org2: Roam Dailies — Go to Date` (`org2.roamDailiesGotoDate`)
  - `Org2: Roam — Copy ID Link` (`org2.roamCopyIdLink`)
  - `Org2: Roam — Insert Backlink (ID Link)` (`org2.roamInsertBacklink`)
  - `Org2: Roam — Open ID Link` (`org2.roamOpenId`)
  - `Org2: Roam — Show Backlinks` (`org2.roamShowBacklinks`)
  - `Org2: Roam — DB Sync (Ensure File IDs)` (`org2.roamDbSync`)
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
  - `r l` → Roam Copy ID Link
  - `r i` → Roam Insert Backlink
  - `r o` → Roam Open ID
  - `r t` → Roam Dailies: Today
  - `r y` → Roam Dailies: Yesterday
  - `r m` → Roam Dailies: Tomorrow
  - `r d` → Roam Dailies: Go to Date
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
