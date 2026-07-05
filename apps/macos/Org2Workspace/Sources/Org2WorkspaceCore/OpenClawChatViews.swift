import AppKit
import SwiftUI

struct ChatBubbleView: View {
  let message: OpenClawChatMessage
  let compact: Bool

  init(message: OpenClawChatMessage, compact: Bool = false) {
    self.message = message
    self.compact = compact
  }

  var body: some View {
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
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          OrgInlineText(message.content)
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
        if message.role == .assistant, let changeSummary = message.changeSummary {
          Divider()
            .padding(.vertical, 2)
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
      .fixedSize(horizontal: false, vertical: true)

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
          .lineLimit(compact ? 2 : 3)
          .truncationMode(.tail)
      }
      Spacer(minLength: 8)
      Button {
        Task { await store.retryOpenClawMessage(messageID) }
      } label: {
        if compact {
          Image(systemName: "arrow.clockwise")
        } else {
          Label("Retry", systemImage: "arrow.clockwise")
        }
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .disabled(store.isSendingOpenClawMessage)
      .help("Retry sending this message")
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
    switch deliveryStatus {
    case .interrupted:
      return "Response interrupted"
    case .sending, .sent, .failed:
      return "Message failed to send"
    }
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
  let focusOnAppear: Bool
  let compact: Bool

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      let composerHeight = OpenClawComposerSizing.height(for: localDraft, compact: compact)
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
          .fill(WorkspaceDesign.surfaceBackground)
          .overlay(
            RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
              .stroke(canSend ? Color.accentColor.opacity(0.26) : WorkspaceDesign.hairline)
          )

        if localDraft.isEmpty {
          Text("Message OpenClaw")
            .font(.body)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }

        OpenClawComposerTextView(
          text: $localDraft,
          focusOnAppear: focusOnAppear,
          onReturn: handleReturn
        )
        .padding(4)
      }
      .frame(minHeight: composerHeight, idealHeight: composerHeight, maxHeight: composerHeight)
      .animation(.easeOut(duration: 0.12), value: composerHeight)

      if !store.openClawPendingAttachments.isEmpty {
        OpenClawPendingAttachmentsView(compact: compact)
      }

      HStack(spacing: 8) {
        if store.isSendingOpenClawMessage {
          HStack(spacing: 6) {
            WorkspaceActivityIndicator(size: .small)
            Text(store.openClawQueuedMessageCount > 1 ? "\(store.openClawQueuedMessageCount - 1) queued" : "Sending")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
              .workspaceShimmer()
          }
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
    }
    .onDisappear {
      flushDraftToStore()
    }
    .onChange(of: localDraft) {
      flushDraftToStore()
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

  private func sendIfPossible() -> Bool {
    guard canSend else { return false }
    let text = localDraft
    localDraft = ""
    lastStoreDraft = ""
    store.openClawDraft = ""
    Task { await store.sendComposedOpenClawMessage(text: text) }
    return true
  }

  private func handleReturn() -> Bool {
    _ = sendIfPossible()
    return true
  }

  private func flushDraftToStore() {
    if store.openClawDraft != localDraft {
      lastStoreDraft = localDraft
      store.openClawDraft = localDraft
    } else {
      lastStoreDraft = store.openClawDraft
    }
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

  private static func isReturnKey(_ keyCode: UInt16) -> Bool {
    keyCode == 36 || keyCode == 76
  }
}

private struct OpenClawComposerTextView: NSViewRepresentable {
  @Binding var text: String
  let focusOnAppear: Bool
  let onReturn: () -> Bool

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

    override func keyDown(with event: NSEvent) {
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

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          WorkspaceActivityIndicator(size: .small)
          TimelineView(.periodic(from: startedAt ?? Date(), by: 1)) { context in
            Text("OpenClaw is thinking\(elapsedSuffix(now: context.date))")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
              .workspaceShimmer()
          }
        }
        Text("Waiting for the gateway response")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(10)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.secondary.opacity(0.16))
      )
      Spacer(minLength: 48)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func elapsedSuffix(now: Date) -> String {
    guard let startedAt else { return "" }
    let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
    if seconds < 1 { return "" }
    if seconds < 60 { return " \(seconds)s" }
    return " \(seconds / 60)m \(seconds % 60)s"
  }
}
