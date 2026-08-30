import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor ClaudeEventRecorder {
  private var values: [String] = []

  func record(_ event: ClaudeCodeEvent) {
    switch event {
    case .sessionStarted(let sessionID): values.append("session:\(sessionID)")
    case .textDelta(let text): values.append("delta:\(text)")
    case .activity(_, let title, _): values.append("activity:\(title)")
    case .warning(let message): values.append("warning:\(message)")
    }
  }

  func snapshot() -> [String] { values }
}

final class ClaudeCodeClientTests: XCTestCase {
  func testExecutableResolutionPrefersExplicitConfiguration() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-claude-resolver-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude")
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    XCTAssertEqual(
      ClaudeCodeClient.resolveExecutableURL(environment: [
        "ORG2_CLAUDE_EXECUTABLE": executable.path,
        "HOME": root.path,
        "PATH": ""
      ]),
      executable.standardizedFileURL
    )
  }

  func testArgumentsMapLocalAgentAccessAndSessionOptions() {
    let prompt = URL(fileURLWithPath: "/tmp/context.txt")
    let attachments = URL(fileURLWithPath: "/tmp/attachments", isDirectory: true)
    let arguments = ClaudeCodeClient.arguments(
      sessionID: "session-123",
      model: "sonnet",
      sandboxAccess: .workspaceWrite,
      systemPromptFile: prompt,
      attachmentDirectory: attachments
    )

    XCTAssertTrue(arguments.contains("--include-partial-messages"))
    XCTAssertEqual(arguments.value(after: "--permission-mode"), "acceptEdits")
    XCTAssertEqual(arguments.value(after: "--resume"), "session-123")
    XCTAssertEqual(arguments.value(after: "--model"), "sonnet")
    XCTAssertEqual(arguments.value(after: "--add-dir"), attachments.path)
    XCTAssertEqual(ClaudeCodeClient.permissionMode(for: .readOnly), "plan")
    XCTAssertEqual(ClaudeCodeClient.permissionMode(for: .fullAccess), "bypassPermissions")
  }

  func testStreamDecoderExtractsSessionDeltasActivitiesAndResult() async {
    let recorder = ClaudeEventRecorder()
    var decoder = ClaudeCodeStreamDecoder()
    let lines = [
      #"{"type":"system","subtype":"init","session_id":"abc"}"#,
      #"{"type":"stream_event","session_id":"abc","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"tool-1","name":"Read"}}}"#,
      #"{"type":"stream_event","session_id":"abc","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}"#,
      #"{"type":"result","subtype":"success","is_error":false,"session_id":"abc","result":"Hello world"}"#
    ]
    for line in lines {
      await decoder.consume(line) { event in await recorder.record(event) }
    }

    XCTAssertEqual(decoder.result.sessionID, "abc")
    XCTAssertEqual(decoder.result.reply, "Hello world")
    XCTAssertTrue(decoder.result.succeeded)
    let events = await recorder.snapshot()
    XCTAssertEqual(events, ["session:abc", "activity:Reading", "delta:Hello"])
  }

  func testRunTurnUsesStreamJSONAndReturnsResumableSession() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-claude-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude")
    let argumentsLog = root.appendingPathComponent("arguments.txt")
    let inputLog = root.appendingPathComponent("input.txt")
    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" > "$ORG2_CLAUDE_TEST_ARGUMENTS"
    cat > "$ORG2_CLAUDE_TEST_INPUT"
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-new"}'
    printf '%s\\n' '{"type":"stream_event","session_id":"session-new","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"session-new","result":"Hi from Claude"}'
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let recorder = ClaudeEventRecorder()
    let client = ClaudeCodeClient(
      executableURL: executable,
      environment: [
        "ORG2_CLAUDE_TEST_ARGUMENTS": argumentsLog.path,
        "ORG2_CLAUDE_TEST_INPUT": inputLog.path,
        "PATH": "/usr/bin:/bin",
        "HOME": root.path
      ]
    ) { _, event in
      await recorder.record(event)
    }

    let result = try await client.runTurn(
      openOrgThreadID: UUID(),
      existingSessionID: "session-old",
      message: "Hello Claude",
      systemPrompt: "OpenOrg context",
      attachments: [],
      cwd: root,
      model: "sonnet",
      sandboxAccess: .readOnly
    )

    XCTAssertEqual(result, ClaudeCodeTurnResult(sessionID: "session-new", reply: "Hi from Claude"))
    XCTAssertEqual(try String(contentsOf: inputLog, encoding: .utf8), "Hello Claude")
    let arguments = try String(contentsOf: argumentsLog, encoding: .utf8)
    XCTAssertTrue(arguments.contains("--resume\nsession-old"))
    XCTAssertTrue(arguments.contains("--permission-mode\nplan"))
    XCTAssertTrue(arguments.contains("--model\nsonnet"))
    let events = await recorder.snapshot()
    XCTAssertEqual(events, ["session:session-new", "delta:Hi"])
  }
}

@MainActor
final class WorkspaceClaudeCodeDestinationTests: XCTestCase {
  func testBuiltInClaudeDestinationRoutesAndPersistsSession() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-claude-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("chats.json")
    let suiteName = "WorkspaceClaudeCodeDestinationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      claudeSendHandlerForTesting: { messages, _, _ in
        XCTAssertEqual(messages.last(where: { $0.role == .user })?.content, "Hello Claude")
        return ClaudeCodeTurnResult(sessionID: "claude-session-1", reply: "Hello from Claude")
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root)

    XCTAssertEqual(
      store.aiChatDestination(id: AIChatDestinationConfiguration.localClaudeID)?.adapter,
      .claudeLocal
    )
    var claude = try XCTUnwrap(
      store.aiChatDestination(id: AIChatDestinationConfiguration.localClaudeID)
    )
    XCTAssertFalse(claude.isEnabled)
    claude.isEnabled = true
    store.updateAIChatDestination(claude)
    let threadID = store.createAIChatThread(
      destinationID: AIChatDestinationConfiguration.localClaudeID
    )
    await store.sendOpenClawMessage(text: "Hello Claude")

    let thread = try XCTUnwrap(store.openClawChatThreads.first(where: { $0.id == threadID }))
    XCTAssertEqual(thread.runtime, .claude)
    XCTAssertEqual(thread.destinationID, AIChatDestinationConfiguration.localClaudeID)
    XCTAssertEqual(
      thread.runtimeThreadID(forDestinationID: AIChatDestinationConfiguration.localClaudeID),
      "claude-session-1"
    )
    XCTAssertEqual(thread.messages.last(where: { $0.role == .assistant })?.content, "Hello from Claude")
  }
}

private extension Array where Element == String {
  func value(after flag: String) -> String? {
    guard let index = firstIndex(of: flag), indices.contains(index + 1) else { return nil }
    return self[index + 1]
  }
}
