# Org2 for OpenClaw

This directory contains the native OpenClaw runtime integration for Org2 Run Center.
It is deliberately maintained in the Org2 repository so lifecycle schema and CLI
changes can be tested with the bridge that consumes them.

The plugin tracks substantial main-agent turns, subagent executions, and cron
executions. It also prepares manual Org2 workflow runs before agent execution,
reconciles active schedule triggers from visible `workflows/*.org2` files into
OpenClaw cron, and continues an existing run in its correlated chat session
after an approval returns the run to `running`. Successful turns record a
reviewer-facing outcome summary; approval and clarification boundaries remain
open instead of being mistaken for completion. Available provider, model,
token, and elapsed-time metadata is copied into the durable run.

The adapter remains pinned to one configured `corpusDir` for writes. Mac
workflow requests include the selected portable corpus ID, and the plugin
rejects a mismatch before creating, syncing, or continuing work. Stable
OpenClaw keys are persisted for correlation and deduplication. Ordinary
conversation and personal TODOs are not promoted into runs.

The plugin also exposes `org2_gmail_draft_send` as the only supported Gmail
draft-send path. Recognizable direct shell and API sends fail closed. The typed
tool resolves one configured absolute `gog` executable, re-reads the provider
draft, resolves account aliases to the canonical provider mailbox identity, and
binds that identity, ordered headers and thread identity, every MIME body, every
attachment byte digest, and the exact RFC822 raw digest into canonical
structured JSON. Reviewer prose is kept separate from the native approval
authority.

Immediately before the provider call, the tool atomically reserves the approved
fingerprint and exact material digest under its tool-call ID. Only that
reservation can consume the effect; a crash or ambiguous provider response
leaves an uncertain reservation that cannot silently become sendable again.
The provider call sends the exact reviewed RFC822 snapshot rather than
re-reading mutable draft content by ID. Successful sends require strict,
matching provider message and thread identities and record a matching native
effect receipt. The provider draft is intentionally retained: deleting by its
mutable ID after the send could erase a concurrent edit. Typed runtime targets
let the adapter reconstruct the approval correlation after private state loss,
while locked state writes preserve future schema fields and versions. Provider
draft IDs and private plugin state remain correlation caches, not alternate
approval authorities.

This plugin is not a host egress sandbox. Opaque arbitrary shell code cannot be
proven mail-free from command text alone, so deployments that expose general
exec must keep Gmail send credentials and Gmail API egress unavailable there.
The native Org2 approval remains authoritative; the typed sender is its
execution boundary. Host credential isolation is the enforcement boundary for
code the plugin cannot identify.

Local development:

```sh
cd integrations/openclaw
npm test
openclaw plugins install --link .
openclaw plugins inspect org2-lifecycle --runtime --json
```

OpenClaw configuration must explicitly enable `org2-lifecycle`, allow its typed
conversation hooks, and set `corpusDir` to the target Org2 corpus.
