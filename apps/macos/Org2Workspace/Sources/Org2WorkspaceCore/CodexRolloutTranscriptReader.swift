import Foundation

enum CodexRolloutTranscriptError: LocalizedError, Sendable {
  case pathUnavailable

  var errorDescription: String? {
    switch self {
    case .pathUnavailable:
      "Codex did not expose a readable transcript for this task."
    }
  }
}

/// Reads the human-visible transcript directly from a Codex rollout without
/// materializing tool output, world state, or other large internal records.
///
/// A long-running Codex task can have a rollout hundreds of megabytes larger
/// than its visible conversation. Asking App Server to decode every turn first
/// makes read-only browsing unnecessarily slow and memory-intensive.
struct CodexRolloutTranscriptReader: Sendable {
  private static let readChunkSize = 4 * 1_024 * 1_024
  private static let eventPrefixLimit = 512
  private static let maximumEventLineSize = 16 * 1_024 * 1_024
  private static let eventMarker = Data(#""type":"event_msg""#.utf8)
  private static let newlineMarker = Data([0x0A])

  static func messages(at url: URL) async throws -> [ExternalThreadMessage] {
    try await Task.detached(priority: .userInitiated) {
      try readMessages(at: url)
    }.value
  }

  nonisolated static func readMessages(at url: URL) throws -> [ExternalThreadMessage] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var messages: [ExternalThreadMessage] = []
    var lineBuffer = Data()
    var discardingLine = false
    var lineNumber = 0
    let fractionalTimestampFormatter = ISO8601DateFormatter()
    fractionalTimestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestampFormatter = ISO8601DateFormatter()
    timestampFormatter.formatOptions = [.withInternetDateTime]

    func consume(_ bytes: Data.SubSequence, endsLine: Bool) {
      if !discardingLine {
        let prefixBytesNeeded = max(0, eventPrefixLimit - lineBuffer.count)
        let prefixByteCount = min(prefixBytesNeeded, bytes.count)
        if prefixByteCount > 0 {
          lineBuffer.append(contentsOf: bytes.prefix(prefixByteCount))
        }
        if lineBuffer.count >= eventPrefixLimit,
           lineBuffer.range(of: eventMarker) == nil {
          // The top-level record type appears near the start of every JSONL
          // record. Once it is absent from the prefix, stop retaining what may
          // be a multi-megabyte tool payload until its newline arrives.
          lineBuffer.removeAll(keepingCapacity: false)
          discardingLine = true
        } else {
          let remainingBytes = bytes.dropFirst(prefixByteCount)
          if lineBuffer.count + remainingBytes.count > maximumEventLineSize {
            lineBuffer.removeAll(keepingCapacity: false)
            discardingLine = true
          } else {
            lineBuffer.append(contentsOf: remainingBytes)
          }
        }
      }

      guard endsLine else { return }
      lineNumber += 1
      if !discardingLine,
         lineBuffer.range(of: eventMarker) != nil,
         let message = message(
           from: lineBuffer,
           lineNumber: lineNumber,
           fractionalTimestampFormatter: fractionalTimestampFormatter,
           timestampFormatter: timestampFormatter
         ) {
        messages.append(message)
      }
      lineBuffer.removeAll(keepingCapacity: true)
      discardingLine = false
    }

    while true {
      try Task.checkCancellation()
      let reachedEnd = try autoreleasepool {
        guard let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty else {
          return true
        }
        var segmentStart = chunk.startIndex
        while let newline = chunk.range(
          of: newlineMarker,
          in: segmentStart..<chunk.endIndex
        )?.lowerBound {
          consume(chunk[segmentStart..<newline], endsLine: true)
          segmentStart = chunk.index(after: newline)
        }
        if segmentStart < chunk.endIndex {
          consume(chunk[segmentStart..<chunk.endIndex], endsLine: false)
        }
        return false
      }
      if reachedEnd { break }
    }

    if !lineBuffer.isEmpty || discardingLine {
      consume(Data.SubSequence(), endsLine: true)
    }
    return messages
  }

  private nonisolated static func message(
    from data: Data,
    lineNumber: Int,
    fractionalTimestampFormatter: ISO8601DateFormatter,
    timestampFormatter: ISO8601DateFormatter
  ) -> ExternalThreadMessage? {
    guard let event = try? JSONDecoder().decode(RolloutEvent.self, from: data),
          event.type == "event_msg",
          let content = normalized(event.payload.message)
    else { return nil }

    let role: ExternalThreadMessage.Role
    switch event.payload.type {
    case "user_message":
      role = .user
    case "agent_message":
      role = .assistant
    default:
      return nil
    }

    let createdAt = fractionalTimestampFormatter.date(from: event.timestamp)
      ?? timestampFormatter.date(from: event.timestamp)
      ?? Date(timeIntervalSince1970: 0)
    let id = event.payload.clientID.flatMap(normalized) ?? "rollout-line-\(lineNumber)"
    return ExternalThreadMessage(id: id, role: role, content: content, createdAt: createdAt)
  }

  private nonisolated static func normalized(_ value: String?) -> String? {
    guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !normalized.isEmpty
    else { return nil }
    return normalized
  }

  private struct RolloutEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: Payload

    struct Payload: Decodable {
      let type: String
      let clientID: String?
      let message: String?

      enum CodingKeys: String, CodingKey {
        case type
        case clientID = "client_id"
        case message
      }
    }
  }
}
