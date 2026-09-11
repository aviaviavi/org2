import Foundation

@main
struct NotificationRoutingRegression {
  @MainActor static func main() throws {
    let suite = "org2.notification-test.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = UUID(), second = UUID()
    let inbox = MobileNotificationInbox(defaults: defaults)
    func expect(_ value: Bool, _ message: String) { precondition(value, message) }

    expect(MobileNotificationDestination.resolve(category: "org2.thread.reply", identifier: "push", userInfo: ["threadID": first.uuidString]) == .thread(first), "APNs tap")
    expect(MobileNotificationDestination.resolve(category: "org2.thread.reply", identifier: "org2.thread.reply.local", userInfo: ["threadID": first.uuidString]) == .thread(first), "Local fallback tap")
    expect(MobileNotificationDestination.resolve(category: "org2.thread.reply", identifier: "push", userInfo: ["threadID": "bad"]) == nil, "Malformed thread")
    expect(MobileNotificationDestination.resolve(category: "unknown", identifier: "push", userInfo: ["threadID": first.uuidString]) == nil, "Unknown notification")
    expect(MobileNotificationDestination.resolve(category: "org2.agenda.due-today", identifier: "new", userInfo: [:]) == .agenda, "Agenda tap")
    for id in ["org2.due-today.daily", "org2.due-today.daily.2026-09-11"] {
      expect(MobileNotificationDestination.resolve(category: "", identifier: id, userInfo: [:]) == .agenda, "Already scheduled agenda notification")
    }
    expect(inbox.pending() == nil, "No spurious startup navigation")
    inbox.enqueue(.thread(first))
    let restored = MobileNotificationInbox(defaults: UserDefaults(suiteName: suite)!)
    let cold = restored.pending()!
    expect(cold.destination == .thread(first), "Cold launch retains tap before navigator mounts")
    expect(restored.pending() == cold, "Readiness/connection checks do not consume tap")
    inbox.enqueue(.thread(second))
    restored.acknowledge(cold)
    expect(inbox.pending()?.destination == .thread(second), "Old consumer cannot clear latest tap")
    let latest = inbox.pending()!
    inbox.acknowledge(latest)
    expect(inbox.pending() == nil, "Accepted tap does not reopen on activation")
    defaults.set(first.uuidString, forKey: MobileNotificationInbox.legacyKey)
    expect(inbox.pending()?.destination == .thread(first), "Recover pending tap saved by previous app")
    expect(defaults.string(forKey: MobileNotificationInbox.legacyKey) == nil, "Legacy migration only once")
    inbox.enqueue(.agenda)
    expect(inbox.pending()?.destination == .agenda, "Agenda replaces earlier thread tap")
    print("Notification routing regressions passed")
  }
}
