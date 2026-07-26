# Org2 Mobile

This is a bare-minimum iOS SwiftUI app for phone-side Org2 review:

- reads a Files-accessible org2 corpus folder;
- shows scheduled/deadline TODOs in a basic agenda;
- finds legacy corpus-headline approvals such as `ORG2_REVIEW_STATUS: review-required`;
- queues new notes in `mobile-inbox.org2` so desktop sync can merge/refile them safely;
- lets new notes become scheduled TODOs with Today, Tomorrow, Next Week, Next Month, or a picked date;
- installs a Share extension named "Capture to Org2" for OS-level capture from apps such as X;
- queues approval-discussion notes in `mobile-inbox.org2` in the selected corpus;
- applies fingerprint-checked legacy headline decisions directly to their source files;
- opens a WhatsApp share URL for approval discussion fallback.

New-note capture and approval discussions are durable outbound requests that can sync back to a desktop agent or OpenClaw workflow. Legacy headline approval decisions are compare-and-swap mutations of the reviewed source file.

The mobile approval list is deliberately labeled as legacy/corpus-headline only. It does not scan hidden `.org2/runs/` state and therefore is not the complete native Org2 approval queue; use the desktop workspace or CLI for native run approvals.

Headline decisions use a stable identity (`ORG2_APPROVAL_ID`, then `ID`) and a canonical SHA-256 fingerprint of the exact reviewed heading, full nested subtree, properties, and paired action. Approve and reject acquire the shared Org2 mutation lock, re-read and compare that fingerprint under the lock, then use an atomic file replacement. Identity-less legacy headings are decided only when their fingerprint resolves uniquely, and receive an `ORG2_APPROVAL_ID` only as part of a successful decision. Agenda status shortcuts refuse to mutate a pending approval; use Corpus Approvals for the canonical decision.

The v2 mutation lock is a per-file `.org2-mutation.lock` directory shared by milestone-compatible CLI, macOS, and iOS clients. Older singleton-lock clients fail closed when they encounter it. This protocol serializes processes that see one locally coherent filesystem; it is not a distributed lock across simultaneous devices or delayed iCloud/File Provider replicas. Mobile legacy-headline decisions therefore remain best-effort across devices, with the reviewed fingerprint and final compare-and-swap providing stale-review detection.

## Sync Shape

Recommended first setup:

1. Sync the corpus into an iOS Files-visible folder with Möbius Sync or another Syncthing-compatible app.
2. Open Org2 Mobile and select that folder.
3. Capture notes and approval-discussion requests into `mobile-inbox.org2` in the synced corpus root.
4. Review legacy headline approvals directly in their source files; let the desktop side consume queued notes and discussions.
5. Refile mobile notes into daily files after sync has settled.

Tailscale can help devices see each other, but iOS does not provide reliable always-on Syncthing-style background daemon behavior. Treat phone sync as opportunistic: open the sync app before reviewing if the corpus has to be current.

The app and share extension use the `group.org.org2.mobile` app group so the extension can reuse the selected corpus bookmark. Enable that App Group for both targets in the Apple developer portal before device signing.
