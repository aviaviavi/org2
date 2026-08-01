import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class MobileRemoteHTTPServerTests: XCTestCase {
  func testParsesAuthenticatedJSONRequestAfterFullBodyArrives() throws {
    let body = try MobileRemoteProtocol.encoder().encode(
      MobileRemoteSendMessageRequest(
        content: "Continue the review",
        attachments: [
          MobileRemoteAttachment(
            fileName: "whiteboard.jpg",
            mimeType: "image/jpeg",
            data: Data([0x01, 0x02, 0x03])
          )
        ]
      )
    )
    let header =
      "POST /v1/threads/123/messages HTTP/1.1\r\n" +
      "Host: 100.64.0.1:48922\r\n" +
      "Authorization: Bearer secret-token\r\n" +
      "Content-Type: application/json\r\n" +
      "Content-Length: \(body.count)\r\n\r\n"
    var bytes = Data(header.utf8)
    bytes.append(body)

    let request = try XCTUnwrap(MobileRemoteHTTPConnection.parseRequestIfComplete(bytes))
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/v1/threads/123/messages")
    XCTAssertEqual(request.bearerToken, "secret-token")
    let decoded = try request.decode(MobileRemoteSendMessageRequest.self)
    XCTAssertEqual(decoded.content, "Continue the review")
    XCTAssertEqual(decoded.attachments.first?.fileName, "whiteboard.jpg")
    XCTAssertEqual(decoded.attachments.first?.data, Data([0x01, 0x02, 0x03]))
  }

  func testWaitsForTheDeclaredBodyLength() {
    let rawRequest =
      "POST /v1/pair HTTP/1.1\r\n" +
      "Content-Length: 12\r\n\r\n" +
      "{\"code\":\"1\""
    let partial = Data(rawRequest.utf8)

    XCTAssertNil(MobileRemoteHTTPConnection.parseRequestIfComplete(partial))
  }

  func testWireDatesRoundTripWithSharedEncoding() throws {
    let expected = MobileRemoteThreadSummary(
      id: UUID(),
      title: "Remote chat",
      runtime: "codex",
      model: "gpt-test",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      isSettled: false,
      isPinned: true,
      isRunning: true,
      unreadMessageCount: 2,
      preview: "Working"
    )

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(MobileRemoteThreadSummary.self, from: data)

    XCTAssertEqual(restored, expected)
  }

  func testModelConfigurationRoundTripsWithProtocolVersionTwo() throws {
    let threadID = UUID()
    let expected = MobileRemoteThreadConfiguration(
      threadID: threadID,
      model: "gpt-test",
      models: [
        MobileRemoteModelOption(
          id: "gpt-test",
          label: "GPT Test",
          detail: "A test model",
          isDefault: true
        )
      ],
      reasoningEffort: "high",
      reasoningOptions: [
        MobileRemoteReasoningOption(id: "medium", label: "Medium", detail: nil),
        MobileRemoteReasoningOption(id: "high", label: "High", detail: "More reasoning")
      ],
      defaultReasoningEffort: "medium"
    )

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteThreadConfiguration.self,
      from: data
    )

    XCTAssertEqual(MobileRemoteProtocol.version, 2)
    XCTAssertEqual(restored, expected)
  }

  func testReasoningConfigurationMutationRoundTrips() throws {
    let expected = MobileRemoteUpdateThreadConfigurationRequest(reasoningEffort: "high")

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteUpdateThreadConfigurationRequest.self,
      from: data
    )

    XCTAssertEqual(restored, expected)
    XCTAssertEqual(restored.setting, "reasoning")
    XCTAssertEqual(restored.value, "high")
  }

  func testThreadStateMutationRoundTrips() throws {
    let expected = MobileRemoteUpdateThreadStateRequest(
      isPinned: true,
      isSettled: false
    )

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteUpdateThreadStateRequest.self,
      from: data
    )

    XCTAssertEqual(restored, expected)
  }

  @MainActor
  func testRemoteThreadCreationDoesNotChangeTheMacSelection() throws {
    let suiteName = "MobileRemoteHTTPServerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-remote-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcriptURL) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcriptURL
    )

    let selectedID = store.createOpenClawChatThread(runtime: .openClaw)
    let remoteID = store.createAIChatRemoteThread(runtime: .codex)

    XCTAssertEqual(store.selectedOpenClawChatThreadID, selectedID)
    XCTAssertNotEqual(remoteID, selectedID)
    XCTAssertEqual(store.openClawChatThreads.first(where: { $0.id == remoteID })?.runtime, .codex)
  }

  @MainActor
  func testRemoteThreadStateUpdatesAreExplicitAndIdempotent() throws {
    let suiteName = "MobileRemoteHTTPServerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-remote-state-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcriptURL) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcriptURL
    )
    let threadID = store.createAIChatRemoteThread(runtime: .openClaw)

    XCTAssertTrue(store.updateAIChatRemoteThreadState(
      threadID: threadID,
      isPinned: true,
      isSettled: true
    ))
    XCTAssertEqual(store.openClawChatThreads.first(where: { $0.id == threadID })?.isPinned, true)
    XCTAssertEqual(store.openClawChatThreads.first(where: { $0.id == threadID })?.isSettled, true)

    XCTAssertTrue(store.updateAIChatRemoteThreadState(
      threadID: threadID,
      isPinned: true,
      isSettled: true
    ))
    XCTAssertEqual(store.openClawChatThreads.first(where: { $0.id == threadID })?.isPinned, true)
    XCTAssertEqual(store.openClawChatThreads.first(where: { $0.id == threadID })?.isSettled, true)

    XCTAssertTrue(store.updateAIChatRemoteThreadState(
      threadID: threadID,
      isPinned: false,
      isSettled: false
    ))
    XCTAssertEqual(store.openClawChatThreads.first(where: { $0.id == threadID })?.isPinned, false)
    XCTAssertEqual(store.openClawChatThreads.first(where: { $0.id == threadID })?.isSettled, false)
  }

  @MainActor
  func testRemoteSendDoesNotInheritTheMacNavigationContext() async throws {
    let suiteName = "MobileRemoteHTTPServerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-remote-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let unrelatedNote = root.appendingPathComponent("unrelated-meeting.org2")
    try "#+TITLE: Unrelated Meeting\n".write(to: unrelatedNote, atomically: true, encoding: .utf8)
    let recorder = MobileRemoteWorkspaceContextRecorder()
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      openClawSendHandler: { _, _, _, context in
        await recorder.record(context)
        return "Remote reply"
      }
    )
    store.setCorpusRoot(root)
    let threadID = store.createAIChatRemoteThread(runtime: .openClaw)
    store.selectCorpusFile(CorpusFile(
      path: unrelatedNote.path,
      relativePath: unrelatedNote.lastPathComponent,
      modifiedAt: nil,
      byteCount: 0
    ))
    XCTAssertEqual(store.selectedLocation?.file, unrelatedNote.path)

    XCTAssertTrue(store.sendAIChatRemoteMessage("Continue this thread", threadID: threadID))
    let deadline = Date().addingTimeInterval(5)
    while await recorder.context() == nil, Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    let recordedContext = await recorder.context()
    let context = try XCTUnwrap(recordedContext)
    XCTAssertEqual(context.selectedSurface, WorkspaceSurface.openClaw.title)
    XCTAssertNil(context.selectedLocation)
    XCTAssertNil(context.selectedEntrySource)
    XCTAssertNil(context.backlinks)
    XCTAssertNil(context.agenda)
    XCTAssertTrue(context.searchQuery.isEmpty)
    XCTAssertTrue(context.searchResults.isEmpty)
    XCTAssertEqual(context.authorizedCorpora.first?.localRoot, root.standardizedFileURL.path)
  }
}

private actor MobileRemoteWorkspaceContextRecorder {
  private var recordedContext: OpenClawWorkspaceContext?

  func record(_ context: OpenClawWorkspaceContext?) {
    recordedContext = context
  }

  func context() -> OpenClawWorkspaceContext? {
    recordedContext
  }
}
