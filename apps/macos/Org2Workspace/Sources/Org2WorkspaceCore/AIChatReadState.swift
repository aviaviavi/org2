import Foundation

/// Device-local read receipts must survive importing an older unread count from
/// a synced transcript. They contain only the activity version, never messages.
@MainActor
final class AIChatReadState {
  private struct Receipt: Codable, Equatable {
    let updatedAt: Date
    let messageCount: Int

    func covers(_ thread: OpenClawChatThread) -> Bool {
      thread.updatedAt <= updatedAt && thread.messageCount <= messageCount
    }
  }

  private let defaults: UserDefaults
  private var receiptsByPath: [String: [UUID: Receipt]] = [:]

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  func markRead(_ thread: OpenClawChatThread, transcriptURL: URL) {
    let path = transcriptURL.standardizedFileURL.path
    var receipts = receipts(for: path)
    let previous = receipts[thread.id]
    guard previous?.covers(thread) != true else { return }
    receipts[thread.id] = Receipt(
      updatedAt: max(previous?.updatedAt ?? thread.updatedAt, thread.updatedAt),
      messageCount: max(previous?.messageCount ?? 0, thread.messageCount)
    )
    guard let data = try? JSONEncoder().encode(receipts) else { return }
    receiptsByPath[path] = receipts
    defaults.set(data, forKey: storageKey(for: path))
  }

  func applying(to threads: [OpenClawChatThread], transcriptURL: URL) -> [OpenClawChatThread] {
    let receipts = receipts(for: transcriptURL.standardizedFileURL.path)
    return threads.map { thread in
      guard thread.unreadMessageCount > 0, receipts[thread.id]?.covers(thread) == true else {
        return thread
      }
      return thread.replacingOpenClawChatMetadata(unreadMessageCount: 0)
    }
  }

  private func receipts(for path: String) -> [UUID: Receipt] {
    if let cached = receiptsByPath[path] { return cached }
    let stored = defaults.data(forKey: storageKey(for: path)).flatMap {
      try? JSONDecoder().decode([UUID: Receipt].self, from: $0)
    } ?? [:]
    receiptsByPath[path] = stored
    return stored
  }

  private func storageKey(for path: String) -> String {
    "Org2Workspace.aiChat.readReceipts.v1:\(path)"
  }
}
