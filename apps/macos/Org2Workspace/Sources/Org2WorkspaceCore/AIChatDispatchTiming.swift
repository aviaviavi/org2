import Foundation
import os

/// Per-step timing for an AI chat turn, measured from the moment the user
/// sent the message. Read it with:
///
///     log show --last 10m --predicate 'subsystem == "org.org2.workspace" AND category == "AIChatDispatch"'
///
/// Each line names the step, the thread, and the milliseconds since send, so
/// a slow "Connecting to …" can be attributed to queueing, preparation, the
/// runtime launch, or the runtime's first event.
enum AIChatDispatchTiming {
  static let logger = Logger(subsystem: "org.org2.workspace", category: "AIChatDispatch")

  static func milliseconds(since sentAt: Date, now: Date = Date()) -> Int {
    max(0, Int((now.timeIntervalSince(sentAt) * 1000).rounded()))
  }

  static func record(_ step: String, threadID: UUID, sentAt: Date?, now: Date = Date()) {
    guard let sentAt else { return }
    let elapsed = milliseconds(since: sentAt, now: now)
    logger.notice("turn \(threadID.uuidString.lowercased(), privacy: .public) \(step, privacy: .public) +\(elapsed, privacy: .public)ms")
  }
}
