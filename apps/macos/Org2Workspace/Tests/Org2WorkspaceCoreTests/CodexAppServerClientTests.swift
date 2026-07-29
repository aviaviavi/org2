import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class CodexAppServerClientTests: XCTestCase {
  func testLegacyChatThreadDefaultsToOpenClawRuntime() throws {
    let id = UUID()
    let json = """
    {
      "id": "\(id.uuidString)",
      "title": "Legacy",
      "createdAt": 0,
      "updatedAt": 0,
      "sessionKey": "agent:main:org2-workspace:legacy",
      "messages": []
    }
    """

    let thread = try JSONDecoder().decode(
      OpenClawChatThread.self,
      from: Data(json.utf8)
    )

    XCTAssertEqual(thread.runtime, .openClaw)
    XCTAssertNil(thread.runtimeThreadID)
  }

  func testCodexChatThreadRuntimeRoundTrips() throws {
    let thread = OpenClawChatThread(
      title: "Local Codex",
      runtime: .codex,
      sessionKey: "unused-for-codex",
      runtimeThreadID: "thr_codex"
    )

    let data = try JSONEncoder().encode(thread)
    let restored = try JSONDecoder().decode(OpenClawChatThread.self, from: data)

    XCTAssertEqual(restored.runtime, .codex)
    XCTAssertEqual(restored.runtimeThreadID, "thr_codex")
  }

  func testChatRuntimeLocksAfterFirstMessage() {
    let thread = OpenClawChatThread(
      title: "Runtime picker",
      runtime: .openClaw,
      sessionKey: "agent:main:runtime-picker"
    )

    XCTAssertTrue(thread.canChangeAIRuntime)
    XCTAssertFalse(
      thread.replacingMessages([
        OpenClawChatMessage(role: .user, content: "Hello")
      ]).canChangeAIRuntime
    )
  }

  func testCodexWorkspaceSnapshotIncludesUnsavedSelectedSource() {
    let context = OpenClawWorkspaceContext(
      localCorpusRoot: "/tmp/example-corpus",
      remoteCorpusRoot: nil,
      selectedSurface: "Files",
      selectedLocation: nil,
      selectedEntrySource: EntrySource(
        file: "/tmp/example-corpus/notes/draft.org2",
        startLine: 1,
        endLineExclusive: 3,
        text: "* Draft\nUnsaved editor text",
        isSubtree: false
      ),
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: []
    )

    let snapshot = context.codexSystemPrompt()

    XCTAssertTrue(snapshot.contains("may include unsaved editor changes"))
    XCTAssertTrue(snapshot.contains("notes/draft.org2"))
    XCTAssertTrue(snapshot.contains("Unsaved editor text"))
  }

  @MainActor
  func testWorkspaceCreatesAndRestoresCodexThread() throws {
    let suiteName = "CodexAppServerClientTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-transcript-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.createOpenClawChatThread()
    XCTAssertTrue(store.canChangeSelectedAIChatRuntime)
    store.setSelectedAIChatRuntime(.codex)
    XCTAssertEqual(store.selectedOpenClawChatThread?.runtime, .codex)
    XCTAssertEqual(
      store.visibleOpenClawChatThreads.first(where: {
        $0.id == store.selectedOpenClawChatThreadID
      })?.runtime,
      .codex
    )

    let restored = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    XCTAssertEqual(restored.selectedOpenClawChatThread?.runtime, .codex)
  }

  func testClientRunsCodexTurnAndAnswersDynamicToolCall() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-app-server-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex")
    try Self.fakeAppServerScript.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )

    let recorder = CodexTestRecorder()
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { event in
        await recorder.record(event)
      },
      dynamicToolHandler: { call in
        await recorder.record(call)
        return CodexDynamicToolResult(
          success: true,
          text: #"{"path":"notes/example.org2","text":"effective local text"}"#
        )
      }
    )

    let account = try await client.accountState()
    XCTAssertEqual(account, .chatGPT(email: "test@example.com", plan: "plus"))

    let threadID = try await client.ensureThread(
      existingThreadID: nil,
      cwd: temporaryDirectory
    )
    XCTAssertEqual(threadID, "thr-test")

    let result = try await client.runTurn(
      threadID: threadID,
      turnID: "local-turn",
      message: "Read the note.",
      workspaceContext: "Selected source includes an unsaved draft.",
      attachments: [],
      cwd: temporaryDirectory,
      clientUserMessageID: UUID()
    )
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.reply, "Final reply")

    let toolCall = await recorder.toolCall
    XCTAssertEqual(toolCall?.tool, "org2_workspace_read")
    XCTAssertEqual(toolCall?.arguments["turnId"]?.stringValue, "local-turn")
    let streamedText = await recorder.streamedText
    XCTAssertEqual(streamedText, "Working…")

    await client.shutdown()
  }

  private static let fakeAppServerScript = #"""
  #!/bin/sh
  while IFS= read -r line; do
    case "$line" in
      *'"method":"initialize"'*)
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake-codex"}}'
        ;;
      *'"method":"initialized"'*)
        ;;
      *'"method":"account/read"'*)
        printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"test@example.com","planType":"plus"},"requiresOpenaiAuth":true}}'
        ;;
      *'"method":"thread/start"'*)
        printf '%s\n' '{"id":3,"result":{"thread":{"id":"thr-test"}}}'
        ;;
      *'"method":"turn/start"'*)
        printf '%s\n' '{"id":4,"result":{"turn":{"id":"turn-test","status":"inProgress","items":[],"error":null}}}'
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-test","turn":{"id":"turn-test","status":"inProgress","items":[],"error":null}}}'
        printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thr-test","turnId":"turn-test","itemId":"msg-test","delta":"Working…"}}'
        printf '%s\n' '{"id":"tool-request","method":"item/tool/call","params":{"callId":"call-test","threadId":"thr-test","turnId":"turn-test","tool":"org2_workspace_read","arguments":{"turnId":"local-turn","path":"notes/example.org2"}}}'
        printf '%s\n' '{"method":"item/completed","params":{"threadId":"thr-test","turnId":"turn-test","completedAtMs":1,"item":{"type":"agentMessage","id":"msg-test","text":"Final reply","phase":"final_answer"}}}'
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-test","turn":{"id":"turn-test","status":"completed","items":[],"error":null}}}'
        ;;
    esac
  done
  """#
}

private actor CodexTestRecorder {
  private(set) var toolCall: CodexDynamicToolCall?
  private(set) var streamedText = ""

  func record(_ event: CodexAppServerEvent) {
    if case .agentMessageDelta(_, _, let delta) = event {
      streamedText += delta
    }
  }

  func record(_ call: CodexDynamicToolCall) {
    toolCall = call
  }
}
