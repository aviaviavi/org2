# Changelog

All notable changes to the Org2 VS Code extension are documented in this file.

## Unreleased

- Added syntax highlighting for checkbox progress cookies (`[n/m]`, `[p%]`).
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
