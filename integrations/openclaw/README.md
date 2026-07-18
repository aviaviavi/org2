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

Local development:

```sh
cd integrations/openclaw
npm test
openclaw plugins install --link .
openclaw plugins inspect org2-lifecycle --runtime --json
```

OpenClaw configuration must explicitly enable `org2-lifecycle`, allow its typed
conversation hooks, and set `corpusDir` to the target Org2 corpus.
