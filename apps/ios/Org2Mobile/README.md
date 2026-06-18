# Org2 Mobile

This is a bare-minimum iOS SwiftUI app for phone-side Org2 review:

- reads a Files-accessible org2 corpus folder;
- shows scheduled/deadline TODOs in a basic agenda;
- finds `ORG2_REVIEW_STATUS: review-required` and similar approval candidates;
- appends new notes directly to today's daily note in the selected corpus;
- appends approval/discussion actions to `mobile-inbox.org2` in the selected corpus;
- opens a WhatsApp share URL for approval discussion fallback.

New-note capture mutates the selected corpus directly. Approvals are durable outbound requests that can sync back to a desktop agent or OpenClaw workflow.

## Sync Shape

Recommended first setup:

1. Sync the corpus into an iOS Files-visible folder with Möbius Sync or another Syncthing-compatible app.
2. Open Org2 Mobile and select that folder.
3. Capture notes directly into `YYYY-MM-DD.org2` daily files.
4. Let approval/discussion actions append to `mobile-inbox.org2` in the synced corpus root.
5. Have the desktop side consume queued headings and apply review status changes.

Tailscale can help devices see each other, but iOS does not provide reliable always-on Syncthing-style background daemon behavior. Treat phone sync as opportunistic: open the sync app before reviewing if the corpus has to be current.
