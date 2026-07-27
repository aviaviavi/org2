# Org2 for OpenClaw

This directory contains the native OpenClaw runtime integration for Org2 Run Center.
It is deliberately maintained in the Org2 repository so lifecycle schema and CLI
changes can be tested with the bridge that consumes them.

The plugin tracks substantial main-agent turns, subagent executions, and cron
executions. It also prepares manual Org2 workflow runs before agent execution,
reconciles active schedule triggers from visible `workflows/*.org2` files into
OpenClaw cron, and continues an existing run in its correlated chat session
after an approval returns the run to `running`. A revision request must carry
concrete feedback; for an eligible revision-only boundary, the plugin resumes
the correlated session with that durable decision note and instructs the agent
to produce replacement review material on the same run without performing the
protected action. Provider-backed approvals keep an exact
`Provider draft: PROVIDER:TOOL:DRAFT_ID` line. OpenClaw discovers pending
`decisionKeys` from `org2 approvals --format json` and resolves the canonical
pending or decided authority through `org2 run approval-resolve --decision-key
KEY --json`; the CLI owns idempotent request and decision reconciliation, so the
adapter must not create a parallel review run for the same provider action.
Scheduled executions retain one
logical workflow identity while each cron firing has a distinct attempt. When a
schedule declares an Org2 event/fresh-work gate, the adapter asks the CLI to
create the attempt and stops workflow work when the gate returns a skip instead
of inventing an empty durable run. Successful turns record a reviewer-facing
outcome summary; approval and clarification boundaries remain open instead of
being mistaken for completion. Available provider, model, token, and
elapsed-time metadata is copied into the durable run.

Delegated prompts may attach a worker to an existing run with an
`ORG2_RUN_ID:` marker. If a tracked OpenClaw session ends without delivering a
terminal agent event, the adapter fails that still-active run as interrupted
instead of leaving it indefinitely `running`. Runs deliberately paused for an
approval, clarification, or artifact review remain open.

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
