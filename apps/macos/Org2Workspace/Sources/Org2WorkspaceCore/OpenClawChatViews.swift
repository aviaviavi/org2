import AppKit
import SwiftUI

struct OpenClawPresentedContext: Identifiable, Hashable, Sendable {
  let kind: String
  let title: String
  let reference: String
  let sourceLine: String

  var id: String { "\(kind)|\(reference)" }

  var systemImage: String {
    switch kind.lowercased() {
    case let value where value.contains("block"):
      return "text.quote"
    case let value where value.contains("entry") || value.contains("heading"):
      return "text.line.first.and.arrowtriangle.forward"
    case let value where value.contains("page") || value.contains("file"):
      return "doc.text"
    default:
      return "scope"
    }
  }
}

struct OpenClawContextPresentation: Equatable, Sendable {
  let contexts: [OpenClawPresentedContext]
  let userText: String

  init(_ rawText: String, extractsContexts: Bool = true) {
    guard extractsContexts else {
      contexts = []
      userText = rawText
      return
    }
    var remaining = rawText.replacingOccurrences(of: "\r\n", with: "\n")
    var parsed: [OpenClawPresentedContext] = []

    while !remaining.isEmpty {
      let separator = remaining.range(of: "\n\n")
      let candidate = separator.map { String(remaining[..<$0.lowerBound]) } ?? remaining
      guard let context = Self.parseContextLine(candidate) else { break }
      parsed.append(context)
      if let separator {
        remaining = String(remaining[separator.upperBound...])
      } else {
        remaining = ""
      }
    }

    contexts = parsed
    userText = remaining
  }

  func replacingUserText(_ nextUserText: String) -> String {
    Self.serialize(contexts: contexts, userText: nextUserText)
  }

  func removing(_ context: OpenClawPresentedContext) -> String {
    Self.serialize(contexts: contexts.filter { $0.id != context.id }, userText: userText)
  }

  var clipboardText: String {
    let contextLines = contexts.map { "[Context: \($0.title)]" }
    return (contextLines + (userText.isEmpty ? [] : [userText])).joined(separator: "\n")
  }

  private static func serialize(contexts: [OpenClawPresentedContext], userText: String) -> String {
    guard !contexts.isEmpty else { return userText }
    return contexts.map(\.sourceLine).joined(separator: "\n\n") + "\n\n" + userText
  }

  private static func parseContextLine(_ line: String) -> OpenClawPresentedContext? {
    guard line.hasPrefix("Use "), line.hasSuffix(" as context.") else { return nil }
    let body = String(line.dropFirst(4).dropLast(" as context.".count))
    let kind: String
    let title: String
    let reference: String
    if let quoteStart = body.range(of: " “"),
       let separator = body.range(of: "” at ", range: quoteStart.upperBound..<body.endIndex) {
      kind = String(body[..<quoteStart.lowerBound])
      title = String(body[quoteStart.upperBound..<separator.lowerBound])
      reference = String(body[separator.upperBound...])
    } else {
      guard let separator = body.range(of: " at ") else { return nil }
      kind = String(body[..<separator.lowerBound])
      reference = String(body[separator.upperBound...])
      title = kind
        .replacingOccurrences(of: "selected ", with: "", options: [.caseInsensitive, .anchored])
        .replacingOccurrences(of: "current ", with: "", options: [.caseInsensitive, .anchored])
        .capitalized
    }

    guard !kind.isEmpty, !title.isEmpty else { return nil }
    return OpenClawPresentedContext(kind: kind, title: title, reference: reference, sourceLine: line)
  }
}

struct ChatBubbleView: View {
  let message: OpenClawChatMessage
  let compact: Bool
  @State private var isHovering = false
  @State private var didCopy = false

  init(message: OpenClawChatMessage, compact: Bool = false) {
    self.message = message
    self.compact = compact
  }

  var body: some View {
    let presentation = OpenClawContextPresentation(
      message.content,
      extractsContexts: message.role == .user
    )
    HStack(alignment: .top, spacing: 10) {
      if message.role == .user {
        Spacer(minLength: compact ? 24 : 48)
      }

      if message.role != .user {
        WorkspaceIconBadge(systemImage: message.role == .assistant ? "sparkles" : "gearshape", tint: roleTint, fill: background)
          .padding(.top, 1)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(message.role == .user ? "You" : "OpenClaw")
            .font(.caption.weight(.semibold))
            .foregroundStyle(roleTint)
          if message.role == .system {
            Text("System")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.orange)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
        }
        .padding(.trailing, 22)
        if !presentation.contexts.isEmpty {
          OpenClawContextPillsView(contexts: presentation.contexts)
        }
        if !presentation.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          OrgInlineText(presentation.userText, managesTextSelection: false)
            .lineLimit(nil)
            .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !message.attachments.isEmpty {
          OpenClawMessageAttachmentsView(attachments: message.attachments, compact: compact)
        }
        if message.role == .user, let sendFailure = message.sendFailure {
          OpenClawSendFailureView(
            messageID: message.id,
            deliveryStatus: message.deliveryStatus,
            failureText: sendFailure,
            compact: compact
          )
        }
        if message.role == .assistant,
           let responseTrace = message.responseTrace,
           !responseTrace.isEmpty {
          Divider()
            .padding(.top, 10)
            .padding(.bottom, 2)
          OpenClawProgressFeedView(
            reasoning: responseTrace.reasoning,
            activities: responseTrace.activities,
            compact: compact,
            isLive: false
          )
        }
        if message.role == .assistant, let changeSummary = message.changeSummary {
          Divider()
            .padding(.top, 10)
            .padding(.bottom, 2)
          OpenClawChangeSummaryView(summary: changeSummary, compact: compact)
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 9)
      .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(borderColor)
      )
      .overlay(alignment: .topTrailing) {
        copyButton
          .padding(.top, 6)
          .padding(.trailing, 6)
      }
      .fixedSize(horizontal: false, vertical: true)
      .onHover { isHovering in
        withAnimation(WorkspaceMotion.quick) {
          self.isHovering = isHovering
          if !isHovering { didCopy = false }
        }
      }

      if message.role != .user {
        Spacer(minLength: compact ? 24 : 48)
      } else {
        WorkspaceIconBadge(systemImage: "person.fill", tint: .accentColor, fill: Color.accentColor.opacity(0.12))
          .padding(.top, 1)
      }
    }
    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var copyButton: some View {
    Button {
      OpenClawMessageClipboard.copy(message)
      didCopy = true
    } label: {
      Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
        .font(.caption2.weight(.semibold))
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(didCopy ? Color.green : Color.secondary)
    .opacity(isHovering || didCopy ? 0.9 : 0.18)
    .help(didCopy ? "Copied" : "Copy message")
    .accessibilityLabel(didCopy ? "Message copied" : "Copy message")
  }

  private var background: Color {
    switch message.role {
    case .user:
      return Color.accentColor.opacity(0.11)
    case .assistant:
      return WorkspaceDesign.surfaceBackground
    case .system:
      return Color.orange.opacity(0.10)
    }
  }

  private var borderColor: Color {
    switch message.role {
    case .user:
      return Color.accentColor.opacity(0.16)
    case .assistant:
      return WorkspaceDesign.hairline
    case .system:
      return Color.orange.opacity(0.20)
    }
  }

  private var roleTint: Color {
    switch message.role {
    case .user:
      return .accentColor
    case .assistant:
      return .secondary
    case .system:
      return .orange
    }
  }
}

enum OpenClawMessageClipboard {
  nonisolated static func text(for message: OpenClawChatMessage) -> String {
    if !message.content.isEmpty {
      return OpenClawContextPresentation(
        message.content,
        extractsContexts: message.role == .user
      ).clipboardText
    }
    return message.attachments.map { "[Attachment: \($0.fileName)]" }.joined(separator: "\n")
  }

  @MainActor
  static func copy(_ message: OpenClawChatMessage, to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.setString(text(for: message), forType: .string)
  }
}

private struct OpenClawContextPillsView: View {
  let contexts: [OpenClawPresentedContext]
  var remove: ((OpenClawPresentedContext) -> Void)?

  init(
    contexts: [OpenClawPresentedContext],
    remove: ((OpenClawPresentedContext) -> Void)? = nil
  ) {
    self.contexts = contexts
    self.remove = remove
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(contexts) { context in
          OpenClawContextPill(context: context, remove: remove)
        }
      }
      .padding(.vertical, 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct OpenClawContextPill: View {
  let context: OpenClawPresentedContext
  let remove: ((OpenClawPresentedContext) -> Void)?

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: context.systemImage)
        .font(.caption2.weight(.semibold))
        .accessibilityHidden(true)
      Text(context.title)
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .truncationMode(.tail)
      if let remove {
        Button {
          remove(context)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Remove \(context.title) from context")
        .accessibilityLabel("Remove \(context.title) from context")
      }
    }
    .foregroundStyle(Color.accentColor)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .frame(maxWidth: 240)
    .background(Color.accentColor.opacity(0.09), in: Capsule())
    .overlay(Capsule().stroke(Color.accentColor.opacity(0.18)))
    .help("\(context.kind.capitalized): \(context.title)")
  }
}

private struct OpenClawSendFailureView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let messageID: UUID
  let deliveryStatus: OpenClawChatMessage.DeliveryStatus
  let failureText: String
  let compact: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.red)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.red)
        Text(failureText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(compact ? 4 : 5)
          .truncationMode(.tail)
      }
      Spacer(minLength: 8)
      Button {
        Task { await store.retryOpenClawMessage(messageID) }
      } label: {
        if compact {
          Image(systemName: "arrow.clockwise")
        } else {
          Label(retryButtonTitle, systemImage: "arrow.clockwise")
        }
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .disabled(store.isSendingOpenClawMessage)
      .help(retryHelpText)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.red.opacity(0.22))
    )
  }

  private var title: String {
    if isProviderAuthenticationFailure {
      return "Model provider authentication failed"
    }
    switch deliveryStatus {
    case .interrupted:
      return "Response interrupted"
    case .sending, .sent, .failed:
      return "Message failed to send"
    }
  }

  private var isProviderAuthenticationFailure: Bool {
    failureText.localizedCaseInsensitiveContains("model provider rejected authentication")
  }

  private var retryButtonTitle: String {
    isProviderAuthenticationFailure ? "Retry After Fix" : "Retry"
  }

  private var retryHelpText: String {
    isProviderAuthenticationFailure
      ? "Fix the model provider on the OpenClaw gateway host, then retry this message"
      : "Retry sending this message"
  }
}

private struct OpenClawMessageAttachmentsView: View {
  let attachments: [OpenClawChatAttachment]
  let compact: Bool

  private var imageSize: CGFloat {
    compact ? 76 : 104
  }

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: imageSize, maximum: imageSize), spacing: 8)],
      alignment: .leading,
      spacing: 8
    ) {
      ForEach(attachments) { attachment in
        OpenClawAttachmentThumbnail(attachment: attachment, size: imageSize)
      }
    }
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
    .padding(.top, 2)
  }
}

private struct OpenClawAttachmentThumbnail: View {
  let attachment: OpenClawChatAttachment
  let size: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Group {
        if let image = NSImage(data: attachment.data) {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: "photo")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(WorkspaceDesign.hairline)
      )

      Text(attachment.fileName)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: size, alignment: .leading)
    }
    .help("\(attachment.fileName) · \(Self.byteCountText(attachment.byteCount))")
  }

  private static func byteCountText(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
  }
}

private struct OpenClawChangeSummaryView: View {
  let summary: OpenClawCorpusChangeSummary
  let compact: Bool

  private var visibleLimit: Int {
    compact ? 4 : 6
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Label(summary.title, systemImage: "doc.text.magnifyingglass")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
        Spacer(minLength: 8)
        OpenClawChangeDeltaView(insertions: summary.totalInsertions, deletions: summary.totalDeletions)
      }

      ForEach(summary.files.prefix(visibleLimit)) { change in
        HStack(spacing: 7) {
          Image(systemName: iconName(for: change.status))
            .font(.caption)
            .foregroundStyle(iconColor(for: change.status))
            .frame(width: 14)
          Text(change.relativePath)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 8)
          OpenClawChangeDeltaView(insertions: change.insertions, deletions: change.deletions)
        }
      }

      if summary.files.count > visibleLimit {
        Text("+\(summary.files.count - visibleLimit) more file\(summary.files.count - visibleLimit == 1 ? "" : "s")")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
  }

  private func iconName(for status: OpenClawCorpusFileChange.Status) -> String {
    switch status {
    case .created:
      return "plus.circle"
    case .modified:
      return "pencil"
    case .deleted:
      return "minus.circle"
    }
  }

  private func iconColor(for status: OpenClawCorpusFileChange.Status) -> Color {
    switch status {
    case .created:
      return .green
    case .modified:
      return .secondary
    case .deleted:
      return .red
    }
  }
}

private struct OpenClawChangeDeltaView: View {
  let insertions: Int
  let deletions: Int

  var body: some View {
    HStack(spacing: 4) {
      if insertions > 0 {
        Text("+\(insertions)")
          .foregroundStyle(.green)
      }
      if deletions > 0 {
        Text("-\(deletions)")
          .foregroundStyle(.red)
      }
      if insertions == 0 && deletions == 0 {
        Text("0")
          .foregroundStyle(.secondary)
      }
    }
    .font(.caption.monospacedDigit().weight(.medium))
    .lineLimit(1)
  }
}

struct OpenClawComposerView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var localDraft = ""
  @State private var lastStoreDraft = ""
  @State private var selectedSlashSuggestionIndex = 0
  let focusOnAppear: Bool
  let compact: Bool

  var body: some View {
    let presentation = OpenClawContextPresentation(localDraft)
    VStack(alignment: .trailing, spacing: 8) {
      let composerHeight = OpenClawComposerSizing.height(for: presentation.userText, compact: compact)
      VStack(alignment: .leading, spacing: 0) {
        if !presentation.contexts.isEmpty {
          OpenClawContextPillsView(contexts: presentation.contexts) { context in
            localDraft = presentation.removing(context)
          }
          .padding(.horizontal, 8)
          .padding(.top, 7)
          .padding(.bottom, 6)

          Divider()
            .padding(.horizontal, 8)
        }

        ZStack(alignment: .topLeading) {
          if presentation.userText.isEmpty {
            Text("Message OpenClaw")
              .font(.body)
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 10)
              .padding(.vertical, 9)
          }

          OpenClawComposerTextView(
            text: visibleDraftBinding,
            focusOnAppear: focusOnAppear,
            onReturn: handleReturn,
            onSuggestionCommand: handleSuggestionCommand
          )
          .padding(4)
        }
        .frame(minHeight: composerHeight, idealHeight: composerHeight, maxHeight: composerHeight)
      }
      .background(WorkspaceDesign.surfaceBackground, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
          .stroke(canSend ? Color.accentColor.opacity(0.26) : WorkspaceDesign.hairline)
      )
      .animation(.easeOut(duration: 0.12), value: composerHeight)

      let slashSuggestions = OpenClawSlashCommands.suggestions(
        for: presentation.userText,
        gatewayCommands: store.openClawGatewayCommands
      )
      if !slashSuggestions.isEmpty {
        OpenClawSlashCommandSuggestions(
          commands: slashSuggestions,
          selectedCommandID: selectedSlashSuggestion(in: slashSuggestions)?.id,
          select: completeSlashCommand
        )
      }

      if !store.openClawPendingAttachments.isEmpty {
        OpenClawPendingAttachmentsView(compact: compact)
      }

      HStack(spacing: 8) {
        if store.isSendingOpenClawMessage {
          Text(store.openClawQueuedMessageCount > 1 ? "\(store.openClawQueuedMessageCount - 1) queued" : "Sending")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        if store.isRecordingOpenClawVoiceNote {
          HStack(spacing: 6) {
            Image(systemName: "waveform")
              .foregroundStyle(.red)
            WorkspaceInputMeterView(
              averageLevel: store.openClawVoiceAverageLevel,
              peakLevel: store.openClawVoicePeakLevel
            )
            .frame(width: compact ? 72 : 110, height: 7)
          }
          .help("Recording OpenClaw dictation")
        } else if store.isTranscribingOpenClawVoiceNote {
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 5) {
                Text("Transcribing")
                  .font(.caption.weight(.medium))
                  .foregroundStyle(.secondary)
                if !store.openClawVoiceTranscriptionElapsedText.isEmpty {
                  Text(store.openClawVoiceTranscriptionElapsedText)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.tertiary)
                }
              }
              ProgressView(value: store.openClawVoiceTranscriptionProgress)
                .progressViewStyle(.linear)
                .frame(width: compact ? 92 : 140)
            }
          }
          .help("Estimated local dictation transcription progress")
        }
        Spacer(minLength: 0)
        Button {
          store.chooseOpenClawImageAttachments()
        } label: {
          Label("Attach Image", systemImage: "photo.badge.plus")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(WorkspaceActionButtonStyle())
        .help("Attach image")

        Button {
          flushDraftToStore()
          Task { await store.toggleOpenClawVoiceNoteRecording() }
        } label: {
          Label(
            store.isRecordingOpenClawVoiceNote ? "Stop Dictation" : "Dictate",
            systemImage: store.isRecordingOpenClawVoiceNote ? "stop.fill" : "mic.fill"
          )
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(!store.isRecordingOpenClawVoiceNote && !store.canStartOpenClawVoiceNoteRecording)
        .help(store.isRecordingOpenClawVoiceNote ? "Stop, transcribe, and send" : "Record a local voice note and send the transcript")

        Button {
          _ = sendIfPossible()
        } label: {
          Label("Send", systemImage: "paperplane.fill")
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(!canSend)
      }
    }
    .onAppear {
      localDraft = store.openClawDraft
      lastStoreDraft = store.openClawDraft
      cacheDraftLocally()
    }
    .onDisappear {
      flushDraftToStore()
    }
    .onChange(of: localDraft) {
      selectedSlashSuggestionIndex = 0
      cacheDraftLocally()
      if OpenClawContextPresentation(localDraft).userText == "/" {
        Task { await store.refreshOpenClawCommands() }
      }
    }
    .onChange(of: store.openClawDraft) { _, newValue in
      let mergedDraft = OpenClawComposerDraftSync.localDraftAfterStoreChange(
        localDraft: localDraft,
        previousStoreDraft: lastStoreDraft,
        nextStoreDraft: newValue
      )
      lastStoreDraft = newValue
      guard mergedDraft != localDraft else { return }
      localDraft = mergedDraft
    }
  }

  private var canSend: Bool {
    !localDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !store.openClawPendingAttachments.isEmpty
  }

  private var visibleDraftBinding: Binding<String> {
    Binding(
      get: { OpenClawContextPresentation(localDraft).userText },
      set: { nextText in
        localDraft = OpenClawContextPresentation(localDraft).replacingUserText(nextText)
      }
    )
  }

  private func sendIfPossible() -> Bool {
    guard canSend else { return false }
    let text = localDraft
    localDraft = ""
    lastStoreDraft = ""
    store.cacheOpenClawComposerDraft("")
    store.submitOpenClawComposerInput(text: text)
    return true
  }

  private func handleReturn() -> Bool {
    _ = sendIfPossible()
    return true
  }

  private func handleSuggestionCommand(_ command: OpenClawComposerSuggestionKeyCommand) -> Bool {
    let suggestions = OpenClawSlashCommands.suggestions(
      for: OpenClawContextPresentation(localDraft).userText,
      gatewayCommands: store.openClawGatewayCommands
    )
    guard !suggestions.isEmpty else { return false }

    switch command {
    case .complete:
      guard let selected = selectedSlashSuggestion(in: suggestions) else { return false }
      completeSlashCommand(selected)
    case .move(let offset):
      selectedSlashSuggestionIndex = OpenClawSlashCommandSelection.movedIndex(
        selectedSlashSuggestionIndex,
        by: offset,
        count: suggestions.count
      )
    }
    return true
  }

  private func selectedSlashSuggestion(in suggestions: [OpenClawSlashCommand]) -> OpenClawSlashCommand? {
    OpenClawSlashCommandSelection.selectedCommand(
      in: suggestions,
      index: selectedSlashSuggestionIndex
    )
  }

  private func completeSlashCommand(_ command: OpenClawSlashCommand) {
    let commandText = command.arguments.isEmpty ? "/\(command.name)" : "/\(command.name) "
    localDraft = OpenClawContextPresentation(localDraft).replacingUserText(commandText)
  }

  private func cacheDraftLocally() {
    store.cacheOpenClawComposerDraft(localDraft)
  }

  private func flushDraftToStore() {
    if store.openClawDraft != localDraft {
      lastStoreDraft = localDraft
      store.publishOpenClawComposerDraft(localDraft)
    } else {
      lastStoreDraft = store.openClawDraft
    }
  }
}

private struct OpenClawSlashCommandSuggestions: View {
  let commands: [OpenClawSlashCommand]
  let selectedCommandID: OpenClawSlashCommand.ID?
  let select: (OpenClawSlashCommand) -> Void

  var body: some View {
    VStack(spacing: 2) {
      ForEach(commands) { command in
        Button {
          select(command)
        } label: {
          HStack(spacing: 9) {
            Image(systemName: command.systemImage)
              .frame(width: 18)
              .foregroundStyle(.secondary)
            Text(command.invocation)
              .font(.callout.monospaced().weight(.medium))
            Text(command.summary)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer(minLength: 4)
            if command.origin == .openClaw || command.isAgentAssisted {
              Text(command.origin == .openClaw ? "OpenClaw" : "Agent")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
          }
          .contentShape(Rectangle())
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
          .background(
            command.id == selectedCommandID ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
          )
        }
        .buttonStyle(.plain)
      }

      HStack(spacing: 10) {
        Label("Navigate", systemImage: "arrow.up.arrow.down")
        Text("Tab Complete")
      }
      .font(.caption2.weight(.medium))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .trailing)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
    }
    .padding(4)
    .background(WorkspaceDesign.surfaceBackground, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius))
    .overlay(
      RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius)
        .stroke(WorkspaceDesign.hairline)
    )
  }
}

enum OpenClawComposerDraftSync {
  static func localDraftAfterStoreChange(
    localDraft: String,
    previousStoreDraft: String,
    nextStoreDraft: String
  ) -> String {
    guard nextStoreDraft != localDraft else { return localDraft }
    guard localDraft != previousStoreDraft else { return nextStoreDraft }
    guard !nextStoreDraft.isEmpty else { return "" }
    guard !localDraft.isEmpty else { return nextStoreDraft }

    if nextStoreDraft.contains(localDraft) {
      return nextStoreDraft
    }

    if !previousStoreDraft.isEmpty,
       let range = nextStoreDraft.range(of: previousStoreDraft) {
      var merged = nextStoreDraft
      merged.replaceSubrange(range, with: localDraft)
      return merged
    }

    return nextStoreDraft + localDraft
  }
}

private struct OpenClawPendingAttachmentsView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let compact: Bool

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(store.openClawPendingAttachments) { attachment in
          OpenClawPendingAttachmentChip(attachment: attachment)
        }
      }
      .padding(.vertical, 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct OpenClawPendingAttachmentChip: View {
  @EnvironmentObject private var store: WorkspaceStore
  let attachment: OpenClawChatAttachment

  var body: some View {
    HStack(spacing: 7) {
      if let image = NSImage(data: attachment.data) {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 30, height: 30)
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      } else {
        Image(systemName: "photo")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 30, height: 30)
          .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      }

      VStack(alignment: .leading, spacing: 1) {
        Text(attachment.fileName)
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: 150, alignment: .leading)

      Button {
        store.removeOpenClawPendingAttachment(attachment)
      } label: {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Remove attachment")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(WorkspaceDesign.surfaceBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(WorkspaceDesign.hairline)
    )
    .help("\(attachment.fileName) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))")
  }
}

enum OpenClawComposerSizing {
  static func height(for text: String, compact: Bool) -> CGFloat {
    let visualLineCount = estimatedVisualLineCount(for: text, compact: compact)
    let baseHeight: CGFloat = 34
    let lineHeight: CGFloat = 20
    let minHeight: CGFloat = compact ? 54 : 58
    let maxHeight: CGFloat = compact ? 150 : 190
    return min(max(baseHeight + CGFloat(max(1, visualLineCount)) * lineHeight, minHeight), maxHeight)
  }

  static func estimatedVisualLineCount(for text: String, compact: Bool) -> Int {
    guard !text.isEmpty else { return 1 }
    let wrapColumn = compact ? 42 : 72
    return text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        max(1, Int(ceil(Double(line.count + 1) / Double(wrapColumn))))
      }
      .reduce(0, +)
  }
}

enum OpenClawComposerKeyCommand {
  static func isSendCommand(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
    return isReturnKey(keyCode) && relevantModifiers.isEmpty
  }

  static func isNewlineCommand(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
    return isReturnKey(keyCode) && relevantModifiers == [.command]
  }

  static func suggestionCommand(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
  ) -> OpenClawComposerSuggestionKeyCommand? {
    let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
    guard relevantModifiers.isEmpty else { return nil }
    switch keyCode {
    case 48:
      return .complete
    case 125:
      return .move(1)
    case 126:
      return .move(-1)
    default:
      return nil
    }
  }

  private static func isReturnKey(_ keyCode: UInt16) -> Bool {
    keyCode == 36 || keyCode == 76
  }
}

enum OpenClawComposerSuggestionKeyCommand: Equatable {
  case complete
  case move(Int)
}

enum OpenClawSlashCommandSelection {
  static func selectedCommand(
    in commands: [OpenClawSlashCommand],
    index: Int
  ) -> OpenClawSlashCommand? {
    guard !commands.isEmpty else { return nil }
    return commands[min(max(0, index), commands.count - 1)]
  }

  static func movedIndex(_ index: Int, by offset: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let normalizedIndex = ((index % count) + count) % count
    return ((normalizedIndex + offset) % count + count) % count
  }
}

private struct OpenClawComposerTextView: NSViewRepresentable {
  @Binding var text: String
  let focusOnAppear: Bool
  let onReturn: () -> Bool
  let onSuggestionCommand: (OpenClawComposerSuggestionKeyCommand) -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder

    let textView = CommandSubmitTextView()
    textView.delegate = context.coordinator
    textView.onReturn = {
      context.coordinator.parent.onReturn()
    }
    textView.onSuggestionCommand = {
      context.coordinator.parent.onSuggestionCommand($0)
    }
    textView.string = text
    textView.font = .systemFont(ofSize: NSFont.systemFontSize)
    textView.textColor = .labelColor
    textView.backgroundColor = .clear
    textView.drawsBackground = false
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainerInset = NSSize(width: 4, height: 5)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
    textView.autoresizingMask = [.width]
    scrollView.documentView = textView

    if focusOnAppear {
      DispatchQueue.main.async {
        textView.window?.makeFirstResponder(textView)
      }
    }

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? CommandSubmitTextView else { return }
    context.coordinator.parent = self
    textView.onReturn = {
      context.coordinator.parent.onReturn()
    }
    textView.onSuggestionCommand = {
      context.coordinator.parent.onSuggestionCommand($0)
    }
    if textView.string != text {
      let selectedRange = textView.selectedRange()
      textView.string = text
      textView.setSelectedRange(NSRange(
        location: min(selectedRange.location, (text as NSString).length),
        length: 0
      ))
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: OpenClawComposerTextView

    init(parent: OpenClawComposerTextView) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
    }
  }

  final class CommandSubmitTextView: NSTextView {
    var onReturn: (() -> Bool)?
    var onSuggestionCommand: ((OpenClawComposerSuggestionKeyCommand) -> Bool)?

    override func keyDown(with event: NSEvent) {
      if let command = OpenClawComposerKeyCommand.suggestionCommand(
        keyCode: event.keyCode,
        modifiers: event.modifierFlags
      ), onSuggestionCommand?(command) == true {
        return
      }
      if OpenClawComposerKeyCommand.isSendCommand(keyCode: event.keyCode, modifiers: event.modifierFlags),
         onReturn?() == true {
        return
      }
      if OpenClawComposerKeyCommand.isNewlineCommand(keyCode: event.keyCode, modifiers: event.modifierFlags) {
        insertText("\n", replacementRange: selectedRange())
        return
      }
      super.keyDown(with: event)
    }
  }
}

struct OpenClawTypingIndicatorView: View {
  let startedAt: Date?
  let connectionState: OpenClawGatewayConnectionState
  let connectionDetail: String?
  let runID: String?
  let streamingReply: String
  let reasoning: String
  let activities: [OpenClawRunActivity]
  let compact: Bool
  let onStop: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 8) {
          WorkspaceActivityIndicator(size: .small, style: .signal)
          Text(statusTitle)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TimelineView(.periodic(from: startedAt ?? Date(), by: 1)) { context in
            Text(elapsedText(now: context.date))
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
              .frame(minWidth: 42, alignment: .leading)
          }
          Spacer(minLength: 8)
          if canStop {
            Button(action: onStop) {
              Image(systemName: "stop.fill")
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Stop OpenClaw run")
            .help("Stop this OpenClaw run")
          }
        }
        .frame(minHeight: 20)

        if !streamingReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          OrgInlineText(streamingReply)
            .lineLimit(nil)
            .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        } else if let progressSummary {
          Text(progressSummary)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .contentTransition(.opacity)
            .animation(WorkspaceMotion.quick, value: progressSummary)
        }

        HStack(spacing: 5) {
          Circle()
            .fill(connectionColor)
            .frame(width: 5, height: 5)
          Text(connectionState.label)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .help(connectionHelp)
        .animation(WorkspaceMotion.quick, value: connectionState)

        if hasProgress {
          OpenClawProgressFeedView(
            reasoning: reasoning,
            activities: activities,
            compact: compact,
            isLive: true
          )
        }
      }
      .padding(10)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.secondary.opacity(0.16))
      )
      .frame(maxWidth: compact ? 430 : 700, alignment: .leading)
      Spacer(minLength: compact ? 24 : 48)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusTitle: String {
    connectionState == .disconnected ? "Connection interrupted" : "OpenClaw is working"
  }

  var progressSummary: String? {
    if let latest = OpenClawActivityFeed.items(from: activities).last(where: { $0.status == .running }) {
      return latest.title
    }
    switch connectionState {
    case .connecting: return "Opening the live connection…"
    case .reconnecting: return "Reconnecting without resending…"
    case .connected: return runID == nil ? "Starting the run…" : nil
    case .fallbackHTTP: return "Gateway unavailable; continuing over HTTP."
    case .disconnected: return connectionDetail ?? "The connection was interrupted."
    }
  }

  private var canStop: Bool {
    connectionState == .connected && runID != nil
  }

  private var trimmedReasoning: String {
    reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var hasProgress: Bool {
    !OpenClawActivityFeed.items(from: activities).isEmpty || !trimmedReasoning.isEmpty
  }

  private var connectionHelp: String {
    var parts: [String] = []
    if let connectionDetail, !connectionDetail.isEmpty { parts.append(connectionDetail) }
    if let runID { parts.append("Run \(runID)") }
    return parts.isEmpty ? connectionState.label : parts.joined(separator: "\n")
  }

  private var connectionColor: Color {
    switch connectionState {
    case .connected: return .green
    case .connecting, .reconnecting: return .orange
    case .fallbackHTTP: return .blue
    case .disconnected: return .red
    }
  }

  private func elapsedText(now: Date) -> String {
    guard let startedAt else { return "0s" }
    let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
    if seconds < 60 { return "\(seconds)s" }
    return "\(seconds / 60)m \(seconds % 60)s"
  }
}

private struct OpenClawProgressFeedView: View {
  let reasoning: String
  let activities: [OpenClawRunActivity]
  let compact: Bool
  let isLive: Bool

  @State private var showsFullFeed = false

  private var items: [OpenClawActivityFeedItem] {
    OpenClawActivityFeed.items(from: activities)
  }

  private var trimmedReasoning: String {
    reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var collapsedItemLimit: Int { compact ? 2 : 3 }

  private var visibleItems: ArraySlice<OpenClawActivityFeedItem> {
    showsFullFeed ? items[...] : items.suffix(collapsedItemLimit)
  }

  private var canExpand: Bool {
    items.count > collapsedItemLimit || trimmedReasoning.count > 360
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 7) {
        Label(isLive ? "Progress" : "Work log", systemImage: isLive ? "waveform.path.ecg" : "clock.arrow.circlepath")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        if canExpand {
          Button {
            withAnimation(WorkspaceMotion.disclosure) {
              showsFullFeed.toggle()
            }
          } label: {
            Label(
              showsFullFeed ? "Show less" : "Show full feed",
              systemImage: showsFullFeed ? "chevron.up" : "chevron.down"
            )
          }
          .labelStyle(.titleAndIcon)
          .buttonStyle(.plain)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
        }
      }

      if !trimmedReasoning.isEmpty {
        Text(trimmedReasoning)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(showsFullFeed ? nil : (isLive ? 5 : 2))
          .textSelection(.enabled)
          .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
      }

      if !visibleItems.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(visibleItems) { item in
            OpenClawActivityFeedRow(item: item)
          }
        }
      }

      if !showsFullFeed, items.count > collapsedItemLimit {
        Text("\(items.count - collapsedItemLimit) earlier update\(items.count - collapsedItemLimit == 1 ? "" : "s") hidden")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
  }
}

private struct OpenClawActivityFeedRow: View {
  let item: OpenClawActivityFeedItem

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      Image(systemName: icon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.caption.weight(.medium))
        if let detail = item.detail, !detail.isEmpty {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(3)
            .textSelection(.enabled)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var icon: String {
    switch item.status {
    case .running: return "wrench.and.screwdriver"
    case .succeeded: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    }
  }

  private var tint: Color {
    switch item.status {
    case .running: return .accentColor
    case .succeeded: return .green
    case .failed: return .red
    }
  }
}
