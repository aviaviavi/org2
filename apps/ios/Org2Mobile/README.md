# Org2 Mobile

This is a bare-minimum iOS SwiftUI app for phone-side Org2 review:

- reads a Files-accessible org2 corpus folder;
- shows scheduled/deadline TODOs in a basic agenda;
- reads the canonical agenda, approvals, and workflow projections from the paired Mac when Mobile Remote is configured;
- falls back to corpus-local agenda and approval discovery only when no Mac is paired;
- queues new notes in `mobile-inbox.org2` so desktop sync can merge/refile them safely;
- lets new notes become scheduled TODOs with Today, Tomorrow, Next Week, Next Month, or a picked date;
- installs a Share extension named "Capture to Org2" for OS-level capture from apps such as X;
- appends approval/discussion actions to `mobile-inbox.org2` in the selected corpus;
- opens a WhatsApp share URL for approval discussion fallback.
- pairs directly with Org2 Workspace on a Mac over Tailscale for live AI chat control.

New-note capture remains a durable outbound request that can sync back to a desktop agent or OpenClaw workflow. When a Mac is paired, approval decisions, TODO state changes, and workflow actions execute directly through the Mac's shared Org2 runtime and update the phone only after canonical state is returned.

## Sync Shape

Recommended first setup:

1. Sync the corpus into an iOS Files-visible folder with Möbius Sync or another Syncthing-compatible app.
2. Open Org2 Mobile and select that folder.
3. Capture notes and approval/discussion actions into `mobile-inbox.org2` in the synced corpus root.
4. Let the desktop side consume queued headings and apply review status changes.
5. Refile mobile notes into daily files after sync has settled.

Tailscale can help devices see each other, but iOS does not provide reliable always-on Syncthing-style background daemon behavior. Treat phone sync as opportunistic: open the sync app before reviewing if the corpus has to be current.

## Mobile Remote

Mobile Remote is independent of corpus file sync. It keeps the Mac app as the AI runtime and lets the iOS app list chats, create a Codex or OpenClaw chat, pin and settle or reopen threads, choose a model and supported reasoning level, dictate into the composer, attach up to four photos, send messages, follow the live connection and work phase, stream replies, copy any message, and stop a live turn. While a response is active, Send becomes Steer and injects guidance into that same Codex or OpenClaw turn; long-pressing it offers Queue as Follow-up instead. The External Threads entry separately lists recent native Codex tasks through the paired Mac, loads a full transcript only when opened, and never resumes or mutates the external task. Continue in New Org2 Thread saves a provenance-marked snapshot under `views/external-threads/` and creates a new local Codex chat with that file staged as context. While a turn is running, meaningful tool activity appears in the same grouped presentation used by the Mac app; low-signal lifecycle events are filtered so an empty activity panel is never shown. Scrolling above the latest content reveals a floating jump-to-bottom control; new streaming content follows automatically only while the reader remains near the bottom. Cited links use Org2's compact accent treatment instead of displaying transport syntax; cited `.org2` and `.org` links open a small, read-only line preview fetched from the Mac. Preview requests use the paired connection and are confined to the active or mounted corpora, including after symlink resolution. In the thread list, swipe right to pin or unpin and swipe left to settle or reopen. A message sent from iOS uses the same thread continuation envelope as the Mac composer: a bounded excerpt of the local transcript plus the thread's cited Org2 file references, supplementing the runtime session cache. It does not inherit whichever page happens to be open on the Mac; only a message composed on the Mac may additionally include that visible selection. Dictation is handled by iOS and its audio is not sent to the Mac. The recorder validates that iOS has a usable microphone input before installing an audio tap and presents a recoverable error when another audio session temporarily owns the input. Photos are resized before they cross the tailnet.

The paired Mac also owns the phone's canonical Agenda, Approvals, and Workflows views. Pulling to refresh asks the Mac to rebuild each projection through the shared CLI. TODO transitions and approval decisions are applied on the Mac before the refreshed result is returned; the phone no longer hides a pending approval while merely queuing an inbox instruction. Run-backed approvals support approve, reject, and request-changes boundaries. Workflows can be activated, paused, returned to draft, and run with their declared inputs; a run opens as an ordinary remote Org2 thread. If the paired Mac is sleeping, unreachable, or too old to expose these endpoints, the app keeps its last canonical snapshot and labels the connection problem instead of substituting independently parsed state.

The Remote screen's **Reply notifications** option polls the paired Mac while the app is open and uses best-effort iOS background refresh while suspended. Replies show a banner without sound or a badge, and tapping one opens its thread. A test-notification action verifies the phone's notification permission. iOS decides when background refresh runs, so a sleeping Mac or unavailable tailnet can delay a notification until the next refresh.

1. Install and sign into Tailscale on the Mac and iPhone with access to the same tailnet.
2. In Org2 Workspace on the Mac, open **Settings → Mobile Remote**.
3. Turn on Mobile Remote, select the detected `100.x.y.z` Tailscale address, and create a one-time pairing code.
4. In Org2 Mobile, open **Remote** and scan the QR code. Manual URL and code entry is also available.

The Mac listener binds only to its Tailscale IPv4 address on port `48922`; it is not exposed on Wi-Fi or the public internet. Tailscale encrypts the transport. Pairing issues a per-device bearer credential, stored in Keychain on both devices, which can be revoked from Mac settings. Pairing codes expire after ten minutes and work once. The Mac must be awake, Org2 Workspace must be running, and the selected AI runtime must already be configured there.

Photo attachments and remote model selection require Mobile Remote protocol v2. Update both the Mac and iOS apps together; the apps reject a mismatched protocol instead of silently dropping attachments.

The app and share extension use the `group.org.org2.mobile` app group so the extension can reuse the selected corpus bookmark. Enable that App Group for both targets in the Apple developer portal before device signing.
