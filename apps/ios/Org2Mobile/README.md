# OpenOrg for iOS

This is the OpenOrg iOS app for phone-side Org2 review:

- reads a Files-accessible org2 corpus folder;
- fuzzy-searches pages, headings, and entry text locally, with rendered entries and an Open full note action;
- shows scheduled/deadline TODOs in a basic agenda;
- reads the canonical agenda and approvals from the paired Mac when Mobile Remote is configured;
- falls back to corpus-local agenda and approval discovery only when no Mac is paired;
- queues new notes in `mobile-inbox.org2` so desktop sync can merge/refile them safely;
- lets new notes become scheduled TODOs with Today, Tomorrow, Next Week, Next Month, or a picked date;
- installs a Share extension named "Capture to OpenOrg" for OS-level capture from apps such as X;
- appends approval/discussion actions to `mobile-inbox.org2` in the selected corpus;
- opens a WhatsApp share URL for approval discussion fallback.
- pairs directly with OpenOrg on a Mac over Tailscale for live AI chat control.

New-note capture remains a durable outbound request that can sync back to a desktop agent or OpenClaw workflow. When a Mac is paired, approval decisions and TODO state changes execute directly through the Mac's shared Org2 runtime and update the phone only after canonical state is returned.

## Sync Shape

Recommended first setup:

1. Sync the corpus into an iOS Files-visible folder with Möbius Sync or another Syncthing-compatible app.
2. Open OpenOrg and select that folder.
3. Capture notes and approval/discussion actions into `mobile-inbox.org2` in the synced corpus root.
4. Let the desktop side consume queued headings and apply review status changes.
5. Refile mobile notes into daily files after sync has settled.

Tailscale can help devices see each other, but iOS does not provide reliable always-on Syncthing-style background daemon behavior. Treat phone sync as opportunistic: open the sync app before reviewing if the corpus has to be current.

## Mobile Remote

Mobile Remote is independent of corpus file sync. It keeps the Mac app as the AI runtime while the iOS AI sidebar lists chats, creates or forks a chat using any enabled Mac destination, including Codex, Claude Code, and OpenClaw, pins and settles or reopens threads, and links to read-only External Threads. Thread screens choose a model and supported reasoning level, dictate into the composer, attach up to four photos, send messages, follow the live connection and work phase, stream replies, copy any message, and stop a live turn. They are presented outside the workspace tab container, so the chat composer is the only bottom control bar while reading a conversation. While a response is active, Send becomes Steer when the selected destination supports live steering; long-pressing it offers Queue as Follow-up instead. Mention completion is available in the composer. Mentioning another destination in a single-agent chat automatically forks the transcript into a new shared room, navigates to it, and sends the message to that harness while leaving the source thread unchanged. The External Threads entry separately lists the same recency-ordered, paginated native Codex catalog exposed by the paired Mac, filters every loaded title, preview, workspace path, and source, loads a full transcript only when opened, and never resumes or mutates the external task. **Fork into Org2** saves a provenance-marked snapshot under `views/external-threads/` and creates a new local Codex chat with that file staged as context. While a turn is running, meaningful tool activity appears in the same grouped presentation used by the Mac app; low-signal lifecycle events are filtered so an empty activity panel is never shown. Scrolling above the latest content reveals a floating jump-to-bottom control; new streaming content follows automatically only while the reader remains near the bottom. Cited links use Org2's compact accent treatment instead of displaying transport syntax; cited `.org2` and `.org` links first open the complete local synced file and scroll to the cited line, falling back to the paired Mac only when the local copy is unavailable. The reader preserves long source lines and scrolls both horizontally and vertically. The dedicated **Files** tab indexes readable text files in the selected corpus and searches note titles, headings, and entry text on-device while the user types. Queries such as `pour over`, `pourover`, or `por over` find a “Pour over” heading, with heading matches ranked above body mentions; `coffee` finds entries mentioning coffee. Results show their parent note and a short preview. Tapping an Org result opens the rendered page or heading subtree, with **Open full note** and **Source** available. Search uses all visible Org files, independent of agenda-file selection, respects corpus ignores, refreshes from synced source, and caches its index for reopening. The bundled shared Org2 parser and HTML renderer run locally; opening a result never requires the Mac or Tailscale. The local rendered reader disables scripts and remote embedded resources; non-Org text files and chat citations retain the source reader. In the thread list, swipe right to pin or unpin and swipe left to settle or reopen. A message sent from iOS uses the same thread continuation envelope as the Mac composer: a bounded excerpt of the local transcript plus the thread's cited Org2 file references, supplementing the runtime session cache. It does not inherit whichever page happens to be open on the Mac; only a message composed on the Mac may additionally include that visible selection. Dictation is handled by iOS and its audio is not sent to the Mac. The recorder validates that iOS has a usable microphone input before installing an audio tap and presents a recoverable error when another audio session temporarily owns the input. Photos are resized before they cross the tailnet.

Long conversations render a bounded page of messages on the phone. Earlier/newer controls navigate the complete history without growing the view indefinitely. Large messages, streaming replies, and reasoning show a bounded preview with **Read full message** opening a selectable, scrolling text reader. Copy preserves the complete message.

The paired Mac also owns the phone's canonical Agenda and Approvals views. Pulling to refresh asks the Mac to rebuild each projection through the shared CLI. TODO transitions and approval decisions are applied on the Mac before the refreshed result is returned; the phone no longer hides a pending approval while merely queuing an inbox instruction. Run-backed approvals support approve, reject, and request-changes boundaries. Workflow controls are intentionally omitted from the mobile navigation for now. If the paired Mac is sleeping, unreachable, or too old to expose these endpoints, the app keeps its last canonical snapshot and labels the connection problem instead of substituting independently parsed state.

The AI sidebar's **Settings → Reply Notifications** option registers the paired phone for Apple Push Notification service (APNs). When the Mac receives a new assistant reply, it sends a quiet banner immediately through APNs; tapping it opens the matching thread. The app's foreground polling and best-effort iOS background refresh remain as a duplicate-safe fallback. **Send Test Notification** exercises the real Mac-to-APNs-to-phone path instead of showing a local test banner. The Mac must be awake with OpenOrg running to originate a push, but the phone does not need the OpenOrg app open or Tailscale active when APNs delivers it.

1. Install and sign into Tailscale on the Mac and iPhone with access to the same tailnet.
2. In OpenOrg on the Mac, open **Settings → Mobile Remote**.
3. Turn on Mobile Remote, select the detected `100.x.y.z` Tailscale address, and create a one-time pairing code.
4. In OpenOrg, open the AI sidebar, choose **Settings → Connect a Mac**, and scan the QR code. Manual URL and code entry is also available.
5. For real-time reply notifications, add the Apple Developer Team ID and APNs key ID under **Settings → Mobile Remote → Real-time Reply Notifications**, then import the downloaded `.p8` APNs authentication key. Org2 stores the private key only in the Mac Keychain; it is never written into the corpus or sent to the phone.

The Mac listener binds only to its Tailscale IPv4 address on port `48922`; it is not exposed on Wi-Fi or the public internet. Tailscale encrypts the transport. Pairing issues a per-device bearer credential, stored in Keychain on both devices, which can be revoked from Mac settings. Pairing codes expire after ten minutes and work once. The Mac must be awake, OpenOrg must be running, and the selected AI runtime must already be configured there.

Photo attachments and remote model selection require Mobile Remote protocol v2. Update both the Mac and iOS apps together; the apps reject a mismatched protocol instead of silently dropping attachments.

Notification taps are retained until the root navigator accepts them, including cold launches and background resumes. Reply taps open the conversation without waiting for the host's thread list; if pairing is needed, Settings opens and the tap is retained until pairing completes. Due-today taps open Agenda, including notifications scheduled by earlier app versions. Dismissed notifications never navigate. The latest tap wins, and an accepted tap does not replay on the next activation.

The app and share extension use the `group.org.org2.mobile` app group so the extension can reuse the selected corpus bookmark. Enable that App Group for both targets in the Apple developer portal before device signing.

## Headless host pairing

Mobile Remote also connects to `org2 server` on a dedicated Mac. Settings → Host Connection saves a separate Keychain credential for each host and selects one host at a time. Existing Mac pairings migrate automatically. Hosts serve the chat history persisted in their configured corpus; selecting another host does not copy history or agent runtime sessions. Simultaneous desktop/server chat editing against synced corpus copies is not coordinated. See [headless server setup](../../../docs/site/headless-server.org).

## Local document runtime

Run `npm run build:mobile-document` after shared parser/renderer changes and before an iOS build. The checked-in JavaScriptCore resource is verified by `npm run check:mobile-document` and `node test/test-ios-mobile-navigation.mjs`. The bridge supplies file and corpus TODO definitions explicitly and provides no filesystem APIs to JavaScript.

The Files view warms one background document renderer unless Low Power Mode is active. Note opens reuse that engine and at most one rendered result, with a 2 MiB source/HTML budget. The cache key includes the full source, selected entry, path, corpus, and TODO definitions; source reads still happen on each open. The engine and result are released after 60 seconds idle, on memory pressure, and when the app enters the background. Corpus-cache encoding and atomic writes run on a separate actor, with generation ordering to prevent a delayed save from replacing a newer snapshot. Reopening Files reuses an already loaded snapshot rather than rehydrating the disk cache.

`node test/test-ios-transcript.mjs` exercises renderer reuse, source/workflow invalidation, cancellation, resource release, ordered cache persistence, and long-prose performance through the actual JavaScriptCore bridge.

Chat renders labeled and bare Org entry links as tappable links. Stable `id:` links resolve within the selected synced corpus; `file:note.org::*Heading`, `::#CUSTOM_ID`, and `::42` select the entry from freshly read source. Missing or ambiguous entries show an error instead of opening the wrong section. Entry views include Open full note and Source. Internal links in rendered notes use the same reader and resolve file paths relative to the source note; external web links remain external.
