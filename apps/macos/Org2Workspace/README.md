# Org2 Workspace for macOS

## Approval mutation coordination

Approval decisions and other guarded corpus writes use a per-file v2 `.org2-mutation.lock` directory shared by milestone-compatible CLI, macOS, and iOS clients. Older singleton-lock clients fail closed when they encounter the directory, so all local writers should be upgraded together.

The ticket protocol serializes processes that see one locally coherent filesystem. It is not a distributed lock across simultaneous devices or delayed cloud/file-provider replicas; exact approval fingerprints and the final compare-and-swap still provide stale-review detection when replicas diverge.
