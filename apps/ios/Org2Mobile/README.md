# Org2 Mobile

This is a bare-minimum iOS SwiftUI app for phone-side Org2 review:

- reads a Files-accessible org2 corpus folder;
- shows scheduled/deadline TODOs in a basic agenda;
- finds `ORG2_REVIEW_STATUS: review-required` and similar approval candidates;
- queues new notes in `mobile-inbox.org2` so desktop sync can merge/refile them safely;
- lets new notes become scheduled TODOs with Today, Tomorrow, Next Week, Next Month, or a picked date;
- installs a Share extension named "Capture to Org2" for OS-level capture from apps such as X;
- appends approval/discussion actions to `mobile-inbox.org2` in the selected corpus;
- opens a WhatsApp share URL for approval discussion fallback.

New-note capture and approvals are durable outbound requests that can sync back to a desktop agent or OpenClaw workflow.

## Sync Shape

Recommended first setup:

1. Sync the corpus into an iOS Files-visible folder with Möbius Sync or another Syncthing-compatible app.
2. Open Org2 Mobile and select that folder.
3. Capture notes and approval/discussion actions into `mobile-inbox.org2` in the synced corpus root.
4. Let the desktop side consume queued headings and apply review status changes.
5. Refile mobile notes into daily files after sync has settled.

Tailscale can help devices see each other, but iOS does not provide reliable always-on Syncthing-style background daemon behavior. Treat phone sync as opportunistic: open the sync app before reviewing if the corpus has to be current.

The app and share extension use the `group.org.org2.mobile` app group so the extension can reuse the selected corpus bookmark. Enable that App Group for both targets in the Apple developer portal before device signing.
