import Foundation

private func mobileRemoteIsMainThread() -> Bool {
  Thread.isMainThread
}

/// A bounded, display-only projection of a chat message for remote lists and
/// notifications. The source budget is deliberately independent of the output
/// limit so context wrappers can be recognized without scanning an entire
/// multi-megabyte message on the main actor.
public struct MobileRemoteMessagePreview: Equatable, Sendable {
  public static let sourceUTF8ByteLimit = 8 * 1_024

  public let text: String
  public let sourceUTF8BytesInspected: Int
  public let sourceWasTruncated: Bool

  public init(
    text: String,
    sourceUTF8BytesInspected: Int,
    sourceWasTruncated: Bool
  ) {
    self.text = text
    self.sourceUTF8BytesInspected = sourceUTF8BytesInspected
    self.sourceWasTruncated = sourceWasTruncated
  }

  public static func make(
    from message: OpenClawChatMessage,
    characterLimit: Int
  ) -> MobileRemoteMessagePreview? {
    let bounded = unicodeSafePrefix(
      message.content,
      utf8ByteLimit: sourceUTF8ByteLimit
    )
    let visible: String
    if message.role == .user {
      visible = visibleUserPrefix(
        bounded.text,
        sourceWasTruncated: bounded.wasTruncated
      )
    } else {
      visible = bounded.text
    }
    let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return MobileRemoteMessagePreview(
      text: String(trimmed.prefix(max(0, characterLimit))),
      sourceUTF8BytesInspected: bounded.bytesInspected,
      sourceWasTruncated: bounded.wasTruncated
    )
  }

  private static func unicodeSafePrefix(
    _ source: String,
    utf8ByteLimit: Int
  ) -> (text: String, bytesInspected: Int, wasTruncated: Bool) {
    let limit = max(0, utf8ByteLimit)
    var bytes = Array(source.utf8.prefix(limit + 1))
    let inspected = bytes.count
    let wasTruncated = bytes.count > limit
    if wasTruncated {
      bytes.removeLast(bytes.count - limit)
    }

    // A byte budget can end in the middle of a scalar. Swift strings always
    // contain valid UTF-8, so at most the final three bytes need removal.
    while !bytes.isEmpty {
      if let text = String(bytes: bytes, encoding: .utf8) {
        return (text, inspected, wasTruncated)
      }
      bytes.removeLast()
    }
    return ("", inspected, wasTruncated)
  }

  private static func visibleUserPrefix(
    _ source: String,
    sourceWasTruncated: Bool
  ) -> String {
    let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
    var remaining = normalized
    var labels: [String] = []

    while let firstNewline = remaining.firstIndex(of: "\n") {
      let header = String(remaining[..<firstNewline])
      guard let title = contextTitle(from: header) else { break }
      labels.append("[Context: \(title)]")

      let afterHeader = remaining.index(after: firstNewline)
      let automaticPrefix = "#+begin_org2_ai_context\n"
      if remaining[afterHeader...].hasPrefix(automaticPrefix) {
        let promptStart = remaining.index(afterHeader, offsetBy: automaticPrefix.count)
        let endToken = "\n#+end_org2_ai_context"
        guard let endRange = remaining.range(
          of: endToken,
          range: promptStart..<remaining.endIndex
        ) else {
          // Never expose a partial automatic context body. If its closing
          // marker lies beyond the bounded scan, the safe label is sufficient.
          return labels.joined(separator: "\n")
        }
        remaining = removingContextSeparator(
          from: remaining,
          after: endRange.upperBound
        )
      } else if let separator = remaining.range(of: "\n\n") {
        remaining = String(remaining[separator.upperBound...])
      } else {
        // A bounded legacy context header may have its separator just beyond
        // the scan. Preserve only its label instead of leaking opaque source.
        return labels.joined(separator: "\n")
      }
    }

    let userText = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
    if labels.isEmpty {
      return userText
    }
    if userText.isEmpty || sourceWasTruncated && remaining == normalized {
      return labels.joined(separator: "\n")
    }
    return (labels + [userText]).joined(separator: "\n")
  }

  private static func contextTitle(from line: String) -> String? {
    guard line.hasPrefix("Use "), line.hasSuffix(" as context.") else { return nil }
    let body = String(line.dropFirst(4).dropLast(" as context.".count))
    if let quoteStart = body.range(of: " “"),
       let separator = body.range(of: "” at ", range: quoteStart.upperBound..<body.endIndex) {
      let title = String(body[quoteStart.upperBound..<separator.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return title.isEmpty ? nil : title
    }
    guard let separator = body.range(of: " at ") else { return nil }
    let kind = String(body[..<separator.lowerBound])
      .replacingOccurrences(of: "selected ", with: "", options: [.caseInsensitive, .anchored])
      .replacingOccurrences(of: "current ", with: "", options: [.caseInsensitive, .anchored])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return kind.isEmpty ? nil : kind.capitalized
  }

  private static func removingContextSeparator(
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
}

public struct MobileRemoteThreadProjectionContext: Sendable {
  public let destinationNamesByID: [String: String]
  public let runningThreadIDs: Set<UUID>

  public init(
    destinationNamesByID: [String: String],
    runningThreadIDs: Set<UUID>
  ) {
    self.destinationNamesByID = destinationNamesByID
    self.runningThreadIDs = runningThreadIDs
  }
}

public struct MobileRemoteThreadDetailProjectionContext: Sendable {
  public let threads: MobileRemoteThreadProjectionContext
  public let activeDestinationName: String?
  public let streamingReply: String
  public let reasoning: String
  public let activities: [OpenClawRunActivity]
  public let connectionState: String
  public let connectionDetail: String?

  public init(
    threads: MobileRemoteThreadProjectionContext,
    activeDestinationName: String?,
    streamingReply: String,
    reasoning: String,
    activities: [OpenClawRunActivity],
    connectionState: String,
    connectionDetail: String?
  ) {
    self.threads = threads
    self.activeDestinationName = activeDestinationName
    self.streamingReply = streamingReply
    self.reasoning = reasoning
    self.activities = activities
    self.connectionState = connectionState
    self.connectionDetail = connectionDetail
  }
}

public enum MobileRemoteThreadProjection {
  public static func list(
    threads: [OpenClawChatThread],
    context: MobileRemoteThreadProjectionContext
  ) -> MobileRemoteThreadList {
    MobileRemoteThreadList(threads: threads.map { summary(thread: $0, context: context) })
  }

  public static func detail(
    thread: OpenClawChatThread,
    context: MobileRemoteThreadDetailProjectionContext
  ) -> MobileRemoteThreadDetail {
    MobileRemoteThreadDetail(
      thread: summary(thread: thread, context: context.threads),
      messages: thread.messages.map { message in
        let audienceDestinationIDs = message.audienceDestinationIDs.isEmpty
          ? [message.targetDestinationID].compactMap { $0 }
          : message.audienceDestinationIDs
        return MobileRemoteChatMessage(
          id: message.id,
          role: message.role.rawValue,
          content: message.content,
          attachmentNames: message.attachments.map(\.fileName),
          createdAt: message.createdAt,
          deliveryStatus: message.deliveryStatus.rawValue,
          deliveryKind: message.deliveryKind.rawValue,
          sendFailure: message.sendFailure,
          authorRuntime: message.authorRuntime?.rawValue,
          authorDestinationID: message.authorDestinationID,
          authorDestinationName: message.authorDestinationID.flatMap {
            context.threads.destinationNamesByID[$0]
          },
          audience: message.audience?.rawValue,
          audienceDestinationNames: audienceDestinationIDs.compactMap {
            context.threads.destinationNamesByID[$0]
          },
          isRoomDispatchCopy: message.isRoomDispatchCopy,
          roomRoundID: message.roomRoundID
        )
      },
      activeDestinationName: context.activeDestinationName,
      streamingReply: context.streamingReply,
      reasoning: context.reasoning,
      activities: MobileRemoteActivityPresentation.items(from: context.activities),
      connectionState: context.connectionState,
      connectionDetail: context.connectionDetail
    )
  }

  public static func summary(
    thread: OpenClawChatThread,
    context: MobileRemoteThreadProjectionContext
  ) -> MobileRemoteThreadSummary {
    var latestPreview: MobileRemoteMessagePreview?
    var latestAssistantMessage: OpenClawChatMessage?
    var latestAssistantPreview: MobileRemoteMessagePreview?

    for message in thread.messages.reversed() {
      let preview = MobileRemoteMessagePreview.make(from: message, characterLimit: 180)
      if latestPreview == nil, let preview {
        latestPreview = preview
      }
      if latestAssistantMessage == nil,
         message.role == .assistant,
         let preview {
        latestAssistantMessage = message
        latestAssistantPreview = preview
      }
      if latestPreview != nil, latestAssistantMessage != nil { break }
    }

    return MobileRemoteThreadSummary(
      id: thread.id,
      title: thread.title,
      runtime: thread.runtime.rawValue,
      destinationID: thread.destinationID,
      destinationName: thread.isSharedRoom
        ? "Shared AI Room"
        : context.destinationNamesByID[thread.destinationID],
      isSharedRoom: thread.isSharedRoom,
      model: thread.model,
      updatedAt: thread.updatedAt,
      isSettled: thread.isSettled,
      isPinned: thread.isPinned,
      isRunning: context.runningThreadIDs.contains(thread.id),
      unreadMessageCount: thread.unreadMessageCount,
      preview: latestPreview?.text,
      latestAssistantMessageID: latestAssistantMessage?.id,
      latestAssistantPreview: latestAssistantPreview?.text
    )
  }
}

public struct MobileRemotePreparedSendMessage: Sendable {
  public let content: String
  public let attachments: [OpenClawChatAttachment]
  public let delivery: String?

  public init(
    content: String,
    attachments: [OpenClawChatAttachment],
    delivery: String?
  ) {
    self.content = content
    self.attachments = attachments
    self.delivery = delivery
  }
}

public enum MobileRemoteSendMessagePreparationError: LocalizedError, Equatable, Sendable {
  case invalidPayload
  case tooManyPhotos
  case photoTooLarge(String)
  case photosTooLarge
  case unsupportedAttachment(String)

  public var errorDescription: String? {
    switch self {
    case .invalidPayload:
      "The message could not be read."
    case .tooManyPhotos:
      "Attach no more than four photos at a time."
    case .photoTooLarge(let name):
      "\(name) is too large to send from Mobile Remote."
    case .photosTooLarge:
      "The selected photos are too large to send together."
    case .unsupportedAttachment(let name):
      "\(name) is not a supported photo attachment."
    }
  }
}

/// Owns CPU-heavy mobile transport work. Every public operation creates a
/// detached task so callers may safely invoke it from `@MainActor` routes.
public struct MobileRemoteBackgroundWork: Sendable {
  private let beforeWork: @Sendable () async -> Void
  private let didFinishWork: @Sendable (_ ranOnMainThread: Bool) -> Void

  public init(
    beforeWork: @escaping @Sendable () async -> Void = {},
    didFinishWork: @escaping @Sendable (_ ranOnMainThread: Bool) -> Void = { _ in }
  ) {
    self.beforeWork = beforeWork
    self.didFinishWork = didFinishWork
  }

  public func jsonResponse<T: Encodable & Sendable>(
    _ value: T,
    statusCode: Int = 200
  ) async -> MobileRemoteHTTPResponse {
    let beforeWork = self.beforeWork
    let didFinishWork = self.didFinishWork
    return await Task.detached(priority: .userInitiated) {
      await beforeWork()
      let response = MobileRemoteHTTPResponse.json(value, statusCode: statusCode)
      didFinishWork(mobileRemoteIsMainThread())
      return response
    }.value
  }

  public func threadListResponse(
    threads: [OpenClawChatThread],
    context: MobileRemoteThreadProjectionContext
  ) async -> MobileRemoteHTTPResponse {
    let beforeWork = self.beforeWork
    let didFinishWork = self.didFinishWork
    return await Task.detached(priority: .userInitiated) {
      await beforeWork()
      let response = MobileRemoteHTTPResponse.json(
        MobileRemoteThreadProjection.list(threads: threads, context: context)
      )
      didFinishWork(mobileRemoteIsMainThread())
      return response
    }.value
  }

  public func threadDetailResponse(
    thread: OpenClawChatThread,
    context: MobileRemoteThreadDetailProjectionContext
  ) async -> MobileRemoteHTTPResponse {
    let beforeWork = self.beforeWork
    let didFinishWork = self.didFinishWork
    return await Task.detached(priority: .userInitiated) {
      await beforeWork()
      let response = MobileRemoteHTTPResponse.json(
        MobileRemoteThreadProjection.detail(thread: thread, context: context)
      )
      didFinishWork(mobileRemoteIsMainThread())
      return response
    }.value
  }

  public func prepareSendMessage(
    from request: MobileRemoteHTTPRequest
  ) async throws -> MobileRemotePreparedSendMessage {
    let beforeWork = self.beforeWork
    let didFinishWork = self.didFinishWork
    return try await Task.detached(priority: .userInitiated) {
      await beforeWork()
      let payload: MobileRemoteSendMessageRequest
      do {
        payload = try request.decode(MobileRemoteSendMessageRequest.self)
      } catch {
        throw MobileRemoteSendMessagePreparationError.invalidPayload
      }
      let prepared = try MobileRemotePreparedSendMessage(
        content: payload.content,
        attachments: Self.chatAttachments(from: payload.attachments),
        delivery: payload.delivery
      )
      didFinishWork(mobileRemoteIsMainThread())
      return prepared
    }.value
  }

  private static func chatAttachments(
    from payloads: [MobileRemoteAttachment]
  ) throws -> [OpenClawChatAttachment] {
    guard payloads.count <= 4 else {
      throw MobileRemoteSendMessagePreparationError.tooManyPhotos
    }
    var totalBytes = 0
    return try payloads.map { payload in
      let mimeType = payload.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard mimeType.hasPrefix("image/") else {
        throw MobileRemoteSendMessagePreparationError.unsupportedAttachment(payload.fileName)
      }
      guard !payload.data.isEmpty, payload.data.count <= 5_000_000 else {
        throw MobileRemoteSendMessagePreparationError.photoTooLarge(payload.fileName)
      }
      totalBytes += payload.data.count
      guard totalBytes <= 8_000_000 else {
        throw MobileRemoteSendMessagePreparationError.photosTooLarge
      }
      let fileName = URL(fileURLWithPath: payload.fileName).lastPathComponent
      guard !fileName.isEmpty else {
        throw MobileRemoteSendMessagePreparationError.unsupportedAttachment("Photo")
      }
      return OpenClawChatAttachment(
        fileName: fileName,
        mimeType: mimeType,
        data: payload.data
      )
    }
  }
}
