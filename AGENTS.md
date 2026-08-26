# Org2 Agent Guide

OpenClaw is the primary agent runtime for this repository today. These
instructions are written so an OpenClaw coding session can work safely without
assuming that the macOS app, a generated index, or model memory is the source of
truth.

## Start here

1. Read this file and inspect `git status` before changing anything. Preserve
   unrelated work in a dirty tree.
2. Decide whether the task concerns this repository or an Org2 corpus. This file
   governs repository work. For corpus writes, also read
   `docs/site/openclaw-knowledge-layer.org` and the nearest `org2.json`.
3. In a fresh checkout, install the locked dependencies with `npm ci`. Reuse an
   existing `node_modules/` when dependencies have not changed. Build before
   using the checkout's CLI:

   ```sh
   npm run build
   npm run org2 -- agent capabilities
   ```

   During development, prefer `npm run org2 -- ...` or `node dist/cli.js ...`
   over a globally installed `org2`; the global binary may describe a different
   version.
4. Ask the implementation what it supports instead of relying on remembered
   flags:

   ```sh
   npm run org2 -- --help
   npm run org2 -- COMMAND --help
   npm run org2 -- agent capabilities
   ```

## Product and architecture

- Org2 is an early-alpha, local-first knowledge compiler and runtime for
  Org-shaped plain text. Ordinary `.org2` and `.org` files are canonical.
- The TypeScript compiler/runtime under `src/` owns parsing, semantics, source
  ranges, IDs, links, agenda behavior, corpus operations, publishing, LSP
  behavior, and agent-facing interfaces. Build output goes to `dist/`.
- Apps and editor integrations are clients of shared semantics. Do not create a
  second parser, private canonical database, or app-only language behavior.
- `apps/macos/Org2Workspace/` is the native Swift workspace and OpenClaw chat
  client. It shells out to the built shared CLI/parser where appropriate.
- `apps/ios/Org2Mobile/` is a lightweight review and capture client. Its
  `mobile-inbox.org2` flow is an append-oriented transport boundary, not a new
  source of language semantics.
- `integrations/openclaw/` contains the native `org2-lifecycle` plugin.
  OpenClaw is the deepest current integration, but run files, workflows, CLI
  JSON, cited context, and MCP interfaces must remain portable to other agents.
- VS Code plus the CLI remains the strongest general editing workflow. The
  macOS rendered editor is a structured workflow surface; raw source editing is
  the full-fidelity escape hatch.
- Prefer a coherent Org2 standard over bug-for-bug GNU Org compatibility.

## Non-negotiable data boundaries

- Keep inspectable plain text as the source of truth. Derived indexes, compiled
  context, app state, and OpenClaw state must be disposable or reconstructible.
- Preserve file/line citations, stable IDs, source ranges, provenance, and
  review state through agent workflows.
- Preview mutations first. Most Org2 write commands require `--apply`; inspect
  the preview or JSON envelope before applying it.
- Write generated or uncertain work to `views/` or `compiled/`. Promotion into
  canonical `notes/` is an explicit review action.
- Keep raw imports in `raw/` and minimize rewriting them. Keep publish output
  derived from reviewed source.
- Never put credentials, tokens, cookies, private keys, or machine-local
  bindings in a corpus, run, workflow, generated artifact, fixture, or
  documentation example.
- Multi-corpus reads require explicit mounts. A human-visible app mount is not
  implicit agent authority. Writes remain scoped to one active corpus.
- Do not perform external side effects—messages, tickets, calendar changes,
  publishing, or other third-party writes—without explicit authorization and
  an inspectable approval boundary.

## OpenClaw integration contract

The `org2-lifecycle` plugin maps substantial main-agent turns, subagent work,
and cron executions into durable Org2 runs. It also prepares manual workflow
runs, reconciles active workflow schedules into OpenClaw cron, and resumes an
approved workflow in its correlated chat session.

When changing this path:

- Keep the adapter pinned to its configured `corpusDir`. Validate the portable
  corpus ID supplied by the Mac app before creating, syncing, or continuing
  work; fail closed on a mismatch.
- Preserve stable OpenClaw correlation and idempotency keys. A retry or resumed
  event must update the same run rather than create a duplicate.
- Do not promote ordinary conversation or personal TODOs into durable runs.
- Treat approvals, clarifications, and `review-required` artifacts as open
  boundaries. A successful agent turn is not the same as a completed durable
  run.
- Record available provider, model, token, cost, and elapsed-time metadata, but
  never credentials.
- On successful completion, record a concise reviewer-facing outcome summary.
  On failure or blockage, record an actionable reason rather than a generic
  status.
- Keep workflow declarations in visible top-level `workflows/`; continue to
  read the legacy `.org2/workflows/` path where compatibility requires it.
- Use shared CLI lifecycle operations instead of hand-editing machine-state
  blocks in `.org2/runs/*.org2`.

The checked-out plugin can be tested and inspected with:

```sh
npm run test:openclaw
openclaw plugins inspect org2-lifecycle --runtime --json
```

Installing the linked plugin, changing OpenClaw configuration, restarting the
Gateway, or reconciling a real user's schedules changes external runtime state.
Do those only when the user explicitly asks. Source-local plugin instructions
live in `integrations/openclaw/README.md`.

## Durable run behavior

Use the CLI contract for durable delegation:

- `run create/list/show/start/resume/cancel/fork/reopen-external` manages the lifecycle.
- `run block ID --reason "Specific clarification or next action"` records a
  useful blocker; reasonless blocks are invalid. If the run already has a
  pending approval, leave it in `waiting-approval`. A genuinely independent
  clarification or operational condition requires `--separate-from-approval`,
  and Org2 rejects that override when the reason merely restates the approval.
- `run approval-decide` is the only way to decide a run-backed approval.
  `org2 approvals` and Agent Work are projections of that same run record; do
  not create a duplicate heading for the decision.
- `run artifact-review` records review of an output and updates linked Org
  artifact metadata when applicable.
- `run complete ID --summary "What happened"` is allowed only when acceptance
  criteria are met and no review-required artifact remains open.
- `run complete-external` is for a person-confirmed outcome completed elsewhere;
  an agent must not infer that resolution.
- `run reopen-external` repairs a mistaken whole-run external completion from
  `waiting-approval` without replacing the run or its retained approval IDs.
- `run runtime` records observable execution metadata.

Authored workflows under `workflows/` are reviewable recipes. They declare
inputs, capabilities, outputs, checks, triggers, and approval boundaries.
Schedule declarations remain portable in the file; OpenClaw owns due checks and
execution state.

## Repository map

- `src/`: TypeScript parser, CLI, compiler/runtime, LSP, publishing, corpus,
  workflow, and agent utilities.
- `test/`: Node integration and regression tests; `test/agent/` contains focused
  agent/context coverage.
- `spec/v0/`: language specification and conformance documents.
- `apps/macos/Org2Workspace/`: Swift package for the native macOS workspace.
- `apps/ios/Org2Mobile/`: iOS app and share extension.
- `integrations/openclaw/`: OpenClaw lifecycle plugin and its unit tests.
- `editors/`: VS Code and Vim integrations.
- `tree-sitter-org2/`: tree-sitter grammar and queries.
- `docs/site/`: canonical documentation sources.
- `site/`: generated website output; never hand-edit it.
- `examples/`: reviewable examples and synthetic demo corpora.
- `.codex/org2-workspace-corpus/`: disposable development corpus for the Codex
  macOS app.

## Implementation rules

- Put shared semantics in TypeScript first. Swift, editor extensions, and
  OpenClaw should consume the shared output rather than reinterpret source.
- Keep changes small and preserve existing formatting and source ranges where
  possible. Do not rewrite unrelated corpus or source content.
- Add or update a focused regression test for behavior changes. Prefer the
  narrowest useful test while iterating, then broaden verification based on
  risk.
- Treat schemas and JSON envelopes as public contracts. Make versioning and
  compatibility deliberate.
- Keep AI/provider behavior optional above deterministic compiler output.
- If a pre-existing test or lint failure is present, record it and verify the
  change does not add a new failure.

## Validation matrix

Choose checks that match the affected surface:

```sh
# TypeScript build
npm run build

# Focused Node test
node test/path-to-test.mjs

# Agent/run/workflow behavior
npm run test:agentic

# OpenClaw plugin plus end-to-end lifecycle contract
npm run test:openclaw

# Corpus identity behavior
npm run test:corpus

# LSP behavior
npm run test:lsp

# Swift package tests
swift test --package-path apps/macos/Org2Workspace

# Full repository suite
npm test
```

The full suite is appropriate for broad parser, CLI, schema, or cross-client
changes. A documentation-only instruction change does not require the entire
runtime suite, but it still requires the documentation checks below.

## Documentation contract

- Treat documentation impact as part of every feature change. Update canonical
  sources under `docs/site/`; do not hand-edit generated `site/` HTML.
- Run `npm run docs:check` when agent discovery, CLI/API behavior, workflows,
  safety boundaries, configuration, app surfaces, or roadmap claims change.
- Run `npm run check:generated` when generated artifacts are intentionally
  updated.
- When adding or removing a public capability, keep `org2 agent capabilities`,
  `docs/site/agent-quickstart.org`, `docs/site/llms.txt`,
  `docs/site/features.org`, and the relevant reference/editor page aligned.
- If no user-facing docs change is needed, say why in the change summary.

## Coordinated releases

Use the repository-owned `.codex/skills/org2-release/SKILL.md` workflow when
cutting, repairing, or auditing a release. It covers npm, VS Code Marketplace,
the macOS DMG, GitHub Releases, and the Scarf-tracked downloads surface. After
all assets are attached, preview and apply `tools/sync-release-downloads.mjs`
so `docs/site/downloads.org` and every GitHub release body use the permanent
Scarf Gateway redirect while GitHub Releases remains the artifact host.

## macOS development safety

The user's daily app is `/Users/avi/Applications/Org2Workspace.app` with bundle
identifier `org.org2.workspace`. Do not quit, overwrite, re-sign, or relaunch it
unless the user explicitly asks to update the main app.

Use the isolated development app:

```sh
npm run build:macos-app:codex
npm run open:macos-app:codex
```

It installs as `/Users/avi/Applications/Org2Workspace Codex.app` with bundle
identifier `org.org2.workspace.codex` and defaults to the disposable
`.codex/org2-workspace-corpus`. Do not point it at
`/Users/avi/avi.org2` without explicit permission. Build the daily app with
`npm run build:macos-app` only when the user asks to promote a validated build.

## Before handing off

1. Re-read the diff and confirm only intended files changed.
2. Run the smallest complete set of checks for the affected surfaces.
3. Report behavior changed, validation run, remaining risks, and documentation
   impact.
4. Do not commit, push, install plugins, restart services, publish, or update the
   daily app unless the user requested that external action.
