# Celorga (VS Code)

VS Code extension for Celorga workflows on ordinary Org files.

## Requirements

- This extension requires the `celorga` CLI. The `org2` executable remains a permanent compatibility alias for `celorga`, and the extension accepts either.
- If neither `celorga` nor `org2` is available, language-only features still work, but agenda/editing/roam/export commands will fail.
- Formerly published as "Org2". The marketplace ID (`AviPress.org2-vscode`), the `org2` language ID, view IDs, and `.org`/`.org2` file associations keep their names so existing installs keep working.

### Command and setting names

Commands are `celorga.*` (for example `celorga.openAgenda`) and settings are `celorga.*` (for example `celorga.agenda.dir`). The pre-rename names still work for several releases:

- Every `org2.*` command is still registered as an alias of its `celorga.*` command, so keybindings and scripts that use `org2.*` IDs keep working. The aliases are hidden from the command palette.
- Every `org2.*` setting is still read. The extension uses `celorga.X` when you set it, otherwise `org2.X` when you set that, otherwise the default. VS Code marks `org2.*` settings as deprecated; rename them to `celorga.*` when convenient.
- The power keymap and VSCodeVim line navigation honor `celorga.keymap.power` / `celorga.vim.visibleLineNavigation` with the same `org2.*` fallback.

## Quick start (60 seconds)

1. Install the Celorga CLI:

```sh
npm install -g celorga
celorga --help
```

2. Install the extension from the VS Code Marketplace:

```sh
code --install-extension AviPress.org2-vscode
```

3. Open your notes folder.
4. Run `Celorga: Open Agenda` from the command palette.

## Source checkout setup

Use this path for extension development or unreleased builds:

```sh
git clone https://github.com/aviaviavi/celorga.git
cd org2
npm ci
npm run build
```

Then install/run the extension from `editors/vscode-org2` with the Extension Development Host, or package a VSIX and install it manually. Ensure `celorga` (or the `org2` alias) is on your `PATH` or use the repo fallback.

## What you get

- Language support for `*.org` and `*.org2`:
  - syntax highlighting
  - folding for headings/lists/property drawers
  - clickable links
- Command workflows powered by the `celorga` CLI:
  - agenda, TODO/planning edits, capture, archive/refile
  - roam backlinks/IDs/dailies
  - HTML export
  - AI draft review workflows, including meeting/transcript summary drafts
- LSP-backed editing:
  - definitions, hovers, completion, rename, formatting, code lens, and more
- Extension-aware serialization: `*.org` saves and formatting rewrite accepted fenced/backtick shorthand to ordinary Org syntax; existing `*.org2` files remain lossless by default.

## Feature details

- File association for `*.org` and `*.org2`
- Syntax highlighting (headings, directives, blocks, drawers, properties, planning keywords, lists, checkboxes, checkbox progress cookies, timestamps, emphasis, links, tables, plus TODO aliases like `OPEN`, `BACKLOG`, `BLOCKED`, `PAUSED`, and `CANCELED` in headlines)
- Folding provider for headings, list items, and `:PROPERTIES:` drawers
- Auto-fold on open/activation (configurable):
  - `celorga.folding.autoFoldMaxHeadingLevel` (number; default 1; 0 = off)
  - `celorga.folding.autoFoldPropertyDrawers` (boolean; default true)
- Clickable links (via VS Code document links): `[[url]]`, `[[url][desc]]`, bare `https://...`
- Quick capture command with diff preview + apply confirmation (`Celorga: Capture Quick Entry`)
- HTML export commands for active file/workspace (`Celorga: Export Current File to HTML`, `Celorga: Export Workspace Org Files to HTML`)
- LSP features: definitions/declarations/type/implementation, hovers, signature help, completion, highlights, rename, file-rename edits, code actions, formatting, semantic tokens, inlay hints, call hierarchy

## Link rendering note (best-effort)

The extension attempts to render described links of the form `[[url][desc]]` so they *look* like just `desc` using VS Code decorations.

Limitation: VS Code decorations cannot truly replace/collapse the underlying text width, so the original `[[url][desc]]` token is hidden (transparent) and `desc` is drawn as a prefix. This means the line still takes up the original character width even though you only see `desc`.

## TODO status editing (MVP)

The extension can toggle/set TODO keywords on the current headline via the `celorga` CLI.

- Command: **Celorga: Toggle Todo Status** (`celorga.toggleTodo`)
- Command: **Celorga: Set Todo Status** (`celorga.setTodoStatus`) — command args accept the same aliases as CLI `todo set --status` (e.g. `open`, `backlog`, `in-progress`, `completed`, `cancelled`).
- Command: **Celorga: Set Priority** (`celorga.setPriority`) → sets/clears headline priority token (`[#A]`/`[#B]`/`[#C]`)
- Direct commands: `celorga.setTodoTODO`, `celorga.setTodoInProgress`, `celorga.setTodoDone`, `celorga.setTodoCanceled`
- Handoff command: `celorga.markDoneAndHandoff` marks the heading `DONE`, sets `STATUS=ready-for-agent`, and writes `ORG2_AGENT_HANDOFF_AT`.
- Default keybinding: `ctrl+alt+t`
- Also available in the editor right-click context menu.

Implementation detail: TODO status changes save the file (if needed), run `celorga todo toggle|set --file ... --line ... --apply` (and add `--logbook` when `celorga.todo.writeTransitionLogbook` is enabled), then refresh the buffer from disk. Priority changes are applied directly in-editor on the current headline and saved immediately for file-backed documents. Agenda-invoked priority edits trigger an immediate agenda reload so priority sort/filter/group views update right away. By default the extension restores the prior cursor/selection after CLI-based edits; this can be disabled with `celorga.editor.restoreSelectionAfterCliApply` if your setup still auto-expands folds. You can also disable the explicit refresh (`celorga.editor.refreshAfterCliApply`) to rely on VS Code file watching and avoid refresh-triggered fold churn. With refresh enabled, `celorga.editor.skipRefreshWhenInSync` (default true) avoids unnecessary `revertResource` calls when the open document already matches disk after CLI apply, and `celorga.editor.allowGlobalRefreshFallback` (default false) controls whether Celorga may fall back to global `workbench.action.files.revert` on older VS Code builds.

## Planning + capture + archiving + refile + export (MVP)

The extension can edit planning keywords, run quick capture, archive subtrees, refile subtrees, and export HTML via the `celorga` CLI.

- Command: **Celorga: Set Scheduled** (`celorga.setScheduled`) → prompts for `YYYY-MM-DD`
- Command: **Celorga: Set Scheduled to Today** (`celorga.setScheduledToday`) → no date prompt
- Command: **Celorga: Set Deadline** (`celorga.setDeadline`) → prompts for `YYYY-MM-DD`
- Command: **Celorga: Set Deadline to Today** (`celorga.setDeadlineToday`) → no date prompt
- Command: **Celorga: Capture Quick Entry** (`celorga.captureQuickEntry`) → pick file/template/title, optionally include current selection as body text, preview diff, then apply
- Command: **Celorga: Archive Subtree** (`celorga.archiveSubtree`) → shows a diff preview, then asks for confirmation
- Command: **Celorga: Refile Subtree** (`celorga.refileSubtree`) → pick destination file/heading, preview diff, then apply
- Command: **Celorga: Export Current File to HTML** (`celorga.exportCurrentFileHtml`) → preview generated HTML, then optionally write to disk
- Command: **Celorga: Export Workspace Org Files to HTML** (`celorga.exportWorkspaceHtml`) → preview batch export count, then optionally write HTML for all workspace Org files (and an optional generated index page)
- Command: **Celorga: Corpus Lint — Graph & Artifact Health** (`celorga.lintWorkspaceCorpus`) → runs `celorga lint` recursively in the workspace and reports graph/artifact health issues, including broken `id:` links, unresolved or ambiguous wiki links, raw/canonical vs generated trust-boundary mistakes, and raw -> notes -> compiled -> views -> publish corpus-flow mismatches, in the output pane
- Command: **Celorga: Graph Audit Workspace** (`celorga.graphAuditWorkspace`) → runs `celorga graph audit` recursively and opens a human-readable graph-health report
- Command: **Celorga: Compile Workspace Corpus Artifact** (`celorga.compileWorkspaceCorpus`) → prompts for a JSON/JSONL output path, runs `celorga compile corpus` recursively against the workspace, and opens the generated machine-readable corpus artifact
- Command: **Celorga: AI — Review Workspace / Active File** (`celorga.aiReviewWorkspace`) → runs `celorga ai review` for either the active file or the workspace and reports generated-artifact lifecycle issues
- Command: **Celorga: AI — Write Draft Artifact** (`celorga.aiRunDraft`) → picks an AI job manifest, previews `celorga ai run`, then writes review-required draft artifacts such as meeting/transcript summaries with citations and TODO/link suggestions after confirmation
- Command: **Celorga: AI — Mark Draft Reviewed/Rejected/Deferred** (`celorga.aiMarkReviewed` / `celorga.aiMarkRejected` / `celorga.aiMarkDeferred`) → stamps the active draft artifact review status before promotion
- Command: **Celorga: AI — Promote Reviewed Draft** (`celorga.aiPromoteDraft`) → previews and appends only reviewed generated artifacts into canonical notes

Implementation detail: the extension saves the file (if needed).
- Planning edits run `celorga plan set ... --apply`.
- Quick capture runs `celorga capture ... --format diff` first to preview the append, then `celorga capture ... --apply --format json` if confirmed, and can pass active-selection text as `--body` when `celorga.capture.useSelectionAsBody` is enabled.
- Archiving runs `celorga archive ... --format diff` first to generate a preview with provenance metadata, then `celorga archive ... --apply --format json` if confirmed and reports the archive destination.
- Refile runs `celorga refile ... --format diff` for preview, then `celorga refile ... --apply --format json` if confirmed.
- Current-file HTML export runs `celorga export html --file ... --format json` for preview and `celorga export html --file ... --out ... --apply --format json` when writing, plus optional export flags from settings (`--css` / `--no-default-style` / `--toc` / `--toc-depth` / `--number-headings` / `--number-headings-depth` / `--rewrite-file-links`).
- Workspace HTML export runs `celorga export html --dir <agenda-root> --recursive --out-dir <celorga.export.outputDir> --format json` for preview, adds optional `--index/--index-title` and export flags (`--css` / `--no-default-style` / `--toc` / `--toc-depth` / `--number-headings` / `--number-headings-depth` / `--rewrite-file-links`) from settings, and adds `--apply` when writing.
- AI draft writing runs `celorga ai run --job ... --out ...` (or the inline `celorga ai run --task summarize-meeting --file ... --out ...` flow) for preview and adds `--apply` only after confirmation. For `summarize-meeting` jobs, the generated draft includes summary, decisions, TODO suggestions, entity/link candidates, and source citations; promotion remains a separate reviewed-draft command.
- Exported HTML maps `#+AUTHOR`, `#+DATE`, `#+SUBTITLE`, `#+DESCRIPTION`, and `#+KEYWORDS` into standard HTML `<meta>` tags, respects `#+LANGUAGE` for `<html lang="...">`, injects `#+HTML_HEAD` / `#+HTML_HEAD_EXTRA` snippets into `<head>`, prepends a document title/subtitle header when `#+SUBTITLE` is present, treats `#+OPTIONS: toc:t` like passing `--toc` and `#+OPTIONS: toc:N` like `--toc-depth N` (auto TOC + heading anchors), treats `#+OPTIONS: num:t` like passing `--number-headings` and `#+OPTIONS: num:N` like `--number-headings-depth N`, emits heading anchor IDs for `--toc`, `--toc-depth`, `--rewrite-file-links`, and in-document `[[* Heading]]` / `[[#custom-id]]` links (including `:CUSTOM_ID:` targets), and uses cleaned default labels (`Heading` / `custom-id`) when those in-document links omit descriptions.
Afterward, the extension refreshes edited files from disk (unless `celorga.editor.refreshAfterCliApply` is disabled). Agenda-invoked archive/refile edits also refresh the agenda view immediately.

## Agenda (MVP)

The extension can show an *agenda* view powered by the `celorga` CLI.

### Usage

1. Ensure `celorga` is available:
   - If you have this repo checked out and built, the extension will *try* to fall back to running `node <repo>/dist/cli.js`.
   - Otherwise install/provide `celorga` (or the `org2` alias) on your `PATH`, or configure `celorga.agenda.command` + `celorga.agenda.args`.
2. Run the command: **`Celorga: Open Agenda`**.
3. Use the view title buttons:
   - **Refresh** (`Celorga: Refresh Agenda`)
   - **Filter** (`Celorga: Agenda Filter`) → Today / Next N days

### Settings

- `celorga.agenda.scope`: `workspace` (scan workspace folder recursively) or `files`
- `celorga.agenda.files`: list of files when scope=`files`
- `celorga.agenda.days`: default window (used for “Next N days”)
- `celorga.agenda.startDate`: optional start-date override (`YYYY-MM-DD`) for agenda range calculations
- `celorga.agenda.endDate`: optional end-date override (`YYYY-MM-DD`) for agenda range calculations
- `celorga.agenda.limit`: max rows to render after sorting (`0` = unlimited)
- `celorga.agenda.dayLimit`: optional per-day row cap applied after sort/group ordering and before `celorga.agenda.limit` (`0` = unlimited)
- `celorga.agenda.groupLimit`: optional per-day per-group row cap when `celorga.agenda.groupBy` is set (`0` = unlimited)
- `celorga.agenda.includeOverdue`: include overdue items
- `celorga.agenda.statusFilter`: filter by TODO state bucket (`all`, `active`, `actionable`, `open`, `todo`, `in_progress`, `done`, `canceled`, `closed`, `custom`; aliases like `default`, `none`, `backlog`, `wip`, `wait`, `hold`, `paused`, `completed`, and `cancelled` normalize automatically, with `none` acting as a no-op sentinel). Comma- or semicolon-separated values are accepted, deduped, and invalid tokens are ignored.
- `celorga.agenda.excludeStatusFilter`: exclude TODO state buckets (`all`, `active`, `actionable`, `open`, `todo`, `in_progress`, `done`, `canceled`, `closed`, `custom`; same aliases are normalized, including `wait`, `hold`, and `paused`, and `none` is treated as a no-op sentinel). Comma- or semicolon-separated values are accepted, deduped, and invalid tokens are ignored.
- `celorga.agenda.kindFilter`: filter by planning kind (`all`, `scheduled`, `deadline`)
- `celorga.agenda.excludeKindFilter`: exclude rows by planning kind (`all`, `scheduled`, `deadline`)
- `celorga.agenda.whenFilter`: filter by time bucket (`all`, `overdue`, `today`, `upcoming`)
- `celorga.agenda.excludeWhenFilter`: exclude rows by time bucket (`all`, `overdue`, `today`, `upcoming`)
- `celorga.agenda.weekdayFilter`: filter by weekday tokens (comma-separated, e.g. `mon,wed`; supports full names plus `weekday`/`weekend`; use `all` to disable)
- `celorga.agenda.excludeWeekdayFilter`: exclude rows by weekday tokens (comma-separated, e.g. `sat,sun`; supports full names plus `weekday`/`weekend`; use `all` for no exclusion)
- `celorga.agenda.weekFilter`: filter by ISO week number (comma-separated `1..53` values with aliases like `w2,week10`; use `all` to disable)
- `celorga.agenda.excludeWeekFilter`: exclude rows by ISO week number (comma-separated `1..53` values with aliases like `w52,week53`; use `all` for no exclusion)
- `celorga.agenda.dayOfMonthFilter`: filter by day-of-month numbers (comma-separated `1..31`, e.g. `1,15,31`; use `all` to disable)
- `celorga.agenda.excludeDayOfMonthFilter`: exclude rows by day-of-month numbers (comma-separated `1..31`, e.g. `1,31`; use `all` for no exclusion)
- `celorga.agenda.monthFilter`: filter by month (comma-separated month numbers `1..12` or aliases like `jan,mar,march`; use `all` to disable)
- `celorga.agenda.excludeMonthFilter`: exclude rows by month (comma-separated month numbers `1..12` or aliases; use `all` for no exclusion)
- `celorga.agenda.quarterFilter`: filter by calendar quarter (comma-separated `1..4` values or aliases like `q1,quarter2`; use `all` to disable)
- `celorga.agenda.excludeQuarterFilter`: exclude rows by calendar quarter (comma-separated `1..4` values or aliases like `q4`; use `all` for no exclusion)
- `celorga.agenda.yearFilter`: filter by year (comma-separated positive year numbers, e.g. `2025,2026`; use `all` to disable)
- `celorga.agenda.excludeYearFilter`: exclude rows by year (comma-separated positive year numbers, e.g. `2026`; use `all` for no exclusion)
- `celorga.agenda.dateFilter`: filter by exact dates (comma-separated `YYYY-MM-DD` values, e.g. `2026-03-01,2026-03-15`; use `all` to disable)
- `celorga.agenda.excludeDateFilter`: exclude rows by exact dates (comma-separated `YYYY-MM-DD` values, e.g. `2026-03-01`; use `all` for no exclusion)
- `celorga.agenda.levelFilter`: filter by headline level (comma-separated positive integers, e.g. `1,2,3`; empty disables)
- `celorga.agenda.excludeLevelFilter`: exclude rows by headline level (comma-separated positive integers, e.g. `1,2`; empty disables)
- `celorga.agenda.matchFilter`: filter by headline text (case-insensitive; comma-separated terms use OR matching)
- `celorga.agenda.excludeMatchFilter`: exclude rows by headline text (case-insensitive; comma-separated terms use OR matching)
- `celorga.agenda.tagFilter`: filter by headline tags (case-insensitive exact tag match; comma-separated tags use OR matching)
- `celorga.agenda.idFilter`: filter by headline `:ID:` / `:CUSTOM_ID:` values (case-insensitive exact match; comma-separated IDs use OR matching)
- `celorga.agenda.todoKeywordFilter`: filter by exact TODO keyword (case-insensitive; comma-separated keywords use OR matching)
- `celorga.agenda.todoOrder`: optional custom TODO keyword ordering used by `sortBy=todo` / `groupBy=todo` (comma-separated, e.g. `TODO,IN_PROGRESS,BLOCKED,DONE`; blank keeps default alphabetical ordering)
- `celorga.agenda.statusOrder`: optional custom normalized status-bucket ordering used by `sortBy=status` / `groupBy=status` (comma- or semicolon-separated values from `todo,in_progress,done,canceled,custom`; aliases like `default`, `none`, `all`, `active`, `actionable`, `open`, `prog`, `wait`, `hold`, `paused`, `completed`, and `closed` are accepted and normalized before CLI args are built)
- `celorga.agenda.kindOrder`: optional custom planning-kind ordering used by `sortBy=kind` / `groupBy=kind` (comma-separated values from `scheduled,deadline`; blank keeps default lexical ordering)
- `celorga.agenda.priorityOrder`: optional custom priority ordering used by `sortBy=priority` / `groupBy=priority` (comma-separated `A..Z`/`0..9`, accepts bracketed tokens like `[#A]`; blank keeps default `A→Z` then `0→9` ordering)
- `celorga.agenda.tagOrder`: optional custom tag ordering used by `sortBy=tags` / `groupBy=tags` (comma-separated tag names, case-insensitive; rows containing listed tags rank first, then lexical fallback)
- `celorga.agenda.effortOrder`: optional custom effort ordering used by `sortBy=effort` / `groupBy=effort` (comma-separated effort tokens like `0:30,45m,2h`; aliases `none`, `empty`, `unset`, and `no-effort` target rows without `:EFFORT:`)
- `celorga.agenda.priorityFilter`: filter by Org priority marker (for example `A,B` or `[#A],[#B]`, case-insensitive)
- `celorga.agenda.timeFilter`: filter by planning clock-time tokens (exact `HH:MM`, inclusive ranges like `09:00-12:30` including overnight windows, plus `timed`/`untimed`; comma-separated terms use OR matching)
- `celorga.agenda.effortFilter`: filter by `:EFFORT:` property value (case-insensitive exact match; comma-separated terms use OR matching, e.g. `0:30,30m,1h`)
- `celorga.agenda.propertyFilter`: filter by exact property terms using `KEY=VALUE` (case-insensitive; comma-separated terms use OR matching). Matches effective properties, including file-level and ancestor heading properties inherited by the agenda row.
- `celorga.agenda.excludeTagFilter`: exclude rows by headline tags (case-insensitive exact tag match; comma-separated tags use OR matching)
- `celorga.agenda.excludeIdFilter`: exclude rows by headline `:ID:` / `:CUSTOM_ID:` values (case-insensitive exact match; comma-separated IDs use OR matching)
- `celorga.agenda.excludeTodoKeywordFilter`: exclude rows by exact TODO keyword (case-insensitive; comma-separated keywords use OR matching)
- `celorga.agenda.excludePriorityFilter`: exclude rows by Org priority marker (for example `A,B` or `[#A],[#B]`, case-insensitive)
- `celorga.agenda.excludeTimeFilter`: exclude rows by planning clock-time tokens (exact `HH:MM`, inclusive ranges like `09:00-12:30` including overnight windows, plus `timed`/`untimed`; comma-separated terms use OR matching)
- `celorga.agenda.excludeEffortFilter`: exclude rows by `:EFFORT:` property value (case-insensitive exact match; comma-separated terms use OR matching)
- `celorga.agenda.excludePropertyFilter`: exclude rows by exact property terms using `KEY=VALUE` (case-insensitive; comma-separated terms use OR matching). Matches effective properties, including inherited file/ancestor heading values.
- `celorga.agenda.fileFilter`: keep rows whose source file path contains any comma-separated term (case-insensitive substring match)
- `celorga.agenda.excludeFileFilter`: hide rows whose source file path contains any comma-separated term (case-insensitive substring match)
- `celorga.formatter.fileFilter`: limit workspace formatter check/apply commands to files whose paths contain any comma-separated term (case-insensitive substring match)
- `celorga.formatter.excludeFileFilter`: exclude files from workspace formatter check/apply commands when paths contain any comma-separated term (case-insensitive substring match)
- `celorga.formatter.configFile`: optional `celorga.json` (or legacy `org2.json`) path for workspace formatter commands; when set, workspace check/apply uses `celorga fmt --config <path>` instead of scanning `celorga.agenda.dir` recursively
- `celorga.capture.defaultFile`: optional default target file for `Celorga: Capture Quick Entry`; absolute paths are used directly, relative paths resolve against `celorga.agenda.dir`/workspace root
- `celorga.capture.defaultTemplate`: default template ordering (`note` or `task`) for `Celorga: Capture Quick Entry`
- `celorga.capture.defaultTodoKeyword`: default TODO keyword ordering for task captures (`TODO`, `IN_PROGRESS`, `DONE`, `CANCELED`, `CANCELLED`)
- `celorga.capture.useSelectionAsBody`: when true (default), pass the active editor selection as capture body text (`--body`) in `Celorga: Capture Quick Entry`
- `celorga.export.outputDir`: output directory for `Celorga: Export Workspace Org Files to HTML`; absolute paths are used directly, relative paths resolve against `celorga.agenda.dir`/workspace root
- `celorga.export.indexFile`: optional workspace export index file path (`index.html` by default); empty disables index generation; relative paths resolve inside `celorga.export.outputDir`
- `celorga.export.indexTitle`: title used for generated workspace export index pages (`Celorga Export Index` by default)
- `celorga.export.stylesheets`: optional comma/newline-separated stylesheet URLs/paths passed to HTML export commands as repeated `--css` flags
- `celorga.export.includeDefaultStyle`: when true (default), keep Celorga's built-in inline stylesheet; disable to export with external CSS only (`--no-default-style`)
- `celorga.export.includeToc`: when true, include a generated table of contents with heading anchor links in exported HTML (`--toc`)
- `celorga.export.tocDepth`: optional TOC depth limit; values `>0` pass `--toc-depth N` (and enable TOC automatically), `0` keeps full-depth behavior
- `celorga.export.numberHeadings`: when true, prefix exported headings (and TOC entries when present) with generated section numbers (`--number-headings`)
- `celorga.export.numberHeadingsDepth`: optional heading-number depth limit; values `>0` pass `--number-headings-depth N` (and enable heading numbers automatically), `0` keeps full-depth numbering behavior
- `celorga.export.rewriteFileLinks`: when true, rewrite Org file links (`file:*.org`, `*.org2`) to `.html` hrefs in exported output and emit heading anchor IDs (including `:CUSTOM_ID:` targets) for rewritten `::* Heading` / `::#custom-id` links (`--rewrite-file-links`)
- `celorga.agenda.sortBy`: optional per-day sort order (`default`, or comma-separated keys like `file,headline,todo,status,priority,effort,id,level,time,kind,tags,line`); prefix a key with `-` (or suffix with `:desc`) for descending order
- `celorga.agenda.groupBy`: optional per-day grouping keys (`default`, or comma-separated keys like `status,todo,id,file`); uses the same key syntax as `sortBy` (including `status`, `id`, `time`, and `-key`/`:desc`)
- `celorga.agenda.dayLimit`: optional per-day row cap applied after sort/group ordering and before global `limit` (`0` = no per-day cap)
- `celorga.agenda.groupLimit`: optional per-day per-group row cap when `groupBy` is set (`0` = no per-group cap)
- `celorga.agenda.dateOrder`: overall date ordering for agenda groups (`asc` oldest-first or `desc` newest-first)
- `celorga.agenda.recursive`: when scope=`workspace`, whether to scan recursively (default true)
- `celorga.roam.dailiesDir`: optional root directory for Roam dailies (new files use `YYYY-MM-DD.org`; existing `.org2` dailies remain discoverable); defaults to `celorga.roam.indexDir`, then `celorga.agenda.dir`, then workspace root
- `celorga.roam.indexDir`: optional root directory for Roam ID/query/backlinks/db-sync operations; absolute paths are used directly, relative paths resolve against `celorga.agenda.dir`/workspace root
- `celorga.roam.nodesDir`: optional directory for `Celorga: Roam — New Node`; absolute paths are used directly, relative paths resolve against `celorga.roam.indexDir` (or `celorga.agenda.dir`/workspace root)
- `celorga.agenda.command`: command used to run the Celorga CLI (default: `org2`; when left unset, the extension runs `celorga` if it is on `PATH` and falls back to the `org2` alias)
- `celorga.agenda.args`: extra args prefixed before `agenda` (advanced)
- `celorga.todo.writeTransitionLogbook`: when true, TODO status updates include `--logbook` (default false)
- `celorga.editor.restoreSelectionAfterCliApply`: when true (default), TODO/planning/archive apply commands restore your prior selection after file refresh; set false to minimize fold auto-expansion side-effects in some VS Code setups.
- `celorga.editor.refreshAfterCliApply`: when true (default), TODO/planning/archive apply commands force a targeted file refresh from disk (`todo`/`plan` only refresh when CLI output reports an actual change); set false to rely on VS Code file watching and avoid refresh-related fold churn.
- `celorga.editor.skipRefreshWhenInSync`: when true (default) and refresh-after-apply is enabled, the extension skips explicit refresh if the open editor already matches on-disk content after CLI apply.
- `celorga.editor.allowGlobalRefreshFallback`: when false (default), Celorga will not fall back to global `workbench.action.files.revert` if target-file `revertResource` is unavailable; enable only if you need compatibility with older VS Code builds and accept broader refresh side-effects.
- `celorga.editor.navigationReveal`: controls reveal behavior after Celorga non-agenda navigation commands (backlinks/open-file/open-id). `outside` (default) only recenters when the target is offscreen, `default` uses normal VS Code reveal, `center` always recenters, and `none` skips forced reveals to reduce fold auto-expansion side-effects.
- `celorga.editor.navigationRevealFromAgenda`: controls reveal behavior when opening agenda items. `none` (default) avoids forced reveal calls to minimize fold churn; `default` inherits `celorga.editor.navigationReveal`; `outside`/`center` apply agenda-specific recentering.

### Agenda visuals

- Each agenda item now shows its source filename in the item description.
- Agenda rows with `:EFFORT:` show the estimate in the item description and tooltip.
- Habit agenda rows from the CLI (`:HABIT: true` / `:STYLE: habit` with repeating planning) show a `habit ×N` streak-ish count and tooltip details.
- Archive commands preview/apply via the CLI; active CLI directory scans exclude common archive destinations by default, with `--include-archives` available for intentional archive queries.
- Agenda items use a minimal urgency color dot:
  - overdue → error color
  - due today → warning color
  - coming up → deemphasized/neutral color
- TODO status is visually differentiated with **both** color and a compact non-color cue prefix:
  - `[T]` planned (TODO/open/backlog)
  - `[~]` in progress (in_progress/doing/started/waiting/wait/blocked/next/wip/hold/paused)
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

Agenda items are clickable; clicking opens the source file at the line reported by the celorga CLI.

### Formatter commands

- `Celorga: Formatter — Check Workspace Drift` runs `celorga fmt --dir <agenda-root> --recursive --check --format json` and reports drift in the `Celorga Formatter` output channel. If `celorga.formatter.configFile` is set, it uses `celorga fmt --config <path> --check --format json` instead. When configured, it also passes `--file-match <celorga.formatter.fileFilter>` and/or `--exclude-file <celorga.formatter.excludeFileFilter>`.
- `Celorga: Formatter — Apply Workspace Formatting` first runs the same drift check, previews the file list, then asks for confirmation before applying `celorga fmt --dir <agenda-root> --recursive --apply --format json` (or `celorga fmt --config <path> --apply --format json` when `celorga.formatter.configFile` is set), with the same optional workspace file filters (fallback: plain `--apply` for older CLIs).
- `Celorga: Formatter — Check Current File Drift` runs `celorga fmt --file <active-file> --format json` (prompts to save first when needed) and reports drift in the same output channel (fallback: `--check --format json` for older CLIs).
- `Celorga: Formatter — Preview Current File Diff` uses `celorga fmt --file <active-file> --format json` to open a side-by-side VS Code diff against formatted output without mutating the file (fallback: plain `celorga fmt --file <active-file>` output for older CLIs).
- `Celorga: Formatter — Apply Current File Formatting` previews current-file drift via the same JSON payload, asks for confirmation, then runs `celorga fmt --file <active-file> --apply --format json` (fallback: plain `--apply` for older CLIs).

## Command reference (VS Code)

Quick command palette index (`Cmd/Ctrl+Shift+P`):

- Agenda
  - `Celorga: Open Agenda` (`celorga.openAgenda`)
  - `Celorga: Refresh Agenda` (`celorga.refreshAgenda`)
  - `Celorga: Formatter — Check Workspace Drift` (`celorga.formatWorkspaceCheck`)
  - `Celorga: Formatter — Apply Workspace Formatting` (`celorga.formatWorkspaceApply`)
  - `Celorga: Formatter — Check Current File Drift` (`celorga.formatCurrentFileCheck`)
  - `Celorga: Formatter — Preview Current File Diff` (`celorga.formatCurrentFilePreviewDiff`)
  - `Celorga: Formatter — Apply Current File Formatting` (`celorga.formatCurrentFileApply`)
  - `Celorga: Export Current File to HTML` (`celorga.exportCurrentFileHtml`)
  - `Celorga: Export Workspace Org Files to HTML` (`celorga.exportWorkspaceHtml`)
  - `Celorga: Agenda Filter` (`celorga.pickAgendaFilter`)
- TODO + planning
  - `Celorga: Toggle Todo Status` (`celorga.toggleTodo`)
  - `Celorga: Set Todo Status` (`celorga.setTodoStatus`)
  - `Celorga: Set Priority` (`celorga.setPriority`)
  - `Celorga: Set Todo → TODO` (`celorga.setTodoTODO`)
  - `Celorga: Set Todo → IN_PROGRESS` (`celorga.setTodoInProgress`)
  - `Celorga: Set Todo → DONE` (`celorga.setTodoDone`)
  - `Celorga: Set Todo → CANCELED` (`celorga.setTodoCanceled`)
  - `Celorga: Mark Done and Handoff to Agent` (`celorga.markDoneAndHandoff`)
  - `Celorga: Set SCHEDULED` (`celorga.setScheduled`)
  - `Celorga: Set SCHEDULED to Today` (`celorga.setScheduledToday`)
  - `Celorga: Set DEADLINE` (`celorga.setDeadline`)
  - `Celorga: Set DEADLINE to Today` (`celorga.setDeadlineToday`)
  - `Celorga: Crypt Decrypt Subtree` (`celorga.cryptDecryptSubtree`)
  - `Celorga: Crypt Encrypt Subtree` (`celorga.cryptEncryptSubtree`)
  - `Celorga: Crypt Re-encrypt Subtree` (`celorga.cryptReencryptSubtree`)

Configure `celorga.crypt.recipients` with your default GPG recipients (for example your user/device key plus an agent key) to make encrypt/re-encrypt use multi-recipient public-key encryption from VS Code. `celorga.crypt.recipientFiles` is also supported for recipient files.
  - `Celorga: Capture Quick Entry` (`celorga.captureQuickEntry`)
  - `Celorga: Archive Subtree` (`celorga.archiveSubtree`)
  - `Celorga: Refile Subtree` (`celorga.refileSubtree`)
  - `Celorga: Promote Subtree` / `Celorga: Demote Subtree` (`celorga.promoteSubtree` / `celorga.demoteSubtree`)
  - `Celorga: Move Subtree Up` / `Celorga: Move Subtree Down` (`celorga.moveSubtreeUp` / `celorga.moveSubtreeDown`)
- Roam
  - `Celorga: Roam Dailies — Go to Today` (`celorga.roamDailiesGotoToday`)
  - `Celorga: Roam Dailies — Go to Yesterday` (`celorga.roamDailiesGotoYesterday`)
  - `Celorga: Roam Dailies — Go to Tomorrow` (`celorga.roamDailiesGotoTomorrow`)
  - `Celorga: Roam Dailies — Go to Date` (`celorga.roamDailiesGotoDate`)
  - `Celorga: Roam — New Node` (`celorga.roamNodeNew`) — pre-fills the title from the current selection/highlighted text when present
  - `Celorga: Roam — Copy ID Link (Current Heading/File)` (`celorga.roamCopyIdLink`)
  - `Celorga: Roam — Copy ID Link (Prompt/Link)` (`celorga.roamCopyIdLinkById`)
  - `Celorga: Roam — Insert Backlink (Prompt/Link)` (`celorga.roamInsertBacklink`)
  - `Celorga: Roam — Open ID (Prompt/Link)` (`celorga.roamOpenId`)
  - `Celorga: Roam — Show Backlinks (Current Heading/File)` (`celorga.roamShowBacklinks`)
  - `Celorga: Roam — Show Backlinks (Prompt/Link)` (`celorga.roamShowBacklinksById`)
  - `Celorga: Roam — Open Backlink Source (Current Heading/File)` (`celorga.roamOpenBacklink`)
  - `Celorga: Roam — Open Backlink Source (Prompt/Link)` (`celorga.roamOpenBacklinkById`)
  - `Celorga: Roam — DB Sync (Ensure File IDs)` (`celorga.roamDbSync`)
  - Open-ID input accepts raw UUIDs, `id:UUID`, and full `[[id:UUID][desc]]` text; when invoked without an argument it prompts.
  - Copy ID Link (Prompt/Link) accepts raw UUIDs, `id:UUID`, and `[[id:UUID][desc]]` input (or selected text), and reuses `[[id:...][desc]]` link text or `celorga query --id` as the copied link title.
  - Insert-Backlink target input accepts the same UUID/id-link formats, and pre-fills the backlink title from an `[[id:...][desc]]` target (or from `celorga query --id` when possible).
  - Show Backlinks now scopes to the current heading when possible (falls back to file-level IDs when no heading context exists).
  - Show Backlinks (Prompt/Link) accepts raw UUIDs, `id:UUID`, and `[[id:UUID][desc]]` input (or selected text), then opens a backlinks report for that explicit target ID.
  - Open Backlink Source (Current Heading/File) uses the same heading/file scope, then offers a quick pick of backlink sources (title + file:line + context snippet) for one-step navigation.
  - Open Backlink Source (Prompt/Link) accepts raw UUIDs, `id:UUID`, and `[[id:UUID][desc]]` input (or selected text), then opens a source pick list for that explicit target ID.
- Folding + debug
  - `Celorga: Re-run Auto-Fold` (`celorga.rerunAutoFold`)
  - `Celorga: Toggle Fold Here` (`celorga.toggleFoldHere`)
  - `Celorga: Debug Folding Ranges` (`celorga.debugFoldingRanges`)
  - `Celorga: Debug List Links` (`celorga.debugListLinks`)

## Keyboard shortcuts

Default direct bindings:

- `ctrl+alt+t` → `Celorga: Toggle Todo Status`
- `ctrl+alt+o` → `Celorga: Toggle Fold Here`
- `ctrl+alt+d` → `Celorga: Debug Folding Ranges`

Power keymap (enabled by default via `celorga.keymap.power: true`):

- Prefix chord: `cmd+;` on macOS, `ctrl+;` on Linux/Windows
- Then one mnemonic key (or namespace chord):
  - `s` → Set SCHEDULED (prompt)
  - `s t` → Set SCHEDULED to Today
  - `d` → Set DEADLINE (prompt)
  - `d t` → Set DEADLINE to Today
  - `x` → Archive Subtree
  - `x r` → Refile Subtree
  - `h left` / `h right` → Promote / Demote Subtree
  - `h up` / `h down` → Move Subtree Up / Down
  - `g a` → Graph Audit Workspace
  - `c q` → Capture Quick Entry
  - `f c` → Formatter Check Current File Drift
  - `f p` → Formatter Preview Current File Diff
  - `f a` → Formatter Apply Current File Formatting
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
  - `a s` → Agenda Status Filter
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
  - `r n` → Roam New Node (uses selected text as the default title)
  - `r s` → Roam DB Sync
- AI lifecycle namespace (`cmd/ctrl+; i ...`):
  - `i v` → AI Review Workspace / Active File
  - `i r` → Mark Draft Reviewed
  - `i x` → Mark Draft Rejected
  - `i d` → Mark Draft Deferred
- TODO namespace (`cmd/ctrl+; t ...`):
  - `t t` → Set TODO
  - `t i` → Set IN_PROGRESS
  - `t d` → Set DONE
  - `t c` → Set CANCELED
  - `t p` → Set Priority (A/B/C/Clear)

All defaults are scoped to `org`/`org2` editors.

### VSCodeVim note

The power keymap uses `cmd/ctrl` chords (not bare leader keys), so it remains reliable even when VSCodeVim is enabled in normal mode.

Optional folded-navigation helper: set `celorga.vim.visibleLineNavigation: true` to remap `j/k` to VS Code `cursorDown/cursorUp` in Org buffers while VSCodeVim Normal mode is active. This makes movement follow *visible* lines across folds.

## Debugging

- `Celorga: Debug Folding Ranges`
- `Celorga: Debug List Links` (prints detected links for the active editor in the `Celorga` output channel)

## Notes

This is intentionally small and TextMate-based. The repo also contains a Tree-sitter grammar in `tree-sitter-org2/` for future richer editor integrations.

### Capture / ingest CLI

The extension shells out to the workspace `celorga` CLI for editor workflows. Unified source capture is currently exposed by the CLI rather than a VS Code command:

```sh
celorga capture --text "note" --to inbox.org --title "Quick note" --apply
celorga capture --stdin --to raw/transcript.org --title "Transcript" --apply
celorga capture --file transcript.txt --to raw/inbox.org --apply
```

Captured source entries include source type, origin, timestamp, author (when provided), content hash, and provenance metadata in an org property drawer.
