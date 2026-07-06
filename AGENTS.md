# Org2 Agent Brief

## What this project is
- Org2 is now an early-alpha local-first knowledge compiler for Org-shaped plain text, not just a concept.
- The center of gravity is the shared compiler/runtime layer: parse ordinary files into structured semantics, then derive agendas, graph data, lint reports, exported sites, editor intelligence, and agent-readable context.
- The project still follows the original standalone Org vision: a comprehensive Org experience decoupled from Emacs and usable from multiple editors/platforms. See https://avi.press/posts/2024-01-15-standalone-org.html.

## Current architecture
- Core parser, CLI, publishing, corpus operations, LSP, and AI/agent-facing utilities live primarily in TypeScript under `src/`.
- The macOS app lives under `apps/macos/Org2Workspace/` and is a native Swift workspace shell over normal Org2/Org files.
- The app calls the shared CLI/parser output through `dist/cli.js` and `dist/parse.js`; it should not become a private database or the canonical parser.
- Editor integrations should sit on top of shared semantics. VS Code + CLI is still the best-supported general editing workflow; the Mac app is for dogfooding richer workspace workflows.

## Product direction
- Favor a clear, sane Org2 standard over bug-for-bug GNU Org compatibility.
- Keep ordinary plain-text files as the source of truth. Every app/editor/agent workflow should write inspectable Org2 text that can be reviewed in Git or another editor.
- Treat the macOS rendered editor as a structured block/workflow surface, not as a replacement for a full general-purpose text editor.
- Raw source editing remains the full-fidelity escape hatch when rendered editing is awkward or incomplete.
- Do not let Swift rendering/editing logic drift into becoming the real language implementation. Semantic parsing, source ranges, IDs, links, agenda behavior, and agent context should come from the shared compiler/runtime whenever practical.

## Agent and OpenClaw direction
- Org2 is a good substrate for agent workflows because it has local files, citations, provenance, review states, TODOs, approvals, and generated artifact zones.
- Keep AI/provider behavior optional and layered above deterministic compiler outputs.
- Generated work should land in reviewable places such as `views/` or `compiled/` before promotion into canonical `notes/`.
- Agents should prefer small, cited, reviewable file changes and should run lint/tests around writes when practical.

## Common development workflow
- Install/build the TypeScript core with `npm install` and `npm run build`.
- Run the full Node test suite with `npm test`; prefer targeted `node test/...mjs` tests while iterating.
- The macOS app expects `dist/cli.js` and `dist/parse.js` to exist, so run `npm run build` before app testing when parser/CLI code changed.
- Swift package tests live under `apps/macos/Org2Workspace/Tests/Org2WorkspaceCoreTests/`.

## macOS app development workflow
- The user's daily app is `/Users/avi/Applications/Org2Workspace.app` with bundle identifier `org.org2.workspace`. Do not quit, overwrite, re-sign, or relaunch it during development unless the user explicitly asks to update the main app.
- Codex development and smoke testing should use `/Users/avi/Applications/Org2Workspace Codex.app` with bundle identifier `org.org2.workspace.codex`.
- Build the Codex app with `npm run build:macos-app:codex`; open it with `npm run open:macos-app:codex`.
- The Codex app defaults point at `.codex/org2-workspace-corpus`, a disposable sandbox corpus. Do not point the Codex app at `/Users/avi/avi.org2` unless the user explicitly asks for real-corpus testing.
- After changes are validated and the user wants to pick them up, promote the build by running `npm run build:macos-app` or by merging/pushing and letting the user update their normal app.
