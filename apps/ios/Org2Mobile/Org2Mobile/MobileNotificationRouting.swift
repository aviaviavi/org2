import Foundation

/// A tap is retained until the root navigator has accepted it. The latest tap
/// wins; stale consumers cannot acknowledge a newer destination.
enum MobileNotificationDestination: Codable, Equatable {
  case thread(UUID)
  case agenda

  static func resolve(category: String, identifier: String, userInfo: [AnyHashable: Any]) -> Self? {
    if category == "org2.thread.reply",
       let raw = userInfo["threadID"] as? String, let id = UUID(uuidString: raw) {
      return .thread(id)
    }
    if category == "org2.agenda.due-today" || identifier == "org2.due-today.daily"
      || identifier.hasPrefix("org2.due-today.daily.") {
      return .agenda
    }
    return nil
  }
}

@MainActor
struct MobileNotificationInbox {
  struct Pending: Codable, Equatable {
    let id: UUID
    let destination: MobileNotificationDestination
  }
  static let key = "Org2Mobile.notification.pendingDestination.v1"
  static let legacyKey = "Org2Mobile.remote.pendingReplyThreadID.v1"
  let defaults: UserDefaults

  func enqueue(_ destination: MobileNotificationDestination) {
    let pending = Pending(id: UUID(), destination: destination)
    guard let data = try? JSONEncoder().encode(pending) else { return }
    defaults.set(data, forKey: Self.key)
    defaults.removeObject(forKey: Self.legacyKey)
  }

  func pending() -> Pending? {
    if let data = defaults.data(forKey: Self.key),
       let pending = try? JSONDecoder().decode(Pending.self, from: data) { return pending }
    if let raw = defaults.string(forKey: Self.legacyKey), let id = UUID(uuidString: raw) {
      enqueue(.thread(id))
      return pending()
    }
    return nil
  }

  func acknowledge(_ pending: Pending) {
    guard self.pending()?.id == pending.id else { return }
    defaults.removeObject(forKey: Self.key)
  }
}
