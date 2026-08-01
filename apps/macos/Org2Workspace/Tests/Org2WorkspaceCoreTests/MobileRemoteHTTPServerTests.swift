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
}
