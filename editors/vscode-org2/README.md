# Org2 (VS Code)

Minimal VS Code language support for Org2.

## Features

- File association for `*.org` and `*.org2`
- Syntax highlighting (headings, directives, blocks, drawers, properties, planning keywords, lists, checkboxes, timestamps, emphasis, links, tables)
- Folding provider for headings, list items, and `:PROPERTIES:` drawers
- Auto-fold on open/activation:
  - folds level-1 headings (`* Heading`)
  - folds `:PROPERTIES:` drawers
- Clickable links (via VS Code document links):
  - `[[url]]`
  - `[[url][desc]]`
  - bare `https://...` URLs

## Link rendering note (best-effort)

The extension attempts to render described links of the form `[[url][desc]]` so they *look* like just `desc` using VS Code decorations.

Limitation: VS Code decorations cannot truly replace/collapse the underlying text width, so the original `[[url][desc]]` token is hidden (transparent) and `desc` is drawn as a prefix. This means the line still takes up the original character width even though you only see `desc`.

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
- `org2.agenda.command`: command used to run org2 (default: `org2`)
- `org2.agenda.args`: extra args prefixed before `agenda` (advanced)

### Click-through

Agenda items are clickable; clicking opens the source file at the line reported by the org2 CLI.

## Debugging

- `Org2: Debug Folding Ranges`
- `Org2: Debug List Links` (prints detected links for the active editor in the `Org2` output channel)

## Notes

This is intentionally small and TextMate-based. The repo also contains a Tree-sitter grammar in `tree-sitter-org2/` for future richer editor integrations.
