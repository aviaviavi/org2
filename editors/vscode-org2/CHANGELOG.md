# Changelog

All notable changes to the Org2 VS Code extension are documented in this file.

## Unreleased

## 0.8.0 - 2026-09-06

OpenOrg 0.8.0 keeps iPhone AI chat and scheduled work available through a dedicated Mac, even when your laptop is asleep or away.

- Run the chat relay and automation scheduler without a desktop window using `org2 server`. Pair, inspect, revoke devices, assign the scheduler host, and install a login service from the CLI.
- Reuse existing corpus chat history. The Mac now refreshes conversations and messages arriving through corpus synchronization while preserving selection and unfinished drafts.
- Give scheduled automations one explicit host. Updated Mac and server schedulers enforce that owner and suppress duplicate occurrences. Automatic failover across replicated copies is not enabled.
- Save multiple hosts in the iOS app and choose which host handles chat. Each host retains its own protected pairing credential.
- Improve LSP compatibility with strict clients: notifications receive no response, and split Unicode messages use correct UTF-8 byte framing.
- Fix chat code/table scrolling, refresh stale Codex model catalogs, and keep the headless supervisor alive through temporary nonblocking input reads.
- Make release retries reuse verified artifacts, install native dependencies separately for each Mac architecture, avoid repeated runtime builds, and stabilize the tests that delayed the previous release.

macOS downloads support macOS 14 or later and include the local dictation runtime. Both Apple Silicon and Intel DMGs require Developer ID signing and Apple notarization before publication. iOS 0.8.0 build 28 is distributed separately through TestFlight, subject to Apple's processing and beta review.

For a synchronized corpus, continue a conversation from one execution host at a time. The desktop refreshes replicated history; it does not yet relay desktop messages through the headless server.

## 0.7.2 - 2026-09-03

# OpenOrg 0.7.2

OpenOrg 0.7.2 improves workspace navigation, AI chat, meeting recording reliability, automation management, and everyday document work.

## Highlights

- Added a dedicated Skills manager for workspace-authored agent procedures, available from the sidebar and with Command-Shift-K. The built-in Org2 operating guidance remains ambient and hidden from the user-managed skill list.
- Made tabs represent the full workspace state, preserving the active surface, document selection, pane focus, and pane layout independently across tabs.
- Added a Daily “Choose Date…” action and Command-Shift-7 shortcut for opening or creating the daily note for any date.
- Added workspace filtering and file-tree navigation improvements, plus richer agent handoff metadata.
- Made the document toolbar adapt cleanly from wide to narrow panes and unified the native toolbar and workspace tab-strip appearance.

## AI chat

- Text selection now spans paragraphs, bullets, links, and consecutive messages, with standard Command-C and Edit → Copy behavior.
- Selection highlights align with the rendered typography, wrapping, links, and indentation.
- Tightened corpus-switch persistence so chat state cannot leak across workspaces during rapid transitions.

## Meetings and reliability

- Meeting recordings now retain the original ScreenCaptureKit interruption error and surface system-audio failures immediately.
- Interrupted system-audio recordings are finalized when possible, and non-empty partial artifacts are preserved for recovery instead of being deleted.
- Stabilized editor saves, sidebar navigation, and macOS CI timing-sensitive coverage.

## Distribution

- Apple Silicon and Intel Mac disk images are Developer ID signed, notarized, stapled, and verified with Gatekeeper.
- npm and the VS Code extension are published from the version tag through their normal release workflows.
- iOS build 27 is published to TestFlight for internal and external testing.

## 0.7.1 - 2026-09-02

# OpenOrg 0.7.1

OpenOrg 0.7.1 is a performance and reliability release focused on keeping large workspaces, long AI chats, editing, and background activity responsive.

## Highlights

- Reworked workspace data flow, file cataloging, document mutation, source indexing, and editor buffering to keep navigation and editing responsive as corpora grow.
- Sharded AI chat transcript storage and added a durable operation journal so long histories and background deliveries no longer require rewriting one large shared record.
- Reduced chat rendering, selection, layout, attachment-preview, and teardown work across local, Codex, Claude Code, and OpenClaw conversations.
- Moved expensive Mobile Remote work away from latency-sensitive UI paths and tightened synchronization with the desktop workspace.
- Added explicit performance budgets, representative large-corpus fixtures, native regression gates, and dedicated macOS performance CI.
- Made subprocess stdin and output handling resilient around EOF and process teardown.
- Corrected daily-note placement so invalid or missing configuration falls back to the corpus's `daily/` directory instead of the corpus root.

## Reliability

- Stabilized timing-sensitive macOS tests and performance workflows while preserving deterministic regression coverage.
- Removed redundant or timing-dependent integration cases that duplicated stronger behavioral checks.
- Updated the release procedure to preserve successful architecture artifacts, resume checkpoints, and use GitHub Trusted Publishing for npm without requiring a local npm token.

## Distribution

- Apple Silicon and Intel Mac disk images are Developer ID signed, notarized, stapled, and verified with Gatekeeper.
- npm and the VS Code extension are published from the version tag through GitHub Trusted Publishing and the Marketplace workflow.
- iOS is intentionally not included in this release.

## 0.7.0 - 2026-09-01

# OpenOrg 0.7.0

OpenOrg 0.7.0 makes ordinary `.org` files the default, formalizes the Org2 language contract, and adds a complete first pass at destination-neutral automations and portable agent tooling.

## Highlights

- New documents use `.org`, while existing `.org2` files remain fully supported. Markdown-style fences and inline backticks remain convenient input syntax and are saved canonically as Org syntax.
- The language standard now includes a normative EBNF surface grammar, contextual parsing rules, executable ambiguity cases, canonical AST schema, and conformance fixtures without replacing the optimized production parser.
- OpenOrg Automations can target Codex, Claude Code, OpenClaw, or direct providers; schedule controls cover intervals, daily, weekdays, weekly, monthly, timezone-aware times, and advanced cron expressions.
- Automations now surface creation and scheduler errors, can be deleted from the Mac UI with preserved run history, and expose a preview-first `org2 workflow delete` command.
- A portable Org2 agent skill now ships with npm and OpenOrg, alongside a dedicated MCP and agent-skills guide and a preview-first skill installer.
- Local web/PDF publication links persist across relaunch and now keep the same URL when the same document scope and format are republished.
- Charts support multiple series, and `.org` canonicalization is consistent across the Mac app, CLI, LSP, and VS Code.

## Reliability and polish

- Reduced source-editor typing lag by removing a highlight feedback loop.
- Improved large AI-chat performance, stale-task recovery, and transcript-wide text selection across paragraphs and messages.
- Improved live workspace tab dragging and stabilized timing-sensitive CI checks.
- Reduced duplicate validation in the coordinated release pipeline while preserving its independent publication gate.

## Compatibility

- Existing `.org2` documents and structured runtime records remain supported.
- This release updates the npm package, VS Code extension, and notarized Apple Silicon and Intel OpenOrg builds.
- iOS/TestFlight is intentionally not included in this release.

## 0.6.0 - 2026-08-30

## Highlights

- OpenOrg now keeps Google Drive publications linked to their source. The first publish records the Drive artifact and guarded version in the relevant `.org2` property drawer; publishing that scope and format again updates the same Doc, Slides deck, Sheet, or PDF instead of creating a duplicate.
- A green Google Drive badge in the document header makes linked artifacts easy to reopen or copy, and the publish sheet clearly distinguishes first-time publishing from updating an existing destination.
- Distributed Mac builds now include OpenOrg's registered Google OAuth desktop client, so most users can connect Google Drive directly while custom clients remain available for self-built deployments.
- The workspace's Context pane and source-cited Brief experience are now represented throughout the product guidance, demo corpus, and generated site.
- Release packaging now verifies the Google OAuth configuration before producing distributable Mac artifacts.

## Stability and polish

- Preserves guarded Google Drive replacement semantics so remote changes or comments are not silently overwritten.
- Improves the getting-started guidance around runtime-neutral agent work, triggers, approvals, and durable corpus records.
- Refreshes the macOS product screenshots and feature presentation for the current workspace UI.

## 0.5.4 - 2026-08-30

## OpenOrg 0.5.4

- Adds signed automatic updates to the Mac app.
- Checks quietly at launch and every two hours by default.
- Adds a manual Check for Updates command and settings to disable checks or install downloaded updates on quit.
- Supports Install, Remind Later, and Skip This Version through the standard macOS update flow.
- Publishes architecture-specific, cryptographically signed update feeds for Apple Silicon and Intel.
- Adds independent workspace tabs with mouse selection, close controls, right-click actions, drag-and-drop reordering, and keyboard navigation.

## 0.5.3 - 2026-08-30

## Highlights

- Add Local Claude Code as an optional OpenOrg AI destination using the installed Claude Code CLI and the user's existing Anthropic sign-in.
- Stream replies, resume Claude sessions, pass explicit attachments and corpus context, and expose Claude Code through shared rooms and Mobile Remote.
- Map OpenOrg local-agent permissions to Claude Code Plan, Accept Edits, and Bypass Permissions modes while preserving the participants in existing rooms.

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
