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
- Default keybinding: `ctrl+alt+t`
- Also available in the editor right-click context menu.

Implementation detail: the extension saves the file (if needed), runs `org2 todo toggle|set --file ... --line ... --apply`, then reverts the buffer to pick up the on-disk edits.

## Planning + archiving (MVP)

The extension can edit planning keywords and archive subtrees via the `org2` CLI.

- Command: **Org2: Set Scheduled** (`org2.setScheduled`) → prompts for `YYYY-MM-DD`
- Command: **Org2: Set Deadline** (`org2.setDeadline`) → prompts for `YYYY-MM-DD`
- Command: **Org2: Archive Subtree** (`org2.archiveSubtree`) → shows a diff preview, then asks for confirmation

Implementation detail: the extension saves the file (if needed).
- Planning edits run `org2 plan set ... --apply`.
- Archiving runs `org2 archive ... --format diff` first to generate a preview, then `org2 archive ... --apply` if confirmed.
Afterward, the extension reverts the buffer to pick up the on-disk edits.

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
  - `Org2: Set SCHEDULED` (`org2.setScheduled`)
  - `Org2: Set DEADLINE` (`org2.setDeadline`)
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
  - `a` → Open Agenda
  - `r` → Refresh Agenda
  - `s` → Set SCHEDULED
  - `d` → Set DEADLINE
  - `x` → Archive Subtree
  - `l` → Roam Copy ID Link
  - `b` → Roam Show Backlinks
  - `i` → Roam Insert Backlink
  - `g` → Roam Open ID
  - `n` → Roam Dailies: Today
  - `1` → Fold to heading level 1 (`editor.foldLevel1`)
  - `2` → Fold to heading level 2 (`editor.foldLevel2`)
  - `3` → Fold to heading level 3 (`editor.foldLevel3`)
  - `4` → Fold to heading level 4 (`editor.foldLevel4`)
- TODO namespace (`cmd/ctrl+; t ...`):
  - `t t` → Set TODO
  - `t i` → Set IN_PROGRESS
  - `t d` → Set DONE
  - `t c` → Set CANCELED

Note: heading promote/demote/set-level commands are not yet exposed by Org2 VS Code commands, so `cmd/ctrl+; 1/2/3/4` are currently wired to VS Code’s closest built-in heading-level operation: fold-to-level.

All defaults are scoped to `org`/`org2` editors.

### VSCodeVim note

The power keymap uses `cmd/ctrl` chords (not bare leader keys), so it remains reliable even when VSCodeVim is enabled in normal mode.

## Debugging

- `Org2: Debug Folding Ranges`
- `Org2: Debug List Links` (prints detected links for the active editor in the `Org2` output channel)

## Notes

This is intentionally small and TextMate-based. The repo also contains a Tree-sitter grammar in `tree-sitter-org2/` for future richer editor integrations.
