import AppKit
import CryptoKit
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
      case .paragraph:
        // Image-only and prose-plus-image replies still need the media renderer.
        // Treating all paragraphs as plain inline text silently drops previews.
        return OrgMediaAttachment.standalone(raw: block.rawText) != nil
          || OrgMediaAttachment.embedded(in: block.rawText) != nil
      case .blank:
        return false
      case .heading, .planning, .properties, .quote, .source, .table,
           .horizontalRule, .listItem, .keyword:
        return true
      }
    }
  }
}

struct OpenClawMessageBodyExcerpt: Equatable, Sendable {
  static let collapsedUTF8ByteLimit = 32 * 1_024

  let text: String
  let isTruncated: Bool

  nonisolated init(_ rawText: String, utf8ByteLimit: Int?) {
    guard let utf8ByteLimit else {
      text = rawText
      isTruncated = false
      return
    }

    let resolvedLimit = max(0, utf8ByteLimit)
    var end = rawText.startIndex
    var byteCount = 0
    var truncated = false
    for character in rawText {
      let characterByteCount = String(character).utf8.count
      if byteCount + characterByteCount > resolvedLimit {
        truncated = true
        break
      }
      byteCount += characterByteCount
      end = rawText.index(after: end)
    }
    text = truncated ? String(rawText[..<end]) : rawText
    isTruncated = truncated
  }

  nonisolated static func displayedUTF8ByteCount(for rawText: String) -> Int {
    rawText.utf8.prefix(collapsedUTF8ByteLimit).count
  }
}

struct OpenClawPreparedMessageBody: Equatable, Sendable {
  let sourceText: String
  let displayedText: String
  let isTruncated: Bool
  let org: OpenClawMessageOrgPresentation?
  let containsInlineSyntax: Bool
}

struct OpenClawMessagePresentationInput: Equatable, Sendable {
  let messageID: UUID
  let role: OpenClawChatMessage.Role
  let rawText: String
  let responseTrace: OpenClawResponseTrace?

  nonisolated init(_ message: OpenClawChatMessage) {
    messageID = message.id
    role = message.role
    rawText = message.content
    responseTrace = message.responseTrace
  }
}

struct OpenClawMessagePresentationRevision: Equatable, Hashable, Sendable {
  private struct Payload: Encodable {
    let role: OpenClawChatMessage.Role
    let rawText: String
    let responseTrace: OpenClawResponseTrace?
  }

  let bytes: [UInt8]

  nonisolated init(_ input: OpenClawMessagePresentationInput) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = Payload(
      role: input.role,
      rawText: input.rawText,
      responseTrace: input.responseTrace
    )
    let data = (try? encoder.encode(payload)) ?? Data(input.rawText.utf8)
    bytes = Array(SHA256.hash(data: data))
  }
}

final class OpenClawCachedMessagePresentation: Sendable {
  let revision: OpenClawMessagePresentationRevision?
  let role: OpenClawChatMessage.Role
  let rawText: String
  let responseTrace: OpenClawResponseTrace?
  let context: OpenClawContextPresentation
  let body: OpenClawPreparedMessageBody
  let activityFeedItems: [OpenClawActivityFeedItem]

  init(
    revision: OpenClawMessagePresentationRevision? = nil,
    role: OpenClawChatMessage.Role,
    rawText: String,
    responseTrace: OpenClawResponseTrace?,
    context: OpenClawContextPresentation,
    body: OpenClawPreparedMessageBody,
    activityFeedItems: [OpenClawActivityFeedItem]
  ) {
    self.revision = revision
    self.role = role
    self.rawText = rawText
    self.responseTrace = responseTrace
    self.context = context
    self.body = body
    self.activityFeedItems = activityFeedItems
  }

  var org: OpenClawMessageOrgPresentation? { body.org }

  nonisolated func matches(_ input: OpenClawMessagePresentationInput) -> Bool {
    guard let revision else { return false }
    return revision == OpenClawMessagePresentationRevision(input)
  }

  func matches(_ message: OpenClawChatMessage) -> Bool {
    matches(OpenClawMessagePresentationInput(message))
  }
}

struct OpenClawPreparedMessagePresentation: Sendable {
  let messageID: UUID
  let value: OpenClawCachedMessagePresentation
  let estimatedCost: Int
}

struct OpenClawResolvedMessagePresentation: Sendable {
  let revision: OpenClawMessagePresentationRevision
  let value: OpenClawCachedMessagePresentation
  let preparedForCacheInstall: OpenClawPreparedMessagePresentation?
}

struct OpenClawExpandedMessageBodyInput: Equatable, Sendable {
  static let pageCharacterLimit = 64 * 1_024

  let messageID: UUID
  let role: OpenClawChatMessage.Role
  let sourceText: String
  let pageIndex: Int

  init(
    messageID: UUID,
    role: OpenClawChatMessage.Role,
    sourceText: String,
    pageIndex: Int = 0
  ) {
    self.messageID = messageID
    self.role = role
    self.sourceText = sourceText
    self.pageIndex = max(0, pageIndex)
  }
}

enum OpenClawMessagePresentationBuilder {
  private static let placeholderUTF8ByteLimit = 2 * 1_024

  nonisolated static func prepare(
    _ input: OpenClawMessagePresentationInput,
    revision suppliedRevision: OpenClawMessagePresentationRevision? = nil
  ) -> OpenClawPreparedMessagePresentation {
    let revision = suppliedRevision ?? OpenClawMessagePresentationRevision(input)
    let context = OpenClawContextPresentation(
      input.rawText,
      extractsContexts: input.role == .user
    )
    let body = prepareBody(
      sourceText: context.userText,
      role: input.role,
      utf8ByteLimit: OpenClawMessageBodyExcerpt.collapsedUTF8ByteLimit
    )
    let activityFeedItems = input.responseTrace.map {
      OpenClawActivityFeed.items(from: $0.activities)
    } ?? []
    let value = OpenClawCachedMessagePresentation(
      revision: revision,
      role: input.role,
      rawText: input.rawText,
      responseTrace: input.responseTrace,
      context: context,
      body: body,
      activityFeedItems: activityFeedItems
    )
    return OpenClawPreparedMessagePresentation(
      messageID: input.messageID,
      value: value,
      estimatedCost: estimatedCost(
        input: input,
        context: context,
        body: body,
        activityFeedItems: activityFeedItems
      )
    )
  }

  nonisolated static func prepareExpandedBody(
    sourceText: String,
    role: OpenClawChatMessage.Role,
    pageIndex: Int? = nil
  ) -> OpenClawPreparedMessageBody? {
    guard !Task.isCancelled else { return nil }
    let body: OpenClawPreparedMessageBody
    if let pageIndex {
      let startOffset = max(0, pageIndex) * OpenClawExpandedMessageBodyInput.pageCharacterLimit
      let start = sourceText.index(
        sourceText.startIndex,
        offsetBy: startOffset,
        limitedBy: sourceText.endIndex
      ) ?? sourceText.endIndex
      let end = sourceText.index(
        start,
        offsetBy: OpenClawExpandedMessageBodyInput.pageCharacterLimit,
        limitedBy: sourceText.endIndex
      ) ?? sourceText.endIndex
      let preparedPage = prepareBody(
        sourceText: String(sourceText[start..<end]),
        role: role,
        utf8ByteLimit: nil
      )
      body = OpenClawPreparedMessageBody(
        sourceText: sourceText,
        displayedText: preparedPage.displayedText,
        isTruncated: end < sourceText.endIndex,
        org: preparedPage.org,
        containsInlineSyntax: preparedPage.containsInlineSyntax
      )
    } else {
      body = prepareBody(sourceText: sourceText, role: role, utf8ByteLimit: nil)
    }
    guard !Task.isCancelled else { return nil }
    return body
  }

  nonisolated static func placeholder(
    _ input: OpenClawMessagePresentationInput
  ) -> OpenClawCachedMessagePresentation {
    if input.role == .user {
      return OpenClawCachedMessagePresentation(
        role: input.role,
        rawText: input.rawText,
        responseTrace: input.responseTrace,
        context: OpenClawContextPresentation("", extractsContexts: false),
        body: OpenClawPreparedMessageBody(
          sourceText: "",
          displayedText: "Preparing message…",
          isTruncated: false,
          org: nil,
          containsInlineSyntax: false
        ),
        activityFeedItems: []
      )
    }
    let excerpt = OpenClawMessageBodyExcerpt(
      input.rawText,
      utf8ByteLimit: placeholderUTF8ByteLimit
    )
    let exceedsCollapsedLimit = input.rawText.utf8
      .prefix(OpenClawMessageBodyExcerpt.collapsedUTF8ByteLimit + 1)
      .count > OpenClawMessageBodyExcerpt.collapsedUTF8ByteLimit
    return OpenClawCachedMessagePresentation(
      role: input.role,
      rawText: input.rawText,
      responseTrace: input.responseTrace,
      context: OpenClawContextPresentation(input.rawText, extractsContexts: false),
      body: OpenClawPreparedMessageBody(
        sourceText: input.rawText,
        displayedText: excerpt.text,
        isTruncated: exceedsCollapsedLimit,
        org: nil,
        containsInlineSyntax: false
      ),
      activityFeedItems: []
    )
  }

  private nonisolated static func prepareBody(
    sourceText: String,
    role: OpenClawChatMessage.Role,
    utf8ByteLimit: Int?
  ) -> OpenClawPreparedMessageBody {
    let excerpt = OpenClawMessageBodyExcerpt(sourceText, utf8ByteLimit: utf8ByteLimit)
    let org = role == .assistant
      ? OpenClawMessageOrgPresentation(excerpt.text)
      : nil
    let inlineText = org?.normalizedText ?? excerpt.text
    let containsInlineSyntax = org?.usesStructuredRendering == true
      ? false
      : OrgInlineParser.hasInlineSyntaxCandidate(inlineText)
    return OpenClawPreparedMessageBody(
      sourceText: sourceText,
      displayedText: excerpt.text,
      isTruncated: excerpt.isTruncated,
      org: org,
      containsInlineSyntax: containsInlineSyntax
    )
  }

  private nonisolated static func estimatedCost(
    input: OpenClawMessagePresentationInput,
    context: OpenClawContextPresentation,
    body: OpenClawPreparedMessageBody,
    activityFeedItems: [OpenClawActivityFeedItem]
  ) -> Int {
    var cost = input.rawText.utf8.count
      + context.userText.utf8.count
      + body.displayedText.utf8.count
      + (body.org?.normalizedText.utf8.count ?? 0)
      + (input.responseTrace?.reasoning.utf8.count ?? 0)
    for contextItem in context.contexts {
      cost += contextItem.kind.utf8.count
        + contextItem.title.utf8.count
        + contextItem.reference.utf8.count
        + contextItem.sourceLine.utf8.count
        + (contextItem.automaticPrompt?.utf8.count ?? 0)
    }
    for block in body.org?.blocks ?? [] {
      cost += block.rawText.utf8.count
    }
    for item in activityFeedItems {
      cost += item.id.utf8.count
      cost += item.title.utf8.count
      cost += item.detail?.utf8.count ?? 0
      cost += item.latestDetail?.utf8.count ?? 0
      cost += 128
    }
    return cost
  }
}

actor OpenClawMessagePresentationPreparationCoordinator {
  static let shared = OpenClawMessagePresentationPreparationCoordinator()
  private static let maximumConcurrentWorkerCount = 2

  private struct Entry {
    let token: UUID
    let input: OpenClawMessagePresentationInput
    let task: Task<OpenClawPreparedMessagePresentation, Never>
  }

  private var entries: [UUID: [Entry]] = [:]
  private var workerPermitWaiters: [CheckedContinuation<Void, Never>] = []
  private var preparationCountForTesting = 0
  private var activeWorkerCountValueForTesting = 0
  private var peakConcurrentWorkerCountValueForTesting = 0
  private var activeWorkerCountsByMessageForTesting: [UUID: Int] = [:]
  private var peakWorkerCountsByMessageForTesting: [UUID: Int] = [:]
  private var pausesWorkersForTesting = false
  private var pausedWorkerContinuationsForTesting: [CheckedContinuation<Void, Never>] = []

  func prepare(
    _ input: OpenClawMessagePresentationInput
  ) async -> OpenClawPreparedMessagePresentation {
    await prepare(input, revision: nil)
  }

  func resolve(
    _ input: OpenClawMessagePresentationInput,
    cachedCandidate: OpenClawCachedMessagePresentation?
  ) async -> OpenClawResolvedMessagePresentation {
    let revision = OpenClawMessagePresentationRevision(input)
    if cachedCandidate?.revision == revision,
       let cachedCandidate {
      return OpenClawResolvedMessagePresentation(
        revision: revision,
        value: cachedCandidate,
        preparedForCacheInstall: nil
      )
    }
    let prepared = await prepare(input, revision: revision)
    return OpenClawResolvedMessagePresentation(
      revision: revision,
      value: prepared.value,
      preparedForCacheInstall: prepared
    )
  }

  private func prepare(
    _ input: OpenClawMessagePresentationInput,
    revision: OpenClawMessagePresentationRevision?
  ) async -> OpenClawPreparedMessagePresentation {
    let token: UUID
    let task: Task<OpenClawPreparedMessagePresentation, Never>
    if let existing = entries[input.messageID]?.first(where: { $0.input == input }) {
      token = existing.token
      task = existing.task
    } else {
      let previousTask = entries[input.messageID]?.last?.task
      token = UUID()
      task = Task.detached(priority: .userInitiated) {
        if let previousTask {
          _ = await previousTask.value
        }
        await self.acquireWorkerPermit(messageID: input.messageID)
        let prepared = OpenClawMessagePresentationBuilder.prepare(
          input,
          revision: revision
        )
        await self.releaseWorkerPermit(messageID: input.messageID)
        return prepared
      }
      entries[input.messageID, default: []].append(Entry(
        token: token,
        input: input,
        task: task
      ))
      preparationCountForTesting += 1
    }
    let prepared = await task.value
    removeFinishedEntry(messageID: input.messageID, token: token)
    return prepared
  }

  private func removeFinishedEntry(messageID: UUID, token: UUID) {
    guard var messageEntries = entries[messageID] else { return }
    messageEntries.removeAll { $0.token == token }
    if messageEntries.isEmpty {
      entries.removeValue(forKey: messageID)
    } else {
      entries[messageID] = messageEntries
    }
  }

  private func acquireWorkerPermit(messageID: UUID) async {
    if activeWorkerCountValueForTesting >= Self.maximumConcurrentWorkerCount {
      await withCheckedContinuation { continuation in
        workerPermitWaiters.append(continuation)
      }
    } else {
      activeWorkerCountValueForTesting += 1
      peakConcurrentWorkerCountValueForTesting = max(
        peakConcurrentWorkerCountValueForTesting,
        activeWorkerCountValueForTesting
      )
    }
    let messageWorkerCount = (activeWorkerCountsByMessageForTesting[messageID] ?? 0) + 1
    activeWorkerCountsByMessageForTesting[messageID] = messageWorkerCount
    peakWorkerCountsByMessageForTesting[messageID] = max(
      peakWorkerCountsByMessageForTesting[messageID] ?? 0,
      messageWorkerCount
    )
    guard pausesWorkersForTesting else { return }
    await withCheckedContinuation { continuation in
      pausedWorkerContinuationsForTesting.append(continuation)
    }
  }

  private func releaseWorkerPermit(messageID: UUID) {
    let messageWorkerCount = max(
      0,
      (activeWorkerCountsByMessageForTesting[messageID] ?? 1) - 1
    )
    if messageWorkerCount == 0 {
      activeWorkerCountsByMessageForTesting.removeValue(forKey: messageID)
    } else {
      activeWorkerCountsByMessageForTesting[messageID] = messageWorkerCount
    }
    if workerPermitWaiters.isEmpty {
      activeWorkerCountValueForTesting -= 1
    } else {
      workerPermitWaiters.removeFirst().resume()
    }
  }

  func resetForTesting() async {
    setWorkersPausedForTesting(false)
    let pendingTasks = entries.values.flatMap { $0 }.map(\.task)
    for task in pendingTasks {
      _ = await task.value
    }
    entries.removeAll()
    preparationCountForTesting = 0
    activeWorkerCountValueForTesting = 0
    peakConcurrentWorkerCountValueForTesting = 0
    activeWorkerCountsByMessageForTesting.removeAll()
    peakWorkerCountsByMessageForTesting.removeAll()
  }

  func countForTesting() -> Int { preparationCountForTesting }
  func activeWorkerCountForTesting() -> Int { activeWorkerCountValueForTesting }
  func peakConcurrentWorkerCountForTesting() -> Int { peakConcurrentWorkerCountValueForTesting }
  func peakWorkerCountForTesting(messageID: UUID) -> Int {
    peakWorkerCountsByMessageForTesting[messageID] ?? 0
  }
  func maximumConcurrentWorkerCountForTesting() -> Int {
    Self.maximumConcurrentWorkerCount
  }

  func setWorkersPausedForTesting(_ paused: Bool) {
    pausesWorkersForTesting = paused
    guard !paused else { return }
    let continuations = pausedWorkerContinuationsForTesting
    pausedWorkerContinuationsForTesting.removeAll()
    continuations.forEach { $0.resume() }
  }
}

actor OpenClawExpandedMessageBodyPreparationCoordinator {
  static let shared = OpenClawExpandedMessageBodyPreparationCoordinator()

  private struct Entry {
    let token: UUID
    let input: OpenClawExpandedMessageBodyInput
    let task: Task<OpenClawPreparedMessageBody?, Never>
  }

  private var entries: [UUID: [Entry]] = [:]
  private var preparationCountForTesting = 0
  private var activeWorkerCountValueForTesting = 0
  private var peakConcurrentWorkerCountValueForTesting = 0
  private var pausesWorkersForTesting = false
  private var pausedWorkerContinuationsForTesting: [CheckedContinuation<Void, Never>] = []

  func prepare(
    _ input: OpenClawExpandedMessageBodyInput
  ) async -> OpenClawPreparedMessageBody? {
    let token: UUID
    let task: Task<OpenClawPreparedMessageBody?, Never>
    if let existing = entries[input.messageID]?.first(where: { $0.input == input }) {
      token = existing.token
      task = existing.task
    } else {
      let previousTask = entries[input.messageID]?.last?.task
      token = UUID()
      task = Task.detached(priority: .userInitiated) {
        if let previousTask {
          _ = await previousTask.value
        }
        await self.workerDidStart()
        let prepared = OpenClawMessagePresentationBuilder.prepareExpandedBody(
          sourceText: input.sourceText,
          role: input.role,
          pageIndex: input.pageIndex
        )
        await self.workerDidFinish()
        return prepared
      }
      entries[input.messageID, default: []].append(Entry(
        token: token,
        input: input,
        task: task
      ))
      preparationCountForTesting += 1
    }
    let prepared = await task.value
    removeFinishedEntry(messageID: input.messageID, token: token)
    return Task.isCancelled ? nil : prepared
  }

  private func removeFinishedEntry(messageID: UUID, token: UUID) {
    guard var messageEntries = entries[messageID] else { return }
    messageEntries.removeAll { $0.token == token }
    if messageEntries.isEmpty {
      entries.removeValue(forKey: messageID)
    } else {
      entries[messageID] = messageEntries
    }
  }

  private func workerDidStart() async {
    activeWorkerCountValueForTesting += 1
    peakConcurrentWorkerCountValueForTesting = max(
      peakConcurrentWorkerCountValueForTesting,
      activeWorkerCountValueForTesting
    )
    guard pausesWorkersForTesting else { return }
    await withCheckedContinuation { continuation in
      pausedWorkerContinuationsForTesting.append(continuation)
    }
  }

  private func workerDidFinish() {
    activeWorkerCountValueForTesting -= 1
  }

  func resetForTesting() async {
    setWorkersPausedForTesting(false)
    let pendingTasks = entries.values.flatMap { $0 }.map(\.task)
    pendingTasks.forEach { $0.cancel() }
    for task in pendingTasks {
      _ = await task.value
    }
    entries.removeAll()
    preparationCountForTesting = 0
    activeWorkerCountValueForTesting = 0
    peakConcurrentWorkerCountValueForTesting = 0
  }

  func countForTesting() -> Int { preparationCountForTesting }
  func activeWorkerCountForTesting() -> Int { activeWorkerCountValueForTesting }
  func peakConcurrentWorkerCountForTesting() -> Int { peakConcurrentWorkerCountValueForTesting }

  func setWorkersPausedForTesting(_ paused: Bool) {
    pausesWorkersForTesting = paused
    guard !paused else { return }
    let continuations = pausedWorkerContinuationsForTesting
    pausedWorkerContinuationsForTesting.removeAll()
    continuations.forEach { $0.resume() }
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
    let input = OpenClawMessagePresentationInput(message)
    let key = CacheKey(messageID: input.messageID)
    if let cached = cache.object(forKey: key), cached.matches(input) {
      return cached
    }

    let prepared = OpenClawMessagePresentationBuilder.prepare(input)
    install(prepared)
    return prepared.value
  }

  static func cachedPresentation(
    for input: OpenClawMessagePresentationInput
  ) -> OpenClawCachedMessagePresentation? {
    guard let cached = cache.object(forKey: CacheKey(messageID: input.messageID)),
          cached.matches(input)
    else { return nil }
    return cached
  }

  static func cachedPresentation(
    messageID: UUID
  ) -> OpenClawCachedMessagePresentation? {
    cache.object(forKey: CacheKey(messageID: messageID))
  }

  static func install(_ prepared: OpenClawPreparedMessagePresentation) {
    cache.setObject(
      prepared.value,
      forKey: CacheKey(messageID: prepared.messageID),
      cost: prepared.estimatedCost
    )
  }

  static func install(_ prepared: [OpenClawPreparedMessagePresentation]) {
    for presentation in prepared {
      install(presentation)
    }
  }

  static func removeAllForTesting() {
    cache.removeAllObjects()
  }

  static func cachedPresentationForTesting(
    messageID: UUID
  ) -> OpenClawCachedMessagePresentation? {
    cache.object(forKey: CacheKey(messageID: messageID))
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

private struct AIChatMediaCorpusRootKey: EnvironmentKey {
  static let defaultValue: URL? = nil
}

extension EnvironmentValues {
  var aiChatMediaCorpusRoot: URL? {
    get { self[AIChatMediaCorpusRootKey.self] }
    set { self[AIChatMediaCorpusRootKey.self] = newValue }
  }
}

struct OpenClawMessageBodyView: View {
  @Environment(\.aiChatMediaCorpusRoot) private var mediaCorpusRoot
  static let maximumStructuredBlockCountPerPage = 120

  static func structuredBlockRange(
    blockCount: Int,
    pageIndex: Int
  ) -> Range<Int> {
    let resolvedBlockCount = max(0, blockCount)
    let maximumPageIndex = max(
      0,
      (resolvedBlockCount - 1) / maximumStructuredBlockCountPerPage
    )
    let resolvedPageIndex = min(max(0, pageIndex), maximumPageIndex)
    let lowerBound = min(
      resolvedBlockCount,
      resolvedPageIndex * maximumStructuredBlockCountPerPage
    )
    let upperBound = min(
      resolvedBlockCount,
      lowerBound + maximumStructuredBlockCountPerPage
    )
    return lowerBound..<upperBound
  }

  let rawText: String
  let compact: Bool
  let managesTextSelection: Bool
  let rendersStructuredOrg2: Bool
  let structuredPresentation: OpenClawMessageOrgPresentation?
  let containsInlineSyntax: Bool?
  let allowsSynchronousStructuredPresentationFallback: Bool
  let structuredPageToken: Int
  @State private var structuredBlockPageIndex = 0

  init(
    rawText: String,
    compact: Bool,
    managesTextSelection: Bool,
    rendersStructuredOrg2: Bool,
    structuredPresentation: OpenClawMessageOrgPresentation? = nil,
    containsInlineSyntax: Bool? = nil,
    allowsSynchronousStructuredPresentationFallback: Bool = true,
    structuredPageToken: Int = 0
  ) {
    self.rawText = rawText
    self.compact = compact
    self.managesTextSelection = managesTextSelection
    self.rendersStructuredOrg2 = rendersStructuredOrg2
    self.structuredPresentation = structuredPresentation
    self.containsInlineSyntax = containsInlineSyntax
    self.allowsSynchronousStructuredPresentationFallback =
      allowsSynchronousStructuredPresentationFallback
    self.structuredPageToken = structuredPageToken
  }

  var body: some View {
    let presentation: OpenClawMessageOrgPresentation? = {
      if rendersStructuredOrg2,
         let structuredPresentation {
        return structuredPresentation
      }
      if rendersStructuredOrg2,
         allowsSynchronousStructuredPresentationFallback {
        return OpenClawMessageOrgPresentation(rawText)
      }
      return nil
    }()
    Group {
      if let presentation, presentation.usesStructuredRendering {
        let blockCount = presentation.blocks.count
        let maximumPageIndex = max(
          0,
          (blockCount - 1) / Self.maximumStructuredBlockCountPerPage
        )
        let resolvedPageIndex = min(max(0, structuredBlockPageIndex), maximumPageIndex)
        let visibleBlockRange = Self.structuredBlockRange(
          blockCount: blockCount,
          pageIndex: resolvedPageIndex
        )
        let lowerBound = visibleBlockRange.lowerBound
        let upperBound = visibleBlockRange.upperBound
        let visibleBlocks = presentation.blocks[lowerBound..<upperBound]
        let containsTable = visibleBlocks.contains { block in
          if case .table = block.rendered { return true }
          return false
        }
        VStack(alignment: .leading, spacing: 0) {
          ForEach(visibleBlocks) { block in
            RenderedBlockView(
              block: block.rendered,
              rawText: block.rawText,
              corpusRoot: mediaCorpusRoot,
              inlineActions: .readOnly(copySourceBlock: { lines in
                OpenClawMessageClipboard.copyCodeSnippet(lines: lines)
              })
            )
            .frame(
              maxWidth: compact || !block.isRenderedTable ? (compact ? 360 : 640) : .infinity,
              alignment: .leading
            )
          }
          if maximumPageIndex > 0 {
            HStack(spacing: 12) {
              if resolvedPageIndex > 0 {
                Button("Previous formatted blocks") {
                  structuredBlockPageIndex = resolvedPageIndex - 1
                }
                .accessibilityIdentifier("openclaw-message-structured-previous")
              }
              Text("Blocks \(lowerBound + 1)–\(upperBound) of \(blockCount)")
                .foregroundStyle(.tertiary)
              if resolvedPageIndex < maximumPageIndex {
                Button("Next formatted blocks") {
                  structuredBlockPageIndex = resolvedPageIndex + 1
                }
                .accessibilityIdentifier("openclaw-message-structured-next")
              }
            }
            .buttonStyle(.plain)
            .font(.caption2.weight(.medium))
            .padding(.top, 6)
          }
        }
        .environment(\.orgInlineTextSelectionOwnerEnabled, managesTextSelection)
        .frame(
          maxWidth: compact || !containsTable ? (compact ? 360 : 640) : .infinity,
          alignment: .leading
        )
      } else if containsInlineSyntax == false {
        OrgInlineText(
          presentation?.normalizedText ?? rawText,
          managesTextSelection: managesTextSelection
        )
          .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
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
    .onChange(of: structuredPageToken) { _, _ in
      structuredBlockPageIndex = 0
    }
  }
}

private struct OpenClawMessageExpansionTaskKey: Equatable {
  let messageID: UUID
  let role: OpenClawChatMessage.Role
  let createdAt: Date
  let pageIndex: Int
  let wantsFullBody: Bool
  let presentationRevision: OpenClawMessagePresentationRevision?
}

@MainActor
private final class OpenClawMessageAccessibilityPressView: NSView {
  var activate: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Pointer input stays with the visible SwiftUI button. This view only
    // supplies a stable native accessibility action for automation and VoiceOver.
    nil
  }

  override func accessibilityPerformPress() -> Bool {
    activate?()
    return activate != nil
  }
}

private struct OpenClawMessageAccessibilityPressTarget: NSViewRepresentable {
  let identifier: String
  let label: String
  let activate: () -> Void

  func makeNSView(context: Context) -> OpenClawMessageAccessibilityPressView {
    OpenClawMessageAccessibilityPressView(frame: .zero)
  }

  func updateNSView(
    _ view: OpenClawMessageAccessibilityPressView,
    context: Context
  ) {
    view.activate = activate
    view.setAccessibilityIdentifier(identifier)
    view.setAccessibilityLabel(label)
  }
}

private struct OpenClawMessageAccessibilityMarker: NSViewRepresentable {
  let identifier: String
  let label: String

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.staticText)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    view.setAccessibilityIdentifier(identifier)
    view.setAccessibilityLabel(label)
  }
}

private struct OpenClawMessagePresentationResolver: NSViewRepresentable {
  let input: OpenClawMessagePresentationInput
  let onResolve: @MainActor (OpenClawResolvedMessagePresentation) -> Void

  @MainActor
  final class Coordinator {
    private var requestGeneration = 0
    private var task: Task<Void, Never>?
    private var lastAppliedRevision: OpenClawMessagePresentationRevision?

    func resolve(
      input: OpenClawMessagePresentationInput,
      onResolve: @escaping @MainActor (OpenClawResolvedMessagePresentation) -> Void
    ) {
      requestGeneration &+= 1
      let generation = requestGeneration
      let cachedCandidate = OpenClawMessagePresentationCache.cachedPresentation(
        messageID: input.messageID
      )
      task?.cancel()
      task = Task { @MainActor in
        let resolved = await OpenClawMessagePresentationPreparationCoordinator.shared.resolve(
          input,
          cachedCandidate: cachedCandidate
        )
        guard !Task.isCancelled,
              generation == requestGeneration
        else { return }
        if let prepared = resolved.preparedForCacheInstall {
          OpenClawMessagePresentationCache.install(prepared)
        }
        guard lastAppliedRevision != resolved.revision else { return }
        lastAppliedRevision = resolved.revision
        onResolve(resolved)
      }
    }

    func cancel() {
      requestGeneration &+= 1
      task?.cancel()
      task = nil
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.setAccessibilityElement(false)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.resolve(input: input, onResolve: onResolve)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.cancel()
  }
}

private extension OrgEditableBlock {
  var isRenderedTable: Bool {
    if case .table = rendered { return true }
    return false
  }
}

struct AIChatTranscriptTextLayout: Equatable {
  let attributedText: NSAttributedString
  let lineSpacing: CGFloat

  var text: String { attributedText.string }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.lineSpacing == rhs.lineSpacing
      && lhs.attributedText.isEqual(to: rhs.attributedText)
  }

  func characterLocation(in bounds: CGRect, at point: CGPoint) -> Int {
    let textKit = makeTextKitLayout(width: bounds.width)
    let localPoint = CGPoint(
      x: point.x,
      y: point.y - verticalOffset(containerHeight: bounds.height, usedHeight: textKit.usedRect.height)
    )
    let utf16Length = attributedText.length
    guard utf16Length > 0, textKit.glyphRange.length > 0 else { return 0 }
    if localPoint.y > textKit.usedRect.maxY { return utf16Length }
    var fraction: CGFloat = 0
    let glyphIndex = textKit.layoutManager.glyphIndex(
      for: CGPoint(
        x: min(max(0, localPoint.x), max(0, bounds.width)),
        y: max(0, localPoint.y)
      ),
      in: textKit.container,
      fractionOfDistanceThroughGlyph: &fraction
    )
    return min(utf16Length, max(0, textKit.layoutManager.characterIndexForGlyph(at: glyphIndex)))
  }

  func selectionRects(for range: NSRange, in bounds: CGRect) -> [CGRect] {
    let textKit = makeTextKitLayout(width: bounds.width)
    let characterRange = NSIntersectionRange(
      range,
      NSRange(location: 0, length: attributedText.length)
    )
    guard characterRange.length > 0 else { return [] }
    let glyphRange = textKit.layoutManager.glyphRange(
      forCharacterRange: characterRange,
      actualCharacterRange: nil
    )
    let yOffset = verticalOffset(
      containerHeight: bounds.height,
      usedHeight: textKit.usedRect.height
    )
    var rects: [CGRect] = []
    textKit.layoutManager.enumerateEnclosingRects(
      forGlyphRange: glyphRange,
      withinSelectedGlyphRange: glyphRange,
      in: textKit.container
    ) { rect, _ in
      rects.append(rect.offsetBy(dx: 0, dy: yOffset))
    }
    return rects
  }

  func makeTextKitLayout(width: CGFloat) -> (
    storage: NSTextStorage,
    layoutManager: NSLayoutManager,
    container: NSTextContainer,
    usedRect: CGRect,
    glyphRange: NSRange
  ) {
    let storage = NSTextStorage(attributedString: attributedText)
    let fullRange = NSRange(location: 0, length: storage.length)
    if storage.length > 0 {
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.lineSpacing = lineSpacing
      paragraphStyle.lineBreakMode = .byWordWrapping
      storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
      if storage.attribute(.font, at: 0, effectiveRange: nil) == nil {
        storage.addAttribute(
          .font,
          value: NSFont.systemFont(ofSize: NSFont.systemFontSize),
          range: fullRange
        )
      }
    }
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(
      width: max(1, width),
      height: CGFloat.greatestFiniteMagnitude
    ))
    container.lineFragmentPadding = 0
    container.lineBreakMode = .byWordWrapping
    container.maximumNumberOfLines = 0
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: container)
    return (
      storage,
      layoutManager,
      container,
      layoutManager.usedRect(for: container),
      layoutManager.glyphRange(for: container)
    )
  }

  private func verticalOffset(containerHeight: CGFloat, usedHeight: CGFloat) -> CGFloat {
    max(0, (containerHeight - usedHeight) / 2)
  }
}

struct AIChatTranscriptSelectableRegion: Equatable {
  let id: UUID
  let messageID: UUID
  let layout: AIChatTranscriptTextLayout
  let frame: CGRect
  var tableCell: AIChatTableCell? = nil

  var text: String { layout.text }
}

struct AIChatTranscriptSelectionEndpoint: Equatable {
  let regionID: UUID
  let utf16Location: Int
}

@MainActor
@Observable
final class AIChatTranscriptSelectionModel {
  private(set) var selectedRanges: [UUID: NSRange] = [:]
  private(set) var regions: [AIChatTranscriptSelectableRegion] = []
  private var anchor: AIChatTranscriptSelectionEndpoint?
  private(set) var isSelecting = false

  func updateRegions(_ incomingRegions: [AIChatTranscriptSelectableRegion]) {
    var latestByID: [UUID: AIChatTranscriptSelectableRegion] = [:]
    for region in incomingRegions where !region.text.isEmpty && region.frame.width > 0 && region.frame.height > 0 {
      latestByID[region.id] = region
    }
    regions = latestByID.values.sorted {
      if abs($0.frame.minY - $1.frame.minY) > 1 {
        return $0.frame.minY < $1.frame.minY
      }
      return $0.frame.minX < $1.frame.minX
    }
    let visibleIDs = Set(regions.map(\.id))
    selectedRanges = selectedRanges.filter { visibleIDs.contains($0.key) }
  }

  func beginSelection(at point: CGPoint) {
    guard let endpoint = endpoint(at: point, requiresContainment: true) else {
      clear()
      return
    }
    anchor = endpoint
    isSelecting = true
    applySelection(from: endpoint, to: endpoint)
  }

  func extendSelection(to point: CGPoint) {
    guard isSelecting,
          let anchor,
          let extent = endpoint(at: point, requiresContainment: false)
    else { return }
    applySelection(from: anchor, to: extent)
  }

  func finishSelection(at point: CGPoint) {
    extendSelection(to: point)
    isSelecting = false
  }

  func applySelection(
    from anchor: AIChatTranscriptSelectionEndpoint,
    to extent: AIChatTranscriptSelectionEndpoint
  ) {
    guard let anchorIndex = regions.firstIndex(where: { $0.id == anchor.regionID }),
          let extentIndex = regions.firstIndex(where: { $0.id == extent.regionID })
    else {
      selectedRanges = [:]
      return
    }

    let lowerIndex = min(anchorIndex, extentIndex)
    let upperIndex = max(anchorIndex, extentIndex)
    var ranges: [UUID: NSRange] = [:]
    for index in lowerIndex...upperIndex {
      let region = regions[index]
      let textLength = (region.text as NSString).length
      let lowerLocation: Int
      let upperLocation: Int
      if anchorIndex == extentIndex {
        lowerLocation = min(anchor.utf16Location, extent.utf16Location)
        upperLocation = max(anchor.utf16Location, extent.utf16Location)
      } else if index == anchorIndex {
        if anchorIndex < extentIndex {
          lowerLocation = anchor.utf16Location
          upperLocation = textLength
        } else {
          lowerLocation = 0
          upperLocation = anchor.utf16Location
        }
      } else if index == extentIndex {
        if extentIndex > anchorIndex {
          lowerLocation = 0
          upperLocation = extent.utf16Location
        } else {
          lowerLocation = extent.utf16Location
          upperLocation = textLength
        }
      } else {
        lowerLocation = 0
        upperLocation = textLength
      }
      let clampedLower = min(textLength, max(0, lowerLocation))
      let clampedUpper = min(textLength, max(clampedLower, upperLocation))
      ranges[region.id] = NSRange(
        location: clampedLower,
        length: clampedUpper - clampedLower
      )
    }
    selectedRanges = ranges
  }

  func selectedRange(for regionID: UUID) -> NSRange? {
    guard let range = selectedRanges[regionID], range.length > 0 else { return nil }
    return range
  }

  private var selectedFragments: [AIChatRichClipboard.Fragment] {
    regions.compactMap { region in
      guard let range = selectedRange(for: region.id) else { return nil }
      return .init(text: (region.text as NSString).substring(with: range), cell: region.tableCell, messageID: region.messageID)
    }
  }

  var selectedText: String? {
    let fragments = selectedFragments
    return fragments.isEmpty ? nil : AIChatRichClipboard.selectionText(fragments)
  }

  @discardableResult
  func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
    guard let selectedText else { return false }
    return OpenClawMessageClipboard.write(selectedText, html: AIChatRichClipboard.selectionHTML(selectedFragments), to: pasteboard)
  }

  func clear() {
    selectedRanges = [:]
    anchor = nil
    isSelecting = false
  }

  private func endpoint(
    at point: CGPoint,
    requiresContainment: Bool
  ) -> AIChatTranscriptSelectionEndpoint? {
    let region = requiresContainment
      ? regions.first(where: { $0.frame.contains(point) })
      : closestRegion(to: point)
    guard let region else { return nil }
    let localPoint = CGPoint(
      x: point.x - region.frame.minX,
      y: point.y - region.frame.minY
    )
    let location = region.layout.characterLocation(
      in: CGRect(origin: .zero, size: region.frame.size),
      at: localPoint
    )
    return AIChatTranscriptSelectionEndpoint(
      regionID: region.id,
      utf16Location: location
    )
  }

  private func closestRegion(to point: CGPoint) -> AIChatTranscriptSelectableRegion? {
    if let containingRegion = regions.first(where: { $0.frame.contains(point) }) {
      return containingRegion
    }
    return regions.min { lhs, rhs in
      squaredDistance(from: point, to: lhs.frame) < squaredDistance(from: point, to: rhs.frame)
    }
  }

  private func squaredDistance(from point: CGPoint, to frame: CGRect) -> CGFloat {
    let dx = max(0, max(frame.minX - point.x, point.x - frame.maxX))
    let dy = max(0, max(frame.minY - point.y, point.y - frame.maxY))
    return dx * dx + dy * dy
  }
}

struct AIChatTranscriptSelectionEventBridge: NSViewRepresentable {
  let selectionModel: AIChatTranscriptSelectionModel

  func makeNSView(context: Context) -> EventView {
    EventView(selectionModel: selectionModel)
  }

  func updateNSView(_ view: EventView, context: Context) {
    view.selectionModel = selectionModel
  }

  static func dismantleNSView(_ view: EventView, coordinator: ()) {
    view.removeEventMonitor()
  }

  @MainActor
  final class EventView: NSView, NSUserInterfaceValidations {
    var selectionModel: AIChatTranscriptSelectionModel
    private var eventMonitor: Any?
    private var observedWindow: NSWindow?

    init(selectionModel: AIChatTranscriptSelectionModel) {
      self.selectionModel = selectionModel
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }

    @IBAction
    func copy(_ sender: Any?) {
      selectionModel.copySelection()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
      if item.action == #selector(copy(_:)) {
        return selectionModel.selectedText != nil
      }
      return responds(to: item.action)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      installEventMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow !== window {
        removeEventMonitor()
      }
      super.viewWillMove(toWindow: newWindow)
    }

    func removeEventMonitor() {
      if let eventMonitor {
        NSEvent.removeMonitor(eventMonitor)
      }
      eventMonitor = nil
      observedWindow = nil
    }

    private func installEventMonitorIfNeeded() {
      guard let window,
            eventMonitor == nil || observedWindow !== window
      else { return }
      removeEventMonitor()
      observedWindow = window
      eventMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .scrollWheel]
      ) { [weak self, weak window] event in
        guard let self,
              let window,
              event.window === window
        else { return event }
        return self.handle(event)
      }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      if event.type == .scrollWheel,
         let window,
         let contentView = window.contentView {
        let location = contentView.convert(event.locationInWindow, from: nil)
        if let hitView = contentView.hitTest(location),
           let outerScrollView = AIChatNestedScrollWheelRouting.outerScrollView(
             for: hitView,
             deltaX: event.scrollingDeltaX,
             deltaY: event.scrollingDeltaY
           ) {
          // SwiftUI's nested horizontal ScrollView consumes vertical wheel
          // gestures even though a rendered table or source block cannot move
          // vertically. Hand that gesture to the transcript instead.
          outerScrollView.scrollWheel(with: event)
          return nil
        }
      }

      if event.type == .keyDown,
         event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
         event.charactersIgnoringModifiers?.lowercased() == "c",
         selectionModel.copySelection() {
        return nil
      }

      let point = convert(event.locationInWindow, from: nil)
      switch event.type {
      case .leftMouseDown:
        selectionModel.beginSelection(at: point)
      case .leftMouseDragged:
        guard selectionModel.isSelecting else { break }
        selectionModel.extendSelection(to: point)
        window?.makeFirstResponder(self)
      case .leftMouseUp:
        guard selectionModel.isSelecting else { break }
        selectionModel.finishSelection(at: point)
        window?.makeFirstResponder(self)
      default:
        break
      }
      return event
    }
  }
}

@MainActor
enum AIChatNestedScrollWheelRouting {
  static func outerScrollView(
    for hitView: NSView,
    deltaX: CGFloat,
    deltaY: CGFloat
  ) -> NSScrollView? {
    guard abs(deltaY) > abs(deltaX), abs(deltaY) > 0 else { return nil }

    var scrollViews: [NSScrollView] = []
    var candidate: NSView? = hitView
    while let view = candidate {
      if let scrollView = view as? NSScrollView {
        scrollViews.append(scrollView)
      }
      candidate = view.superview
    }
    guard scrollViews.count >= 2 else { return nil }

    let innerScrollView = scrollViews[0]
    guard !innerScrollView.hasVerticalScroller else { return nil }
    return scrollViews[1]
  }
}

private struct AIChatTranscriptSelectionModelKey: EnvironmentKey {
  static let defaultValue: AIChatTranscriptSelectionModel? = nil
}

private struct AIChatTranscriptSelectionMessageIDKey: EnvironmentKey {
  static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
  var aiChatTranscriptSelectionModel: AIChatTranscriptSelectionModel? {
    get { self[AIChatTranscriptSelectionModelKey.self] }
    set { self[AIChatTranscriptSelectionModelKey.self] = newValue }
  }

  var aiChatTranscriptSelectionMessageID: UUID? {
    get { self[AIChatTranscriptSelectionMessageIDKey.self] }
    set { self[AIChatTranscriptSelectionMessageIDKey.self] = newValue }
  }
}

struct AIChatTranscriptSelectableRegionPreferenceKey: PreferenceKey {
  nonisolated(unsafe) static let defaultValue: [AIChatTranscriptSelectableRegion] = []

  static func reduce(
    value: inout [AIChatTranscriptSelectableRegion],
    nextValue: () -> [AIChatTranscriptSelectableRegion]
  ) {
    value.append(contentsOf: nextValue())
  }
}

struct AIChatTranscriptSelectableTextModifier: ViewModifier {
  @Environment(\.aiChatTranscriptSelectionModel) private var selectionModel
  @Environment(\.aiChatTranscriptSelectionMessageID) private var messageID
  @Environment(\.aiChatTableCell) private var tableCell
  #if compiler(>=6.2)
  @Environment(\.fontResolutionContext) private var fontContext
  #else
  private let fontContext = AIChatNativeTextAttributes.FontContext()
  #endif
  @Environment(\.openOrgFileReference) private var openFileReference
  @State private var regionID = UUID()
  let rawText: String
  let font: Font
  let lineSpacing: CGFloat
  let linkResolver: OrgRoamLinkResolver
  let searchHighlightQuery: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let selectionModel, let messageID {
      let layout = selectionLayout
      AIChatTranscriptRenderedText(
        layout: layout,
        range: selectionModel.selectedRange(for: regionID),
        openLink: { url in
          if let reference = OpenClawFileReference.fromDeepLinkURL(url) {
            openFileReference(reference)
          } else if url.isFileURL {
            openFileReference(OpenClawFileReference(path: url.path, line: nil))
          } else if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
          }
        }
      )
        .background {
          GeometryReader { proxy in
            Color.clear.preference(
              key: AIChatTranscriptSelectableRegionPreferenceKey.self,
              value: [AIChatTranscriptSelectableRegion(
                id: regionID,
                messageID: messageID,
                layout: layout,
                frame: proxy.frame(in: .named(AIChatTranscriptSelectionModel.coordinateSpaceName)),
                tableCell: tableCell
              )]
            )
          }
        }
    } else {
      content
    }
  }

  private var selectionLayout: AIChatTranscriptTextLayout {
    let attributed: AttributedString
    if let searchHighlightQuery,
       !searchHighlightQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let base = OrgInlineText.usesAttributedRendering(rawText)
        ? OrgInlineAttributedString.cached(
            raw: rawText,
            baseFont: font,
            linkResolver: linkResolver
          )
        : OrgInlineAttributedString.plain(rawText, baseFont: font)
      attributed = OrgInlineAttributedString.highlightingSearchMatches(
        in: base,
        query: searchHighlightQuery
      )
    } else if OrgInlineText.usesAttributedRendering(rawText) {
      attributed = OrgInlineAttributedString.cached(
        raw: rawText,
        baseFont: font,
        linkResolver: linkResolver
      )
    } else {
      attributed = OrgInlineAttributedString.plain(rawText, baseFont: font)
    }
    return AIChatTranscriptTextLayout(
      attributedText: AIChatNativeTextAttributes.make(attributed, fontContext: fontContext),
      lineSpacing: lineSpacing
    )
  }
}

// Drawing, sizing, hit testing, and selection all use the same TextKit layout.
// A SwiftUI Text plus a separately measured background can never guarantee this.
struct AIChatTranscriptRenderedText: NSViewRepresentable {
  let layout: AIChatTranscriptTextLayout
  let range: NSRange?
  let openLink: (URL) -> Void

  func makeNSView(context: Context) -> TextView { TextView(frame: .zero) }

  func updateNSView(_ view: TextView, context: Context) {
    view.textLayout = layout
    view.range = range
    view.openLink = openLink
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.staticText)
    view.setAccessibilityValue(layout.text)
    view.invalidateIntrinsicContentSize()
    view.needsDisplay = true
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
    let ideal = layout.makeTextKitLayout(width: 100_000).usedRect.size
    let width = max(1, min(proposal.width ?? ideal.width, ceil(ideal.width)))
    let measured = layout.makeTextKitLayout(width: width).usedRect.size
    return CGSize(width: width, height: ceil(measured.height))
  }

  final class TextView: NSView {
    var textLayout: AIChatTranscriptTextLayout?
    var range: NSRange?
    var openLink: ((URL) -> Void)?
    private var dragged = false
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { dragged = false }
    override func mouseDragged(with event: NSEvent) { dragged = true }
    override func mouseUp(with event: NSEvent) {
      guard !dragged, let textLayout else { return }
      let location = textLayout.characterLocation(in: bounds, at: convert(event.locationInWindow, from: nil))
      guard location < textLayout.attributedText.length,
            let url = textLayout.attributedText.attribute(.link, at: location, effectiveRange: nil) as? URL
      else { return }
      openLink?(url)
    }
    override func draw(_ dirtyRect: NSRect) {
      guard let textLayout, bounds.width > 0 else { return }
      let kit = textLayout.makeTextKitLayout(width: bounds.width)
      let origin = CGPoint(x: 0, y: max(0, (bounds.height - kit.usedRect.height) / 2))
      kit.layoutManager.drawBackground(forGlyphRange: kit.glyphRange, at: origin)
      if let range {
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.58).setFill()
        for rect in textLayout.selectionRects(for: range, in: bounds) {
          NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
      }
      kit.layoutManager.drawGlyphs(forGlyphRange: kit.glyphRange, at: origin)
    }
  }
}

@MainActor
enum AIChatNativeTextAttributes {
  // Runtime availability does not hide unknown SDK types from Xcode 16.
  // Keep the existing native-font fallback buildable with that toolchain.
  #if compiler(>=6.2)
  typealias FontContext = Font.Context
  #else
  struct FontContext {}
  #endif

  static func make(_ attributed: AttributedString, fontContext: FontContext) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
    var offset = 0
    for run in attributed.runs {
      let length = String(attributed[run.range].characters).utf16.count
      let range = NSRange(location: offset, length: length)
      let font = run.font ?? .body
      let nativeFont: NSFont
      #if compiler(>=6.2)
      if #available(macOS 26, *) {
        nativeFont = font.resolve(in: fontContext).ctFont as NSFont
      } else {
        nativeFont = fallbackFont(font)
      }
      #else
      nativeFont = fallbackFont(font)
      #endif
      result.addAttribute(.font, value: nativeFont, range: range)
      result.addAttribute(.foregroundColor, value: run.foregroundColor.map(NSColor.init) ?? NSColor.labelColor, range: range)
      if let background = run.backgroundColor {
        result.addAttribute(.backgroundColor, value: NSColor(background), range: range)
      }
      offset += length
    }
    return result
  }

  private static func fallbackFont(_ font: Font) -> NSFont {
    let styles: [(Font, CGFloat)] = [(.body, 13), (.callout, 12), (.headline, 13),
      (.title, 22), (.title2, 17), (.title3, 15), (.caption, 10), (.caption2, 10), (.footnote, 10)]
    for (style, size) in styles {
      for weight: Font.Weight in [.regular, .semibold, .bold] {
        let candidate = weight == .regular ? style : style.weight(weight)
        let native = NSFont.systemFont(ofSize: size, weight: weight == .bold ? .bold : (weight == .semibold || style == .headline ? .semibold : .regular))
        if font == candidate { return native }
        if font == candidate.italic() { return NSFontManager.shared.convert(native, toHaveTrait: .italicFontMask) }
      }
    }
    if font == .system(.body, design: .monospaced) {
      return .monospacedSystemFont(ofSize: 13, weight: .regular)
    }
    return .systemFont(ofSize: 13)
  }
}

extension View {
  func aiChatTranscriptSelectableText(
    rawText: String,
    font: Font,
    lineSpacing: CGFloat,
    linkResolver: OrgRoamLinkResolver,
    searchHighlightQuery: String?
  ) -> some View {
    modifier(AIChatTranscriptSelectableTextModifier(
      rawText: rawText,
      font: font,
      lineSpacing: lineSpacing,
      linkResolver: linkResolver,
      searchHighlightQuery: searchHighlightQuery
    ))
  }
}

extension AIChatTranscriptSelectionModel {
  static let coordinateSpaceName = "openclaw-chat-transcript-selection"
}

struct ChatBubbleView: View {
  // One selection owner wraps the bounded visible transcript. Giving each
  // message or rendered block its own owner prevents a drag from crossing
  // paragraphs, bullets, and message boundaries.
  static let managesMessageTextSelection = false

  let message: OpenClawChatMessage
  let runtime: AIChatRuntime
  let destinationTitlesByID: [String: String]
  let compact: Bool
  let isQueued: Bool
  let isRoomResponse: Bool
  let isSearchMatch: Bool
  let isSelectedSearchMatch: Bool
  let selectedSearchMatchPageIndex: Int
  let canSteerQueuedMessage: Bool
  let steerQueuedMessage: () -> Void
  let editQueuedMessage: () -> Void
  let deleteQueuedMessage: () -> Void
  @State private var isHovering = false
  @State private var didCopy = false
  @State private var previewedAttachment: OpenClawChatAttachment?
  @State private var explicitlyShowsFullBody = false
  @State private var expandedBodyPageIndex = 0
  @State private var expandedBody: OpenClawPreparedMessageBody?
  @State private var expandedBodyInput: OpenClawExpandedMessageBodyInput?
  @State private var asynchronouslyPreparedPresentation: OpenClawCachedMessagePresentation?
  @State private var presentationRevision: OpenClawMessagePresentationRevision?

  init(
    message: OpenClawChatMessage,
    runtime: AIChatRuntime = .openClaw,
    destinationTitlesByID: [String: String] = [:],
    compact: Bool = false,
    isQueued: Bool = false,
    isRoomResponse: Bool = false,
    isSearchMatch: Bool = false,
    isSelectedSearchMatch: Bool = false,
    selectedSearchMatchPageIndex: Int = 0,
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
    self.isSearchMatch = isSearchMatch
    self.isSelectedSearchMatch = isSelectedSearchMatch
    self.selectedSearchMatchPageIndex = max(0, selectedSearchMatchPageIndex)
    self.canSteerQueuedMessage = canSteerQueuedMessage
    self.steerQueuedMessage = steerQueuedMessage
    self.editQueuedMessage = editQueuedMessage
    self.deleteQueuedMessage = deleteQueuedMessage
    _expandedBodyPageIndex = State(initialValue: max(0, selectedSearchMatchPageIndex))
  }

  var body: some View {
    let presentationInput = OpenClawMessagePresentationInput(message)
    let cachedPresentation = asynchronouslyPreparedPresentation
      ?? OpenClawMessagePresentationBuilder.placeholder(presentationInput)
    let presentation = cachedPresentation.context
    let wantsFullBody = explicitlyShowsFullBody
      || (isSelectedSearchMatch && cachedPresentation.body.isTruncated)
    let expectedExpandedInput = OpenClawExpandedMessageBodyInput(
      messageID: presentationInput.messageID,
      role: presentationInput.role,
      sourceText: cachedPresentation.body.sourceText,
      pageIndex: expandedBodyPageIndex
    )
    let expandedBodyMatchesCurrentPage = expandedBodyInput?.messageID == expectedExpandedInput.messageID
      && expandedBodyInput?.role == expectedExpandedInput.role
      && expandedBodyInput?.pageIndex == expectedExpandedInput.pageIndex
    let resolvedBody = wantsFullBody
      && expandedBodyMatchesCurrentPage
      ? expandedBody ?? cachedPresentation.body
      : cachedPresentation.body
    let expansionTaskKey = OpenClawMessageExpansionTaskKey(
      messageID: message.id,
      role: message.role,
      createdAt: message.createdAt,
      pageIndex: expandedBodyPageIndex,
      wantsFullBody: wantsFullBody,
      presentationRevision: presentationRevision
    )
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
        if OpenClawProgressPresentation.containsNonWhitespace(resolvedBody.displayedText) {
          OpenClawMessageBodyView(
            rawText: resolvedBody.displayedText,
            compact: compact,
            managesTextSelection: Self.managesMessageTextSelection,
            rendersStructuredOrg2: message.role == .assistant,
            structuredPresentation: resolvedBody.org,
            containsInlineSyntax: resolvedBody.containsInlineSyntax,
            allowsSynchronousStructuredPresentationFallback: false,
            structuredPageToken: wantsFullBody ? expandedBodyPageIndex + 1 : 0
          )
          .environment(\.aiChatTranscriptSelectionMessageID, message.id)
        }
        if cachedPresentation.body.isTruncated {
          largeMessageExpansionControl(
            resolvedBody: resolvedBody,
            wantsFullBody: wantsFullBody,
            pageIsPrepared: expandedBodyMatchesCurrentPage && expandedBody != nil
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
          .stroke(effectiveBorderColor, lineWidth: searchBorderWidth)
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(
      "openclaw-chat-message-\(message.id.uuidString.lowercased())"
    )
    .background {
      OpenClawMessageAccessibilityMarker(
        identifier: "openclaw-chat-message-\(message.id.uuidString.lowercased())",
        label: "\(roleTitle) message"
      )
    }
    .sheet(item: $previewedAttachment) { attachment in
      OpenClawAttachmentPreviewView(attachment: attachment)
    }
    .background {
      OpenClawMessagePresentationResolver(input: presentationInput) { resolved in
        asynchronouslyPreparedPresentation = resolved.value
        presentationRevision = resolved.revision
      }
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    }
    .task(id: expansionTaskKey) {
      await synchronizeExpandedBody(
        input: presentationInput,
        wantsFullBody: wantsFullBody
      )
    }
    .onChange(of: selectedSearchMatchPageIndex) { _, pageIndex in
      guard isSelectedSearchMatch else { return }
      expandedBodyPageIndex = max(0, pageIndex)
    }
  }

  @ViewBuilder
  private func largeMessageExpansionControl(
    resolvedBody: OpenClawPreparedMessageBody,
    wantsFullBody: Bool,
    pageIsPrepared: Bool
  ) -> some View {
    let messageIdentifier = message.id.uuidString.lowercased()
    if wantsFullBody && !pageIsPrepared {
      HStack(spacing: 7) {
        ProgressView()
          .controlSize(.small)
        Text(isSelectedSearchMatch
          ? "Revealing full message for the selected match…"
          : "Preparing full message…")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Preparing full message")
      .accessibilityIdentifier("openclaw-message-preparing-full-\(messageIdentifier)")
    } else if pageIsPrepared && resolvedBody.isTruncated {
      HStack(spacing: 12) {
        if expandedBodyPageIndex > 0 {
          Button("Previous part") {
            expandedBodyPageIndex -= 1
          }
          .accessibilityIdentifier("openclaw-message-previous-part-\(messageIdentifier)")
        }
        Button("Next part") {
          expandedBodyPageIndex += 1
        }
        .accessibilityIdentifier("openclaw-message-next-part-\(messageIdentifier)")
        Button("Show Less") {
          explicitlyShowsFullBody = false
          expandedBodyPageIndex = 0
        }
        .accessibilityIdentifier("openclaw-message-show-less-\(messageIdentifier)")
        .background {
          OpenClawMessageAccessibilityPressTarget(
            identifier: "openclaw-message-show-less-\(messageIdentifier)",
            label: "Show collapsed message preview"
          ) {
            explicitlyShowsFullBody = false
            expandedBodyPageIndex = 0
          }
        }
      }
      .buttonStyle(.plain)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
    } else if !resolvedBody.isTruncated && isSelectedSearchMatch {
      Label("Full message shown for selected match", systemImage: "magnifyingglass")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("openclaw-message-full-revealed-\(messageIdentifier)")
        .background {
          OpenClawMessageAccessibilityMarker(
            identifier: "openclaw-message-full-revealed-\(messageIdentifier)",
            label: "Full message shown for selected match"
          )
        }
    } else if !resolvedBody.isTruncated {
      Button {
        explicitlyShowsFullBody = false
        expandedBodyPageIndex = 0
      } label: {
        Label("Show Less", systemImage: "chevron.up")
      }
      .buttonStyle(.plain)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .accessibilityLabel("Show collapsed message preview")
      .accessibilityIdentifier("openclaw-message-show-less-\(messageIdentifier)")
      .background {
        OpenClawMessageAccessibilityPressTarget(
          identifier: "openclaw-message-show-less-\(messageIdentifier)",
          label: "Show collapsed message preview"
        ) {
          explicitlyShowsFullBody = false
          expandedBodyPageIndex = 0
        }
      }
    } else if !wantsFullBody {
      Button {
        explicitlyShowsFullBody = true
        expandedBodyPageIndex = 0
      } label: {
        Label("Show Full Message", systemImage: "chevron.down")
      }
      .buttonStyle(.plain)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .help("Show all of this large message")
      .accessibilityLabel("Show full message")
      .accessibilityIdentifier("openclaw-message-show-full-\(messageIdentifier)")
      .background {
        OpenClawMessageAccessibilityPressTarget(
          identifier: "openclaw-message-show-full-\(messageIdentifier)",
          label: "Show full message"
        ) {
          explicitlyShowsFullBody = true
          expandedBodyPageIndex = 0
        }
      }
    }
  }

  @MainActor
  private func synchronizeExpandedBody(
    input: OpenClawMessagePresentationInput,
    wantsFullBody: Bool
  ) async {
    guard wantsFullBody else {
      expandedBody = nil
      expandedBodyInput = nil
      return
    }

    let cachedCandidate = OpenClawMessagePresentationCache.cachedPresentation(
      messageID: input.messageID
    )
    let resolved = await OpenClawMessagePresentationPreparationCoordinator.shared.resolve(
      input,
      cachedCandidate: cachedCandidate
    )
    guard !Task.isCancelled,
          message.id == input.messageID,
          message.role == input.role
    else { return }
    if let prepared = resolved.preparedForCacheInstall {
      OpenClawMessagePresentationCache.install(prepared)
    }
    presentationRevision = resolved.revision
    asynchronouslyPreparedPresentation = resolved.value
    let preparedPresentation = resolved.value
    guard preparedPresentation.body.isTruncated else {
      expandedBody = nil
      expandedBodyInput = nil
      return
    }

    let expandedInput = OpenClawExpandedMessageBodyInput(
      messageID: input.messageID,
      role: input.role,
      sourceText: preparedPresentation.body.sourceText,
      pageIndex: expandedBodyPageIndex
    )
    let alreadyPreparedCurrentPage = expandedBodyInput?.messageID == expandedInput.messageID
      && expandedBodyInput?.role == expandedInput.role
      && expandedBodyInput?.pageIndex == expandedInput.pageIndex
      && expandedBody != nil
    guard !alreadyPreparedCurrentPage else { return }
    let prepared = await OpenClawExpandedMessageBodyPreparationCoordinator.shared.prepare(
      expandedInput
    )
    guard !Task.isCancelled,
          let prepared,
          message.id == expandedInput.messageID,
          expandedBodyPageIndex == expandedInput.pageIndex,
          presentationRevision == resolved.revision
    else { return }
    expandedBody = prepared
    expandedBodyInput = expandedInput
  }

  private var copyButton: some View {
    Button {
      let input = OpenClawMessageClipboard.Input(message)
      Task { @MainActor in
        didCopy = await OpenClawMessageClipboard.copy(input)
      }
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

  private var effectiveBorderColor: Color {
    if isSelectedSearchMatch { return Color.accentColor.opacity(0.82) }
    if isSearchMatch { return Color.accentColor.opacity(0.34) }
    return borderColor
  }

  private var searchBorderWidth: CGFloat {
    isSelectedSearchMatch ? 2 : 1
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

struct AIChatRoomRound: Identifiable, Equatable, Sendable {
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

enum AIChatRoomTranscriptItem: Identifiable, Equatable, Sendable {
  case message(OpenClawChatMessage)
  case round(AIChatRoomRound)

  var id: UUID {
    switch self {
    case .message(let message): message.id
    case .round(let round): round.id
    }
  }

  var visibleChatBubbleMessages: [OpenClawChatMessage] {
    switch self {
    case .message(let message):
      return [message]
    case .round(let round):
      return [round.trigger] + round.expectedDestinationIDs
        .prefix(AIChatRoomRoundView.maximumVisibleDestinationCount)
        .compactMap {
        round.response(forDestinationID: $0)
      }
    }
  }

  var visibleChatBubbleCount: Int {
    visibleChatBubbleMessages.count
  }

  var displayedContentUTF8ByteCount: Int {
    visibleChatBubbleMessages.reduce(into: 0) { total, message in
      total += OpenClawMessageBodyExcerpt.displayedUTF8ByteCount(for: message.content)
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
    var messagesByRoundID: [UUID: [OpenClawChatMessage]] = [:]
    messagesByRoundID.reserveCapacity(messages.count / 3)
    for message in messages {
      if let roomRoundID = message.roomRoundID {
        messagesByRoundID[roomRoundID, default: []].append(message)
      }
    }
    var nextVisibleUserIndex = messages.endIndex
    var legacyGroupEndIndexes = Array(repeating: messages.endIndex, count: messages.count)
    for index in messages.indices.reversed() {
      legacyGroupEndIndexes[index] = nextVisibleUserIndex
      if messages[index].role == .user && !messages[index].isRoomDispatchCopy {
        nextVisibleUserIndex = index
      }
    }

    for (index, message) in messages.enumerated() {
      guard !consumed.contains(message.id) else { continue }
      guard !message.isRoomDispatchCopy else {
        consumed.insert(message.id)
        continue
      }
      let expectedDestinationIDs = !message.audienceDestinationIDs.isEmpty
        ? message.audienceDestinationIDs
        : legacyDestinationIDs(for: message.audience)
      guard message.role == .user, !expectedDestinationIDs.isEmpty
      else {
        consumed.insert(message.id)
        items.append(.message(message))
        continue
      }

      let groupedMessages: [OpenClawChatMessage]
      if let roomRoundID = message.roomRoundID {
        groupedMessages = messagesByRoundID[roomRoundID] ?? [message]
      } else {
        groupedMessages = Array(messages[index..<legacyGroupEndIndexes[index]])
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

  private static func legacyDestinationIDs(
    for audience: AIChatAudience?
  ) -> [String] {
    guard let audience else { return [] }
    if audience == .everyone {
      return [
        AIChatDestinationConfiguration.localCodexID,
        AIChatDestinationConfiguration.openClawID,
      ]
    }
    return audience.runtimes.map(AIChatDestinationConfiguration.defaultID(for:))
  }
}

struct AIChatThreadSearchMatch: Identifiable, Equatable {
  let messageID: UUID
  let scrollTargetID: UUID
  let rawMessageIndex: Int
  let anchorRawMessageIndex: Int
  let expandedBodyPageIndex: Int

  init(
    messageID: UUID,
    scrollTargetID: UUID,
    rawMessageIndex: Int = 0,
    anchorRawMessageIndex: Int? = nil,
    expandedBodyPageIndex: Int = 0
  ) {
    self.messageID = messageID
    self.scrollTargetID = scrollTargetID
    self.rawMessageIndex = rawMessageIndex
    self.anchorRawMessageIndex = anchorRawMessageIndex ?? rawMessageIndex
    self.expandedBodyPageIndex = max(0, expandedBodyPageIndex)
  }

  var id: UUID { messageID }
}

struct AIChatThreadSearchCandidate: Equatable {
  let messageID: UUID
  let scrollTargetID: UUID
  let searchableText: String
  let rawMessageIndex: Int
  let anchorRawMessageIndex: Int
}

struct AIChatThreadSearchMessageInput: Sendable {
  let messageID: UUID
  let role: OpenClawChatMessage.Role
  let rawText: String
  let attachmentFileNames: [String]
  let isRoomDispatchCopy: Bool
  let roomRoundID: UUID?
  let beginsLegacySharedRound: Bool

  nonisolated init(_ message: OpenClawChatMessage) {
    messageID = message.id
    role = message.role
    rawText = message.content
    attachmentFileNames = message.attachments.map(\.fileName)
    isRoomDispatchCopy = message.isRoomDispatchCopy
    roomRoundID = message.roomRoundID
    beginsLegacySharedRound = message.role == .user
      && (!message.audienceDestinationIDs.isEmpty || message.audience != nil)
  }
}

enum AIChatThreadSearch {
  nonisolated static func candidates(
    in messages: [OpenClawChatMessage],
    isSharedRoom: Bool
  ) -> [AIChatThreadSearchCandidate] {
    candidates(
      in: messages.map(AIChatThreadSearchMessageInput.init),
      isSharedRoom: isSharedRoom
    )
  }

  static func candidates(
    in items: [AIChatRoomTranscriptItem]
  ) -> [AIChatThreadSearchCandidate] {
    items.enumerated().flatMap { index, item -> [AIChatThreadSearchCandidate] in
      switch item {
      case .message(let message):
        return [candidate(for: message, scrollTargetID: message.id, rawMessageIndex: index)]
      case .round(let round):
        let visibleMessages = [round.trigger] + round.expectedDestinationIDs.compactMap {
          round.response(forDestinationID: $0)
        }
        return visibleMessages.map { message in
          candidate(for: message, scrollTargetID: round.id, rawMessageIndex: index)
        }
      }
    }
  }

  nonisolated static func candidates(
    in messages: [AIChatThreadSearchMessageInput],
    isSharedRoom: Bool
  ) -> [AIChatThreadSearchCandidate] {
    var explicitRoundAnchors: [UUID: Int] = [:]
    if isSharedRoom {
      for (index, message) in messages.enumerated()
      where !message.isRoomDispatchCopy && message.role == .user {
        if let roundID = message.roomRoundID,
           explicitRoundAnchors[roundID] == nil {
          explicitRoundAnchors[roundID] = index
        }
      }
    }

    var result: [AIChatThreadSearchCandidate] = []
    result.reserveCapacity(messages.count)
    var legacyRoundAnchor: (id: UUID, index: Int)?
    for (index, message) in messages.enumerated() {
      guard !Task.isCancelled else { return [] }
      guard !message.isRoomDispatchCopy else { continue }
      let scrollTargetID: UUID
      let anchorIndex: Int
      if !isSharedRoom {
        scrollTargetID = message.messageID
        anchorIndex = index
      } else if let roundID = message.roomRoundID {
        scrollTargetID = roundID
        anchorIndex = explicitRoundAnchors[roundID] ?? index
      } else if message.role == .user {
        if message.beginsLegacySharedRound {
          legacyRoundAnchor = (message.messageID, index)
        } else {
          legacyRoundAnchor = nil
        }
        scrollTargetID = legacyRoundAnchor?.id ?? message.messageID
        anchorIndex = legacyRoundAnchor?.index ?? index
      } else {
        scrollTargetID = legacyRoundAnchor?.id ?? message.messageID
        anchorIndex = legacyRoundAnchor?.index ?? index
      }
      result.append(candidate(
        for: message,
        scrollTargetID: scrollTargetID,
        rawMessageIndex: index,
        anchorRawMessageIndex: anchorIndex
      ))
    }
    return result
  }

  static func matches(
    query rawQuery: String,
    in items: [AIChatRoomTranscriptItem]
  ) -> [AIChatThreadSearchMatch] {
    matches(query: rawQuery, in: candidates(in: items))
  }

  static func matches(
    query rawQuery: String,
    in candidates: [AIChatThreadSearchCandidate]
  ) -> [AIChatThreadSearchMatch] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }

    var result: [AIChatThreadSearchMatch] = []
    result.reserveCapacity(min(candidates.count, 128))
    for candidate in candidates {
      guard !Task.isCancelled else { return [] }
      guard let matchRange = candidate.searchableText.range(
        of: query,
        options: [.caseInsensitive, .diacriticInsensitive]
      ) else {
        continue
      }
      let matchCharacterOffset = candidate.searchableText.distance(
        from: candidate.searchableText.startIndex,
        to: matchRange.lowerBound
      )
      result.append(AIChatThreadSearchMatch(
        messageID: candidate.messageID,
        scrollTargetID: candidate.scrollTargetID,
        rawMessageIndex: candidate.rawMessageIndex,
        anchorRawMessageIndex: candidate.anchorRawMessageIndex,
        expandedBodyPageIndex: matchCharacterOffset
          / OpenClawExpandedMessageBodyInput.pageCharacterLimit
      ))
    }
    return result
  }

  private static func candidate(
    for message: OpenClawChatMessage,
    scrollTargetID: UUID,
    rawMessageIndex: Int
  ) -> AIChatThreadSearchCandidate {
    let searchableText = ([OpenClawMessageClipboard.text(for: message)]
      + message.attachments.map(\.fileName))
      .joined(separator: "\n")
    return AIChatThreadSearchCandidate(
      messageID: message.id,
      scrollTargetID: scrollTargetID,
      searchableText: searchableText,
      rawMessageIndex: rawMessageIndex,
      anchorRawMessageIndex: rawMessageIndex
    )
  }

  private nonisolated static func candidate(
    for message: AIChatThreadSearchMessageInput,
    scrollTargetID: UUID,
    rawMessageIndex: Int,
    anchorRawMessageIndex: Int
  ) -> AIChatThreadSearchCandidate {
    let content: String
    if message.role == .user {
      content = OpenClawContextPresentation(message.rawText).clipboardText
    } else if message.role == .assistant {
      content = OpenClawMessageOrgNormalizer.normalized(message.rawText)
    } else {
      content = message.rawText
    }
    return AIChatThreadSearchCandidate(
      messageID: message.messageID,
      scrollTargetID: scrollTargetID,
      searchableText: ([content] + message.attachmentFileNames).joined(separator: "\n"),
      rawMessageIndex: rawMessageIndex,
      anchorRawMessageIndex: anchorRawMessageIndex
    )
  }
}

struct AIChatThreadFindBar: View {
  @Binding var query: String
  let selectedMatchIndex: Int?
  let matchCount: Int
  let focusRequest: Int
  let compact: Bool
  let onPrevious: () -> Void
  let onNext: () -> Void
  let onClose: () -> Void
  @FocusState private var isSearchFieldFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Find in this thread", text: $query)
        .textFieldStyle(.plain)
        .focused($isSearchFieldFocused)
        .onSubmit {
          onNext()
        }
        .accessibilityLabel("Find in current AI chat thread")
        .accessibilityIdentifier("openclaw-chat-thread-find-field")

      Text(resultSummary)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(minWidth: compact ? 58 : 72, alignment: .trailing)

      Button(action: onPrevious) {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.plain)
      .disabled(matchCount == 0)
      .help("Previous match")
      .accessibilityLabel("Previous match")

      Button(action: onNext) {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.plain)
      .disabled(matchCount == 0)
      .help("Next match")
      .accessibilityLabel("Next match")

      Button(action: onClose) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .help("Close find")
      .accessibilityLabel("Close find")
    }
    .padding(.horizontal, compact ? 10 : 16)
    .padding(.vertical, 8)
    .background(WorkspaceDesign.barBackground)
    .onAppear(perform: focusSearchField)
    .onChange(of: focusRequest) { _, _ in
      focusSearchField()
    }
    .onExitCommand(perform: onClose)
  }

  private var resultSummary: String {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return "" }
    guard let selectedMatchIndex, matchCount > 0 else { return "No matches" }
    return "\(selectedMatchIndex + 1) of \(matchCount)"
  }

  private func focusSearchField() {
    Task { @MainActor in
      isSearchFieldFocused = true
    }
  }
}

struct AIChatRoomRoundView: View {
  nonisolated static let maximumVisibleDestinationCount = 8

  @Environment(WorkspaceStore.self) private var store
  let round: AIChatRoomRound
  let compact: Bool
  let searchMatchMessageIDs: Set<UUID>
  let selectedSearchMatchMessageID: UUID?
  let selectedSearchMatchPageIndex: Int

  init(
    round: AIChatRoomRound,
    compact: Bool,
    searchMatchMessageIDs: Set<UUID> = [],
    selectedSearchMatchMessageID: UUID? = nil,
    selectedSearchMatchPageIndex: Int = 0
  ) {
    self.round = round
    self.compact = compact
    self.searchMatchMessageIDs = searchMatchMessageIDs
    self.selectedSearchMatchMessageID = selectedSearchMatchMessageID
    self.selectedSearchMatchPageIndex = selectedSearchMatchPageIndex
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ChatBubbleView(
        message: round.trigger,
        runtime: store.selectedAIChatRuntime,
        destinationTitlesByID: store.aiChatDestinationTitlesByID,
        compact: compact,
        isQueued: store.isAIChatMessageQueued(round.trigger.id),
        isSearchMatch: searchMatchMessageIDs.contains(round.trigger.id),
        isSelectedSearchMatch: selectedSearchMatchMessageID == round.trigger.id,
        selectedSearchMatchPageIndex: selectedSearchMatchPageIndex,
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
            ForEach(visibleDestinationIDs, id: \.self) { destinationID in
              agentSlot(destinationID)
                .frame(minWidth: 270, maxWidth: .infinity, alignment: .topLeading)
            }
          }
          VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleDestinationIDs, id: \.self) { destinationID in
              agentSlot(destinationID)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
          }
        }
        if omittedDestinationCount > 0 {
          Text("\(omittedDestinationCount) additional destination\(omittedDestinationCount == 1 ? "" : "s") not mounted")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityIdentifier("openclaw-room-round-omitted-destinations")
            .background {
              OpenClawMessageAccessibilityMarker(
                identifier: "openclaw-room-round-omitted-destinations",
                label: "Additional shared-room destinations not mounted"
              )
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
      searchMatchMessageIDs: searchMatchMessageIDs,
      selectedSearchMatchMessageID: selectedSearchMatchMessageID,
      selectedSearchMatchPageIndex: selectedSearchMatchPageIndex,
      isActive: store.selectedAIChatActiveRoomRoundID == round.id
        && store.selectedAIChatActiveDestinationID == destinationID
    )
  }

  private var visibleDestinationIDs: [String] {
    var visible = Array(round.expectedDestinationIDs.prefix(Self.maximumVisibleDestinationCount))
    if let selectedSearchMatchMessageID,
       let selectedDestinationID = round.expectedDestinationIDs.first(where: {
         round.response(forDestinationID: $0)?.id == selectedSearchMatchMessageID
       }),
       !visible.contains(selectedDestinationID) {
      visible.append(selectedDestinationID)
    }
    return visible
  }

  private var omittedDestinationCount: Int {
    max(0, round.expectedDestinationIDs.count - visibleDestinationIDs.count)
  }

  private var roundStatus: String {
    if round.isComplete { return "Complete" }
    return "\(round.completedCount) of \(round.expectedDestinationIDs.count) complete"
  }
}

private struct AIChatRoomAgentSlot: View {
  @Environment(WorkspaceStore.self) private var store
  let round: AIChatRoomRound
  let destinationID: String
  let compact: Bool
  let searchMatchMessageIDs: Set<UUID>
  let selectedSearchMatchMessageID: UUID?
  let selectedSearchMatchPageIndex: Int
  let isActive: Bool

  private var runtime: AIChatRuntime { store.aiChatDestinationRuntime(destinationID) }
  private var destinationTitle: String { store.aiChatDestinationTitle(destinationID) }
  private var destinationSystemImage: String {
    store.aiChatDestination(id: destinationID)?.systemImage ?? runtime.systemImage
  }

  var body: some View {
    Group {
      if let response = round.response(forDestinationID: destinationID) {
        ChatBubbleView(
          message: response,
          runtime: runtime,
          destinationTitlesByID: store.aiChatDestinationTitlesByID,
          compact: true,
          isRoomResponse: true,
          isSearchMatch: searchMatchMessageIDs.contains(response.id),
          isSelectedSearchMatch: selectedSearchMatchMessageID == response.id,
          selectedSearchMatchPageIndex: selectedSearchMatchPageIndex
        )
      } else if isActive {
        VStack(alignment: .leading, spacing: 6) {
          Label(destinationTitle, systemImage: destinationSystemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          OpenClawLiveTypingIndicatorView(
            liveState: store.openClawLiveState,
            threadID: store.selectedOpenClawChatThreadID,
            startedAt: store.openClawRequestStartedAt,
            runtime: runtime,
            destinationTitle: destinationTitle,
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
  struct Input: Sendable {
    let role: OpenClawChatMessage.Role
    let content: String
    let attachmentFileNames: [String]

    nonisolated init(_ message: OpenClawChatMessage) {
      role = message.role
      content = message.content
      attachmentFileNames = message.attachments.map(\.fileName)
    }
  }

  nonisolated static func text(for message: OpenClawChatMessage) -> String {
    text(for: Input(message))
  }

  nonisolated static func text(for input: Input) -> String {
    if !input.content.isEmpty {
      let content = OpenClawContextPresentation(
        input.content,
        extractsContexts: input.role == .user
      ).clipboardText
      return AIChatRichClipboard.alignedMessage(input.role == .assistant
        ? OpenClawMessageOrgNormalizer.normalized(content)
        : content)
    }
    return input.attachmentFileNames.map { "[Attachment: \($0)]" }.joined(separator: "\n")
  }

  @MainActor
  @discardableResult
  static func copy(
    _ input: Input,
    to pasteboard: NSPasteboard = .general
  ) async -> Bool {
    let preparedText = await Task.detached(priority: .userInitiated) {
      text(for: input)
    }.value
    guard !Task.isCancelled else { return false }
    return write(preparedText, html: AIChatRichClipboard.messageHTML(preparedText), to: pasteboard)
  }

  @MainActor
  @discardableResult
  static func copy(
    _ message: OpenClawChatMessage,
    to pasteboard: NSPasteboard = .general
  ) -> Bool {
    let text = text(for: message)
    return write(text, html: AIChatRichClipboard.messageHTML(text), to: pasteboard)
  }

  nonisolated static func codeSnippetText(lines: [String]) -> String {
    lines.joined(separator: "\n")
  }

  @MainActor
  @discardableResult
  static func copyCodeSnippet(
    lines: [String],
    to pasteboard: NSPasteboard = .general
  ) -> Bool {
    write(codeSnippetText(lines: lines), to: pasteboard)
  }

  @MainActor
  @discardableResult
  static func write(_ text: String, html: String? = nil, to pasteboard: NSPasteboard = .general) -> Bool {
    let item = NSPasteboardItem()
    guard item.setString(text, forType: .string) else { return false }
    if let html { item.setString(html, forType: .html) }
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }
}

private struct OpenClawContextPillsView: View {
  @Environment(WorkspaceStore.self) private var store
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
  @Environment(WorkspaceStore.self) private var store
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
  @Environment(WorkspaceStore.self) private var store
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
        OpenClawAsyncAttachmentImage(attachment: attachment) { error in
          Group {
            if error != nil {
              Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            Image(systemName: OpenClawAttachmentPresentation.systemImage(for: attachment.mimeType))
              .font(.title3)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
  @Environment(WorkspaceStore.self) private var store
  @State private var localDraft = ""
  @State private var lastStoreDraft = ""
  @State private var selectedSlashSuggestionIndex = 0
  @State private var selectedMentionSuggestionIndex = 0
  @State private var moveComposerCursorToEndRequest = 0
  @State private var corpusSkillDiscoveryTask: Task<Void, Never>?
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
                ? "Add context, or @mention an agent or file…"
                : "Message \(store.selectedAIChatDestination.title), or @mention a file…"
            )
              .font(.body)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 10)
              .padding(.vertical, 9)
          }

          OpenClawComposerTextView(
            text: visibleDraftBinding,
            focusOnAppear: focusOnAppear,
            moveCursorToEndRequest: moveComposerCursorToEndRequest,
            onReturn: handleReturn,
            onSuggestionCommand: handleSuggestionCommand,
            onDropAttachment: handleDropAttachment,
            onPasteLargeText: { text in
              store.attachOpenClawAttachment(
                data: Data(text.utf8), fileName: "Pasted Text.txt", mimeType: "text/plain"
              )
            }
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

      footer
    }
    .onAppear {
      localDraft = store.openClawDraft
      lastStoreDraft = store.openClawDraft
      cacheDraftLocally()
    }
    .onDisappear {
      corpusSkillDiscoveryTask?.cancel()
      flushDraftToStore()
    }
    .onChange(of: localDraft) {
      selectedSlashSuggestionIndex = 0
      selectedMentionSuggestionIndex = 0
      cacheDraftLocally()
      if OpenClawContextPresentation(localDraft).userText == "/" {
        refreshCorpusAgentSkills()
        if store.selectedAIChatDestination.adapter == .openClaw {
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

  private var footer: some View {
    ViewThatFits(in: .horizontal) {
      composerFooter(showsDetailedConfiguration: true)
      composerFooter(showsDetailedConfiguration: false)
      VStack(alignment: .leading, spacing: 6) {
        compactConfigurationControls
        HStack(spacing: 5) {
          composerStatus(compact: true)
          Spacer(minLength: 0)
          composerActionButtons
            .labelStyle(.iconOnly)
        }
      }
    }
  }

  private func refreshCorpusAgentSkills() {
    corpusSkillDiscoveryTask?.cancel()
    guard let requestedRoot = store.corpusRoot?.standardizedFileURL else { return }
    corpusSkillDiscoveryTask = Task { @MainActor in
      _ = await CorpusAgentSkillCatalog.prepareCommands(
        in: requestedRoot,
        force: true
      )
      guard !Task.isCancelled,
            store.corpusRoot?.standardizedFileURL == requestedRoot
      else {
        return
      }
      // This call now only installs the already prepared cache entry. Directory
      // enumeration and SKILL.md reads happened on the detached loader above.
      store.refreshCorpusAgentSkills()
      corpusSkillDiscoveryTask = nil
    }
  }

  private func composerFooter(showsDetailedConfiguration: Bool) -> some View {
    HStack(spacing: showsDetailedConfiguration ? 8 : 5) {
      composerStatus(compact: !showsDetailedConfiguration)
      Spacer(minLength: 0)
      if showsDetailedConfiguration {
        detailedConfigurationControls
        composerActionButtons
      } else {
        compactConfigurationControls
        composerActionButtons
          .labelStyle(.iconOnly)
      }
    }
  }

  @ViewBuilder
  private var compactConfigurationControls: some View {
    if store.selectedAIChatIsSharedRoom {
      Menu {
        ForEach(store.selectedAIChatRoomDestinationIDs, id: \.self) { destinationID in
          roomModelPicker(forDestinationID: destinationID)
        }
      } label: {
        Label("Models", systemImage: "cpu")
          .font(.caption.weight(.medium))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Shared room models")
    } else {
      HStack(spacing: 2) {
        runtimePicker(iconOnly: true)
        modelPicker
        if !store.selectedAIChatDestination.adapter.isDirectProvider {
          reasoningPicker(iconOnly: true)
        }
      }
    }
  }

  @ViewBuilder
  private func composerStatus(compact compactStatus: Bool) -> some View {
    if store.isSendingOpenClawMessage && !compactStatus {
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
          .frame(width: compactStatus ? 42 : (compact ? 72 : 110), height: 7)
      }
      .help("Recording \(store.selectedAIChatDisplayTitle) dictation")
    } else if store.isTranscribingOpenClawVoiceNote {
      if compactStatus {
        ProgressView(value: store.openClawVoiceTranscriptionProgress)
          .progressViewStyle(.circular)
          .controlSize(.small)
          .help("Transcribing \(store.openClawVoiceTranscriptionElapsedText)")
      } else {
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
        .help("Estimated local dictation transcription progress")
      }
    }
  }

  @ViewBuilder
  private var detailedConfigurationControls: some View {
    if store.selectedAIChatIsSharedRoom {
      ForEach(store.selectedAIChatRoomDestinationIDs, id: \.self) { destinationID in
        roomModelPicker(forDestinationID: destinationID)
      }
    } else {
      runtimePicker()
      modelPicker
      if !store.selectedAIChatDestination.adapter.isDirectProvider {
        reasoningPicker()
      }
    }
  }

  @ViewBuilder
  private var composerActionButtons: some View {
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
      .help("Steer the current turn now (⌘Return)")
    }
  }

  private func runtimePicker(iconOnly: Bool = false) -> some View {
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
        if !iconOnly { Text(store.selectedAIChatDestination.title) }
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
    .accessibilityLabel("AI destination: \(store.selectedAIChatDestination.title)")
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
        Image(systemName: destination?.systemImage ?? runtime.systemImage)
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
    .accessibilityIdentifier("ai-chat-model-picker")
    .accessibilityLabel("Model: \(store.selectedAIChatModelLabel)")
    .help("Choose a model for this chat, or inherit the \(store.selectedAIChatDestination.title) default")
  }

  private func reasoningPicker(iconOnly: Bool = false) -> some View {
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
        if !iconOnly {
          Text(store.selectedAIChatReasoningLabel)
            .lineLimit(1)
        }
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
    .accessibilityLabel("Reasoning effort: \(store.selectedAIChatReasoningLabel)")
    .help("Reasoning effort: \(store.selectedAIChatReasoningLabel)")
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
      return "Queue behind the current turn. Press Command-Return to steer now."
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
    moveComposerCursorToEndRequest &+= 1
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
    performPrimaryAction(
      delivery: OpenClawComposerKeyCommand.resolvedDelivery(
        requested: delivery,
        isRunning: isRunning
      )
    )
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
    in suggestions: [AIChatComposerMentionSuggestion]
  ) -> AIChatComposerMentionSuggestion? {
    guard !suggestions.isEmpty else { return nil }
    return suggestions[min(max(0, selectedMentionSuggestionIndex), suggestions.count - 1)]
  }

  private func completeMention(_ suggestion: AIChatComposerMentionSuggestion) {
    let presentation = OpenClawContextPresentation(localDraft)
    switch suggestion {
    case .destination(let destination):
      localDraft = presentation.replacingUserText(
        destination.completingMention(in: presentation.userText)
      )
    case .corpusFile(let file):
      let draftWithoutMention = presentation.replacingUserText(
        AIChatMentionSuggestion.removingActiveMention(in: presentation.userText)
      )
      localDraft = store.openClawDraftByAddingCorpusFileContext(file, to: draftWithoutMention)
    }
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

  private func mentionSuggestions(for text: String) -> [AIChatComposerMentionSuggestion] {
    AIChatComposerMentionSuggestion.suggestions(
      for: text,
      destinations: store.enabledAIChatDestinations,
      allDestinationIDs: store.selectedAIChatIsSharedRoom
        ? store.selectedAIChatRoomDestinationIDs
        : store.enabledAIChatDestinations.map(\.id),
      corpusFiles: store.corpusFiles
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
    case .builtInSkill, .corpusSkill: "Skill"
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

  static func activeMentionQuery(in text: String) -> String? {
    guard let range = activeMentionRange(in: text) else { return nil }
    return String(text[range].dropFirst())
  }

  static func removingActiveMention(in text: String) -> String {
    guard let range = activeMentionRange(in: text) else { return text }
    return text.replacingCharacters(in: range, with: "")
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

enum AIChatComposerMentionSuggestion: Identifiable, Equatable {
  case destination(AIChatMentionSuggestion)
  case corpusFile(CorpusFile)

  var id: String {
    switch self {
    case .destination(let suggestion): "destination:\(suggestion.id)"
    case .corpusFile(let file): "file:\(file.id)"
    }
  }

  var title: String {
    switch self {
    case .destination(let suggestion): suggestion.title
    case .corpusFile(let file): file.name
    }
  }

  var detail: String {
    switch self {
    case .destination(let suggestion): suggestion.detail
    case .corpusFile(let file): file.relativePath
    }
  }

  var systemImage: String {
    switch self {
    case .destination(let suggestion): suggestion.systemImage
    case .corpusFile: "doc.text"
    }
  }

  static func suggestions(
    for text: String,
    destinations: [AIChatDestinationConfiguration],
    allDestinationIDs: [String],
    corpusFiles: [CorpusFile],
    limit: Int = 10
  ) -> [AIChatComposerMentionSuggestion] {
    guard let query = AIChatMentionSuggestion.activeMentionQuery(in: text) else { return [] }
    let destinationSuggestions = AIChatMentionSuggestion.suggestions(
      for: text,
      destinations: destinations,
      allDestinationIDs: allDestinationIDs
    )
    let fileLimit = max(0, limit - destinationSuggestions.count)
    let matchingFiles: [CorpusFile]
    if query.isEmpty {
      matchingFiles = Array(corpusFiles.prefix(fileLimit))
    } else {
      matchingFiles = WorkspaceStore.searchCorpusFilesForWorkspace(
        corpusFiles,
        query: query,
        limit: fileLimit
      )
    }
    return Array(
      (destinationSuggestions.map(AIChatComposerMentionSuggestion.destination)
        + matchingFiles.map(AIChatComposerMentionSuggestion.corpusFile))
        .prefix(limit)
    )
  }
}

private struct AIChatMentionSuggestionsView: View {
  let suggestions: [AIChatComposerMentionSuggestion]
  let selectedSuggestionID: AIChatComposerMentionSuggestion.ID?
  let select: (AIChatComposerMentionSuggestion) -> Void

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
  @Environment(WorkspaceStore.self) private var store
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
  @Environment(WorkspaceStore.self) private var store
  let attachment: OpenClawChatAttachment
  @State private var isPreviewing = false

  var body: some View {
    HStack(spacing: 7) {
      Button {
        isPreviewing = true
      } label: {
        HStack(spacing: 7) {
          OpenClawAsyncAttachmentImage(attachment: attachment) { error in
            Image(systemName: error == nil
              ? OpenClawAttachmentPresentation.systemImage(for: attachment.mimeType)
              : "exclamationmark.triangle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            .frame(width: 30, height: 30)
            .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
          }
          .frame(width: 30, height: 30)
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

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
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Preview attachment")

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
    .sheet(isPresented: $isPreviewing) {
      OpenClawAttachmentPreviewView(attachment: attachment)
    }
  }
}

enum OpenClawComposerSizing {
  static func height(for text: String, compact: Bool) -> CGFloat {
    // Both layouts reach their height cap within this prefix. Do not scan a
    // restored large draft on every keystroke after it has reached that cap.
    let visualLineCount = estimatedVisualLineCount(for: String(text.prefix(576)), compact: compact)
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
    return isReturnKey(keyCode)
      && (relevantModifiers == [.command] || relevantModifiers == [.command, .shift])
  }

  static func isNewlineCommand(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
    return isReturnKey(keyCode) && relevantModifiers == [.shift]
  }

  static func resolvedDelivery(
    requested: AIChatMessageDeliveryPreference,
    isRunning: Bool
  ) -> AIChatMessageDeliveryPreference {
    if requested == .steer && !isRunning {
      return .automatic
    }
    return requested
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

struct OpenClawComposerTextView: NSViewRepresentable {
  @Binding var text: String
  let focusOnAppear: Bool
  let moveCursorToEndRequest: Int
  let onReturn: (AIChatMessageDeliveryPreference) -> Bool
  let onSuggestionCommand: (OpenClawComposerSuggestionKeyCommand) -> Bool
  let onDropAttachment: (OpenClawComposerDropPayload) -> Bool
  let onPasteLargeText: (String) -> Bool

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
    textView.onPasteLargeText = { context.coordinator.parent.onPasteLargeText($0) }
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
    context.coordinator.textSynchronization = OpenClawComposerTextSynchronization(
      initialModelText: text
    )

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
    textView.onPasteLargeText = { context.coordinator.parent.onPasteLargeText($0) }
    let movesCursorToEnd = context.coordinator.lastMoveCursorToEndRequest != moveCursorToEndRequest
    let selectedRange = textView.selectedRange()
    // AppKit can accept another keystroke before SwiftUI presents the state
    // from the previous one. Never replace that newer native edit with its
    // delayed model echo, because doing so also restores an older selection.
    let modelUpdate = context.coordinator.textSynchronization.modelTextUpdate(
      text,
      forced: movesCursorToEnd
    )
    let textChanged = modelUpdate == .applyModelText && textView.string != text
    if textChanged {
      context.coordinator.isApplyingModelText = true
      textView.string = text
      context.coordinator.isApplyingModelText = false
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
    var textSynchronization = OpenClawComposerTextSynchronization()
    var isApplyingModelText = false

    init(parent: OpenClawComposerTextView) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard !isApplyingModelText,
            let textView = notification.object as? NSTextView
      else { return }
      let nativeText = textView.string
      textSynchronization.nativeTextDidChange(nativeText)
      parent.text = nativeText
    }
  }

  final class CommandSubmitTextView: NSTextView {
    var onReturn: ((AIChatMessageDeliveryPreference) -> Bool)?
    var onSuggestionCommand: ((OpenClawComposerSuggestionKeyCommand) -> Bool)?
    var onDropAttachment: ((OpenClawComposerDropPayload) -> Bool)?
    var onPasteLargeText: ((String) -> Bool)?
    private var pendingLatencyTokens: [WorkspaceInteractionLatency.Token] = []

    @discardableResult
    func attachLargePaste(from pasteboard: NSPasteboard) -> Bool {
      guard let text = pasteboard.string(forType: .string),
            AIChatLargePaste.shouldAttach(text)
      else { return false }
      return onPasteLargeText?(text) == true
    }

    override func paste(_ sender: Any?) {
      if !attachLargePaste(from: .general) { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
      if !attachLargePaste(from: .general) { super.pasteAsPlainText(sender) }
    }

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

enum OpenClawComposerModelTextUpdate: Equatable {
  case applyModelText
  case preserveNativeText
}

struct OpenClawComposerTextSynchronization {
  private var pendingNativeTexts: [String] = []
  private var lastModelText: String?

  init(initialModelText: String? = nil) {
    lastModelText = initialModelText
  }

  mutating func nativeTextDidChange(_ text: String) {
    if pendingNativeTexts.isEmpty, let lastModelText {
      pendingNativeTexts.append(lastModelText)
    }
    guard pendingNativeTexts.last != text else { return }
    pendingNativeTexts.append(text)
  }

  mutating func modelTextUpdate(
    _ text: String,
    forced: Bool = false
  ) -> OpenClawComposerModelTextUpdate {
    lastModelText = text
    if forced {
      pendingNativeTexts.removeAll(keepingCapacity: true)
      return .applyModelText
    }

    if let acknowledgedIndex = pendingNativeTexts.lastIndex(of: text) {
      pendingNativeTexts.removeFirst(acknowledgedIndex + 1)
      return .preserveNativeText
    }

    pendingNativeTexts.removeAll(keepingCapacity: true)
    return .applyModelText
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
  let destinationTitle: String?
  let compact: Bool
  let onStop: () -> Void

  var body: some View {
    let presentationSnapshot = threadID.map(liveState.presentationSnapshot(for:)) ?? .empty
    OpenClawTypingIndicatorView(
      startedAt: startedAt,
      lastEventAt: threadID.flatMap(liveState.lastEventAt(for:)),
      runtime: runtime,
      destinationTitle: destinationTitle,
      connectionState: threadID.map(liveState.connectionState(for:)) ?? .disconnected,
      connectionDetail: threadID.flatMap(liveState.connectionDetail(for:)),
      runID: threadID.flatMap(liveState.activeRunID(for:)),
      streamingReply: presentationSnapshot.streamingReply,
      streamingReplyHasOmittedPrefix: presentationSnapshot.isStreamingReplyTruncated,
      reasoning: presentationSnapshot.reasoning,
      reasoningHasOmittedPrefix: presentationSnapshot.isReasoningTruncated,
      activities: threadID.map(liveState.runActivities(for:)) ?? [],
      compact: compact,
      onStop: onStop
    )
  }
}

struct OpenClawLiveTextPreparationInput: Equatable, Sendable {
  static let maximumActivityCount = 80
  static let maximumActivityDetailUTF8ByteCount = 8 * 1_024

  let rawText: String
  let showsAll: Bool
  let hasOmittedPrefix: Bool
  let reasoning: String
  let reasoningHasOmittedPrefix: Bool
  let activities: [OpenClawRunActivity]

  init(
    rawText: String,
    showsAll: Bool,
    hasOmittedPrefix: Bool = false,
    reasoning: String = "",
    reasoningHasOmittedPrefix: Bool = false,
    activities: [OpenClawRunActivity] = []
  ) {
    self.rawText = rawText
    self.showsAll = showsAll
    self.hasOmittedPrefix = hasOmittedPrefix
    self.reasoning = reasoning
    self.reasoningHasOmittedPrefix = reasoningHasOmittedPrefix
    self.activities = activities.suffix(Self.maximumActivityCount).map { activity in
      OpenClawRunActivity(
        id: String(activity.id.prefix(256)),
        runID: String(activity.runID.prefix(256)),
        kind: activity.kind,
        title: String(activity.title.prefix(512)),
        detail: activity.detail.map {
          OpenClawMessageBodyExcerpt(
            $0,
            utf8ByteLimit: Self.maximumActivityDetailUTF8ByteCount
          ).text
        },
        status: activity.status,
        updatedAt: activity.updatedAt
      )
    }
  }
}

struct OpenClawPreparedLiveTextPresentation: Equatable, Sendable {
  let text: OpenClawProgressPresentation.LiveTextPresentation?
  let body: OpenClawPreparedMessageBody?
  let reasoning: String?
  let activityFeedItems: [OpenClawActivityFeedItem]
}

private struct OpenClawLiveTextPreparationTaskKey: Equatable {
  let lastEventAt: Date?
  let showsAll: Bool
  let streamingCharacterCount: Int
  let reasoningCharacterCount: Int
  let activityCount: Int
  let latestActivityUpdate: Date?
}

actor OpenClawLiveTextPreparationCoordinator {
  static let shared = OpenClawLiveTextPreparationCoordinator()

  private struct Entry {
    let token: UUID
    let input: OpenClawLiveTextPreparationInput
    let task: Task<OpenClawPreparedLiveTextPresentation?, Never>
  }

  private var entries: [UUID: [Entry]] = [:]
  private var tailTask: Task<OpenClawPreparedLiveTextPresentation?, Never>?
  private var tailToken: UUID?
  private var preparationCountForTesting = 0
  private var activeWorkerCountValueForTesting = 0
  private var peakConcurrentWorkerCountValueForTesting = 0
  private var activeTokensByStream: [UUID: UUID] = [:]
  private var parserInputsForTesting: [OpenClawLiveTextPreparationInput] = []
  private var pausesWorkersForTesting = false
  private var pausedWorkerContinuationsForTesting: [CheckedContinuation<Void, Never>] = []

  func prepare(
    streamID: UUID,
    input: OpenClawLiveTextPreparationInput
  ) async -> OpenClawPreparedLiveTextPresentation? {
    let token: UUID
    let task: Task<OpenClawPreparedLiveTextPresentation?, Never>
    if let existing = entries[streamID]?.first(where: {
      $0.input == input && !$0.task.isCancelled
    }) {
      token = existing.token
      task = existing.task
    } else {
      let activeToken = activeTokensByStream[streamID]
      let retainedEntries = entries[streamID]?.filter { entry in
        if entry.token == activeToken { return true }
        entry.task.cancel()
        return false
      } ?? []
      if retainedEntries.isEmpty {
        entries.removeValue(forKey: streamID)
      } else {
        entries[streamID] = retainedEntries
      }
      let previousTask = tailTask
      token = UUID()
      task = Task.detached(priority: .userInitiated) {
        if let previousTask {
          _ = await previousTask.value
        }
        guard !Task.isCancelled else { return nil }
        await self.workerDidStart(streamID: streamID, token: token)
        guard !Task.isCancelled else {
          await self.workerDidFinish(streamID: streamID, token: token)
          return nil
        }
        await self.parserWillStart(input: input)
        let text = OpenClawProgressPresentation.liveTextPresentation(
          from: input.rawText,
          showsAll: input.showsAll,
          hasOmittedPrefix: input.hasOmittedPrefix
        )
        let body = text.flatMap {
          OpenClawMessagePresentationBuilder.prepareExpandedBody(
            sourceText: $0.text,
            role: .assistant
          )
        }
        let reasoning = OpenClawProgressPresentation.reasoningText(
          from: input.reasoning,
          hasOmittedPrefix: input.reasoningHasOmittedPrefix
        )
        let activityFeedItems = OpenClawActivityFeed.items(from: input.activities)
        let prepared = body == nil && reasoning == nil && activityFeedItems.isEmpty
          ? nil
          : OpenClawPreparedLiveTextPresentation(
            text: text,
            body: body,
            reasoning: reasoning,
            activityFeedItems: activityFeedItems
          )
        await self.workerDidFinish(streamID: streamID, token: token)
        return prepared
      }
      entries[streamID, default: []].append(Entry(
        token: token,
        input: input,
        task: task
      ))
      tailTask = task
      tailToken = token
      preparationCountForTesting += 1
    }
    let prepared = await task.value
    removeFinishedEntry(streamID: streamID, token: token)
    if tailToken == token {
      tailTask = nil
      tailToken = nil
    }
    return Task.isCancelled ? nil : prepared
  }

  private func removeFinishedEntry(streamID: UUID, token: UUID) {
    guard var streamEntries = entries[streamID] else { return }
    streamEntries.removeAll { $0.token == token }
    if streamEntries.isEmpty {
      entries.removeValue(forKey: streamID)
    } else {
      entries[streamID] = streamEntries
    }
  }

  private func workerDidStart(streamID: UUID, token: UUID) async {
    activeWorkerCountValueForTesting += 1
    peakConcurrentWorkerCountValueForTesting = max(
      peakConcurrentWorkerCountValueForTesting,
      activeWorkerCountValueForTesting
    )
    activeTokensByStream[streamID] = token
    guard pausesWorkersForTesting else { return }
    await withCheckedContinuation { continuation in
      pausedWorkerContinuationsForTesting.append(continuation)
    }
  }

  private func parserWillStart(input: OpenClawLiveTextPreparationInput) {
    parserInputsForTesting.append(input)
  }

  private func workerDidFinish(streamID: UUID, token: UUID) {
    activeWorkerCountValueForTesting -= 1
    if activeTokensByStream[streamID] == token {
      activeTokensByStream.removeValue(forKey: streamID)
    }
  }

  func resetForTesting() async {
    setWorkersPausedForTesting(false)
    let pendingTasks = entries.values.flatMap { $0 }.map(\.task)
    for task in pendingTasks {
      _ = await task.value
    }
    entries.removeAll()
    tailTask = nil
    tailToken = nil
    preparationCountForTesting = 0
    activeWorkerCountValueForTesting = 0
    peakConcurrentWorkerCountValueForTesting = 0
    activeTokensByStream.removeAll()
    parserInputsForTesting.removeAll()
  }

  func countForTesting() -> Int { preparationCountForTesting }
  func activeWorkerCountForTesting() -> Int { activeWorkerCountValueForTesting }
  func peakConcurrentWorkerCountForTesting() -> Int { peakConcurrentWorkerCountValueForTesting }
  func parserInputsForTestingSnapshot() -> [OpenClawLiveTextPreparationInput] {
    parserInputsForTesting
  }

  func setWorkersPausedForTesting(_ paused: Bool) {
    pausesWorkersForTesting = paused
    guard !paused else { return }
    let continuations = pausedWorkerContinuationsForTesting
    pausedWorkerContinuationsForTesting.removeAll()
    continuations.forEach { $0.resume() }
  }
}

struct OpenClawTypingIndicatorView: View {
  static let quietRunInterval: TimeInterval = 2 * 60
  static let stalledRunInterval: TimeInterval = 10 * 60

  let startedAt: Date?
  let lastEventAt: Date?
  let runtime: AIChatRuntime
  let destinationTitle: String?
  let connectionState: OpenClawGatewayConnectionState
  let connectionDetail: String?
  let runID: String?
  let streamingReply: String
  let streamingReplyHasOmittedPrefix: Bool
  let reasoning: String
  let reasoningHasOmittedPrefix: Bool
  let activities: [OpenClawRunActivity]
  let compact: Bool
  let onStop: () -> Void

  @State private var showsAllStreamingProgress = false
  @State private var statusEvaluationDate = Date()
  @State private var livePresentation: OpenClawPreparedLiveTextPresentation?
  @State private var livePresentationStreamID = UUID()

  init(
    startedAt: Date?,
    lastEventAt: Date? = nil,
    runtime: AIChatRuntime = .openClaw,
    destinationTitle: String? = nil,
    connectionState: OpenClawGatewayConnectionState,
    connectionDetail: String?,
    runID: String?,
    streamingReply: String,
    streamingReplyHasOmittedPrefix: Bool = false,
    reasoning: String,
    reasoningHasOmittedPrefix: Bool = false,
    activities: [OpenClawRunActivity],
    compact: Bool,
    onStop: @escaping () -> Void
  ) {
    self.startedAt = startedAt
    self.lastEventAt = lastEventAt
    self.runtime = runtime
    self.destinationTitle = destinationTitle
    self.connectionState = connectionState
    self.connectionDetail = connectionDetail
    self.runID = runID
    self.streamingReply = streamingReply
    self.streamingReplyHasOmittedPrefix = streamingReplyHasOmittedPrefix
    self.reasoning = reasoning
    self.reasoningHasOmittedPrefix = reasoningHasOmittedPrefix
    self.activities = activities
    self.compact = compact
    self.onStop = onStop
  }

  var body: some View {
    let livePresentationInput = OpenClawLiveTextPreparationInput(
      rawText: streamingReply,
      showsAll: showsAllStreamingProgress,
      hasOmittedPrefix: streamingReplyHasOmittedPrefix,
      reasoning: reasoning,
      reasoningHasOmittedPrefix: reasoningHasOmittedPrefix,
      activities: activities
    )
    let livePresentationTaskKey = OpenClawLiveTextPreparationTaskKey(
      lastEventAt: lastEventAt,
      showsAll: showsAllStreamingProgress,
      streamingCharacterCount: streamingReply.count,
      reasoningCharacterCount: reasoning.count,
      activityCount: activities.count,
      latestActivityUpdate: activities.last?.updatedAt
    )
    let presentedActivityItems = livePresentation?.activityFeedItems ?? []
    let presentedReasoning = livePresentation?.reasoning
    HStack {
      VStack(alignment: .leading, spacing: 9) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            OpenClawShimmeringStatusText(
              titleProvider: {
                statusTitle(
                  now: $0,
                  activityFeedItems: presentedActivityItems,
                  hasReasoning: presentedReasoning != nil
                )
              },
              animates: statusAnimates(now: statusEvaluationDate)
            )
            AppKitPeriodicLabel(
              font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
              color: .tertiaryLabelColor,
              textProvider: { elapsedText(now: $0) }
            )
            .frame(width: 58, height: 14, alignment: .leading)
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
              .accessibilityLabel("Stop \(displayTitle) run")
              .help("Stop this \(displayTitle) run")
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

        if let livePresentation,
           let text = livePresentation.text,
           let body = livePresentation.body {
          OpenClawMessageBodyView(
            rawText: body.displayedText,
            compact: compact,
            managesTextSelection: false,
            rendersStructuredOrg2: true,
            structuredPresentation: body.org,
            containsInlineSyntax: body.containsInlineSyntax,
            allowsSynchronousStructuredPresentationFallback: false
          )
          .accessibilityIdentifier("openclaw-live-presentation-ready")
          .background {
            OpenClawMessageAccessibilityMarker(
              identifier: "openclaw-live-presentation-ready",
              label: "Live response presentation ready"
            )
          }

          if text.hasEarlierText {
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

        if !presentedActivityItems.isEmpty || presentedReasoning != nil {
          OpenClawProgressFeedView(
            reasoning: "",
            activities: [],
            compact: compact,
            isLive: true,
            presentedItems: presentedActivityItems,
            presentedReasoning: presentedReasoning
          )
        }
      }
      .padding(10)
      .frame(maxWidth: compact ? 430 : 700, alignment: .leading)
      Spacer(minLength: compact ? 24 : 48)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: livePresentationTaskKey) {
      do {
        try await Task.sleep(for: .milliseconds(24))
      } catch {
        return
      }
      let prepared = await OpenClawLiveTextPreparationCoordinator.shared.prepare(
        streamID: livePresentationStreamID,
        input: livePresentationInput
      )
      guard !Task.isCancelled else { return }
      livePresentation = prepared
    }
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
    statusTitle(
      now: now,
      activityFeedItems: OpenClawActivityFeed.items(from: activities),
      hasReasoning: hasReasoning
    )
  }

  private func statusTitle(
    now: Date,
    activityFeedItems: [OpenClawActivityFeedItem],
    hasReasoning: Bool
  ) -> String {
    if connectionState == .connected, runID != nil {
      if runLivenessAge(now: now) >= Self.stalledRunInterval {
        return "\(displayTitle) may be stalled"
      }
      if runLivenessAge(now: now) >= Self.quietRunInterval {
        return "Waiting for \(displayTitle)"
      }
    }
    if destinationTitle != nil {
      switch connectionState {
      case .connecting:
        return "Connecting to \(displayTitle)"
      case .reconnecting:
        return "Reconnecting to \(displayTitle)"
      case .fallbackHTTP:
        return "\(displayTitle) is working over HTTP"
      case .disconnected:
        return "\(displayTitle) connection interrupted"
      case .connected:
        if let latest = activityFeedItems.last(where: { $0.status == .running }) {
          return "Running \(latest.title.lowercased())"
        }
        if runID == nil {
          return "Starting \(displayTitle)"
        }
        if hasReasoning {
          return "\(displayTitle) is thinking"
        }
        return "\(displayTitle) is working"
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
        if let latest = activityFeedItems.last(where: { $0.status == .running }) {
          return "Running \(latest.title.lowercased())"
        }
        if runID == nil {
          return "Starting Codex"
        }
        if hasReasoning {
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
      if let latest = activityFeedItems.last(where: { $0.status == .running }) {
        return "Running \(latest.title.lowercased())"
      }
      if runID == nil {
        return "Starting OpenClaw"
      }
      if hasReasoning {
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

  private var displayTitle: String {
    let normalized = destinationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return normalized.isEmpty ? runtime.title : normalized
  }

  private var hasReasoning: Bool {
    OpenClawProgressPresentation.containsNonWhitespace(reasoning)
  }

  private var hasProgress: Bool {
    !OpenClawActivityFeed.items(from: activities).isEmpty || hasReasoning
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
  let reasoningHasOmittedPrefix: Bool
  let preparedReasoning: String?

  @State private var showsFullFeed = false

  init(
    reasoning: String,
    activities: [OpenClawRunActivity],
    compact: Bool,
    isLive: Bool,
    presentedItems: [OpenClawActivityFeedItem]? = nil,
    reasoningHasOmittedPrefix: Bool = false,
    presentedReasoning: String? = nil
  ) {
    self.reasoning = reasoning
    self.activities = activities
    self.compact = compact
    self.isLive = isLive
    self.presentedItems = presentedItems
    self.reasoningHasOmittedPrefix = reasoningHasOmittedPrefix
    preparedReasoning = presentedReasoning
  }

  private var items: [OpenClawActivityFeedItem] {
    presentedItems ?? OpenClawActivityFeed.items(from: activities)
  }

  private var presentedReasoning: String? {
    preparedReasoning ?? OpenClawProgressPresentation.reasoningText(
      from: reasoning,
      hasOmittedPrefix: reasoningHasOmittedPrefix
    )
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

      let omittedExpandedItemCount = OpenClawProgressFeedPresentation.omittedExpandedItemCount(
        itemCount: items.count,
        isExpanded: showsFullFeed
      )
      if omittedExpandedItemCount > 0 {
        Text("Showing the latest \(OpenClawProgressFeedPresentation.maximumExpandedItemCount) of \(items.count) updates. Earlier updates remain in the durable run record.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
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
  static let maximumExpandedItemCount = 96

  static func visibleItems(
    _ items: [OpenClawActivityFeedItem],
    isLive: Bool,
    isExpanded: Bool,
    collapsedItemLimit: Int
  ) -> [OpenClawActivityFeedItem] {
    if isLive {
      guard !isExpanded else { return Array(items.suffix(maximumExpandedItemCount)) }
      return items.last(where: { $0.status == .running }).map { [$0] }
        ?? items.last.map { [$0] }
        ?? []
    }
    return isExpanded
      ? Array(items.suffix(maximumExpandedItemCount))
      : Array(items.suffix(collapsedItemLimit))
  }

  static func omittedExpandedItemCount(itemCount: Int, isExpanded: Bool) -> Int {
    guard isExpanded else { return 0 }
    return max(0, itemCount - maximumExpandedItemCount)
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
    switch item.status {
    case .running: return "wrench.and.screwdriver"
    case .succeeded: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    }
  }
}

enum OpenClawProgressPresentation {
  struct LiveTextPresentation: Equatable, Sendable {
    let text: String
    let hasEarlierText: Bool
  }

  private static let maximumReasoningLength = 1_200
  static let maximumReasoningInputUTF8ByteCount = 8 * 1_024
  static let maximumLiveNormalizationInputCharacterCount = 8 * 1_024
  private static let maximumCollapsedLiveLength = 320

  nonisolated static func liveTextPresentation(
    from raw: String,
    showsAll: Bool,
    hasOmittedPrefix: Bool = false
  ) -> LiveTextPresentation? {
    let bounded = boundedSuffix(
      raw,
      maximumCharacterCount: maximumLiveNormalizationInputCharacterCount
    )
    let readable = normalizedReadableText(bounded.text)
    guard !readable.isEmpty else { return nil }

    let paragraphs = readable.components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let latest = paragraphs.last ?? readable
    let collapsed: String
    if latest.count > maximumCollapsedLiveLength {
      collapsed = String(latest.prefix(maximumCollapsedLiveLength - 1))
        .trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    } else {
      collapsed = latest
    }
    return LiveTextPresentation(
      text: showsAll ? readable : collapsed,
      hasEarlierText: hasOmittedPrefix || bounded.wasTruncated || collapsed != readable
    )
  }

  nonisolated static func liveText(from raw: String, showsAll: Bool) -> String? {
    liveTextPresentation(from: raw, showsAll: showsAll)?.text
  }

  nonisolated static func hasEarlierLiveText(_ raw: String) -> Bool {
    liveTextPresentation(from: raw, showsAll: false)?.hasEarlierText ?? false
  }

  nonisolated static func reasoningText(
    from raw: String,
    hasOmittedPrefix: Bool = false
  ) -> String? {
    guard containsNonWhitespace(raw) else { return nil }
    let excerpt = OpenClawMessageBodyExcerpt(
      raw,
      utf8ByteLimit: maximumReasoningInputUTF8ByteCount
    )
    let trimmed = excerpt.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let startsLikeStructuredPayload = trimmed.first == "{" || trimmed.first == "["
    if startsLikeStructuredPayload {
      return nil
    }
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
    guard hasOmittedPrefix
            || excerpt.isTruncated
            || readable.count > maximumReasoningLength
    else { return readable }
    return String(readable.prefix(maximumReasoningLength - 1))
      .trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
  }

  nonisolated static func containsNonWhitespace(_ raw: String) -> Bool {
    raw.contains { !$0.isWhitespace }
  }

  private nonisolated static func boundedSuffix(
    _ raw: String,
    maximumCharacterCount: Int
  ) -> (text: String, wasTruncated: Bool) {
    guard raw.count > maximumCharacterCount else { return (raw, false) }
    return (String(raw.suffix(maximumCharacterCount)), true)
  }

  private nonisolated static func normalizedReadableText(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\n[ \\t]*\\n(?:[ \\t]*\\n)+", with: "\n\n", options: .regularExpression)
  }
}
