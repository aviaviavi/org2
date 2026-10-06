import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AIChatAutomationThreadBulkSettleTests: XCTestCase {
  @MainActor
  func testMarksEveryAutomationThreadReadAndSettledInOneBatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("chat.json")
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let earlierSettlement = Date(timeIntervalSince1970: 1_500)
    let automations = (0..<1_200).map { index in
      AIChatThread(
        title: "Automation: Daily brief \(index)",
        createdAt: createdAt,
        updatedAt: createdAt,
        sessionKey: "automation-\(index)",
        messages: [AIChatMessage(role: .assistant, content: "Brief \(index)", createdAt: createdAt)],
        unreadMessageCount: index.isMultiple(of: 2) ? 1 : 0
      )
    }
    let alreadySettled = AIChatThread(
      title: "Automation: Weekly review",
      createdAt: createdAt,
      updatedAt: createdAt,
      sessionKey: "automation-settled",
      isArchived: true,
      settledAt: earlierSettlement,
      unreadMessageCount: 1
    )
    let ordinary = AIChatThread(
      title: "Planning",
      createdAt: createdAt,
      updatedAt: createdAt,
      sessionKey: "ordinary",
      messages: [AIChatMessage(role: .assistant, content: "Unread", createdAt: createdAt)],
      unreadMessageCount: 1
    )
    let forkedAutomation = AIChatThread(
      title: "Shared: Automation: Daily brief 1",
      createdAt: createdAt,
      updatedAt: createdAt,
      sessionKey: "forked",
      unreadMessageCount: 1
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [ordinary, forkedAutomation, alreadySettled] + automations,
        selectedThreadID: ordinary.id,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let suite = "automation-bulk-settle-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL
    )
    await store.waitForAIChatTranscriptLoadForTesting()
    try await store.waitForAIChatTranscriptPersistenceForTesting()

    let settledAt = Date(timeIntervalSince1970: 2_000)
    let changed = store.markAllAutomationAIChatThreadsReadAndSettled(at: settledAt)

    XCTAssertEqual(changed, automations.count + 1)
    let byID = Dictionary(uniqueKeysWithValues: store.aiChatThreads.map { ($0.id, $0) })
    for automation in automations {
      let thread = try XCTUnwrap(byID[automation.id])
      XCTAssertTrue(thread.isSettled)
      XCTAssertEqual(thread.settledAt, settledAt)
      XCTAssertEqual(thread.unreadMessageCount, 0)
    }
    let settled = try XCTUnwrap(byID[alreadySettled.id])
    XCTAssertEqual(settled.settledAt, earlierSettlement, "Existing settlement time is kept")
    XCTAssertEqual(settled.unreadMessageCount, 0)
    XCTAssertFalse(try XCTUnwrap(byID[ordinary.id]).isSettled)
    XCTAssertEqual(byID[ordinary.id]?.unreadMessageCount, 1)
    XCTAssertFalse(try XCTUnwrap(byID[forkedAutomation.id]).isSettled)
    XCTAssertEqual(byID[forkedAutomation.id]?.unreadMessageCount, 1)
    XCTAssertEqual(store.aiChatUnreadMessageCount, 2)

    XCTAssertEqual(store.markAllAutomationAIChatThreadsReadAndSettled(), 0, "A second run is a no-op")

    store.flushDeferredAIChatTranscriptPersistence()
    try await store.waitForAIChatTranscriptPersistenceForTesting()
    let reopened = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL
    )
    await reopened.waitForAIChatTranscriptLoadForTesting()
    let reopenedAutomations = reopened.aiChatThreads.filter {
      WorkspaceStore.isAutomationAIChatThreadTitle($0.title)
    }
    XCTAssertEqual(reopenedAutomations.count, automations.count + 1)
    XCTAssertTrue(reopenedAutomations.allSatisfy { $0.isSettled && $0.unreadMessageCount == 0 })
    XCTAssertEqual(reopened.aiChatUnreadMessageCount, 2)
  }
}
