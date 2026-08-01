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
- pairs directly with Org2 Workspace on a Mac over Tailscale for live AI chat control.

New-note capture and approvals are durable outbound requests that can sync back to a desktop agent or OpenClaw workflow.

## Sync Shape

Recommended first setup:

1. Sync the corpus into an iOS Files-visible folder with Möbius Sync or another Syncthing-compatible app.
2. Open Org2 Mobile and select that folder.
3. Capture notes and approval/discussion actions into `mobile-inbox.org2` in the synced corpus root.
4. Let the desktop side consume queued headings and apply review status changes.
5. Refile mobile notes into daily files after sync has settled.

Tailscale can help devices see each other, but iOS does not provide reliable always-on Syncthing-style background daemon behavior. Treat phone sync as opportunistic: open the sync app before reviewing if the corpus has to be current.

## Mobile Remote

Mobile Remote is independent of corpus file sync. It keeps the Mac app as the AI runtime and lets the iOS app list chats, create a Codex or OpenClaw chat, pin and settle or reopen threads, choose a model and supported reasoning level, dictate into the composer, attach up to four photos, send messages, follow the live connection and work phase, stream replies and activity, copy any message, and stop a live turn. In the thread list, swipe right to pin or unpin and swipe left to settle or reopen. A message sent from iOS continues the selected remote thread without inheriting whichever page happens to be open on the Mac. Dictation is handled by iOS and its audio is not sent to the Mac. Photos are resized before they cross the tailnet.

1. Install and sign into Tailscale on the Mac and iPhone with access to the same tailnet.
2. In Org2 Workspace on the Mac, open **Settings → Mobile Remote**.
3. Turn on Mobile Remote, select the detected `100.x.y.z` Tailscale address, and create a one-time pairing code.
4. In Org2 Mobile, open **Remote** and scan the QR code. Manual URL and code entry is also available.

The Mac listener binds only to its Tailscale IPv4 address on port `48922`; it is not exposed on Wi-Fi or the public internet. Tailscale encrypts the transport. Pairing issues a per-device bearer credential, stored in Keychain on both devices, which can be revoked from Mac settings. Pairing codes expire after ten minutes and work once. The Mac must be awake, Org2 Workspace must be running, and the selected AI runtime must already be configured there.

Photo attachments and remote model selection require Mobile Remote protocol v2. Update both the Mac and iOS apps together; the apps reject a mismatched protocol instead of silently dropping attachments.

The app and share extension use the `group.org.org2.mobile` app group so the extension can reuse the selected corpus bookmark. Enable that App Group for both targets in the Apple developer portal before device signing.
