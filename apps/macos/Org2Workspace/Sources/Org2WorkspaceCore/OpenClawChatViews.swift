import AppKit
import SwiftUI

enum AIChatMessageTimestampPresentation {
  static func displayText(
    for date: Date,
    relativeTo now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    var calendar = calendar
    calendar.timeZone = timeZone
    let time = date.formatted(
      Date.FormatStyle(
        date: .omitted,
        time: .shortened,
        locale: locale,
        calendar: calendar,
        timeZone: timeZone
      )
    )

    if calendar.isDate(date, inSameDayAs: now) {
      return "Today at \(time)"
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(date, inSameDayAs: yesterday) {
      return "Yesterday at \(time)"
    }

    let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
    let day: String
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
      day = date.formatted(style.month(.abbreviated).day())
    } else {
      day = date.formatted(style.month(.abbreviated).day().year())
    }
    return "\(day) at \(time)"
  }

  static func fullText(
    for date: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    var calendar = Calendar.current
    calendar.timeZone = timeZone
    return date.formatted(
      Date.FormatStyle(
        date: .complete,
        time: .shortened,
        locale: locale,
        calendar: calendar,
        timeZone: timeZone
      )
    )
  }
}

struct OpenClawPresentedContext: Identifiable, Hashable, Sendable {
  let kind: String
  let title: String
  let reference: String
  let sourceLine: String
  let automaticPrompt: String?

  init(
    kind: String,
    title: String,
    reference: String,
    sourceLine: String,
    automaticPrompt: String? = nil
  ) {
    self.kind = kind
    self.title = title
    self.reference = reference
    self.sourceLine = sourceLine
    self.automaticPrompt = automaticPrompt
  }

  var id: String { "\(kind)|\(reference)|\(title)" }

  var usesGenericTitle: Bool {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["page", "file", "entry", "heading", "block", "selection", "context"].contains(normalized)
  }

  var systemImage: String {
    if automaticPrompt != nil { return "sparkles" }
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
  static let automaticContextBegin = "#+begin_org2_ai_context"
  static let automaticContextEnd = "#+end_org2_ai_context"

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
      guard let (context, rest) = Self.consumeContext(from: remaining) else { break }
      parsed.append(context)
      remaining = rest
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

  static func automaticContext(
    kind: String,
    title: String,
    reference: String,
    prompt: String,
    userText: String = ""
  ) -> String {
    let safeTitle = title
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "”", with: "'")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedUserText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
    let context = """
    Use \(kind) “\(safeTitle)” at \(reference) as context.
    \(automaticContextBegin)
    \(normalizedPrompt)
    \(automaticContextEnd)
    """
    return normalizedUserText.isEmpty ? context : "\(context)\n\n\(normalizedUserText)"
  }

  private static func consumeContext(
    from remaining: String
  ) -> (context: OpenClawPresentedContext, rest: String)? {
    let firstNewline = remaining.firstIndex(of: "\n")
    let header = firstNewline.map { String(remaining[..<$0]) } ?? remaining
    guard var context = parseContextLine(header) else { return nil }

    if let firstNewline {
      let afterHeader = remaining[firstNewline...]
      let automaticPrefix = "\n\(automaticContextBegin)\n"
      if afterHeader.hasPrefix(automaticPrefix) {
        let promptStart = remaining.index(firstNewline, offsetBy: automaticPrefix.count)
        let endToken = "\n\(automaticContextEnd)"
        guard let endRange = remaining.range(
          of: endToken,
          range: promptStart..<remaining.endIndex
        ) else { return nil }
        let prompt = String(remaining[promptStart..<endRange.lowerBound])
        let sourceEnd = endRange.upperBound
        context = OpenClawPresentedContext(
          kind: context.kind,
          title: context.title,
          reference: context.reference,
          sourceLine: String(remaining[..<sourceEnd]),
          automaticPrompt: prompt
        )
        return (context, trimmingContextSeparator(from: remaining, after: sourceEnd))
      }
    }

    let separator = remaining.range(of: "\n\n")
    let sourceEnd = separator?.lowerBound ?? remaining.endIndex
    context = OpenClawPresentedContext(
      kind: context.kind,
      title: context.title,
      reference: context.reference,
      sourceLine: String(remaining[..<sourceEnd])
    )
    let rest = separator.map { String(remaining[$0.upperBound...]) } ?? ""
    return (context, rest)
  }

  private static func trimmingContextSeparator(
    from source: String,
    after sourceEnd: String.Index
  ) -> String {
    var next = sourceEnd
    var removedNewlines = 0
    while next < source.endIndex,
          source[next] == "\n",
          removedNewlines < 2 {
      next = source.index(after: next)
      removedNewlines += 1
    }
    return String(source[next...])
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

struct OpenClawMessageOrgPresentation: Equatable, Sendable {
  let normalizedText: String
  let blocks: [OrgEditableBlock]
  let usesStructuredRendering: Bool

  nonisolated init(_ rawText: String) {
    normalizedText = OpenClawMessageOrgNormalizer.normalized(rawText)
    blocks = OrgEntryRenderer.parseEditable(normalizedText)
    usesStructuredRendering = blocks.contains { block in
      switch block.rendered {
      case .paragraph, .blank:
        return false
      case .heading, .planning, .properties, .quote, .source, .table,
           .horizontalRule, .listItem, .keyword:
        return true
      }
    }
  }
}

final class OpenClawCachedMessagePresentation {
  let role: OpenClawChatMessage.Role
  let rawText: String
  let responseTrace: OpenClawResponseTrace?
  let context: OpenClawContextPresentation
  let org: OpenClawMessageOrgPresentation?
  let activityFeedItems: [OpenClawActivityFeedItem]

  init(
    role: OpenClawChatMessage.Role,
    rawText: String,
    responseTrace: OpenClawResponseTrace?,
    context: OpenClawContextPresentation,
    org: OpenClawMessageOrgPresentation?,
    activityFeedItems: [OpenClawActivityFeedItem]
  ) {
    self.role = role
    self.rawText = rawText
    self.responseTrace = responseTrace
    self.context = context
    self.org = org
    self.activityFeedItems = activityFeedItems
  }

  func matches(_ message: OpenClawChatMessage) -> Bool {
    role == message.role
      && rawText == message.content
      && responseTrace == message.responseTrace
  }
}

@MainActor
enum OpenClawMessagePresentationCache {
  private final class CacheKey: NSObject {
    let messageID: UUID

    init(messageID: UUID) {
      self.messageID = messageID
    }

    override var hash: Int { messageID.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? CacheKey else { return false }
      return messageID == other.messageID
    }
  }

  private static let cache: NSCache<CacheKey, OpenClawCachedMessagePresentation> = {
    let cache = NSCache<CacheKey, OpenClawCachedMessagePresentation>()
    cache.countLimit = 1_024
    cache.totalCostLimit = 32 * 1_024 * 1_024
    return cache
  }()

  static func presentation(for message: OpenClawChatMessage) -> OpenClawCachedMessagePresentation {
    let key = CacheKey(messageID: message.id)
    if let cached = cache.object(forKey: key), cached.matches(message) {
      return cached
    }

    let context = OpenClawContextPresentation(
      message.content,
      extractsContexts: message.role == .user
    )
    let org = message.role == .assistant
      ? OpenClawMessageOrgPresentation(context.userText)
      : nil
    let activityFeedItems = message.responseTrace.map {
      OpenClawActivityFeed.items(from: $0.activities)
    } ?? []
    let value = OpenClawCachedMessagePresentation(
      role: message.role,
      rawText: message.content,
      responseTrace: message.responseTrace,
      context: context,
      org: org,
      activityFeedItems: activityFeedItems
    )
    let cost = message.content.utf8.count
      + (message.responseTrace?.activities.count ?? 0) * 256
    cache.setObject(value, forKey: key, cost: cost)
    return value
  }

  static func removeAllForTesting() {
    cache.removeAllObjects()
  }
}

enum OpenClawMessageOrgNormalizer {
  private nonisolated static let blockDirectiveNames = [
    "begin_src",
    "end_src",
    "begin_example",
    "end_example",
    "begin_quote",
    "end_quote"
  ]

  nonisolated static func normalized(_ rawText: String) -> String {
    var lines = rawText
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    for index in lines.indices {
      lines[index] = normalizedBlockDirective(lines[index])

      guard index > lines.startIndex,
            isTableSeparator(lines[index]),
            let cells = tableCells(lines[lines.index(before: index)]),
            cells.count > 1
      else {
        continue
      }

      let trimmedSeparator = lines[index].trimmingCharacters(in: .whitespaces)
      let actualJoinCount = trimmedSeparator.filter { $0 == "+" }.count
      guard actualJoinCount != cells.count - 1 else { continue }

      let indentation = String(lines[index].prefix { $0 == " " || $0 == "\t" })
      let hline = "|" + cells
        .map { String(repeating: "-", count: max(3, $0.count + 2)) }
        .joined(separator: "+") + "|"
      lines[index] = indentation + hline
    }

    return lines.joined(separator: "\n")
  }

  private nonisolated static func normalizedBlockDirective(_ line: String) -> String {
    let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
    let trimmed = line.dropFirst(indentation.count)
    let hashCount = trimmed.prefix { $0 == "#" }.count
    guard hashCount > 1 else { return line }
    let suffix = trimmed.dropFirst(hashCount)
    guard suffix.first == "+" else { return line }
    let directive = suffix.dropFirst().lowercased()
    guard blockDirectiveNames.contains(where: {
      directive == $0 || directive.hasPrefix($0 + " ") || directive.hasPrefix($0 + "\t")
    }) else { return line }
    return indentation + "#" + suffix
  }

  private nonisolated static func isTableSeparator(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return false }
    let inner = trimmed.dropFirst().dropLast()
    return inner.contains("-") && inner.allSatisfy { $0 == "-" || $0 == "+" || $0.isWhitespace }
  }

  private nonisolated static func tableCells(_ line: String) -> [String]? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
    let cells = trimmed
      .dropFirst()
      .dropLast()
      .split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    return cells.isEmpty ? nil : cells
  }
}

private struct OpenClawMessageBodyView: View {
  let rawText: String
  let compact: Bool
  let managesTextSelection: Bool
  let rendersStructuredOrg2: Bool
  let structuredPresentation: OpenClawMessageOrgPresentation?

  init(
    rawText: String,
    compact: Bool,
    managesTextSelection: Bool,
    rendersStructuredOrg2: Bool,
    structuredPresentation: OpenClawMessageOrgPresentation? = nil
  ) {
    self.rawText = rawText
    self.compact = compact
    self.managesTextSelection = managesTextSelection
    self.rendersStructuredOrg2 = rendersStructuredOrg2
    self.structuredPresentation = structuredPresentation
  }

  var body: some View {
    let presentation = rendersStructuredOrg2
      ? (structuredPresentation ?? OpenClawMessageOrgPresentation(rawText))
      : nil
    Group {
      if let presentation, presentation.usesStructuredRendering {
        let containsTable = presentation.blocks.contains { block in
          if case .table = block.rendered { return true }
          return false
        }
        VStack(alignment: .leading, spacing: 0) {
          ForEach(presentation.blocks) { block in
            RenderedBlockView(
              block: block.rendered,
              rawText: block.rawText,
              inlineActions: .readOnly
            )
            .frame(
              maxWidth: compact || !block.isRenderedTable ? (compact ? 360 : 640) : .infinity,
              alignment: .leading
            )
          }
        }
        .environment(\.orgInlineTextSelectionEnabled, managesTextSelection)
        .frame(
          maxWidth: compact || !containsTable ? (compact ? 360 : 640) : .infinity,
          alignment: .leading
        )
      } else {
        OrgInlineText(
          presentation?.normalizedText ?? rawText,
          managesTextSelection: managesTextSelection
        )
        .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
      }
    }
    .lineLimit(nil)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private extension OrgEditableBlock {
  var isRenderedTable: Bool {
    if case .table = rendered { return true }
    return false
  }
}

struct ChatBubbleView: View {
  static let managesMessageTextSelection = true

  let message: OpenClawChatMessage
  let runtime: AIChatRuntime
  let destinationTitlesByID: [String: String]
  let compact: Bool
  let isQueued: Bool
  let isRoomResponse: Bool
  let canSteerQueuedMessage: Bool
  let steerQueuedMessage: () -> Void
  let editQueuedMessage: () -> Void
  let deleteQueuedMessage: () -> Void
  @State private var isHovering = false
  @State private var didCopy = false
  @State private var previewedAttachment: OpenClawChatAttachment?

  init(
    message: OpenClawChatMessage,
    runtime: AIChatRuntime = .openClaw,
    destinationTitlesByID: [String: String] = [:],
    compact: Bool = false,
    isQueued: Bool = false,
    isRoomResponse: Bool = false,
    canSteerQueuedMessage: Bool = false,
    steerQueuedMessage: @escaping () -> Void = {},
    editQueuedMessage: @escaping () -> Void = {},
    deleteQueuedMessage: @escaping () -> Void = {}
  ) {
    self.message = message
    self.runtime = runtime
    self.destinationTitlesByID = destinationTitlesByID
    self.compact = compact
    self.isQueued = isQueued
    self.isRoomResponse = isRoomResponse
    self.canSteerQueuedMessage = canSteerQueuedMessage
    self.steerQueuedMessage = steerQueuedMessage
    self.editQueuedMessage = editQueuedMessage
    self.deleteQueuedMessage = deleteQueuedMessage
  }

  var body: some View {
    let cachedPresentation = OpenClawMessagePresentationCache.presentation(for: message)
    let presentation = cachedPresentation.context
    HStack(alignment: .top, spacing: 10) {
      if message.role == .user {
        Spacer(minLength: compact ? 24 : 48)
      }

      if message.role != .user && !isRoomResponse {
        WorkspaceIconBadge(systemImage: message.role == .assistant ? "sparkles" : "gearshape", tint: roleTint, fill: background)
          .padding(.top, 1)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(roleTitle)
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
          if isQueued {
            Label("Queued", systemImage: "clock")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
          } else if message.role == .user,
                    message.deliveryKind == .steer,
                    message.deliveryStatus == .sending {
            Label("Steering…", systemImage: "arrow.turn.up.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          Text(AIChatMessageTimestampPresentation.displayText(for: message.createdAt))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .help(AIChatMessageTimestampPresentation.fullText(for: message.createdAt))
            .accessibilityLabel(
              "Sent \(AIChatMessageTimestampPresentation.fullText(for: message.createdAt))"
            )
          copyButton
        }
        if !presentation.contexts.isEmpty {
          OpenClawContextPillsView(contexts: presentation.contexts)
        }
        if !presentation.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          OpenClawMessageBodyView(
            rawText: presentation.userText,
            compact: compact,
            managesTextSelection: Self.managesMessageTextSelection,
            rendersStructuredOrg2: message.role == .assistant,
            structuredPresentation: cachedPresentation.org
          )
        }
        if !message.attachments.isEmpty {
          OpenClawMessageAttachmentsView(
            attachments: message.attachments,
            compact: compact,
            onPreview: { previewedAttachment = $0 }
          )
        }
        if isQueued {
          OpenClawQueuedMessageActions(
            compact: compact,
            canSteer: canSteerQueuedMessage,
            steer: steerQueuedMessage,
            edit: editQueuedMessage,
            remove: deleteQueuedMessage
          )
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
            isLive: false,
            presentedItems: cachedPresentation.activityFeedItems
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
      .padding(.top, 9)
      .padding(.bottom, 12)
      .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(borderColor)
      )
      .frame(maxWidth: isRoomResponse ? .infinity : nil, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .onHover { isHovering in
        withAnimation(WorkspaceMotion.quick) {
          self.isHovering = isHovering
          if !isHovering { didCopy = false }
        }
      }

      if message.role != .user && !isRoomResponse {
        Spacer(minLength: compact ? 24 : 48)
      } else {
        WorkspaceIconBadge(systemImage: "person.fill", tint: .accentColor, fill: Color.accentColor.opacity(0.12))
          .padding(.top, 1)
      }
    }
    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    .fixedSize(horizontal: false, vertical: true)
    .sheet(item: $previewedAttachment) { attachment in
      OpenClawAttachmentPreviewView(attachment: attachment)
    }
  }

  private var copyButton: some View {
    Button {
      didCopy = OpenClawMessageClipboard.copy(message)
    } label: {
      Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
        .font(.caption2.weight(.semibold))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(didCopy ? Color.green : Color.secondary)
    .opacity(isHovering || didCopy ? 1 : 0.48)
    .help(didCopy ? "Copied" : "Copy message")
    .accessibilityLabel(didCopy ? "Message copied" : "Copy message")
  }

  private var roleTitle: String {
    switch message.role {
    case .user:
      if !message.audienceDestinationIDs.isEmpty {
        return "You → " + message.audienceDestinationIDs
          .map(destinationTitle)
          .joined(separator: " + ")
      }
      return message.audience.map { "You → \($0.title)" } ?? "You"
    case .assistant:
      return message.authorLabel
        ?? message.authorDestinationID.map(destinationTitle)
        ?? (message.authorRuntime ?? runtime).title
    case .system:
      return message.authorLabel
        ?? message.authorDestinationID.map(destinationTitle)
        ?? message.authorRuntime?.title
        ?? "Org2"
    }
  }

  private func destinationTitle(_ destinationID: String) -> String {
    if let title = destinationTitlesByID[destinationID] { return title }
    if destinationID == AIChatDestinationConfiguration.localCodexID { return "Codex" }
    if destinationID == AIChatDestinationConfiguration.openClawID { return "OpenClaw" }
    return destinationID
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

struct AIChatRoomRound: Identifiable, Equatable {
  let id: UUID
  let trigger: OpenClawChatMessage
  let expectedDestinationIDs: [String]
  let dispatchesByDestinationID: [String: OpenClawChatMessage]
  let responsesByDestinationID: [String: OpenClawChatMessage]

  var expectedRuntimes: [AIChatRuntime] {
    expectedDestinationIDs.compactMap { dispatchesByDestinationID[$0]?.targetRuntime }
  }

  var completedCount: Int {
    expectedDestinationIDs.filter(isTerminal).count
  }

  var isComplete: Bool {
    !expectedDestinationIDs.isEmpty && completedCount == expectedDestinationIDs.count
  }

  func dispatch(forDestinationID destinationID: String) -> OpenClawChatMessage? {
    dispatchesByDestinationID[destinationID]
  }

  func response(forDestinationID destinationID: String) -> OpenClawChatMessage? {
    responsesByDestinationID[destinationID]
  }

  func dispatch(for runtime: AIChatRuntime) -> OpenClawChatMessage? {
    expectedDestinationIDs.compactMap { dispatchesByDestinationID[$0] }
      .first(where: { $0.targetRuntime == runtime })
  }

  func response(for runtime: AIChatRuntime) -> OpenClawChatMessage? {
    expectedDestinationIDs.compactMap { responsesByDestinationID[$0] }
      .first(where: { $0.authorRuntime == runtime })
  }

  private func isTerminal(_ destinationID: String) -> Bool {
    if responsesByDestinationID[destinationID] != nil { return true }
    guard let dispatch = dispatchesByDestinationID[destinationID] else { return false }
    return dispatch.deliveryStatus == .failed || dispatch.deliveryStatus == .interrupted
  }
}

enum AIChatRoomTranscriptItem: Identifiable, Equatable {
  case message(OpenClawChatMessage)
  case round(AIChatRoomRound)

  var id: UUID {
    switch self {
    case .message(let message): message.id
    case .round(let round): round.id
    }
  }
}

enum AIChatRoomTranscriptPresentation {
  static func items(
    messages: [OpenClawChatMessage],
    isSharedRoom: Bool
  ) -> [AIChatRoomTranscriptItem] {
    guard isSharedRoom else {
      return messages
        .filter { !$0.isRoomDispatchCopy }
        .map(AIChatRoomTranscriptItem.message)
    }

    var items: [AIChatRoomTranscriptItem] = []
    var consumed = Set<UUID>()

    for (index, message) in messages.enumerated() {
      guard !consumed.contains(message.id) else { continue }
      guard !message.isRoomDispatchCopy else {
        consumed.insert(message.id)
        continue
      }
      let expectedDestinationIDs = !message.audienceDestinationIDs.isEmpty
        ? message.audienceDestinationIDs
        : (message.audience?.runtimes.map(AIChatDestinationConfiguration.defaultID(for:)) ?? [])
      guard message.role == .user, !expectedDestinationIDs.isEmpty
      else {
        consumed.insert(message.id)
        items.append(.message(message))
        continue
      }

      let groupedMessages: [OpenClawChatMessage]
      if let roomRoundID = message.roomRoundID {
        groupedMessages = messages.filter { $0.roomRoundID == roomRoundID }
      } else {
        let nextVisibleUserIndex = messages.indices.dropFirst(index + 1).first { candidate in
          messages[candidate].role == .user && !messages[candidate].isRoomDispatchCopy
        } ?? messages.endIndex
        groupedMessages = Array(messages[index..<nextVisibleUserIndex])
      }
      consumed.formUnion(groupedMessages.map(\.id))

      let dispatches = groupedMessages.filter { $0.role == .user }
      let responses = groupedMessages.filter { $0.role != .user }
      var dispatchesByDestinationID: [String: OpenClawChatMessage] = [:]
      dispatches.forEach { dispatch in
        if let destinationID = dispatch.targetDestinationID
          ?? dispatch.targetRuntime.map(AIChatDestinationConfiguration.defaultID(for:)) {
          dispatchesByDestinationID[destinationID] = dispatch
        }
      }

      var responsesByDestinationID: [String: OpenClawChatMessage] = [:]
      var unattributedResponses: [OpenClawChatMessage] = []
      for response in responses {
        if let destinationID = response.authorDestinationID
          ?? response.authorRuntime.map(AIChatDestinationConfiguration.defaultID(for:)) {
          responsesByDestinationID[destinationID] = response
        } else {
          unattributedResponses.append(response)
        }
      }
      let missingDestinationIDs = expectedDestinationIDs.filter {
        responsesByDestinationID[$0] == nil
      }
      for (destinationID, response) in zip(missingDestinationIDs, unattributedResponses) {
        responsesByDestinationID[destinationID] = response
      }

      items.append(.round(AIChatRoomRound(
        id: message.roomRoundID ?? message.id,
        trigger: message,
        expectedDestinationIDs: expectedDestinationIDs,
        dispatchesByDestinationID: dispatchesByDestinationID,
        responsesByDestinationID: responsesByDestinationID
      )))
    }
    return items
  }
}

struct AIChatRoomRoundView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let round: AIChatRoomRound
  let compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ChatBubbleView(
        message: round.trigger,
        runtime: store.selectedAIChatRuntime,
        destinationTitlesByID: store.aiChatDestinationTitlesByID,
        compact: compact,
        isQueued: store.isAIChatMessageQueued(round.trigger.id),
        editQueuedMessage: { store.editQueuedAIChatMessage(round.trigger.id) },
        deleteQueuedMessage: { store.deleteQueuedAIChatMessage(round.trigger.id) }
      )

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 7) {
          Label("Agent round", systemImage: "person.2.fill")
            .font(.caption.weight(.semibold))
          Spacer(minLength: 8)
          Text(roundStatus)
            .font(.caption2.weight(.medium))
            .foregroundStyle(round.isComplete ? .secondary : Color.accentColor)
        }

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 8) {
            ForEach(round.expectedDestinationIDs, id: \.self) { destinationID in
              agentSlot(destinationID)
                .frame(minWidth: 270, maxWidth: .infinity, alignment: .topLeading)
            }
          }
          VStack(alignment: .leading, spacing: 8) {
            ForEach(round.expectedDestinationIDs, id: \.self) { destinationID in
              agentSlot(destinationID)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
          }
        }
      }
      .padding(9)
      .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(WorkspaceDesign.hairline)
      )
      .padding(.leading, compact ? 0 : 38)
    }
  }

  private func agentSlot(_ destinationID: String) -> some View {
    AIChatRoomAgentSlot(
      round: round,
      destinationID: destinationID,
      compact: compact,
      isActive: store.selectedAIChatActiveRoomRoundID == round.id
        && store.selectedAIChatActiveDestinationID == destinationID
    )
  }

  private var roundStatus: String {
    if round.isComplete { return "Complete" }
    return "\(round.completedCount) of \(round.expectedDestinationIDs.count) complete"
  }
}

private struct AIChatRoomAgentSlot: View {
  @EnvironmentObject private var store: WorkspaceStore
  let round: AIChatRoomRound
  let destinationID: String
  let compact: Bool
  let isActive: Bool

  private var runtime: AIChatRuntime { store.aiChatDestinationRuntime(destinationID) }
  private var destinationTitle: String { store.aiChatDestinationTitle(destinationID) }

  var body: some View {
    Group {
      if let response = round.response(forDestinationID: destinationID) {
        ChatBubbleView(
          message: response,
          runtime: runtime,
          destinationTitlesByID: store.aiChatDestinationTitlesByID,
          compact: true,
          isRoomResponse: true
        )
      } else if isActive {
        VStack(alignment: .leading, spacing: 6) {
          Label(destinationTitle, systemImage: runtime.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          OpenClawLiveTypingIndicatorView(
            liveState: store.openClawLiveState,
            threadID: store.selectedOpenClawChatThreadID,
            startedAt: store.openClawRequestStartedAt,
            runtime: runtime,
            compact: true,
            onStop: { Task { await store.stopOpenClawRun() } }
          )
        }
        .padding(9)
        .background(WorkspaceDesign.surfaceBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      } else {
        HStack(spacing: 8) {
          if showsProgress {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: statusImage)
              .foregroundStyle(.secondary)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(destinationTitle)
              .font(.caption.weight(.semibold))
            Text(statusText)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(9)
        .background(WorkspaceDesign.surfaceBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(WorkspaceDesign.hairline)
        )
      }
    }
  }

  private var deliveryStatus: OpenClawChatMessage.DeliveryStatus? {
    round.dispatch(forDestinationID: destinationID)?.deliveryStatus
  }

  private var showsProgress: Bool {
    deliveryStatus == .sending
  }

  private var statusImage: String {
    switch deliveryStatus {
    case .failed: "exclamationmark.triangle.fill"
    case .interrupted: "stop.circle"
    case .sent: "ellipsis"
    case .sending, nil: "clock"
    }
  }

  private var statusText: String {
    switch deliveryStatus {
    case .failed: "Could not respond"
    case .interrupted: "Stopped"
    case .sent: "Finishing response…"
    case .sending, nil: "Waiting to respond"
    }
  }
}

private struct OpenClawQueuedMessageActions: View {
  let compact: Bool
  let canSteer: Bool
  let steer: () -> Void
  let edit: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Text("Waiting behind the current turn")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      if canSteer {
        Button {
          steer()
        } label: {
          if compact {
            Image(systemName: "arrow.turn.up.right")
          } else {
            Label("Steer Now", systemImage: "arrow.turn.up.right")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .help("Send this queued message to the current turn now")
      }

      Button {
        edit()
      } label: {
        if compact {
          Image(systemName: "pencil")
        } else {
          Label("Edit", systemImage: "pencil")
        }
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .help("Remove this message from the queue and put it back in the composer")

      Button {
        remove()
      } label: {
        if compact {
          Image(systemName: "xmark")
        } else {
          Label("Remove", systemImage: "xmark")
        }
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .help("Remove this message before it is sent")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(WorkspaceDesign.hairline)
    )
  }
}

enum OpenClawMessageClipboard {
  nonisolated static func text(for message: OpenClawChatMessage) -> String {
    if !message.content.isEmpty {
      let content = OpenClawContextPresentation(
        message.content,
        extractsContexts: message.role == .user
      ).clipboardText
      return message.role == .assistant
        ? OpenClawMessageOrgNormalizer.normalized(content)
        : content
    }
    return message.attachments.map { "[Attachment: \($0.fileName)]" }.joined(separator: "\n")
  }

  @MainActor
  @discardableResult
  static func copy(
    _ message: OpenClawChatMessage,
    to pasteboard: NSPasteboard = .general
  ) -> Bool {
    write(text(for: message), to: pasteboard)
  }

  @MainActor
  @discardableResult
  static func write(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
    let item = NSPasteboardItem()
    guard item.setString(text, forType: .string) else { return false }
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }
}

private struct OpenClawContextPillsView: View {
  @EnvironmentObject private var store: WorkspaceStore
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
          OpenClawContextPill(
            context: store.resolvedOpenClawContext(context),
            remove: remove
          )
        }
      }
      .padding(.vertical, 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct OpenClawContextPill: View {
  @EnvironmentObject private var store: WorkspaceStore
  let context: OpenClawPresentedContext
  let remove: ((OpenClawPresentedContext) -> Void)?
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 3) {
      Button {
        store.openOpenClawContext(context)
      } label: {
        HStack(spacing: 5) {
          Image(systemName: context.systemImage)
            .font(.caption2.weight(.semibold))
            .accessibilityHidden(true)
          Text(context.title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: isHovering ? 320 : 152, alignment: .leading)
          if remove == nil, isHovering {
            Image(systemName: "arrow.up.right")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.secondary)
              .transition(.opacity.combined(with: .scale(scale: 0.82)))
          }
        }
        .padding(.leading, 8)
        .padding(.trailing, remove == nil || !isHovering ? 8 : 2)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open \(context.title)")
      .accessibilityLabel("Open context: \(context.title)")

      if let remove, isHovering {
        Button {
          remove(context)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .frame(width: 16, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.trailing, 4)
        .transition(.opacity.combined(with: .scale(scale: 0.82)))
        .help("Remove \(context.title) from context")
        .accessibilityLabel("Remove \(context.title) from context")
      }
    }
    .foregroundStyle(Color.accentColor)
    .background(Color.accentColor.opacity(0.09), in: Capsule())
    .overlay(Capsule().stroke(Color.accentColor.opacity(0.18)))
    .contentShape(Capsule())
    .onHover { hovering in
      withAnimation(WorkspaceMotion.quick) {
        isHovering = hovering
      }
    }
    .animation(WorkspaceMotion.quick, value: isHovering)
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
  let onPreview: (OpenClawChatAttachment) -> Void

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
        OpenClawAttachmentThumbnail(
          attachment: attachment,
          size: imageSize,
          onPreview: { onPreview(attachment) }
        )
      }
    }
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
    .padding(.top, 2)
  }
}

private struct OpenClawAttachmentThumbnail: View {
  let attachment: OpenClawChatAttachment
  let size: CGFloat
  let onPreview: () -> Void

  var body: some View {
    Button(action: onPreview) {
      VStack(alignment: .leading, spacing: 4) {
        Group {
          if let image = NSImage(data: attachment.data) {
            Image(nsImage: image)
              .resizable()
              .scaledToFill()
          } else {
            Image(systemName: OpenClawAttachmentPresentation.systemImage(for: attachment.mimeType))
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
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .help("Open \(attachment.fileName) · \(Self.byteCountText(attachment.byteCount))")
    .accessibilityLabel("Open attachment \(attachment.fileName)")
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
  @State private var selectedMentionSuggestionIndex = 0
  @State private var moveComposerCursorToEndRequest = 0
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
            Text(
              store.selectedAIChatIsSharedRoom
                ? "Add context, or @mention an agent…"
                : "Message \(store.selectedAIChatDestination.title)"
            )
              .font(.body)
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 10)
              .padding(.vertical, 9)
          }

          OpenClawComposerTextView(
            text: visibleDraftBinding,
            focusOnAppear: focusOnAppear,
            moveCursorToEndRequest: moveComposerCursorToEndRequest,
            onReturn: handleReturn,
            onSuggestionCommand: handleSuggestionCommand,
            onDropAttachment: handleDropAttachment
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
        gatewayCommands: store.activeAIChatGatewayCommands,
        corpusSkills: store.corpusAgentSkillCommands
      )
      let mentionSuggestions = mentionSuggestions(for: presentation.userText)
      if !mentionSuggestions.isEmpty {
        AIChatMentionSuggestionsView(
          suggestions: mentionSuggestions,
          selectedSuggestionID: selectedMentionSuggestion(in: mentionSuggestions)?.id,
          select: completeMention
        )
      } else if !slashSuggestions.isEmpty {
        OpenClawSlashCommandSuggestions(
          commands: slashSuggestions,
          selectedCommandID: selectedSlashSuggestion(in: slashSuggestions)?.id,
          select: completeSlashCommand
        )
      }

      if !store.openClawPendingAttachments.isEmpty {
        OpenClawPendingAttachmentsView(compact: compact)
      }

      if store.selectedAIChatIsSharedRoom {
        let routing = destinationRouting(for: presentation.userText)
        Label(
          routing.summary,
          systemImage: routing.destinationIDs.isEmpty ? "text.bubble" : "person.2.fill"
        )
          .font(.caption.weight(.medium))
          .foregroundStyle(routing.destinationIDs.isEmpty ? .secondary : Color.accentColor)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 2)
      } else {
        let routing = destinationRouting(for: presentation.userText)
        if routing.destinationIDs.contains(where: { $0 != store.selectedAIChatDestination.id }) {
          Label(
            "Forks into a shared room · \(routing.summary)",
            systemImage: "arrow.triangle.branch"
          )
          .font(.caption.weight(.medium))
          .foregroundStyle(Color.accentColor)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 2)
        }
      }

      HStack(spacing: 8) {
        if store.isSendingOpenClawMessage {
          Text(store.openClawQueuedMessageCount > 1 ? "\(store.openClawQueuedMessageCount - 1) queued" : "Sending")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        if store.isRecordingOpenClawVoiceNote {
          HStack(spacing: 6) {
            Image(systemName: "waveform")
              .foregroundStyle(.red)
            OpenClawVoiceInputMeterView(meterState: store.openClawVoiceMeterState)
              .frame(width: compact ? 72 : 110, height: 7)
          }
          .help("Recording \(store.selectedAIChatDisplayTitle) dictation")
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
        if store.selectedAIChatIsSharedRoom {
          ForEach(store.selectedAIChatRoomDestinationIDs, id: \.self) { destinationID in
            roomModelPicker(forDestinationID: destinationID)
          }
        } else {
          runtimePicker
          modelPicker
          reasoningPicker
        }

        Button {
          store.chooseOpenClawAttachments()
        } label: {
          Label("Attach File", systemImage: "paperclip")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(WorkspaceActionButtonStyle())
        .help("Attach file or image")

        Button {
          flushDraftToStore()
          if store.isRecordingOpenClawVoiceNote {
            Task {
              await store.stopOpenClawVoiceNoteRecording(action: .insertIntoComposer)
            }
          } else {
            Task { await store.startOpenClawVoiceNoteRecording() }
          }
        } label: {
          Label(
            store.isRecordingOpenClawVoiceNote ? "Stop Dictation" : "Dictate",
            systemImage: store.isRecordingOpenClawVoiceNote ? "stop.fill" : "mic.fill"
          )
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(!store.isRecordingOpenClawVoiceNote && !store.canStartOpenClawVoiceNoteRecording)
        .help(
          store.isRecordingOpenClawVoiceNote
            ? "Stop dictating and place the transcript in the composer without sending"
            : "Start local voice dictation"
        )

        Button {
          performPrimaryAction(delivery: .automatic)
        } label: {
          Label(
            primaryActionTitle,
            systemImage: primaryActionSystemImage
          )
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(!store.isRecordingOpenClawVoiceNote && !canSend)
        .help(primaryActionHelp)

        if isRunning
          && !store.selectedAIChatIsSharedRoom
          && !store.isRecordingOpenClawVoiceNote
        {
          Menu {
            Button {
              _ = sendIfPossible(delivery: .steer)
            } label: {
              Label("Steer Now", systemImage: "arrow.turn.up.right")
            }
            .disabled(!canSend)
          } label: {
            Label("More delivery options", systemImage: "chevron.down")
          }
          .labelStyle(.iconOnly)
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Steer the current turn now (⌘⇧Return)")
        }
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
      selectedMentionSuggestionIndex = 0
      cacheDraftLocally()
      if OpenClawContextPresentation(localDraft).userText == "/" {
        store.refreshCorpusAgentSkills()
        if store.selectedAIChatDestination.runtime == .openClaw {
          Task { await store.refreshOpenClawCommands() }
        }
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
    .task(id: store.openClawChatSelectionGeneration) {
      await store.refreshAIChatConfiguration()
    }
  }

  private var runtimePicker: some View {
    Menu {
      ForEach(store.enabledAIChatDestinations) { destination in
        Button {
          store.setSelectedAIChatDestination(destination.id)
        } label: {
          HStack {
            Label(destination.title, systemImage: destination.systemImage)
            if destination.id == store.selectedAIChatDestination.id {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: store.selectedAIChatDestination.systemImage)
        Text(store.selectedAIChatDestination.title)
        Image(
          systemName: store.canChangeSelectedAIChatRuntime
            ? "chevron.up.chevron.down"
            : "lock.fill"
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(!store.canChangeSelectedAIChatRuntime)
    .help(
      store.canChangeSelectedAIChatRuntime
        ? "Choose the AI destination for this new thread"
        : "The AI destination is locked after the conversation starts"
    )
  }

  private func roomModelPicker(forDestinationID destinationID: String) -> some View {
    let options = store.aiChatDestinationModelOptions[destinationID] ?? []
    let destination = store.aiChatDestination(id: destinationID)
    let runtime = store.aiChatDestinationRuntime(destinationID)
    return Menu {
      Button {
        store.setSelectedAIChatRoomModel(nil, forDestinationID: destinationID)
      } label: {
        HStack {
          Text("Default model")
          if store.selectedAIChatRoomModel(forDestinationID: destinationID) == nil {
            Image(systemName: "checkmark")
          }
        }
      }

      if !options.isEmpty {
        Divider()
        ForEach(options) { model in
          Button {
            store.setSelectedAIChatRoomModel(model.id, forDestinationID: destinationID)
          } label: {
            HStack {
              Text(model.label)
              if store.selectedAIChatRoomModel(forDestinationID: destinationID) == model.id {
                Image(systemName: "checkmark")
              }
            }
          }
          .help(model.detail ?? model.id)
        }
      } else if store.isRefreshingAIChatConfiguration {
        Text("Loading models…")
      } else {
        Text("No models reported")
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: runtime.systemImage)
        Text("\(destination?.title ?? destinationID) · \(store.selectedAIChatRoomModelLabel(forDestinationID: destinationID))")
          .lineLimit(1)
          .frame(maxWidth: compact ? 125 : 165)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(isRunning)
    .help("Choose the model for \(destination?.title ?? destinationID) in this shared room")
  }

  private var modelPicker: some View {
    Menu {
      Button {
        store.setSelectedAIChatModel(nil)
      } label: {
        HStack {
          Text("Default model")
          if store.selectedAIChatModel == nil {
            Image(systemName: "checkmark")
          }
        }
      }

      Divider()

      if store.isRefreshingAIChatConfiguration && store.aiChatModelOptions.isEmpty {
        Text("Loading models…")
      } else if store.aiChatModelOptions.isEmpty {
        Text("No models reported")
      } else {
        ForEach(store.aiChatModelOptions) { model in
          Button {
            store.setSelectedAIChatModel(model.id)
          } label: {
            HStack {
              Text(model.label)
              if model.id == store.selectedAIChatModel {
                Image(systemName: "checkmark")
              }
            }
          }
          .help(model.detail ?? model.id)
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "cpu")
        Text(store.selectedAIChatModelLabel)
          .lineLimit(1)
          .frame(maxWidth: compact ? 88 : 140)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(!store.canChangeSelectedAIChatConfiguration)
    .help("Choose a model for this chat, or inherit the \(store.selectedAIChatDestination.title) default")
  }

  private var reasoningPicker: some View {
    Menu {
      Button {
        store.setSelectedAIChatReasoningEffort(nil)
      } label: {
        HStack {
          Text(defaultReasoningLabel)
          if store.selectedAIChatReasoningEffort == nil {
            Image(systemName: "checkmark")
          }
        }
      }

      if !store.aiChatReasoningOptions.isEmpty {
        Divider()
        ForEach(store.aiChatReasoningOptions) { option in
          Button {
            store.setSelectedAIChatReasoningEffort(option.id)
          } label: {
            HStack {
              Text(option.label)
              if option.id == store.selectedAIChatReasoningEffort {
                Image(systemName: "checkmark")
              }
            }
          }
          .help(option.detail ?? option.id)
        }
      } else if store.isRefreshingAIChatConfiguration {
        Text("Loading reasoning options…")
      } else {
        Text("Choose a model to load supported levels")
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "brain")
        Text(store.selectedAIChatReasoningLabel)
          .lineLimit(1)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(!store.canChangeSelectedAIChatConfiguration)
    .help("Choose the reasoning effort for this chat")
  }

  private var defaultReasoningLabel: String {
    guard let effort = store.aiChatDefaultReasoningEffort else {
      return "Default reasoning"
    }
    let label = store.aiChatReasoningOptions.first(where: {
      $0.id == effort
    })?.label ?? effort.capitalized
    return "Default reasoning (\(label))"
  }

  private var canSend: Bool {
    !localDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !store.openClawPendingAttachments.isEmpty
  }

  private var isRunning: Bool {
    guard let threadID = store.selectedOpenClawChatThreadID else { return false }
    return store.isAIChatThreadRunning(threadID)
  }

  private var primaryActionTitle: String {
    if store.isRecordingOpenClawVoiceNote {
      return "Finish & Send"
    }
    if store.selectedAIChatIsSharedRoom,
       destinationRouting(for: OpenClawContextPresentation(localDraft).userText)
         .destinationIDs.isEmpty {
      return "Post"
    }
    if isRunning {
      return "Queue"
    }
    return "Send"
  }

  private var primaryActionSystemImage: String {
    if store.isRecordingOpenClawVoiceNote {
      return "arrow.up.circle.fill"
    }
    if store.selectedAIChatIsSharedRoom,
       destinationRouting(for: OpenClawContextPresentation(localDraft).userText)
         .destinationIDs.isEmpty {
      return "text.bubble.fill"
    }
    if isRunning {
      return "clock"
    }
    return "paperplane.fill"
  }

  private var primaryActionHelp: String {
    if store.isRecordingOpenClawVoiceNote {
      return "Finish dictating and send the transcript"
    }
    if isRunning {
      return "Queue behind the current turn. Press Command-Shift-Return to steer now."
    }
    return "Send message"
  }

  private var visibleDraftBinding: Binding<String> {
    Binding(
      get: { OpenClawContextPresentation(localDraft).userText },
      set: { nextText in
        localDraft = OpenClawContextPresentation(localDraft).replacingUserText(nextText)
      }
    )
  }

  private func sendIfPossible(
    delivery: AIChatMessageDeliveryPreference = .automatic
  ) -> Bool {
    guard canSend else { return false }
    let text = localDraft
    localDraft = ""
    lastStoreDraft = ""
    store.cacheOpenClawComposerDraft("")
    if delivery == .automatic {
      store.submitOpenClawComposerInput(text: text)
    } else {
      store.sendComposedOpenClawMessage(text: text, delivery: delivery)
    }
    return true
  }

  private func handleReturn(_ delivery: AIChatMessageDeliveryPreference) -> Bool {
    performPrimaryAction(delivery: delivery)
    return true
  }

  private func performPrimaryAction(
    delivery: AIChatMessageDeliveryPreference = .automatic
  ) {
    if store.isRecordingOpenClawVoiceNote {
      flushDraftToStore()
      Task {
        await store.stopOpenClawVoiceNoteRecording(action: .send)
      }
      return
    }
    _ = sendIfPossible(delivery: delivery)
  }

  private func handleSuggestionCommand(_ command: OpenClawComposerSuggestionKeyCommand) -> Bool {
    let visibleText = OpenClawContextPresentation(localDraft).userText
    let mentionSuggestions = mentionSuggestions(for: visibleText)
    if !mentionSuggestions.isEmpty {
      switch command {
      case .complete:
        guard let selected = selectedMentionSuggestion(in: mentionSuggestions) else { return false }
        completeMention(selected)
      case .move(let offset):
        selectedMentionSuggestionIndex = OpenClawSlashCommandSelection.movedIndex(
          selectedMentionSuggestionIndex,
          by: offset,
          count: mentionSuggestions.count
        )
      }
      return true
    }

    let suggestions = OpenClawSlashCommands.suggestions(
      for: visibleText,
      gatewayCommands: store.activeAIChatGatewayCommands,
      corpusSkills: store.corpusAgentSkillCommands
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
    moveComposerCursorToEndRequest &+= 1
  }

  private func selectedMentionSuggestion(
    in suggestions: [AIChatMentionSuggestion]
  ) -> AIChatMentionSuggestion? {
    guard !suggestions.isEmpty else { return nil }
    return suggestions[min(max(0, selectedMentionSuggestionIndex), suggestions.count - 1)]
  }

  private func completeMention(_ suggestion: AIChatMentionSuggestion) {
    let presentation = OpenClawContextPresentation(localDraft)
    localDraft = presentation.replacingUserText(
      suggestion.completingMention(in: presentation.userText)
    )
    moveComposerCursorToEndRequest &+= 1
  }

  private func destinationRouting(for text: String) -> AIChatDestinationRouting {
    AIChatDestinationRouting(
      text,
      destinations: store.enabledAIChatDestinations,
      allDestinationIDs: store.selectedAIChatIsSharedRoom
        ? store.selectedAIChatRoomDestinationIDs
        : store.enabledAIChatDestinations.map(\.id)
    )
  }

  private func mentionSuggestions(for text: String) -> [AIChatMentionSuggestion] {
    AIChatMentionSuggestion.suggestions(
      for: text,
      destinations: store.enabledAIChatDestinations,
      allDestinationIDs: store.selectedAIChatIsSharedRoom
        ? store.selectedAIChatRoomDestinationIDs
        : store.enabledAIChatDestinations.map(\.id)
    )
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

  private func handleDropAttachment(_ payload: OpenClawComposerDropPayload) -> Bool {
    switch payload {
    case .fileURLs(let urls):
      store.attachOpenClawFiles(urls: urls)
    case .image(let data, let fileName, let mimeType):
      store.attachOpenClawAttachment(data: data, fileName: fileName, mimeType: mimeType)
    }
    return true
  }
}

private struct OpenClawVoiceInputMeterView: View {
  @ObservedObject var meterState: WorkspaceInputMeterState

  var body: some View {
    WorkspaceInputMeterView(
      averageLevel: meterState.levels.averageLevel,
      peakLevel: meterState.levels.peakLevel
    )
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
            if let badge = badge(for: command) {
              Text(badge)
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

  private func badge(for command: OpenClawSlashCommand) -> String? {
    switch command.origin {
    case .openClaw: "OpenClaw"
    case .corpusSkill: "Skill"
    case .org2: command.isAgentAssisted ? "Agent" : nil
    }
  }
}

struct AIChatMentionSuggestion: Identifiable, Equatable {
  let id: String
  let title: String
  let detail: String
  let systemImage: String
  let insertion: String

  static let all: [AIChatMentionSuggestion] = suggestions(
    for: "@",
    destinations: AIChatDestinationConfiguration.defaults,
    allDestinationIDs: AIChatDestinationConfiguration.defaults.map(\.id)
  )

  static func suggestions(for text: String) -> [AIChatMentionSuggestion] {
    suggestions(
      for: text,
      destinations: AIChatDestinationConfiguration.defaults,
      allDestinationIDs: AIChatDestinationConfiguration.defaults.map(\.id)
    )
  }

  static func suggestions(
    for text: String,
    destinations: [AIChatDestinationConfiguration],
    allDestinationIDs: [String]
  ) -> [AIChatMentionSuggestion] {
    guard let activeRange = activeMentionRange(in: text) else { return [] }
    let query = String(text[activeRange]).dropFirst().lowercased()
    let enabled = destinations.filter(\.isEnabled)
    let destinationSuggestions = enabled.map { destination in
      AIChatMentionSuggestion(
        id: destination.mention,
        title: "@\(destination.mention)",
        detail: "Request a response from \(destination.name)",
        systemImage: destination.adapter.systemImage,
        insertion: "@\(destination.mention) "
      )
    }
    let destinationByID = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
    let allMentions = allDestinationIDs.compactMap { destinationByID[$0]?.mention }
    let allSuggestion = AIChatMentionSuggestion(
      id: "all",
      title: "@all",
      detail: "Request a response from every destination in this thread",
      systemImage: "person.2.fill",
      insertion: allMentions.map { "@\($0)" }.joined(separator: " ") + " "
    )
    return (destinationSuggestions + [allSuggestion]).filter { suggestion in
      suggestion.id.hasPrefix(query)
        || suggestion.title.dropFirst().lowercased().hasPrefix(query)
    }
  }

  func completingMention(in text: String) -> String {
    guard let range = Self.activeMentionRange(in: text) else { return text }
    return text.replacingCharacters(in: range, with: insertion)
  }

  private static func activeMentionRange(in text: String) -> Range<String.Index>? {
    guard let atIndex = text.lastIndex(of: "@") else { return nil }
    if atIndex != text.startIndex {
      let previous = text[text.index(before: atIndex)]
      guard previous.isWhitespace else { return nil }
    }
    let suffix = text[atIndex...]
    guard suffix.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
      return nil
    }
    return atIndex..<text.endIndex
  }
}

private struct AIChatMentionSuggestionsView: View {
  let suggestions: [AIChatMentionSuggestion]
  let selectedSuggestionID: AIChatMentionSuggestion.ID?
  let select: (AIChatMentionSuggestion) -> Void

  var body: some View {
    VStack(spacing: 2) {
      ForEach(suggestions) { suggestion in
        Button {
          select(suggestion)
        } label: {
          HStack(spacing: 9) {
            Image(systemName: suggestion.systemImage)
              .frame(width: 18)
              .foregroundStyle(.secondary)
            Text(suggestion.title)
              .font(.callout.monospaced().weight(.medium))
            Text(suggestion.detail)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer(minLength: 4)
          }
          .contentShape(Rectangle())
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
          .background(
            suggestion.id == selectedSuggestionID ? Color.accentColor.opacity(0.12) : Color.clear,
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
        Image(systemName: OpenClawAttachmentPresentation.systemImage(for: attachment.mimeType))
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

  static func isSteerCommand(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
    return isReturnKey(keyCode) && relevantModifiers == [.command, .shift]
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
    case 36, 48, 76:
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

enum OpenClawComposerDropPayload: Equatable {
  case fileURLs([URL])
  case image(data: Data, fileName: String, mimeType: String)
}

enum OpenClawComposerDrop {
  static func payload(from pasteboard: NSPasteboard) -> OpenClawComposerDropPayload? {
    let urls = (pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) ?? []).compactMap { item -> URL? in
      guard let url = item as? NSURL else { return nil }
      return url as URL
    }
    if !urls.isEmpty {
      return .fileURLs(urls)
    }

    if let data = pasteboard.data(forType: .png) {
      return .image(data: data, fileName: "Dropped Image.png", mimeType: "image/png")
    }
    if let data = pasteboard.data(forType: .tiff) {
      return .image(data: data, fileName: "Dropped Image.tiff", mimeType: "image/tiff")
    }
    return nil
  }
}

enum OpenClawAttachmentPresentation {
  static func systemImage(for mimeType: String) -> String {
    if mimeType.hasPrefix("image/") { return "photo" }
    if mimeType.hasPrefix("audio/") { return "waveform" }
    if mimeType == "application/pdf" { return "doc.richtext" }
    if mimeType.hasPrefix("text/") { return "doc.text" }
    return "doc"
  }
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
  let moveCursorToEndRequest: Int
  let onReturn: (AIChatMessageDeliveryPreference) -> Bool
  let onSuggestionCommand: (OpenClawComposerSuggestionKeyCommand) -> Bool
  let onDropAttachment: (OpenClawComposerDropPayload) -> Bool

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
      context.coordinator.parent.onReturn($0)
    }
    textView.onSuggestionCommand = {
      context.coordinator.parent.onSuggestionCommand($0)
    }
    textView.onDropAttachment = {
      context.coordinator.parent.onDropAttachment($0)
    }
    textView.registerForDraggedTypes([.fileURL, .png, .tiff])
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
    context.coordinator.lastMoveCursorToEndRequest = moveCursorToEndRequest

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
      context.coordinator.parent.onReturn($0)
    }
    textView.onSuggestionCommand = {
      context.coordinator.parent.onSuggestionCommand($0)
    }
    textView.onDropAttachment = {
      context.coordinator.parent.onDropAttachment($0)
    }
    let movesCursorToEnd = context.coordinator.lastMoveCursorToEndRequest != moveCursorToEndRequest
    let selectedRange = textView.selectedRange()
    let textChanged = textView.string != text
    if textChanged {
      textView.string = text
    }
    if textChanged || movesCursorToEnd {
      let nextRange = OpenClawComposerSelection.updatedRange(
        previous: selectedRange,
        textLength: (text as NSString).length,
        movesToEnd: movesCursorToEnd
      )
      if textView.selectedRange() != nextRange {
        textView.setSelectedRange(nextRange)
        textView.scrollRangeToVisible(nextRange)
      }
    }
    context.coordinator.lastMoveCursorToEndRequest = moveCursorToEndRequest
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: OpenClawComposerTextView
    var lastMoveCursorToEndRequest = 0

    init(parent: OpenClawComposerTextView) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
    }
  }

  final class CommandSubmitTextView: NSTextView {
    var onReturn: ((AIChatMessageDeliveryPreference) -> Bool)?
    var onSuggestionCommand: ((OpenClawComposerSuggestionKeyCommand) -> Bool)?
    var onDropAttachment: ((OpenClawComposerDropPayload) -> Bool)?
    private var pendingLatencyTokens: [WorkspaceInteractionLatency.Token] = []

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      let tokens = pendingLatencyTokens
      pendingLatencyTokens.removeAll(keepingCapacity: true)
      for token in tokens {
        WorkspaceInteractionLatency.finish(token)
      }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
      if OpenClawComposerDrop.payload(from: sender.draggingPasteboard) != nil {
        return .copy
      }
      return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
      if let payload = OpenClawComposerDrop.payload(from: sender.draggingPasteboard),
         onDropAttachment?(payload) == true {
        return true
      }
      return super.performDragOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
      let latencyToken = WorkspaceInteractionLatency.begin(.composerKeyToDraw)
      defer {
        pendingLatencyTokens.append(latencyToken)
        needsDisplay = true
      }
      if let command = OpenClawComposerKeyCommand.suggestionCommand(
        keyCode: event.keyCode,
        modifiers: event.modifierFlags
      ), onSuggestionCommand?(command) == true {
        return
      }
      if OpenClawComposerKeyCommand.isSteerCommand(keyCode: event.keyCode, modifiers: event.modifierFlags),
         onReturn?(.steer) == true {
        return
      }
      if OpenClawComposerKeyCommand.isSendCommand(keyCode: event.keyCode, modifiers: event.modifierFlags),
         onReturn?(.automatic) == true {
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

enum OpenClawComposerSelection {
  static func updatedRange(
    previous: NSRange,
    textLength: Int,
    movesToEnd: Bool
  ) -> NSRange {
    guard !movesToEnd else {
      return NSRange(location: textLength, length: 0)
    }
    let location = min(previous.location, textLength)
    return NSRange(
      location: location,
      length: min(previous.length, textLength - location)
    )
  }
}

/// Observes only the high-frequency live-turn model, so token streaming does
/// not rebuild the transcript, composer, sidebar, or unrelated workspace UI.
struct OpenClawLiveTypingIndicatorView: View {
  @ObservedObject var liveState: OpenClawChatLiveState
  let threadID: UUID?
  let startedAt: Date?
  let runtime: AIChatRuntime
  let compact: Bool
  let onStop: () -> Void

  var body: some View {
    OpenClawTypingIndicatorView(
      startedAt: startedAt,
      lastEventAt: threadID.flatMap(liveState.lastEventAt(for:)),
      runtime: runtime,
      connectionState: threadID.map(liveState.connectionState(for:)) ?? .disconnected,
      connectionDetail: threadID.flatMap(liveState.connectionDetail(for:)),
      runID: threadID.flatMap(liveState.activeRunID(for:)),
      streamingReply: threadID.map(liveState.streamingReply(for:)) ?? "",
      reasoning: threadID.map(liveState.reasoning(for:)) ?? "",
      activities: threadID.map(liveState.runActivities(for:)) ?? [],
      compact: compact,
      onStop: onStop
    )
  }
}

struct OpenClawTypingIndicatorView: View {
  static let quietRunInterval: TimeInterval = 2 * 60
  static let stalledRunInterval: TimeInterval = 10 * 60

  let startedAt: Date?
  let lastEventAt: Date?
  let runtime: AIChatRuntime
  let connectionState: OpenClawGatewayConnectionState
  let connectionDetail: String?
  let runID: String?
  let streamingReply: String
  let reasoning: String
  let activities: [OpenClawRunActivity]
  let compact: Bool
  let onStop: () -> Void

  @State private var showsAllStreamingProgress = false
  @State private var statusEvaluationDate = Date()

  init(
    startedAt: Date?,
    lastEventAt: Date? = nil,
    runtime: AIChatRuntime = .openClaw,
    connectionState: OpenClawGatewayConnectionState,
    connectionDetail: String?,
    runID: String?,
    streamingReply: String,
    reasoning: String,
    activities: [OpenClawRunActivity],
    compact: Bool,
    onStop: @escaping () -> Void
  ) {
    self.startedAt = startedAt
    self.lastEventAt = lastEventAt
    self.runtime = runtime
    self.connectionState = connectionState
    self.connectionDetail = connectionDetail
    self.runID = runID
    self.streamingReply = streamingReply
    self.reasoning = reasoning
    self.activities = activities
    self.compact = compact
    self.onStop = onStop
  }

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 9) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            OpenClawShimmeringStatusText(
              titleProvider: { statusTitle(now: $0) },
              animates: statusAnimates(now: statusEvaluationDate)
            )
            .fixedSize(horizontal: true, vertical: false)
            AppKitPeriodicLabel(
              font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
              color: .tertiaryLabelColor,
              textProvider: { elapsedText(now: $0) }
            )
            .frame(minWidth: 36, idealWidth: 48, maxWidth: 58, minHeight: 14, alignment: .leading)
            if canStop {
              Button(action: onStop) {
                Image(systemName: "stop.fill")
                  .font(.system(size: 7, weight: .bold))
                  .frame(width: 22, height: 22)
                  .background(Color.secondary.opacity(0.11), in: Circle())
                  .contentShape(Circle())
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Stop \(runtime.title) run")
              .help("Stop this \(runtime.title) run")
            }
          }
          .frame(minHeight: 20)

          if let statusDetail = statusDetail(now: statusEvaluationDate) {
            Text(statusDetail)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .help(connectionHelp(now: statusEvaluationDate))

        if let liveText = OpenClawProgressPresentation.liveText(
          from: streamingReply,
          showsAll: showsAllStreamingProgress
        ) {
          OpenClawMessageBodyView(
            rawText: liveText,
            compact: compact,
            managesTextSelection: true,
            rendersStructuredOrg2: true
          )

          if OpenClawProgressPresentation.hasEarlierLiveText(streamingReply) {
            Button {
              withAnimation(WorkspaceMotion.disclosure) {
                showsAllStreamingProgress.toggle()
              }
            } label: {
              Label(
                showsAllStreamingProgress ? "Show latest update" : "Show all progress",
                systemImage: showsAllStreamingProgress ? "chevron.up" : "chevron.down"
              )
            }
            .buttonStyle(.plain)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
          }
        }

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
      .frame(maxWidth: compact ? 430 : 700, alignment: .leading)
      Spacer(minLength: compact ? 24 : 48)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: nextStatusTransition) {
      guard let nextStatusTransition else { return }
      let delay = max(0, nextStatusTransition.timeIntervalSinceNow)
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      statusEvaluationDate = Date()
    }
  }

  private var nextStatusTransition: Date? {
    guard connectionState == .connected,
          runID != nil,
          let reference = lastEventAt ?? startedAt else { return nil }
    let now = Date()
    return [Self.quietRunInterval, Self.stalledRunInterval]
      .map { reference.addingTimeInterval($0) }
      .first(where: { $0 > now })
  }

  var statusTitle: String {
    statusTitle(now: Date())
  }

  func statusTitle(now: Date) -> String {
    if connectionState == .connected, runID != nil {
      if runLivenessAge(now: now) >= Self.stalledRunInterval {
        return "\(runtime.title) may be stalled"
      }
      if runLivenessAge(now: now) >= Self.quietRunInterval {
        return "Waiting for \(runtime.title)"
      }
    }
    if runtime == .codex {
      switch connectionState {
      case .connecting:
        return "Connecting to Codex"
      case .reconnecting:
        return "Reconnecting to Codex"
      case .fallbackHTTP:
        return "Codex is working"
      case .disconnected:
        return "Codex connection interrupted"
      case .connected:
        if let latest = OpenClawActivityFeed.items(from: activities)
          .last(where: { $0.status == .running }) {
          return "Running \(latest.title.lowercased())"
        }
        if runID == nil {
          return "Starting Codex"
        }
        if !trimmedReasoning.isEmpty {
          return "Codex is thinking"
        }
        return "Codex is working"
      }
    }
    switch connectionState {
    case .connecting:
      return "Connecting to OpenClaw"
    case .reconnecting:
      return "Reconnecting to OpenClaw"
    case .fallbackHTTP:
      return "OpenClaw is working over HTTP"
    case .disconnected:
      return "Connection interrupted"
    case .connected:
      if let latest = OpenClawActivityFeed.items(from: activities)
        .last(where: { $0.status == .running }) {
        return "Running \(latest.title.lowercased())"
      }
      if runID == nil {
        return "Starting OpenClaw"
      }
      if !trimmedReasoning.isEmpty {
        return "OpenClaw is thinking"
      }
      return "OpenClaw is working"
    }
  }

  var canStop: Bool {
    // This view is only rendered for a locally active send. Connecting,
    // reconnecting, and disconnected recovered turns need Stop most: their
    // durable pending turn otherwise has no way to leave the recovery loop.
    true
  }

  private var trimmedReasoning: String {
    reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var hasProgress: Bool {
    !OpenClawActivityFeed.items(from: activities).isEmpty || !trimmedReasoning.isEmpty
  }

  func statusDetail(now: Date) -> String? {
    switch connectionState {
    case .reconnecting:
      return normalizedConnectionDetail
        ?? "The run is saved and will reconnect without being sent twice."
    case .disconnected:
      return normalizedConnectionDetail
        ?? "The connection was interrupted; the run may still be working remotely."
    case .connected where runID != nil:
      let age = runLivenessAge(now: now)
      if age >= Self.stalledRunInterval {
        return "No new activity for \(durationText(age)). The run is saved; the connection or agent may be stalled."
      }
      if age >= Self.quietRunInterval {
        return "No new activity for \(durationText(age)). It may still be working."
      }
      return nil
    case .connecting, .connected, .fallbackHTTP:
      return nil
    }
  }

  private func statusAnimates(now: Date) -> Bool {
    guard connectionState != .disconnected else { return false }
    return connectionState != .connected
      || runID == nil
      || runLivenessAge(now: now) < Self.stalledRunInterval
  }

  private var normalizedConnectionDetail: String? {
    let detail = connectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return detail.isEmpty ? nil : detail
  }

  private func runLivenessAge(now: Date) -> TimeInterval {
    guard let reference = lastEventAt ?? startedAt else { return 0 }
    return max(0, now.timeIntervalSince(reference))
  }

  private func connectionHelp(now: Date) -> String {
    var parts: [String] = []
    if let normalizedConnectionDetail { parts.append(normalizedConnectionDetail) }
    if lastEventAt != nil || startedAt != nil {
      parts.append("Last update \(durationText(runLivenessAge(now: now))) ago")
    }
    if let runID { parts.append("Run \(runID)") }
    return parts.isEmpty ? connectionState.label : parts.joined(separator: "\n")
  }

  private func durationText(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 60 * 60 { return "\(seconds / 60)m" }
    let hours = seconds / (60 * 60)
    let minutes = (seconds % (60 * 60)) / 60
    return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
  }

  private func elapsedText(now: Date) -> String {
    guard let startedAt else { return "0s" }
    let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
    if seconds < 60 { return "\(seconds)s" }
    return "\(seconds / 60)m \(seconds % 60)s"
  }
}

private struct OpenClawShimmeringStatusText: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let titleProvider: (Date) -> String
  let animates: Bool

  init(
    titleProvider: @escaping (Date) -> String,
    animates: Bool = true
  ) {
    self.titleProvider = titleProvider
    self.animates = animates
  }

  var body: some View {
    HStack(spacing: 5) {
      if animates {
        CoreAnimationActivityDot(
          animates: !reduceMotion,
          colorStyle: .secondary
        )
        .frame(width: 5, height: 5)
      }

      AppKitPeriodicLabel(
        font: .systemFont(ofSize: 11, weight: .medium),
        color: .secondaryLabelColor,
        textProvider: titleProvider
      )
      .frame(minWidth: 96, idealWidth: 140, maxWidth: 180, minHeight: 14, alignment: .leading)
    }
  }
}

private struct OpenClawProgressFeedView: View {
  let reasoning: String
  let activities: [OpenClawRunActivity]
  let compact: Bool
  let isLive: Bool
  let presentedItems: [OpenClawActivityFeedItem]?

  @State private var showsFullFeed = false

  init(
    reasoning: String,
    activities: [OpenClawRunActivity],
    compact: Bool,
    isLive: Bool,
    presentedItems: [OpenClawActivityFeedItem]? = nil
  ) {
    self.reasoning = reasoning
    self.activities = activities
    self.compact = compact
    self.isLive = isLive
    self.presentedItems = presentedItems
  }

  private var items: [OpenClawActivityFeedItem] {
    presentedItems ?? OpenClawActivityFeed.items(from: activities)
  }

  private var presentedReasoning: String? {
    OpenClawProgressPresentation.reasoningText(from: reasoning)
  }

  private var collapsedItemLimit: Int { compact ? 2 : 3 }

  private var visibleItems: [OpenClawActivityFeedItem] {
    OpenClawProgressFeedPresentation.visibleItems(
      items,
      isLive: isLive,
      isExpanded: showsFullFeed,
      collapsedItemLimit: collapsedItemLimit
    )
  }

  private var showsReasoning: Bool {
    OpenClawProgressFeedPresentation.showsReasoning(
      isLive: isLive,
      isExpanded: showsFullFeed
    )
  }

  private var canExpand: Bool {
    OpenClawProgressFeedPresentation.canExpand(
      itemCount: items.count,
      reasoningLength: presentedReasoning?.count ?? 0,
      isLive: isLive,
      collapsedItemLimit: collapsedItemLimit
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      if !isLive {
        HStack(spacing: 7) {
          Label("How it worked", systemImage: "clock.arrow.circlepath")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          if canExpand {
            expansionButton
          }
        }
      }

      if isLive, showsFullFeed, canExpand {
        expansionButton
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if showsReasoning, let presentedReasoning {
        HStack(alignment: .top, spacing: 7) {
          Image(systemName: "sparkles")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.purple)
            .frame(width: 14)
          VStack(alignment: .leading, spacing: 2) {
            Text("Approach")
              .font(.caption.weight(.medium))
            Text(presentedReasoning)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(showsFullFeed ? 8 : 2)
              .truncationMode(.tail)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if !visibleItems.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(visibleItems) { item in
            OpenClawActivityFeedRow(
              item: item,
              isExpanded: showsFullFeed,
              isLive: isLive
            )
          }
        }
      }

      if isLive, !showsFullFeed, canExpand {
        expansionButton
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if !isLive, !showsFullFeed, items.count > collapsedItemLimit {
        Button {
          withAnimation(WorkspaceMotion.disclosure) {
            showsFullFeed = true
          }
        } label: {
          Text("Show \(items.count - collapsedItemLimit) earlier update\(items.count - collapsedItemLimit == 1 ? "" : "s")")
        }
        .buttonStyle(.plain)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tertiary)
        .help("Show the complete activity feed")
      }
    }
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
    .clipped()
  }

  private var expansionButton: some View {
    Button {
      withAnimation(WorkspaceMotion.disclosure) {
        showsFullFeed.toggle()
      }
    } label: {
      Label(
        OpenClawProgressFeedPresentation.disclosureTitle(
          isLive: isLive,
          isExpanded: showsFullFeed
        ),
        systemImage: showsFullFeed ? "chevron.down" : "chevron.right"
      )
    }
    .labelStyle(.titleAndIcon)
    .buttonStyle(.plain)
    .font(.caption2.weight(.medium))
    .foregroundStyle(.secondary)
  }
}

enum OpenClawProgressFeedPresentation {
  static func visibleItems(
    _ items: [OpenClawActivityFeedItem],
    isLive: Bool,
    isExpanded: Bool,
    collapsedItemLimit: Int
  ) -> [OpenClawActivityFeedItem] {
    if isLive {
      guard !isExpanded else { return items }
      return items.last(where: { $0.status == .running }).map { [$0] }
        ?? items.last.map { [$0] }
        ?? []
    }
    return isExpanded ? items : Array(items.suffix(collapsedItemLimit))
  }

  static func showsReasoning(isLive: Bool, isExpanded: Bool) -> Bool {
    !isLive || isExpanded
  }

  static func canExpand(
    itemCount: Int,
    reasoningLength: Int,
    isLive: Bool,
    collapsedItemLimit: Int
  ) -> Bool {
    if isLive {
      return itemCount > 0 || reasoningLength > 0
    }
    return itemCount > collapsedItemLimit || reasoningLength > 240
  }

  static func disclosureTitle(isLive: Bool, isExpanded: Bool) -> String {
    if isLive {
      return isExpanded ? "Hide activity" : "Show activity"
    }
    return isExpanded ? "Show less" : "Show full feed"
  }
}

private struct OpenClawActivityFeedRow: View {
  let item: OpenClawActivityFeedItem
  let isExpanded: Bool
  let isLive: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      activityIcon
      VStack(alignment: .leading, spacing: 2) {
        if isActive {
          HStack(spacing: 5) {
            Text(item.title)
              .font(.caption.weight(.medium))
            AppKitPeriodicLabel(
              font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
              color: .tertiaryLabelColor,
              textProvider: { "\u{00b7} \(freshnessText(now: $0))" }
            )
            .frame(minWidth: 48, idealWidth: 92, maxWidth: 112, minHeight: 14, alignment: .leading)
          }
        } else {
          Text(item.title)
            .font(.caption.weight(.medium))
        }
        if let detail = item.detail, !detail.isEmpty {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(isExpanded ? 3 : 1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if isActive, let latestDetail = item.latestDetail, !latestDetail.isEmpty {
          Text(latestDetail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(isExpanded ? 3 : 2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(WorkspaceMotion.quick, value: item)
  }

  @ViewBuilder
  private var activityIcon: some View {
    if isActive {
      WorkspaceActivityIndicator(size: .mini, tint: .secondary)
        .frame(width: 14, height: 14)
        .help("This operation is still running")
    } else {
      Image(systemName: icon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 14)
    }
  }

  private var isActive: Bool {
    isLive && item.status == .running
  }

  private func freshnessText(now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(item.updatedAt)))
    if seconds < 5 { return "live" }
    if seconds < 60 { return "updated \(seconds)s ago" }
    if seconds < 60 * 60 { return "updated \(seconds / 60)m ago" }
    let hours = seconds / (60 * 60)
    return "updated \(hours)h ago"
  }

  private var icon: String {
    if item.kind == .reasoning { return "sparkles" }
    switch item.status {
    case .running: return "wrench.and.screwdriver"
    case .succeeded: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    }
  }
}

enum OpenClawProgressPresentation {
  private static let maximumReasoningLength = 1_200
  private static let maximumCollapsedLiveLength = 320

  static func liveText(from raw: String, showsAll: Bool) -> String? {
    let readable = normalizedReadableText(raw)
    guard !readable.isEmpty else { return nil }
    guard !showsAll else { return readable }

    let paragraphs = readable.components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let latest = paragraphs.last ?? readable
    guard latest.count > maximumCollapsedLiveLength else { return latest }
    return String(latest.prefix(maximumCollapsedLiveLength - 1))
      .trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
  }

  static func hasEarlierLiveText(_ raw: String) -> Bool {
    guard let collapsed = liveText(from: raw, showsAll: false),
          let expanded = liveText(from: raw, showsAll: true)
    else { return false }
    return collapsed != expanded
  }

  static func reasoningText(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let data = trimmed.data(using: .utf8),
       (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
      return nil
    }

    let looksLikeEncodedPayload = trimmed.contains("\\\"content\\\"")
      || trimmed.contains("\\\"results\\\"")
      || trimmed.hasPrefix("{\\n")
      || trimmed.hasPrefix("[\\n")
    guard !looksLikeEncodedPayload else { return nil }

    let readable = normalizedReadableText(trimmed)
    guard readable.count > maximumReasoningLength else { return readable }
    return String(readable.prefix(maximumReasoningLength - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
  }

  private static func normalizedReadableText(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\n[ \\t]*\\n(?:[ \\t]*\\n)+", with: "\n\n", options: .regularExpression)
  }
}
