# Org2 for OpenClaw

This directory contains the native OpenClaw runtime integration for Org2 Run Center.
It is deliberately maintained in the Org2 repository so lifecycle schema and CLI
changes can be tested with the bridge that consumes them.

The plugin tracks substantial main-agent turns, subagent executions, and cron
executions. Stable OpenClaw keys are persisted on Org2 runs for correlation and
deduplication. Ordinary conversation and personal TODOs are not promoted into runs.

Local development:

```sh
cd integrations/openclaw
npm test
openclaw plugins install --link .
openclaw plugins inspect org2-lifecycle --runtime --json
```

OpenClaw configuration must explicitly enable `org2-lifecycle`, allow its typed
conversation hooks, and set `corpusDir` to the target Org2 corpus.
