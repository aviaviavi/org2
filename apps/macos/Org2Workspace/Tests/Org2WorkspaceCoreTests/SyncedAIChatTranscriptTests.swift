import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class SyncedAIChatTranscriptTests: XCTestCase {
  private func replicate(_ source: URL, to target: URL) throws {
    let fm = FileManager.default
    let sourceStore = AIChatTranscriptStore.storeDirectory(for: source)
    let targetStore = AIChatTranscriptStore.storeDirectory(for: target)
    if fm.fileExists(atPath: targetStore.path) { try fm.removeItem(at: targetStore) }
    try fm.copyItem(at: sourceStore, to: targetStore)
  }

  @MainActor
  func testSyncedThreadRefreshPreservesSelectionDraftAndDoesNotWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let localURL = root.appendingPathComponent("local.json")
    let remoteURL = root.appendingPathComponent("remote.json")
    let original = OpenClawChatThread(title: "Local", sessionKey: "agent:main:local", messages: [])
    let incoming = OpenClawChatThread(title: "Phone via server", sessionKey: "agent:main:server", messages: [
      OpenClawChatMessage(role: .user, content: "From my phone"),
      OpenClawChatMessage(role: .assistant, content: "From the server")
    ])
    let settings = OpenClawThreadSettlementSettings()
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original], selectedThreadID: original.id, settlementSettings: settings
    ), legacyURL: localURL)
    let suite = "synced-chat-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults, openClawTranscriptURL: localURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.publishOpenClawComposerDraft("Keep my unfinished message")
    try await store.waitForAIChatTranscriptPersistenceForTesting()
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, incoming], selectedThreadID: incoming.id, settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let marker = AIChatTranscriptStore.storeDirectory(for: localURL).appendingPathComponent("migration-marker.json")
    let before = try Data(contentsOf: marker)
    XCTAssertFalse(store.hasUnpersistedAIChatTranscriptMutationForTesting)
    let refreshed = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(refreshed)
    XCTAssertEqual(Set(store.openClawChatThreads.map(\.id)), [original.id, incoming.id])
    XCTAssertEqual(store.selectedOpenClawChatThreadID, original.id)
    XCTAssertEqual(store.openClawDraft, "Keep my unfinished message")
    store.selectOpenClawChatThread(incoming.id)
    await store.waitForAIChatThreadHydrationForTesting(incoming.id)
    XCTAssertEqual(store.openClawMessages.map(\.content), ["From my phone", "From the server"])
    XCTAssertEqual(try Data(contentsOf: marker), before, "Viewing a synced conversation must not create a commit")

    let pendingMessage = OpenClawChatMessage(role: .user, content: "Still working", deliveryStatus: .sending)
    let working = OpenClawChatThread(
      id: incoming.id, title: incoming.title, sessionKey: incoming.sessionKey,
      messages: [pendingMessage], pendingTurn: OpenClawPendingTurn(
        userMessageID: pendingMessage.id, runID: "remote-run", agentID: "main", gatewayMessage: "Still working"
      )
    )
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, working], selectedThreadID: incoming.id, settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let importedPending = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(importedPending)
    XCTAssertNotNil(store.openClawChatThreads.first { $0.id == incoming.id }?.pendingTurn)
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, incoming], selectedThreadID: incoming.id, settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let importedCompletion = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(importedCompletion, "A remote pending turn must not prevent refreshing its completion")
    XCTAssertNil(store.openClawChatThreads.first { $0.id == incoming.id }?.pendingTurn)
    XCTAssertEqual(store.openClawMessages.map(\.content), ["From my phone", "From the server"])
  }

  func testStaleSnapshotPreservesUnseenThreadsButHonorsKnownDeletion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("chat.json")
    let original = OpenClawChatThread(title: "Known", sessionKey: "known", messages: [])
    let incoming = OpenClawChatThread(title: "Unseen", sessionKey: "unseen", messages: [OpenClawChatMessage(role: .assistant, content: "Preserve me")])
    let settings = OpenClawThreadSettlementSettings()
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, incoming], selectedThreadID: original.id, settlementSettings: settings
    ), legacyURL: url)
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [], selectedThreadID: nil, settlementSettings: settings, knownThreadIDs: [original.id]
    ), legacyURL: url)
    let actual = try XCTUnwrap(AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: url, preferPersisted: true))
    XCTAssertEqual(actual.snapshot.threads.map(\.id), [incoming.id])
    XCTAssertEqual(actual.snapshot.threads.first?.messages.first?.content, "Preserve me")
  }

  func testDeliveryUpdatesNeverMoveActivityTimeBackward() {
    let before = Date(timeIntervalSinceReferenceDate: 1_000)
    let message = OpenClawChatMessage(role: .user, content: "Earlier message", createdAt: before.addingTimeInterval(-10))
    let thread = OpenClawChatThread(title: "Conversation", updatedAt: before, sessionKey: "agent:main:test", messages: [message])
    let changed = WorkspaceStore.updatedOpenClawChatThread(
      thread, messages: [message.replacingDeliveryStatus(.interrupted, sendFailure: "Stopped")],
      newAssistantMessageCount: 0, isThreadOpen: true, pendingTurnUpdate: .replace(nil)
    )
    XCTAssertEqual(changed.updatedAt, before)
    let later = OpenClawChatMessage(role: .assistant, content: "New reply", createdAt: before.addingTimeInterval(10))
    let replied = WorkspaceStore.updatedOpenClawChatThread(
      changed, messages: [message, later], newAssistantMessageCount: 1,
      isThreadOpen: true, pendingTurnUpdate: .preserve
    )
    XCTAssertEqual(replied.updatedAt, later.createdAt)
  }

  func testTranscriptEventsAreRecognizedWithoutRefreshingCanonicalDocuments() {
    let root = URL(fileURLWithPath: "/tmp/corpus")
    let classified = WorkspaceStore.classifyCorpusFileEvents([
      "/tmp/corpus/.org2/openclaw-chat.store/migration-marker.json",
      "/tmp/corpus/.org2/openclaw-chat.store/threads/new.json"
    ], corpusRoot: root)
    XCTAssertTrue(classified.hasAIChatTranscriptChanges)
    XCTAssertTrue(classified.contentPaths.isEmpty)
  }
}
