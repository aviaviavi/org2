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

  func testFilePreviewRoundTrips() throws {
    let expected = MobileRemoteFilePreview(
      title: "talk.org2",
      relativePath: "notes/talk.org2",
      startLine: 23,
      highlightedLine: 31,
      content: "* Opening\nThe experiment gap"
    )

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(MobileRemoteFilePreview.self, from: data)

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

  func testMobileActivityPresentationHidesEmptyLifecycleAndGroupsUsefulWork() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let activities = [
      OpenClawRunActivity(
        id: "lifecycle-start",
        runID: "run-1",
        kind: .lifecycle,
        title: "Agent started",
        status: .running,
        updatedAt: now
      ),
      OpenClawRunActivity(
        id: "shell-1",
        runID: "run-1",
        kind: .tool,
        title: "Shell command",
        status: .succeeded,
        updatedAt: now.addingTimeInterval(1)
      ),
      OpenClawRunActivity(
        id: "shell-2",
        runID: "run-1",
        kind: .tool,
        title: "Shell command",
        status: .failed,
        updatedAt: now.addingTimeInterval(2)
      )
    ]

    let presented = MobileRemoteActivityPresentation.items(from: activities)

    let item = try XCTUnwrap(presented.first)
    XCTAssertEqual(presented.count, 1)
    XCTAssertEqual(item.title, "2 shell command calls")
    XCTAssertEqual(item.detail, "1 completed · 1 failed")
    XCTAssertEqual(item.status, "succeeded")
    XCTAssertEqual(item.updatedAt, now.addingTimeInterval(2))
    XCTAssertFalse(presented.contains(where: { $0.title == "Agent started" }))
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
  func testFilePreviewReadsOnlyOrgFilesInsideMountedCorpora() throws {
    let suiteName = "MobileRemoteHTTPServerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-preview-\(UUID().uuidString)", isDirectory: true)
    let root = container.appendingPathComponent("demo.org2", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let source = notes.appendingPathComponent("talk.org2")
    let sourceText = (1...30).map { "Line \($0)" }.joined(separator: "\n")
    try sourceText.write(to: source, atomically: true, encoding: .utf8)
    let outside = container.appendingPathComponent("outside.org2")
    try "Private".write(to: outside, atomically: true, encoding: .utf8)
    let symlink = notes.appendingPathComponent("escape.org2")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: container.appendingPathComponent("openclaw-chat.json")
    )
    store.setCorpusRoot(root)

    let relativePreview = try store.mobileRemoteFilePreview(
      path: "notes/talk.org2",
      line: 12
    )
    XCTAssertEqual(relativePreview.title, "talk.org2")
    XCTAssertEqual(relativePreview.relativePath, "notes/talk.org2")
    XCTAssertEqual(relativePreview.startLine, 4)
    XCTAssertEqual(relativePreview.highlightedLine, 12)
    XCTAssertTrue(relativePreview.content.contains("Line 12"))

    let absolutePreview = try store.mobileRemoteFilePreview(path: source.path, line: 1)
    XCTAssertEqual(absolutePreview.relativePath, "notes/talk.org2")

    XCTAssertThrowsError(try store.mobileRemoteFilePreview(path: outside.path, line: 1))
    XCTAssertThrowsError(try store.mobileRemoteFilePreview(path: symlink.path, line: 1))
    XCTAssertThrowsError(try store.mobileRemoteFilePreview(path: "../outside.org2", line: 1))
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
  func testRemoteAndMacSendsShareThreadContextWithoutRemoteNavigationLeak() async throws {
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
    store.renameOpenClawChatThread(threadID, title: "Render Atlanta Talk")

    XCTAssertTrue(store.sendAIChatRemoteMessage(
      "Use selected page “Opening” at notes/render-atlanta.org2:1 as context.\n\nImprove the talk.",
      threadID: threadID
    ))
    let firstReplyDeadline = Date().addingTimeInterval(5)
    while (
      store.openClawChatThreads.first(where: { $0.id == threadID })?.messages.count != 2
        || store.isAIChatThreadRunning(threadID)
    ),
          Date() < firstReplyDeadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    store.selectCorpusFile(CorpusFile(
      path: unrelatedNote.path,
      relativePath: unrelatedNote.lastPathComponent,
      modifiedAt: nil,
      byteCount: 0
    ))
    XCTAssertEqual(store.selectedLocation?.file, unrelatedNote.path)

    XCTAssertTrue(store.sendAIChatRemoteMessage("Continue this thread", threadID: threadID))
    let deadline = Date().addingTimeInterval(5)
    while await recorder.contexts().count < 2, Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    let recordedContext = await recorder.contexts().last
    let context = try XCTUnwrap(recordedContext)
    XCTAssertEqual(context.selectedSurface, WorkspaceSurface.openClaw.title)
    XCTAssertNil(context.selectedLocation)
    XCTAssertNil(context.selectedEntrySource)
    XCTAssertNil(context.backlinks)
    XCTAssertNil(context.agenda)
    XCTAssertTrue(context.searchQuery.isEmpty)
    XCTAssertTrue(context.searchResults.isEmpty)
    XCTAssertEqual(context.authorizedCorpora.first?.localRoot, root.standardizedFileURL.path)
    let prompt = context.systemPrompt()
    XCTAssertTrue(prompt.contains("Selected AI chat thread continuation"))
    XCTAssertTrue(prompt.contains("Thread title: Render Atlanta Talk"))
    XCTAssertTrue(prompt.contains("Improve the talk."))
    XCTAssertTrue(prompt.contains("Remote reply"))
    XCTAssertTrue(prompt.contains("notes/render-atlanta.org2:1"))
    XCTAssertTrue(prompt.contains("Org2 response formatting contract"))
    XCTAssertTrue(prompt.contains("|-------+--------------|"))
    XCTAssertFalse(prompt.contains("unrelated-meeting.org2"))
    let codexPrompt = context.codexSystemPrompt()
    XCTAssertTrue(codexPrompt.contains("Thread title: Render Atlanta Talk"))
    XCTAssertTrue(codexPrompt.contains("Improve the talk."))
    XCTAssertTrue(codexPrompt.contains("notes/render-atlanta.org2:1"))
    XCTAssertTrue(codexPrompt.contains("Org2 response formatting contract"))
    XCTAssertTrue(codexPrompt.contains("|-------+--------------|"))
    XCTAssertFalse(codexPrompt.contains("unrelated-meeting.org2"))

    let secondReplyDeadline = Date().addingTimeInterval(5)
    while (
      store.openClawChatThreads.first(where: { $0.id == threadID })?.messages.count != 4
        || store.isAIChatThreadRunning(threadID)
    ),
          Date() < secondReplyDeadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    store.selectOpenClawChatThread(threadID)
    store.sendComposedOpenClawMessage(text: "Continue from the Mac")
    let macContextDeadline = Date().addingTimeInterval(5)
    while await recorder.contexts().count < 3, Date() < macContextDeadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    let recordedMacContext = await recorder.contexts().last
    let macContext = try XCTUnwrap(recordedMacContext)
    XCTAssertEqual(macContext.selectedLocation?.file, unrelatedNote.path)
    XCTAssertEqual(macContext.threadContinuation?.title, context.threadContinuation?.title)
    XCTAssertEqual(
      macContext.threadContinuation?.org2References,
      context.threadContinuation?.org2References
    )
    let macPrompt = macContext.systemPrompt()
    XCTAssertTrue(macPrompt.contains("Thread title: Render Atlanta Talk"))
    XCTAssertTrue(macPrompt.contains("Continue this thread"))
    XCTAssertTrue(macPrompt.contains("notes/render-atlanta.org2:1"))
  }
}

private actor MobileRemoteWorkspaceContextRecorder {
  private var recordedContexts: [OpenClawWorkspaceContext] = []

  func record(_ context: OpenClawWorkspaceContext?) {
    if let context {
      recordedContexts.append(context)
    }
  }

  func contexts() -> [OpenClawWorkspaceContext] {
    recordedContexts
  }
}
