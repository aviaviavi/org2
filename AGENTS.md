# Org2 Agent Brief

## What this project is
- An effort to build a from-scratch successor to Emacs org mode that works in any editor and on any platform. See the original vision post: https://avi.press/posts/2024-01-15-standalone-org.html.
- Goal: a comprehensive org experience decoupled from Emacs, with a formal spec and thriving plugin ecosystem.
- Current state: concept only; no code written yet.

## Guiding principles (from the post)
- Favor a clear, sane standard over bug-for-bug Emacs compatibility; let quirks go.
- Choose a popular language to maximize contributors; portability and easy editor integration are essential.
- Make flagship org features first-class: agenda, publishing, plugin support (e.g., org-roam, org-crypt).

## How to help
- If you want to contribute or mentor/launch the initial implementation, please reach out to the maintainer.
- Useful starting work: exploring language/runtime options, drafting a spec for core org constructs, and mapping editor-integration paths.

## macOS app development workflow
- The user's daily app is `/Users/avi/Applications/Org2Workspace.app` with bundle identifier `org.org2.workspace`. Do not quit, overwrite, re-sign, or relaunch it during development unless the user explicitly asks to update the main app.
- Codex development and smoke testing should use `/Users/avi/Applications/Org2Workspace Codex.app` with bundle identifier `org.org2.workspace.codex`.
- Build the Codex app with `npm run build:macos-app:codex`; open it with `npm run open:macos-app:codex`.
- The Codex app defaults point at `.codex/org2-workspace-corpus`, a disposable sandbox corpus. Do not point the Codex app at `/Users/avi/avi.org2` unless the user explicitly asks for real-corpus testing.
- After changes are validated and the user wants to pick them up, promote the build by running `npm run build:macos-app` or by merging/pushing and letting the user update their normal app.
