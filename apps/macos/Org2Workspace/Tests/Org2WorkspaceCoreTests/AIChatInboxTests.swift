import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AIChatInboxTests: XCTestCase {
  @MainActor
  func testEmbeddedCodexThreadPostToolUsesTheSharedQueueContract() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-tool-\(UUID().uuidString)", isDirectory: true)
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatInboxToolTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let threadID = store.createOpenClawChatThread(runtime: .codex)
    store.flushDeferredAIChatTranscriptPersistence()
    XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
    XCTAssertTrue(try String(contentsOf: transcript).lowercased().contains(threadID.uuidString.lowercased()))

    let result = await store.handleCodexThreadPostTool(.object([
      "threadId": .string(threadID.uuidString.lowercased()),
      "message": .string("The delegated check is complete."),
      "author": .string("Build Scout"),
      "agentRef": .string("build-scout"),
      "source": .string("run:build-42"),
      "idempotencyKey": .string("build-42:complete"),
    ]))

    XCTAssertTrue(result.success, result.text)
    let delivered = try XCTUnwrap(
      store.openClawChatThreads.first(where: { $0.id == threadID })?.messages.first
    )
    XCTAssertEqual(delivered.content, "The delegated check is complete.")
    XCTAssertEqual(delivered.authorLabel, "Build Scout")
    XCTAssertEqual(delivered.authorAgentRef, "build-scout")
    XCTAssertEqual(delivered.source, "run:build-42")
    XCTAssertFalse(store.isAIChatThreadRunning(threadID))
  }

  @MainActor
  func testBackgroundAgentMessageIsDeliveredWithoutStartingATurn() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-inbox-\(UUID().uuidString)", isDirectory: true)
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatInboxTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let threadID = store.createOpenClawChatThread(runtime: .codex)
    store.settleOpenClawChatThread(threadID)
    XCTAssertTrue(store.openClawChatThreads.first(where: { $0.id == threadID })?.isSettled == true)
    let messageID = UUID()
    let inbox = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("ai-chat-inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let envelope = inbox.appendingPathComponent("\(messageID.uuidString.lowercased()).json")
    let payload: [String: Any] = [
      "schema": "org2:ai-chat-inbox-message:v1",
      "id": messageID.uuidString.lowercased(),
      "threadID": threadID.uuidString.lowercased(),
      "content": "The background export finished.",
      "createdAt": "2026-08-19T19:30:00.000Z",
      "authorLabel": "Revenue Scout",
      "authorAgentRef": "agent-profile-revenue-scout",
      "source": "run:export-42"
    ]
    try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
      .write(to: envelope, options: .atomic)

    store.drainAIChatInbox()

    let delivered = try XCTUnwrap(
      store.openClawChatThreads.first(where: { $0.id == threadID })
    )
    XCTAssertEqual(delivered.messages.count, 1)
    XCTAssertEqual(delivered.messages[0].id, messageID)
    XCTAssertEqual(delivered.messages[0].role, .assistant)
    XCTAssertEqual(delivered.messages[0].content, "The background export finished.")
    XCTAssertEqual(delivered.messages[0].authorLabel, "Revenue Scout")
    XCTAssertEqual(delivered.messages[0].authorAgentRef, "agent-profile-revenue-scout")
    XCTAssertEqual(delivered.messages[0].source, "run:export-42")
    XCTAssertEqual(delivered.unreadMessageCount, 1)
    XCTAssertFalse(delivered.isSettled)
    XCTAssertFalse(store.isAIChatThreadRunning(threadID))
    XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))

    let restored = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let restoredMessage = try XCTUnwrap(
      restored.openClawChatThreads.first(where: { $0.id == threadID })?.messages.first
    )
    XCTAssertEqual(restoredMessage.authorLabel, "Revenue Scout")
    XCTAssertEqual(restoredMessage.authorAgentRef, "agent-profile-revenue-scout")

    try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
      .write(to: envelope, options: .atomic)
    store.drainAIChatInbox()
    XCTAssertEqual(
      store.openClawChatThreads.first(where: { $0.id == threadID })?.messages.count,
      1
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))
  }

  func testCorpusEventsRecognizeAIChatInboxDeliveries() {
    let root = URL(fileURLWithPath: "/tmp/org2-ai-chat-inbox-events")
    let delivery = root
      .appendingPathComponent(".org2/ai-chat-inbox/message.json")
      .path
    let classified = WorkspaceStore.classifyCorpusFileEvents(
      [delivery],
      corpusRoot: root
    )
    XCTAssertTrue(classified.hasAIChatInboxChanges)
    XCTAssertTrue(classified.contentPaths.isEmpty)
  }
}
