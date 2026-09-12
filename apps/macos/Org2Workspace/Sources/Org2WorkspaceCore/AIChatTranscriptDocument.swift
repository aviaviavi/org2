import AppKit
import SwiftUI
import WebKit

/// One DOM and one native WebKit scroll view own the entire visible transcript.
/// Selection, autoscroll while dragging, and wheel routing are WebKit behavior.
struct AIChatTranscriptDocument: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.openOrgFileReference) private var openFileReference
  @Environment(\.orgRoamLinkResolver) private var linkResolver
  @ObservedObject private var liveState: OpenClawChatLiveState
  @State private var rendered: [UUID: RenderedBody] = [:]
  @State private var preparedLive: PreparedLive?
  @State private var showsAllLiveText = false
  @State private var showsLiveActivity = false
  @State private var previewedAttachment: OpenClawChatAttachment?
  @State private var expandedMessageIDs: Set<UUID> = []
  @State private var copiedMessageID: UUID?
  @State private var copyFeedbackTask: Task<Void, Never>?
  let items: [AIChatRoomTranscriptItem]
  let compact: Bool
  let earlierTitle: String?
  let searchMessageID: UUID?
  let searchGeneration: Int
  let onEarlier: () -> Void
  let onPosition: (Double) -> Void

  init(
    liveState: OpenClawChatLiveState,
    items: [AIChatRoomTranscriptItem],
    compact: Bool,
    earlierTitle: String?,
    searchMessageID: UUID?,
    searchGeneration: Int,
    onEarlier: @escaping () -> Void,
    onPosition: @escaping (Double) -> Void
  ) {
    _liveState = ObservedObject(wrappedValue: liveState)
    self.items = items
    self.compact = compact
    self.earlierTitle = earlierTitle
    self.searchMessageID = searchMessageID
    self.searchGeneration = searchGeneration
    self.onEarlier = onEarlier
    self.onPosition = onPosition
  }

  private struct RenderedBody {
    let source: String
    let expanded: Bool
    let html: String
    let contexts: [AIChatTranscriptHTML.Context]
  }
  private struct RenderInput: Equatable {
    let id: UUID
    let text: String
    let formatted: Bool
    let expanded: Bool
  }
  private struct RenderKey: Equatable { let sourcePath: String; let inputs: [RenderInput] }
  private struct LiveInput: Equatable {
    let threadID: UUID
    let startedAt: Date?
    let lastEventAt: Date?
    let runtime: AIChatRuntime
    let destinationTitle: String
    let connectionState: OpenClawGatewayConnectionState
    let connectionDetail: String?
    let runID: String?
    let preparation: OpenClawLiveTextPreparationInput
  }
  private struct PreparedLive {
    let threadID: UUID
    let startedAt: Date?
    let text: String?
    let hasEarlierText: Bool
    let reasoning: String?
    let activities: [OpenClawActivityFeedItem]
  }
  private struct MessageSlot {
    let message: OpenClawChatMessage
    let isRoomResponse: Bool
  }
  private var messageSlots: [MessageSlot] {
    items.flatMap { item in
      switch item {
      case .message(let message): return [MessageSlot(message: message, isRoomResponse: false)]
      case .round(let round):
        return [MessageSlot(message: round.trigger, isRoomResponse: false)]
          + round.expectedDestinationIDs.compactMap { destination in
            round.response(forDestinationID: destination).map {
              MessageSlot(message: $0, isRoomResponse: true)
            }
        }
      }
    }
  }
  private var messages: [OpenClawChatMessage] { messageSlots.map(\.message) }
  private var sourcePath: String {
    (store.corpusRoot ?? FileManager.default.temporaryDirectory).appendingPathComponent("chat-message.org").path
  }

  private var liveInput: LiveInput? {
    guard store.isSendingOpenClawMessage,
          !store.selectedAIChatIsSharedRoom,
          let threadID = store.selectedOpenClawChatThreadID
    else { return nil }
    let snapshot = liveState.presentationSnapshot(for: threadID)
    return LiveInput(
      threadID: threadID,
      startedAt: store.openClawRequestStartedAt,
      lastEventAt: liveState.lastEventAt(for: threadID),
      runtime: store.selectedAIChatActiveRuntime,
      destinationTitle: store.aiChatDestinationTitle(store.selectedAIChatActiveDestinationID),
      connectionState: liveState.connectionState(for: threadID),
      connectionDetail: liveState.connectionDetail(for: threadID),
      runID: liveState.activeRunID(for: threadID),
      preparation: OpenClawLiveTextPreparationInput(
        rawText: snapshot.streamingReply,
        showsAll: showsAllLiveText,
        hasOmittedPrefix: snapshot.isStreamingReplyTruncated,
        reasoning: snapshot.reasoning,
        reasoningHasOmittedPrefix: snapshot.isReasoningTruncated,
        activities: liveState.runActivities(for: threadID)
      )
    )
  }

  var body: some View {
    let liveInput = liveInput
    let inputs = messages.map { message in
      RenderInput(id: message.id,
        text: message.content,
        formatted: message.role == .assistant,
        expanded: expandedMessageIDs.contains(message.id))
    }
    let entries = zip(messageSlots, inputs).map { slot, input in
      let message = slot.message
      let excerpt = OpenClawMessageBodyExcerpt(
        message.content,
        utf8ByteLimit: input.expanded ? nil : OpenClawMessageBodyExcerpt.collapsedUTF8ByteLimit
      )
      let resolved = rendered[message.id].flatMap {
        $0.source == input.text && $0.expanded == input.expanded ? $0 : nil
      }
      return AIChatTranscriptHTML.Entry(
        id: message.id.uuidString.lowercased(), role: message.role.rawValue,
        title: title(message), timestamp: AIChatMessageTimestampPresentation.displayText(for: message.createdAt),
        html: resolved?.html ?? AIChatDocumentHTML.plain(message.role == .user ? "Preparing message…" : excerpt.text),
        contexts: resolved?.contexts ?? [],
        attachments: message.attachments.map(AIChatTranscriptHTML.Attachment.init),
        failure: message.sendFailure,
        queued: store.isAIChatMessageQueued(message.id),
        canSteer: store.canSteerQueuedAIChatMessage(message.id),
        isRoomResponse: slot.isRoomResponse,
        copied: copiedMessageID == message.id,
        isTruncated: excerpt.isTruncated,
        responseTrace: message.responseTrace.flatMap(AIChatTranscriptHTML.Trace.init),
        changeSummary: message.changeSummary.map(AIChatTranscriptHTML.ChangeSummary.init)
      )
    }
    AIChatTranscriptWebView(
      payload: AIChatTranscriptHTML.Payload(
        thread: store.selectedOpenClawChatThreadID?.uuidString ?? "empty",
        entries: entries, earlier: earlierTitle,
        sending: store.isSendingOpenClawMessage,
        status: store.openClawMessages.isEmpty ? "Ask about your workspace, or request an edit to review." : store.openClawStatusText,
        search: searchMessageID?.uuidString.lowercased(), searchGeneration: searchGeneration,
        initialPosition: store.openClawChatScrollPosition(isAssistantPanel: compact) ?? 1,
        compact: compact,
        live: liveInput.map(livePayload)
      ), sourcePath: sourcePath, corpusRoot: store.corpusRoot,
      linkResolver: linkResolver, openFileReference: openFileReference,
      onAction: handleAction,
      onPosition: { thread, position in
        guard thread == store.selectedOpenClawChatThreadID?.uuidString else { return }
        store.recordOpenClawChatScrollPosition(position, isAssistantPanel: compact, threadID: store.selectedOpenClawChatThreadID)
        onPosition(position)
      }
    )
    .task(id: RenderKey(sourcePath: sourcePath, inputs: inputs)) {
      let ids = Set(inputs.map(\.id))
      rendered = rendered.filter { ids.contains($0.key) }
      for input in inputs where rendered[input.id]?.source != input.text
        || rendered[input.id]?.expanded != input.expanded {
        do {
          try Task.checkCancellation()
          let prepared = await Task.detached(priority: .userInitiated) {
            let excerpt = OpenClawMessageBodyExcerpt(
              input.text,
              utf8ByteLimit: input.expanded ? nil : OpenClawMessageBodyExcerpt.collapsedUTF8ByteLimit
            )
            if input.formatted {
              return (OpenClawMessageOrgNormalizer.normalized(excerpt.text), [AIChatTranscriptHTML.Context]())
            }
            let presentation = OpenClawContextPresentation(excerpt.text)
            return (presentation.userText, presentation.contexts.map(AIChatTranscriptHTML.Context.init))
          }.value
          let html = input.formatted
            ? try await AIChatDocumentRenderCache.shared.render(prepared.0, sourcePath: sourcePath)
            : AIChatDocumentHTML.plain(prepared.0)
          try Task.checkCancellation()
          rendered[input.id] = RenderedBody(
            source: input.text,
            expanded: input.expanded,
            html: html,
            contexts: prepared.1
          )
        } catch is CancellationError { return }
        catch { /* The selectable plain body remains available. */ }
      }
    }
    .task(id: liveInput) {
      guard let liveInput else {
        preparedLive = nil
        showsAllLiveText = false
        showsLiveActivity = false
        return
      }
      if preparedLive?.threadID != liveInput.threadID || preparedLive?.startedAt != liveInput.startedAt {
        preparedLive = nil
      }
      do {
        try await Task.sleep(for: .milliseconds(24))
      } catch {
        return
      }
      let prepared = await OpenClawLiveTextPreparationCoordinator.shared.prepare(
        streamID: liveInput.threadID,
        input: liveInput.preparation
      )
      guard !Task.isCancelled else { return }
      preparedLive = PreparedLive(
        threadID: liveInput.threadID,
        startedAt: liveInput.startedAt,
        text: prepared?.text?.text,
        hasEarlierText: prepared?.text?.hasEarlierText ?? false,
        reasoning: prepared?.reasoning,
        activities: prepared?.activityFeedItems ?? []
      )
    }
    .sheet(item: $previewedAttachment) { attachment in
      OpenClawAttachmentPreviewView(attachment: attachment)
    }
    .onDisappear {
      copyFeedbackTask?.cancel()
      copyFeedbackTask = nil
    }
  }

  private func title(_ message: OpenClawChatMessage) -> String {
    if message.role == .user {
      if !message.audienceDestinationIDs.isEmpty {
        return "You → " + message.audienceDestinationIDs.map(store.aiChatDestinationTitle).joined(separator: " + ")
      }
      return message.audience.map { "You → " + $0.title } ?? "You"
    }
    return message.authorLabel ?? message.authorDestinationID.map(store.aiChatDestinationTitle)
      ?? message.authorRuntime?.title ?? (message.role == .system ? "Org2" : store.selectedAIChatRuntime.title)
  }

  private func livePayload(_ input: LiveInput) -> AIChatTranscriptHTML.Live {
    let now = Date()
    let presentation = OpenClawTypingIndicatorView(
      startedAt: input.startedAt,
      lastEventAt: input.lastEventAt,
      runtime: input.runtime,
      destinationTitle: input.destinationTitle,
      connectionState: input.connectionState,
      connectionDetail: input.connectionDetail,
      runID: input.runID,
      streamingReply: input.preparation.rawText,
      streamingReplyHasOmittedPrefix: input.preparation.hasOmittedPrefix,
      reasoning: input.preparation.reasoning,
      reasoningHasOmittedPrefix: input.preparation.reasoningHasOmittedPrefix,
      activities: input.preparation.activities,
      compact: compact,
      onStop: {}
    )
    let prepared = preparedLive?.threadID == input.threadID && preparedLive?.startedAt == input.startedAt
      ? preparedLive
      : nil
    let displayTitle = input.destinationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = displayTitle.isEmpty ? input.runtime.title : displayTitle
    let referenceDate = input.lastEventAt ?? input.startedAt
    let livenessAge = referenceDate.map { max(0, now.timeIntervalSince($0)) } ?? 0
    let animates = input.connectionState != .disconnected
      && (input.connectionState != .connected || input.runID == nil
        || livenessAge < OpenClawTypingIndicatorView.stalledRunInterval)
    return AIChatTranscriptHTML.Live(
      title: presentation.statusTitle(now: now),
      detail: presentation.statusDetail(now: now),
      quietTitle: "Waiting for \(resolvedTitle)",
      quietDetail: "No new activity for 2m. It may still be working.",
      stalledTitle: "\(resolvedTitle) may be stalled",
      stalledDetail: "No new activity for 10m. The run is saved; the connection or agent may be stalled.",
      startedAtMilliseconds: input.startedAt.map { $0.timeIntervalSince1970 * 1_000 },
      lastEventAtMilliseconds: referenceDate.map { $0.timeIntervalSince1970 * 1_000 },
      usesLivenessThresholds: input.connectionState == .connected && input.runID != nil,
      animates: animates,
      text: prepared?.text,
      hasEarlierText: prepared?.hasEarlierText ?? false,
      textExpanded: showsAllLiveText,
      reasoning: prepared?.reasoning,
      activities: (prepared?.activities ?? []).map(AIChatTranscriptHTML.Activity.init),
      activityExpanded: showsLiveActivity
    )
  }

  private func handleAction(_ action: String, _ id: String?, _ detail: String?) {
    if action == "restored" { store.completeOpenClawChatScrollRestoration(threadID: store.selectedOpenClawChatThreadID); return }
    if action == "earlier" { onEarlier(); return }
    if action == "stop" { Task { await store.stopOpenClawRun() }; return }
    if action == "liveTextToggle" { showsAllLiveText.toggle(); return }
    if action == "liveActivityToggle" { showsLiveActivity.toggle(); return }
    guard let id, let uuid = UUID(uuidString: id), let message = messages.first(where: { $0.id == uuid }) else { return }
    switch action {
    case "copy":
      let input = OpenClawMessageClipboard.Input(message)
      copyFeedbackTask?.cancel()
      copyFeedbackTask = Task { @MainActor in
        guard await OpenClawMessageClipboard.copy(input), !Task.isCancelled else { return }
        copiedMessageID = uuid
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        if copiedMessageID == uuid { copiedMessageID = nil }
      }
    case "attachment":
      guard let detail, let attachmentID = UUID(uuidString: detail) else { return }
      previewedAttachment = message.attachments.first { $0.id == attachmentID }
    case "expand": expandedMessageIDs.insert(uuid)
    case "collapse": expandedMessageIDs.remove(uuid)
    case "retry": Task { await store.retryOpenClawMessage(uuid) }
    case "edit": store.editQueuedAIChatMessage(uuid)
    case "delete": store.deleteQueuedAIChatMessage(uuid)
    case "steer": Task { await store.steerQueuedAIChatMessage(uuid) }
    default: break
    }
  }
}

enum AIChatTranscriptHTML {
  struct Context: Codable, Equatable {
    let title: String
    let kind: String
    let isAutomatic: Bool

    init(_ context: OpenClawPresentedContext) {
      title = context.title
      kind = context.kind
      isAutomatic = context.automaticPrompt != nil
    }
  }

  struct Attachment: Codable, Equatable {
    let id: String
    let fileName: String
    let mimeType: String

    init(_ attachment: OpenClawChatAttachment) {
      id = attachment.id.uuidString.lowercased()
      fileName = attachment.fileName
      mimeType = attachment.mimeType
    }
  }

  struct Activity: Codable, Equatable {
    let title: String
    let detail: String?
    let latestDetail: String?
    let status: String

    init(_ item: OpenClawActivityFeedItem) {
      title = item.title
      detail = item.detail
      latestDetail = item.latestDetail
      status = item.status.rawValue
    }
  }

  struct Trace: Codable, Equatable {
    let reasoning: String?
    let activities: [Activity]

    init?(_ trace: OpenClawResponseTrace) {
      guard !trace.isEmpty else { return nil }
      reasoning = OpenClawProgressPresentation.reasoningText(from: trace.reasoning)
      activities = OpenClawActivityFeed.items(from: trace.activities).map(Activity.init)
    }
  }

  struct FileChange: Codable, Equatable {
    let relativePath: String
    let status: String
    let insertions: Int
    let deletions: Int

    init(_ change: OpenClawCorpusFileChange) {
      relativePath = change.relativePath
      status = change.status.rawValue
      insertions = change.insertions
      deletions = change.deletions
    }
  }

  struct ChangeSummary: Codable, Equatable {
    let title: String
    let totalInsertions: Int
    let totalDeletions: Int
    let files: [FileChange]

    init(_ summary: OpenClawCorpusChangeSummary) {
      title = summary.title
      totalInsertions = summary.totalInsertions
      totalDeletions = summary.totalDeletions
      files = summary.files.map(FileChange.init)
    }
  }

  struct Live: Codable, Equatable {
    let title: String
    let detail: String?
    let quietTitle: String
    let quietDetail: String
    let stalledTitle: String
    let stalledDetail: String
    let startedAtMilliseconds: Double?
    let lastEventAtMilliseconds: Double?
    let usesLivenessThresholds: Bool
    let animates: Bool
    let text: String?
    let hasEarlierText: Bool
    let textExpanded: Bool
    let reasoning: String?
    let activities: [Activity]
    let activityExpanded: Bool
  }

  struct Entry: Codable, Equatable {
    let id: String
    let role: String
    let title: String
    let timestamp: String
    let html: String
    let contexts: [Context]
    let attachments: [Attachment]
    let failure: String?
    let queued: Bool
    let canSteer: Bool
    let isRoomResponse: Bool
    let copied: Bool
    let isTruncated: Bool
    let responseTrace: Trace?
    let changeSummary: ChangeSummary?
  }
  struct Payload: Codable, Equatable {
    let thread: String
    let entries: [Entry]
    let earlier: String?
    let sending: Bool
    let status: String
    let search: String?
    let searchGeneration: Int
    var initialPosition: Double
    let compact: Bool
    let live: Live?
  }

  static let style = AIChatDocumentHTML.style + """
  [hidden] { display:none!important; }
  html { overflow-y:auto; overflow-x:hidden; }
  body { padding:16px!important; }
  #messages { display:flex; flex-direction:column; gap:12px; }
  body.compact { padding:10px!important; }
  article { display:flex; align-items:flex-start; gap:10px; min-width:0; }
  article.user { justify-content:flex-end; }
  article.room-response { display:block; }
  .message-card { width:fit-content; max-width:calc(100% - 82px); min-width:0; padding:9px 11px 12px; border:1px solid light-dark(#d8d8d3,#424442); border-radius:8px; background:light-dark(#fcfbf8,#242624); }
  article.user .message-card { background:light-dark(#eef2f9,#252d39); }
  article.room-response .message-card { box-sizing:border-box; width:100%; max-width:none; }
  article.match .message-card { outline:2px solid #609ce8; }
  .avatar { flex:0 0 32px; width:32px; height:32px; display:grid; place-items:center; border-radius:8px; color:light-dark(#5f6d7e,#c5cfdb); background:light-dark(#eef0f2,#292d31); }
  .avatar.user-avatar { color:light-dark(#1672dc,#70afff); background:light-dark(#e5f0ff,#26384e); }
  .avatar svg { width:16px; height:16px; }
  .message-header { display:flex; align-items:center; gap:6px; min-height:24px; font-size:11px; color:light-dark(#777,#aaa); margin-bottom:5px; }
  .message-header strong { color:light-dark(#666,#bbb); font-weight:600; }
  .message-header time { opacity:.7; }
  .system-badge,.queued-badge { padding:2px 5px; border-radius:4px; font-size:10px; font-weight:600; background:light-dark(#f9ead6,#503b26); color:light-dark(#a05b08,#f0aa5b); }
  .queued-badge { color:inherit; background:light-dark(#eee,#383838); }
  button { font:inherit; color:inherit; border:0; border-radius:4px; padding:3px 6px; background:transparent; cursor:pointer; user-select:none; -webkit-user-select:none; }
  button:hover { background:light-dark(#e5e5e5,#424242); }
  .icon-button { display:grid; place-items:center; width:24px; height:24px; padding:0; opacity:.5; }
  .icon-button:hover,.icon-button.copied { opacity:1; }
  .icon-button.copied { color:#25a244; }
  .glyph { display:inline-grid; place-items:center; flex:0 0 14px; width:14px; height:14px; line-height:0; }
  .glyph svg,.icon-button svg,.detail-icon svg,.activity-icon svg,.change-icon svg { width:14px; height:14px; }
  .context-pills { display:flex; flex-wrap:wrap; gap:5px; margin-bottom:6px; }
  .context-pill { padding:3px 7px; border-radius:999px; font-size:10px; color:light-dark(#2773bd,#83bafa); background:light-dark(#eaf3fc,#27394b); border:1px solid light-dark(#bdd8f0,#34516b); }
  .message-card > main { min-width:0; }
  .message-card > main > :first-child { margin-top:0; }
  .message-card > main > :last-child { margin-bottom:0; }
  .attachments { display:grid; grid-template-columns:repeat(auto-fill,minmax(76px,104px)); gap:8px; margin-top:8px; }
  .attachment { text-align:left; padding:0; overflow:hidden; }
  .attachment-preview { height:72px; display:grid; place-items:center; border:1px solid light-dark(#d8d8d3,#424442); border-radius:6px; background:light-dark(#f5f4f1,#1d1f1d); }
  .attachment-preview svg { width:22px; height:22px; opacity:.65; }
  .attachment-name { display:block; margin-top:4px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:10px; color:light-dark(#777,#aaa); }
  .queued-actions { display:flex; align-items:center; gap:8px; margin-top:8px; font-size:11px; color:light-dark(#777,#aaa); }
  .queued-actions .spacer { flex:1; }
  .failure { display:grid; grid-template-columns:14px minmax(0,1fr) max-content; align-items:start; gap:8px; margin-top:8px; padding:7px 8px; color:light-dark(#b33820,#ffa98d); background:light-dark(#fff0ed,#3a2420); border:1px solid light-dark(#efc1b8,#704139); border-radius:6px; font-size:11px; }
  .failure > .glyph { margin-top:1px; }
  .failure-copy { min-width:0; white-space:pre-wrap; overflow-wrap:anywhere; }
  .failure button { display:inline-flex; align-items:center; justify-content:center; flex:none; min-width:max-content; white-space:nowrap; font-weight:600; line-height:1.25; }
  .expansion { margin-top:7px; font-size:11px; font-weight:500; color:light-dark(#777,#aaa); }
  .detail-block { margin-top:12px; padding-top:9px; border-top:1px solid light-dark(#dddcd7,#444642); font-size:11px; max-width:640px; }
  .detail-header { display:flex; align-items:center; gap:7px; font-weight:600; color:light-dark(#5c5c5c,#c4c4c4); }
  .detail-header .spacer { flex:1; }
  .disclosure-button { display:inline-flex; align-items:center; justify-content:flex-start; gap:5px; flex:none; min-width:max-content; white-space:nowrap; line-height:14px; }
  .disclosure-button .glyph { flex-basis:10px; width:10px; height:14px; }
  .disclosure-button .glyph svg { width:10px; height:10px; }
  .reasoning-row,.activity-row,.change-row { display:flex; align-items:flex-start; gap:7px; margin-top:7px; min-width:0; }
  .reasoning-copy,.activity-copy,.change-path { min-width:0; }
  .reasoning-title,.activity-title { display:block; font-weight:500; }
  .reasoning-text,.activity-detail { display:-webkit-box; overflow:hidden; -webkit-box-orient:vertical; -webkit-line-clamp:2; margin-top:2px; color:light-dark(#777,#aaa); font-size:10px; white-space:pre-wrap; }
  .trace.expanded .reasoning-text { -webkit-line-clamp:8; }
  .activity-detail { -webkit-line-clamp:1; white-space:normal; text-overflow:ellipsis; }
  .trace.expanded .activity-detail { -webkit-line-clamp:3; }
  .activity-row.omitted { display:none; }
  .trace.expanded .activity-row.omitted { display:flex; }
  .show-earlier { margin-top:6px; padding-left:21px; font-size:10px; color:light-dark(#888,#999); font-weight:500; }
  .change-summary .detail-header { color:light-dark(#333,#ddd); }
  .change-row { align-items:center; }
  .change-path { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
  .delta { display:flex; gap:4px; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-weight:600; }
  .insertions { color:#25a244; } .deletions { color:#d6483e; }
  .more-files { margin-top:7px; font-size:10px; font-weight:500; color:light-dark(#777,#aaa); }
  #earlier { display:block; margin:0 auto 12px; }
  #live { box-sizing:border-box; width:100%; max-width:700px; padding:16px 10px 14px; color:light-dark(#777,#aaa); }
  body.compact #live { max-width:430px; padding-left:6px; padding-right:6px; }
  .live-status-row { display:flex; align-items:center; gap:8px; min-height:22px; font-size:11px; user-select:none; -webkit-user-select:none; }
  .live-pulse { display:block; flex:0 0 5px; width:5px; height:5px; border-radius:50%; background:currentColor; }
  #live.animating .live-pulse { animation:pulse .85s ease-in-out infinite alternate; }
  .live-title { min-width:0; max-width:180px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-weight:500; }
  #live.animating .live-title { color:transparent; background:linear-gradient(90deg,light-dark(#777,#aaa) 20%,light-dark(#333,#eee) 50%,light-dark(#777,#aaa) 80%); background-size:220% 100%; background-clip:text; -webkit-background-clip:text; animation:shimmer 1.7s linear infinite; }
  .live-elapsed { flex:0 0 58px; width:58px; font:10px ui-monospace,SFMono-Regular,Menlo,monospace; color:light-dark(#999,#888); }
  .live-stop { display:grid; place-items:center; flex:0 0 22px; width:22px; height:22px; padding:0; border-radius:50%; background:light-dark(#0000000d,#ffffff12); }
  .live-stop .glyph,.live-stop svg { width:8px; height:8px; }
  .live-detail { max-width:640px; margin-top:2px; font-size:10px; color:light-dark(#999,#888); white-space:pre-wrap; }
  .live-text { max-width:640px; margin-top:9px; color:light-dark(#202020,#e7e7e7); font-size:13px; line-height:1.5; white-space:pre-wrap; }
  .live-text-toggle { margin-top:5px; font-size:10px; font-weight:500; color:light-dark(#777,#aaa); }
  .live-feed { max-width:640px; margin-top:9px; font-size:11px; }
  .live-feed .reasoning-row,.live-feed .activity-row { margin-top:6px; }
  .live-feed.expanded .reasoning-text { -webkit-line-clamp:8; }
  .live-feed.expanded .activity-detail { -webkit-line-clamp:3; }
  .live-running-dot { display:block; width:7px; height:7px; margin:3px; border-radius:50%; background:currentColor; animation:pulse .85s ease-in-out infinite alternate; }
  .live-activity-toggle { margin-top:6px; font-size:10px; font-weight:500; color:light-dark(#777,#aaa); }
  #status { display:flex; align-items:center; gap:8px; min-height:22px; padding:16px 0; color:light-dark(#777,#aaa); font-size:11px; }
  #status.working::before { content:''; display:block; flex:0 0 5px; width:5px; height:5px; border-radius:50%; background:currentColor; animation:pulse 1.2s ease-in-out infinite; }
  #status button { display:inline-flex; align-items:center; justify-content:center; flex:none; white-space:nowrap; line-height:1.25; }
  @keyframes pulse { from { opacity:.55; transform:scale(.78); } to { opacity:1; transform:scale(1); } }
  @keyframes shimmer { from { background-position:100% 0; } to { background-position:-120% 0; } }
  @media (prefers-reduced-motion:reduce) {
    #live.animating .live-pulse,.live-running-dot { animation:none; }
    #live.animating .live-title { color:inherit; background:none; animation:none; }
  }
  #latest { position:fixed; bottom:12px; right:14px; border:1px solid #8886; border-radius:20px; background:light-dark(#fff,#333); box-shadow:0 2px 6px #0002; }
  pre { max-height:none!important; height:auto!important; overflow-x:auto; overflow-y:hidden; white-space:pre; }
  table { max-width:100%; table-layout:fixed; }
  """

  static let script = #"""
  (() => {
    let current = null, pending = null, pendingLive = null, hasPendingLive = false, nearBottom = true, searchToken = '';
    const post = (action, id, detail) => webkit.messageHandlers.transcript.postMessage({action, id:id??null, detail:detail??null, thread:current?.thread??""});
    const selected = () => { const s=getSelection(); return s && !s.isCollapsed; };
    const maxScroll = () => Math.max(0,document.documentElement.scrollHeight-innerHeight);
    const report = () => {
      const max=maxScroll(); nearBottom=max-scrollY<60;
      document.getElementById('latest').hidden=nearBottom;
      webkit.messageHandlers.transcript.postMessage({position:max>0?scrollY/max:1,thread:current?.thread});
    };
    const button = (label, action, id, detail) => {
      const b=document.createElement('button'); b.textContent=label;
      b.addEventListener('click',()=>post(action,id,detail)); return b;
    };
    const icon = name => {
      const span=document.createElement('span'); span.className='glyph'; span.setAttribute('aria-hidden','true');
      const common='viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"';
      const paths={
        copy:'<rect x="8" y="7" width="11" height="13" rx="2"/><path d="M16 7V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h3"/>',
        check:'<path d="m5 12 4 4L19 6"/>',
        sparkle:'<path d="M12 2c.7 4.7 2.9 6.9 7.5 7.5C14.9 10.1 12.7 12.3 12 17c-.7-4.7-2.9-6.9-7.5-7.5C9.1 8.9 11.3 6.7 12 2Z"/><path d="M19 15c.3 2.1 1.3 3.1 3 3.5-1.7.3-2.7 1.3-3 3.5-.3-2.2-1.3-3.2-3-3.5 1.7-.4 2.7-1.4 3-3.5Z"/>',
        person:'<circle cx="12" cy="8" r="4"/><path d="M4.5 21a7.5 7.5 0 0 1 15 0"/>',
        gear:'<circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.4 1A8 8 0 0 0 15 6l-.3-2.6h-4L10.4 6A8 8 0 0 0 8.8 7L6.5 6l-2 3.4 2 1.5a7 7 0 0 0 0 2.1l-2 1.5 2 3.4 2.3-1a8 8 0 0 0 1.6 1l.3 2.6h4L15 18a8 8 0 0 0 1.6-1l2.3 1 2-3.4-2-1.5a7 7 0 0 0 .1-1Z"/>',
        clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
        file:'<path d="M6 3h8l4 4v14H6Z"/><path d="M14 3v5h5M9 13h6M9 17h6"/>',
        searchfile:'<path d="M5 3h9l4 4v6M14 3v5h5"/><circle cx="15" cy="17" r="3"/><path d="m17.5 19.5 2 2"/>',
        success:'<circle cx="12" cy="12" r="9"/><path d="m8 12 2.5 2.5L16 9"/>',
        failed:'<path d="M12 3 2.5 20h19Z"/><path d="M12 9v4M12 17h.01"/>',
        tool:'<path d="m14.5 6.5 3-3a4 4 0 0 1-5 5L6 15l3 3 6.5-6.5a4 4 0 0 1 5-5l-3 3Z"/>',
        stop:'<rect x="7" y="7" width="10" height="10" rx="1.5" fill="currentColor" stroke="none"/>',
        chevronRight:'<path d="m9 5 7 7-7 7"/>',
        chevronDown:'<path d="m5 9 7 7 7-7"/>',
        chevronUp:'<path d="m5 15 7-7 7 7"/>'
      };
      span.innerHTML='<svg '+common+'>'+paths[name]+'</svg>'; return span;
    };
    const iconButton = (name, label, action, id, copied=false) => {
      const b=button('',action,id); b.className='icon-button'+(copied?' copied':'');
      b.setAttribute('aria-label',label); b.title=label; b.append(icon(name)); return b;
    };
    const updateDisclosure = (button, label, iconName) => {
      const copy=document.createElement('span'); copy.textContent=label;
      button.replaceChildren(icon(iconName),copy);
    };
    const appendDelta = (parent, insertions, deletions) => {
      const d=document.createElement('span'); d.className='delta';
      if(insertions>0) { const n=document.createElement('span'); n.className='insertions'; n.textContent='+'+insertions; d.append(n); }
      if(deletions>0) { const n=document.createElement('span'); n.className='deletions'; n.textContent='-'+deletions; d.append(n); }
      if(!insertions && !deletions) d.textContent='0'; parent.append(d);
    };
    const makeMessage = e => {
      const a=document.createElement('article'); a.id='message-'+e.id; a.className=e.role;
      if(e.isRoomResponse) a.classList.add('room-response');
      a.setAttribute('aria-label',e.title+' message');
      if(e.role!=='user' && !e.isRoomResponse) {
        const avatar=document.createElement('span'); avatar.className='avatar'; avatar.append(icon(e.role==='assistant'?'sparkle':'gear')); a.append(avatar);
      }
      const card=document.createElement('div'); card.className='message-card';
      const header=document.createElement('header'); header.className='message-header';
      const title=document.createElement('strong'); title.textContent=e.title;
      const time=document.createElement('time'); time.textContent=e.timestamp;
      header.append(title);
      if(e.role==='system') { const badge=document.createElement('span'); badge.className='system-badge'; badge.textContent='System'; header.append(badge); }
      if(e.queued) { const q=document.createElement('span'); q.className='queued-badge'; q.textContent='Queued'; header.append(q); }
      header.append(time,iconButton(e.copied?'check':'copy',e.copied?'Copied':'Copy message','copy',e.id,e.copied));
      card.append(header);
      if(e.contexts.length) {
        const pills=document.createElement('div'); pills.className='context-pills';
        for(const context of e.contexts) { const pill=document.createElement('span'); pill.className='context-pill'; pill.textContent=(context.isAutomatic?'✦ ':'')+context.title; pills.append(pill); }
        card.append(pills);
      }
      const doc=new DOMParser().parseFromString(e.html,'text/html');
      const css=doc.querySelector('style');
      if(css && !document.getElementById('renderer-style')) { css.id='renderer-style'; document.head.prepend(css); }
      doc.querySelectorAll('script,.org2-document-header').forEach(x=>x.remove());
      const main=doc.querySelector('main') || doc.body;
      const body=document.createElement('main'); body.className='org2-document'; body.append(...main.childNodes);
      for(const pre of body.querySelectorAll('pre')) {
        const wrap=document.createElement('div'); wrap.className='chat-code'; pre.replaceWith(wrap); wrap.append(pre);
        const b=document.createElement('button'); b.className='chat-copy-code'; b.textContent='Copy code';
        b.onclick=()=>webkit.messageHandlers.chatCopyCode.postMessage(pre.textContent.replace(/\n$/,'')); wrap.append(b);
      }
      card.append(body);
      if(e.isTruncated) { const expand=button('⌄  Show Full Message','expand',e.id); expand.className='expansion'; card.append(expand); }
      if(e.attachments.length) {
        const attachments=document.createElement('div'); attachments.className='attachments';
        for(const attachment of e.attachments) {
          const b=button('','attachment',e.id,attachment.id); b.className='attachment'; b.title='Open '+attachment.fileName;
          const preview=document.createElement('span'); preview.className='attachment-preview'; preview.append(icon('file'));
          const name=document.createElement('span'); name.className='attachment-name'; name.textContent=attachment.fileName;
          b.append(preview,name); attachments.append(b);
        }
        card.append(attachments);
      }
      if(e.queued) {
        const actions=document.createElement('div'); actions.className='queued-actions';
        const label=document.createElement('span'); label.textContent='Waiting behind the current turn';
        const spacer=document.createElement('span'); spacer.className='spacer'; actions.append(label,spacer);
        if(e.canSteer) actions.append(button('Steer now','steer',e.id));
        actions.append(button('Edit','edit',e.id),button('Remove','delete',e.id)); card.append(actions);
      }
      if(e.failure) {
        const failure=document.createElement('div'); failure.className='failure'; failure.append(icon('failed'));
        const copy=document.createElement('span'); copy.className='failure-copy'; copy.textContent=e.failure; failure.append(copy,button('Retry','retry',e.id)); card.append(failure);
      }
      if(e.responseTrace) {
        const trace=document.createElement('section'); trace.className='detail-block trace';
        const head=document.createElement('div'); head.className='detail-header detail-icon'; head.append(icon('clock'));
        const label=document.createElement('span'); label.textContent='How it worked'; head.append(label);
        const canExpand=e.responseTrace.activities.length>3 || (e.responseTrace.reasoning?.length||0)>240;
        if(canExpand) {
          const spacer=document.createElement('span'); spacer.className='spacer';
          const toggle=button(''); toggle.className='disclosure-button';
          updateDisclosure(toggle,'Show full feed','chevronRight');
          toggle.onclick=()=>{ const expanded=trace.classList.toggle('expanded'); updateDisclosure(toggle,expanded?'Show less':'Show full feed',expanded?'chevronDown':'chevronRight'); };
          head.append(spacer,toggle);
        }
        trace.append(head);
        if(e.responseTrace.reasoning) {
          const row=document.createElement('div'); row.className='reasoning-row detail-icon'; row.append(icon('sparkle'));
          const copy=document.createElement('div'); copy.className='reasoning-copy';
          const title=document.createElement('span'); title.className='reasoning-title'; title.textContent='Approach';
          const value=document.createElement('span'); value.className='reasoning-text'; value.textContent=e.responseTrace.reasoning;
          copy.append(title,value); row.append(copy); trace.append(row);
        }
        const activities=e.responseTrace.activities;
        activities.forEach((activity,index)=>{
          const row=document.createElement('div'); row.className='activity-row'+(index<activities.length-3?' omitted':'');
          const image=document.createElement('span'); image.className='activity-icon'; image.append(icon(activity.status==='failed'?'failed':activity.status==='succeeded'?'success':'tool'));
          const copy=document.createElement('div'); copy.className='activity-copy';
          const title=document.createElement('span'); title.className='activity-title'; title.textContent=activity.title;
          copy.append(title);
          const detail=activity.latestDetail||activity.detail;
          if(detail) { const value=document.createElement('span'); value.className='activity-detail'; value.textContent=detail; copy.append(value); }
          row.append(image,copy); trace.append(row);
        });
        if(activities.length>3) { const more=document.createElement('div'); more.className='show-earlier'; more.textContent='Show '+(activities.length-3)+' earlier update'+(activities.length-3===1?'':'s'); trace.append(more); }
        card.append(trace);
      }
      if(e.changeSummary) {
        const summary=e.changeSummary, section=document.createElement('section'); section.className='detail-block change-summary';
        const head=document.createElement('div'); head.className='detail-header change-icon'; head.append(icon('searchfile'));
        const title=document.createElement('span'); title.textContent=summary.title;
        const spacer=document.createElement('span'); spacer.className='spacer'; head.append(title,spacer); appendDelta(head,summary.totalInsertions,summary.totalDeletions); section.append(head);
        summary.files.slice(0,6).forEach(change=>{
          const row=document.createElement('div'); row.className='change-row';
          const image=document.createElement('span'); image.className='change-icon'; image.append(icon(change.status==='deleted'?'failed':change.status==='created'?'success':'file'));
          const path=document.createElement('span'); path.className='change-path'; path.textContent=change.relativePath;
          row.append(image,path); appendDelta(row,change.insertions,change.deletions); section.append(row);
        });
        if(summary.files.length>6) { const more=document.createElement('div'); more.className='more-files'; more.textContent='+'+(summary.files.length-6)+' more file'+(summary.files.length-6===1?'':'s'); section.append(more); }
        card.append(section);
      }
      a.append(card);
      if(e.role==='user') { const avatar=document.createElement('span'); avatar.className='avatar user-avatar'; avatar.append(icon('person')); a.append(avatar); }
      a.dataset.entry=JSON.stringify(e); return a;
    };
    const ensureLive = () => {
      const root=document.getElementById('live');
      if(root.childElementCount) return root;
      const status=document.createElement('div'); status.className='live-status-row';
      const pulse=document.createElement('span'); pulse.className='live-pulse'; pulse.setAttribute('aria-hidden','true');
      const title=document.createElement('span'); title.className='live-title';
      const elapsed=document.createElement('time'); elapsed.className='live-elapsed';
      const stop=button('','stop'); stop.className='live-stop'; stop.setAttribute('aria-label','Stop agent run'); stop.title='Stop this agent run'; stop.append(icon('stop'));
      status.append(pulse,title,elapsed,stop);
      const detail=document.createElement('div'); detail.className='live-detail';
      const text=document.createElement('div'); text.className='live-text';
      const textToggle=button('','liveTextToggle'); textToggle.className='disclosure-button live-text-toggle';
      const feed=document.createElement('div'); feed.className='live-feed';
      root.append(status,detail,text,textToggle,feed); return root;
    };
    const duration = milliseconds => {
      const seconds=Math.max(0,Math.floor(milliseconds/1000));
      if(seconds<60) return seconds+'s';
      return Math.floor(seconds/60)+'m '+seconds%60+'s';
    };
    const updateLiveClock = () => {
      const root=document.getElementById('live'), live=root.liveData;
      if(!live || root.hidden) return;
      const now=Date.now(), age=live.lastEventAtMilliseconds==null?0:Math.max(0,now-live.lastEventAtMilliseconds);
      let title=live.title, detail=live.detail||'', animates=live.animates;
      if(live.usesLivenessThresholds && age>=600000) { title=live.stalledTitle; detail=live.stalledDetail; animates=false; }
      else if(live.usesLivenessThresholds && age>=120000) { title=live.quietTitle; detail=live.quietDetail; }
      root.classList.toggle('animating',animates);
      root.querySelector('.live-title').textContent=title;
      const detailNode=root.querySelector('.live-detail'); detailNode.textContent=detail; detailNode.hidden=!detail;
      root.querySelector('.live-elapsed').textContent=duration(now-(live.startedAtMilliseconds??now));
    };
    const renderLive = live => {
      const root=ensureLive(); root.liveData=live; root.hidden=!live;
      if(!live) return;
      const text=root.querySelector('.live-text'); text.textContent=live.text||''; text.hidden=!live.text;
      const textToggle=root.querySelector('.live-text-toggle'); textToggle.hidden=!live.hasEarlierText;
      if(live.hasEarlierText) updateDisclosure(textToggle,live.textExpanded?'Show latest update':'Show all progress',live.textExpanded?'chevronUp':'chevronDown');
      const feed=root.querySelector('.live-feed'); feed.replaceChildren(); feed.classList.toggle('expanded',live.activityExpanded);
      if(live.activityExpanded && live.reasoning) {
        const row=document.createElement('div'); row.className='reasoning-row detail-icon'; row.append(icon('sparkle'));
        const copy=document.createElement('div'); copy.className='reasoning-copy';
        const title=document.createElement('span'); title.className='reasoning-title'; title.textContent='Approach';
        const value=document.createElement('span'); value.className='reasoning-text'; value.textContent=live.reasoning;
        copy.append(title,value); row.append(copy); feed.append(row);
      }
      let activities=live.activities;
      if(!live.activityExpanded) { const running=activities.filter(x=>x.status==='running').slice(-1)[0]; activities=running?[running]:activities.slice(-1); }
      activities.forEach(activity=>{
        const row=document.createElement('div'); row.className='activity-row';
        const image=document.createElement('span'); image.className='activity-icon';
        if(activity.status==='running') { const dot=document.createElement('span'); dot.className='live-running-dot'; image.append(dot); }
        else image.append(icon(activity.status==='failed'?'failed':'success'));
        const copy=document.createElement('div'); copy.className='activity-copy';
        const title=document.createElement('span'); title.className='activity-title'; title.textContent=activity.title; copy.append(title);
        const detail=activity.latestDetail||activity.detail;
        if(detail) { const value=document.createElement('span'); value.className='activity-detail'; value.textContent=detail; copy.append(value); }
        row.append(image,copy); feed.append(row);
      });
      if(live.activities.length || live.reasoning) {
        const toggle=button('','liveActivityToggle'); toggle.className='disclosure-button live-activity-toggle';
        updateDisclosure(toggle,live.activityExpanded?'Hide activity':'Show activity',live.activityExpanded?'chevronDown':'chevronRight'); feed.append(toggle);
      }
      feed.hidden=!feed.childElementCount; updateLiveClock();
    };
    window.__transcriptLiveUpdate = live => {
      if(selected()) { pendingLive=live; hasPendingLive=true; return; }
      const follow=nearBottom;
      if(current) current={...current,live};
      renderLive(live);
      requestAnimationFrame(()=>{ if(follow) scrollTo(0,maxScroll()); report(); });
    };
    window.__transcriptUpdate = data => {
      const changedThread=current?.thread!==data.thread;
      if(!changedThread && selected()) { pending=data; return; }
      if(changedThread) getSelection().removeAllRanges();
      const oldTop=scrollY, first=[...document.querySelectorAll('article')].find(x=>x.getBoundingClientRect().bottom>0);
      const anchor=first?{id:first.id,top:first.getBoundingClientRect().top}:null;
      const follow=nearBottom && !selected();
      const root=document.getElementById('messages');
      if(changedThread) root.replaceChildren();
      const wanted=new Set(data.entries.map(e=>'message-'+e.id));
      for(const child of [...root.children]) if(!wanted.has(child.id)) child.remove();
      data.entries.forEach((e,i)=>{
        let a=document.getElementById('message-'+e.id);
        if(!a || a.dataset.entry!==JSON.stringify(e)) { const next=makeMessage(e); if(a) a.replaceWith(next); a=next; }
        if(root.children[i]!==a) root.insertBefore(a,root.children[i]||null);
        a.classList.toggle('match',data.search===e.id);
      });
      const earlier=document.getElementById('earlier'); earlier.textContent=data.earlier||''; earlier.hidden=!data.earlier;
      const status=document.getElementById('status'); status.replaceChildren();
      document.body.classList.toggle('compact',data.compact);
      current=data; renderLive(data.live||null);
      status.classList.toggle('working',data.sending && !data.live);
      if(data.sending && !data.live) { status.append(document.createTextNode('Working…'),button('Stop','stop')); }
      else if(!data.entries.length) status.textContent=data.status;
      pending=null; hasPendingLive=false;
      requestAnimationFrame(()=>{
        const token=data.thread+':'+data.searchGeneration+':'+data.search;
        const target=data.search && document.getElementById('message-'+data.search);
        if(target && token!==searchToken) { target.scrollIntoView({block:'center'}); searchToken=token; }
        else if(changedThread) scrollTo(0,maxScroll()*data.initialPosition);
        else if(follow) scrollTo(0,maxScroll());
        else if(anchor && document.getElementById(anchor.id)) scrollTo(0,oldTop+document.getElementById(anchor.id).getBoundingClientRect().top-anchor.top);
        report();
      });
    };
    document.addEventListener('selectionchange',()=>{
      if(selected()) return;
      if(pending) { const next=pending; pending=null; window.__transcriptUpdate(next); }
      else if(hasPendingLive) { const next=pendingLive; hasPendingLive=false; pendingLive=null; window.__transcriptLiveUpdate(next); }
    });
    document.getElementById('earlier').onclick=()=>post('earlier');
    document.getElementById('latest').onclick=()=>scrollTo(0,maxScroll());
    let scheduled=false;
    addEventListener('scroll',()=>{ if(!scheduled) { scheduled=true; requestAnimationFrame(()=>{scheduled=false; report();}); } },{passive:true});
    const resize=new ResizeObserver(()=>{ if(current && nearBottom && !selected()) scrollTo(0,maxScroll()); });
    resize.observe(document.getElementById('messages')); resize.observe(document.getElementById('live'));
    setInterval(updateLiveClock,1000);
  })();
  """#

  static let shell = """
  <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data: org2-resource:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'"><style>\(style)</style></head><body><button id="earlier" hidden></button><div id="messages"></div><section id="live" hidden aria-label="Live agent activity"></section><div id="status"></div><button id="latest" hidden aria-label="Jump to latest message">↓</button></body></html>
  """
}

struct AIChatTranscriptWebView: NSViewRepresentable {
  let payload: AIChatTranscriptHTML.Payload
  let sourcePath: String
  let corpusRoot: URL?
  let linkResolver: OrgRoamLinkResolver
  let openFileReference: (OpenClawFileReference) -> Void
  let onAction: (String, String?, String?) -> Void
  let onPosition: (String, Double) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView {
    let config=WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(context.coordinator.resources, forURLScheme: OrgHTMLLocalResourceSchemeHandler.scheme)
    for name in ["transcript", "chatCopyCode"] { config.userContentController.add(context.coordinator, name: name) }
    config.userContentController.addUserScript(WKUserScript(source: AIChatTranscriptHTML.script + "\n" + OrgHTMLRichCopy.installationScript,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    let view=WKWebView(frame: .zero, configuration: config)
    view.navigationDelegate=context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    view.setAccessibilityLabel("Chat transcript")
    view.setAccessibilityIdentifier(OpenClawChatAccessibilityIdentity.transcriptScrollBridge)
    view.loadHTMLString(AIChatTranscriptHTML.shell, baseURL: URL(fileURLWithPath: sourcePath).deletingLastPathComponent())
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {
    let c=context.coordinator
    c.onAction=onAction; c.onPosition=onPosition; c.openFileReference=openFileReference
    c.sourcePath=sourcePath; c.corpusRoot=corpusRoot; c.linkResolver=linkResolver
    c.resources.configure(source: EntrySource(file:sourcePath,startLine:1,endLineExclusive:1,text:"",isSubtree:false),corpusRoot:corpusRoot)
    var next = payload
    if let previous = c.payload, previous.thread == next.thread { next.initialPosition = previous.initialPosition }
    let previous = c.payload
    guard previous != next else { return }
    let onlyLiveChanged = previous.map { Self.documentPayloadMatches($0, next) } ?? false
    c.payload=next
    if c.loaded {
      if onlyLiveChanged { c.updateLive(view) }
      else { c.update(view) }
    }
  }
  static func documentPayloadMatches(
    _ lhs: AIChatTranscriptHTML.Payload,
    _ rhs: AIChatTranscriptHTML.Payload
  ) -> Bool {
    lhs.thread == rhs.thread
      && lhs.entries == rhs.entries
      && lhs.earlier == rhs.earlier
      && lhs.sending == rhs.sending
      && lhs.status == rhs.status
      && lhs.search == rhs.search
      && lhs.searchGeneration == rhs.searchGeneration
      && lhs.initialPosition == rhs.initialPosition
      && lhs.compact == rhs.compact
  }
  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    AIChatDocumentWebView.dismantleNSView(view, coordinator: coordinator)
    view.configuration.userContentController.removeScriptMessageHandler(forName:"transcript")
  }
  final class Coordinator: AIChatDocumentWebView.Coordinator {
    var payload: AIChatTranscriptHTML.Payload?
    var restoredThread: String?
    var onAction: ((String,String?,String?) -> Void)?
    var onPosition: ((String,Double) -> Void)?
    override func update(_ view: WKWebView) {
      guard let payload, let data=try? JSONEncoder().encode(payload) else { return }
      // Rewrite HTML fields before encoding: JSON escaping must remain intact.
      var object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
      object["entries"] = payload.entries.map { entry -> [String:Any] in
        var value=(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(entry))) as? [String:Any] ?? [:]
        value["html"]=OrgHTMLLocalResourceSchemeHandler.rewritingLocalImageSources(in:entry.html)
        return value
      }
      view.callAsyncJavaScript("window.__transcriptUpdate(data)",arguments:["data":object],in:nil,in:.page)
    }
    func updateLive(_ view: WKWebView) {
      guard let payload else { return }
      let object: Any
      if let live = payload.live,
         let data = try? JSONEncoder().encode(live),
         let value = try? JSONSerialization.jsonObject(with: data) {
        object = value
      } else {
        object = NSNull()
      }
      view.callAsyncJavaScript("window.__transcriptLiveUpdate(live)",arguments:["live":object],in:nil,in:.page)
    }
    override func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.name=="transcript" else { super.userContentController(controller,didReceive:message); return }
      guard message.frameInfo.isMainFrame, let value=message.body as? [String:Any],
            let thread=value["thread"] as? String, thread==payload?.thread else { return }
      if let position=value["position"] as? Double, position.isFinite {
        if restoredThread != thread { restoredThread = thread; onAction?("restored", nil, nil) }
        onPosition?(thread,min(1,max(0,position)))
      }
      if let action=value["action"] as? String {
        onAction?(action, value["id"] as? String, value["detail"] as? String)
      }
    }
  }
}
