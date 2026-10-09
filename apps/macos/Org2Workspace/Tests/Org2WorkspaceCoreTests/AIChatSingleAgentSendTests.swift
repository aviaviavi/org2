import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor SingleAgentSendRecorder {
  var messageIDs: [UUID] = []
  let pausesFirst: Bool
  var firstContinuation: CheckedContinuation<Void, Never>?
  init(pausesFirst: Bool = false) { self.pausesFirst = pausesFirst }
  func resumeFirst() { firstContinuation?.resume(); firstContinuation = nil }
  func record(_ messages: [AIChatMessage]) async {
    messageIDs.append(messages.last(where: { $0.role == .user })!.id)
    if pausesFirst && messageIDs.count == 1 {
      await withCheckedContinuation { firstContinuation = $0 }
    }
  }
}

final class AIChatSingleAgentSendTests: XCTestCase {
  @MainActor
  private func fixture(destinationAvailable: Bool = true, pausesFirst: Bool = false) throws -> (WorkspaceStore, URL, UUID, SingleAgentSendRecorder) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-single-send-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let suite = "CelorgaSingleAgentSendTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    if !destinationAvailable {
      var destinations = AIChatDestinationConfiguration.defaults
      for index in destinations.indices where destinations[index].id == AIChatDestinationConfiguration.localCodexID {
        destinations[index].isEnabled = false
      }
      defaults.set(try JSONEncoder().encode(destinations), forKey: "Org2Workspace.aiChat.destinations.v1")
    }
    let recorder = SingleAgentSendRecorder(pausesFirst: pausesFirst)
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent(".org2/openclaw-chat.json"),
      codexSendHandlerForTesting: { messages, _, _ in
        await recorder.record(messages)
        return "SINGLE_SEND_OK"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    return (store, root, store.createAIChatThread(runtime: .codex), recorder)
  }

  private func writeSend(root: URL, threadID: UUID, messageID: UUID,
                         destinationID: String = AIChatDestinationConfiguration.localCodexID) throws -> URL {
    let directory = root.appendingPathComponent(".org2/ai-chat-inbox")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("\(messageID.uuidString.lowercased()).json")
    try JSONSerialization.data(withJSONObject: [
      "schema": "org2:ai-chat-send-message:v1",
      "id": messageID.uuidString, "threadID": threadID.uuidString,
      "destinationID": destinationID, "content": "Reply SINGLE_SEND_OK only.",
      "createdAt": "2026-10-09T03:00:00Z", "authorLabel": "CLI test"
    ]).write(to: file, options: .atomic)
    return file
  }

  @MainActor
  private func waitForReply(_ store: WorkspaceStore, threadID: UUID, expectedCount: Int = 1) async throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if store.aiChatThreads.first(where: { $0.id == threadID })?.messages.filter({
        $0.role == .assistant && $0.content == "SINGLE_SEND_OK"
      }).count == expectedCount, !store.isAIChatThreadRunning(threadID) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The existing Codex send queue did not finish the request: \(store.errorText ?? "")")
  }

  @MainActor
  func testSingleAgentSendUsesCodexQueueAndDuplicateNeverDispatchesAgain() async throws {
    let (store, root, threadID, recorder) = try fixture()
    let messageID = UUID()
    let file = try writeSend(root: root, threadID: threadID, messageID: messageID)
    await store.drainAIChatInbox()
    try await waitForReply(store, threadID: threadID)
    let message = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID })?
      .messages.first(where: { $0.id == messageID }))
    XCTAssertEqual(message.role, .user)
    XCTAssertEqual(message.deliveryStatus, .sent)
    XCTAssertEqual(message.targetDestinationID, AIChatDestinationConfiguration.localCodexID)
    XCTAssertEqual(message.provenance?.originClient, .inbox)
    XCTAssertEqual(message.provenance?.requestedByLabel, "CLI test")
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    _ = try writeSend(root: root, threadID: threadID, messageID: messageID)
    await store.drainAIChatInbox()
    let calls = await recorder.messageIDs
    XCTAssertEqual(calls, [messageID])
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.messages
      .filter { $0.id == messageID }.count, 1)
  }

  @MainActor
  func testSendDoesNotStartBeforeDurabilityAndRetryUsesTheSameQueuedMessage() async throws {
    let (store, root, threadID, recorder) = try fixture()
    let messageID = UUID()
    let file = try writeSend(root: root, threadID: threadID, messageID: messageID)
    store.aiChatTranscriptSaverForTesting = { throw CocoaError(.fileWriteUnknown) }
    await store.drainAIChatInbox()
    let before = await recorder.messageIDs
    XCTAssertTrue(before.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    store.aiChatTranscriptSaverForTesting = nil
    await store.drainAIChatInbox()
    try await waitForReply(store, threadID: threadID)
    let after = await recorder.messageIDs
    XCTAssertEqual(after, [messageID])
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  @MainActor
  func testBusyQueueCannotDispatchFollowUpBeforeInboxDurability() async throws {
    let (store, root, threadID, recorder) = try fixture(pausesFirst: true)
    let initial = Task { await store.sendAIChatMessage(text: "First request") }
    let deadline = Date().addingTimeInterval(5)
    while await recorder.messageIDs.isEmpty, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let messageID = UUID()
    let file = try writeSend(root: root, threadID: threadID, messageID: messageID)
    store.aiChatTranscriptSaverForTesting = { throw CocoaError(.fileWriteUnknown) }
    await store.drainAIChatInbox()
    await recorder.resumeFirst()
    await initial.value
    let before = await recorder.messageIDs
    XCTAssertEqual(before.count, 1, "the active queue must not take the uncommitted follow-up")
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.messages
      .first(where: { $0.id == messageID })?.deliveryKind, .followUp)
    store.aiChatTranscriptSaverForTesting = nil
    await store.drainAIChatInbox()
    try await waitForReply(store, threadID: threadID, expectedCount: 2)
    let after = await recorder.messageIDs
    XCTAssertEqual(after.count, 2)
    XCTAssertEqual(after.last, messageID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  @MainActor
  func testUnavailableChangedAndSharedDestinationsRetainSendWithoutDispatch() async throws {
    let (store, root, threadID, recorder) = try fixture(destinationAvailable: false)
    XCTAssertNil(store.aiChatDestination(id: AIChatDestinationConfiguration.localCodexID))
    let disabled = try writeSend(root: root, threadID: threadID, messageID: UUID())
    let changed = try writeSend(root: root, threadID: threadID, messageID: UUID(), destinationID: "missing-agent")
    store.createAIChatSharedRoom()
    let roomID = try XCTUnwrap(store.selectedAIChatThreadID)
    let shared = try writeSend(root: root, threadID: roomID, messageID: UUID())
    await store.drainAIChatInbox()
    let calls = await recorder.messageIDs
    XCTAssertTrue(calls.isEmpty)
    XCTAssertTrue(store.errorText?.contains("destination is unavailable or changed") == true)
    for file in [disabled, changed, shared] {
      XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    XCTAssertTrue(store.aiChatThreads.first(where: { $0.id == threadID })?.messages.isEmpty == true)
    XCTAssertTrue(store.aiChatThreads.first(where: { $0.id == roomID })?.messages.isEmpty == true)
  }
}
