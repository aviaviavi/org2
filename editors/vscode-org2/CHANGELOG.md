# Changelog

All notable changes to the Org2 VS Code extension are documented in this file.

## Unreleased

## 0.5.2 - 2026-08-28

- Coordinated the extension with the OpenOrg 0.5.2 alpha release and current Org2 runtime.
- Added format-on-save defaults and pane-aware list selection shortcuts.
- Included the latest approval-state, source-sync, AI chat rendering, and local Codex recovery fixes.

## 0.5.1 - 2026-08-27

- Coordinated the extension with the OpenOrg 0.5.1 alpha release and current Org2 runtime.
- Improved node actions, search routing, and approval workflows shared with the OpenOrg apps.
- Included the latest parser, editor responsiveness, remote-agent, and generated-site reliability fixes.

## 0.5.0 - 2026-08-24

- Coordinated the extension with the OpenOrg 0.5.0 product launch while preserving the Org2 developer-tooling name and extension identifier.
- Added corpus-aware node actions, richer AI review workflows, and compatibility with the redesigned OpenOrg desktop and mobile clients.
- Improved agenda ordering, editor reliability, formatter commands, and the shared Org2 runtime integration.

## 0.4.2 - 2026-08-19

- Coordinated the Marketplace package version with the Org2 CLI and macOS workspace 0.4.2 release.
- Prioritized overdue agenda items by Org priority while preserving configurable agenda ordering.
- Expanded status-filter normalization and kept editor commands aligned with the current Org2 runtime.

## 0.4.1 - 2026-08-02

- Coordinated the Marketplace package version with the Org2 CLI and macOS workspace 0.4.1 release.
- Kept extension behavior compatible with the current Org2 language runtime; this patch contains no extension-specific command or UI changes.

## 0.4.0 - 2026-07-19

- Added syntax highlighting for checkbox progress cookies (`[n/m]`, `[p%]`).
- Agenda property filters now follow Org2 effective property inheritance from file and ancestor heading drawers.
- Added syntax coverage tests for Org timestamp repeaters and warning offsets.
- Agenda rows now surface CLI habit metadata with a compact streak-ish `habit ×N` cue and tooltip details.

## 0.1.0 - 2026-05-24

Minor release for the expanded editor workflow surface.

Highlights:

- New-node creation now pre-fills the title from selected/highlighted text.
- Added graph audit and AI review/status commands to the command palette.
- Added power-keymap bindings for graph audit, AI draft lifecycle status, and subtree promote/demote/move commands.
- Documented the new editor commands and shortcuts.

## 0.0.2 - 2026-03-26

Patch release for Marketplace publishing.

## 0.0.1 - 2026-02-22

Initial Marketplace preview release.

Highlights:

- Org/Org2 language support (syntax highlighting, folding, clickable links)
- Agenda view powered by `org2` CLI
- TODO/planning edit commands
- Capture, archive, and refile commands
- Roam workflows (IDs, backlinks, dailies, node creation, link insertion)
- HTML export commands
- Org-crypt subtree encrypt/decrypt commands
- Power keymap with Org-focused command chords
