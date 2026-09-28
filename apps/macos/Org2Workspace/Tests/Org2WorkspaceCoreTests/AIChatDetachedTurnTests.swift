import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor RecoveredTurnLog {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

/// OpenOrg can quit, crash, or be rebuilt while an agent turn is running.
/// Afterwards a chat must either follow the turn that is still running or show
/// it as interrupted; it must never look busy with no way to stop or retry.
final class AIChatDetachedTurnTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-detached-turn-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: Stale sends

  func testStaleSendRepairInterruptsOnlyThisHostsTurnsFromAnEarlierProcess() {
    let startedAt = Date()
    let earlier = startedAt.addingTimeInterval(-60)
    func send(_ content: String, host: String?, acceptedAt: Date?, createdAt: Date = earlier) -> OpenClawChatMessage {
      OpenClawChatMessage(
        role: .user,
        content: content,
        createdAt: createdAt,
        deliveryStatus: .sending,
        provenance: host.map {
          AIChatMessageProvenance(executionHostRef: $0, executionHostName: $0, acceptedAt: acceptedAt)
        }
      )
    }
    let local = send("local", host: "desktop-here", acceptedAt: earlier)
    let legacy = send("legacy", host: nil, acceptedAt: nil)
    let remote = send("remote", host: "desktop-there", acceptedAt: earlier)
    let handoff = send("handoff", host: "desktop-here", acceptedAt: nil)
    let acceptedNow = send("accepted by this process", host: "desktop-here", acceptedAt: startedAt.addingTimeInterval(1))
    let thread = OpenClawChatThread(
      title: "Mixed",
      sessionKey: "mixed",
      messages: [local, legacy, remote, handoff, acceptedNow]
    )

    let repaired = WorkspaceStore.interruptStaleLocalAIChatSends(
      in: [thread],
      processStartedAt: startedAt,
      isLocalHost: { $0 == "desktop-here" }
    )

    XCTAssertTrue(repaired.changed)
    XCTAssertEqual(repaired.threads.first?.messages.map(\.deliveryStatus), [
      .interrupted, .sending, .sending, .sending, .sending
    ])
  }

  func testStaleSendRepairLeavesRecoverablePendingTurnsAndColdThreads() {
    let startedAt = Date()
    let message = OpenClawChatMessage(
      role: .user,
      content: "Reattach me",
      createdAt: startedAt.addingTimeInterval(-60),
      deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        executionHostRef: "desktop-here",
        acceptedAt: startedAt.addingTimeInterval(-60)
      )
    )
    let recoverable = OpenClawChatThread(
      title: "Recoverable",
      sessionKey: "recoverable",
      messages: [message],
      pendingTurn: OpenClawPendingTurn(
        userMessageID: message.id,
        runID: message.id.uuidString.lowercased(),
        agentID: "opencode",
        gatewayMessage: ""
      )
    )
    let cold = OpenClawChatThread(title: "Cold", sessionKey: "cold", messages: [message])
      .metadataOnly()

    let repaired = WorkspaceStore.interruptStaleLocalAIChatSends(
      in: [recoverable, cold],
      processStartedAt: startedAt,
      isLocalHost: { _ in true }
    )

    XCTAssertFalse(repaired.changed)
  }

  /// The reported bug: after a mid-turn restart the chat stayed "working"
  /// with no Stop or Retry. The repaired state must also be saved, or the
  /// next replica refresh brings the busy turn back.
  @MainActor
  func testRelaunchPersistsInterruptionOfThisHostsUnrecoverableTurn() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let hostRef = AIChatHostIdentity.desktop(writer: AIChatTranscriptStore.shared.writerIdentity).ref
    let earlier = Date().addingTimeInterval(-60)
    let stale = OpenClawChatMessage(
      role: .user,
      content: "Rebuilt the app mid-turn",
      createdAt: earlier,
      deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        executionHostRef: hostRef,
        executionHostName: "AiroPress",
        acceptedAt: earlier
      )
    )
    let thread = OpenClawChatThread(
      title: "Mid-turn restart",
      runtime: .openCode,
      destinationID: "missing-destination",
      sessionKey: "mid-turn-restart",
      messages: [stale]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [thread],
        selectedThreadID: thread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )

    let store = try makeStore(transcriptURL: transcriptURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    try await store.waitForAIChatTranscriptPersistenceForTesting()

    XCTAssertFalse(store.isAIChatThreadRunning(thread.id))
    XCTAssertEqual(
      store.openClawChatThreads.first(where: { $0.id == thread.id })?.messages.first?.deliveryStatus,
      .interrupted
    )
    let persisted = AIChatTranscriptStore.shared.loadThread(
      id: thread.id,
      metadata: thread.metadataOnly(),
      legacyURL: transcriptURL
    )
    XCTAssertEqual(persisted?.messages.first?.deliveryStatus, .interrupted)
  }

  /// Threads outside the eager working set load without messages, so the
  /// launch repair cannot see their stale sends until they are opened.
  @MainActor
  func testOpeningAColdThreadInterruptsItsStaleLocalSend() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let hostRef = AIChatHostIdentity.desktop(writer: AIChatTranscriptStore.shared.writerIdentity).ref
    let earlier = Date().addingTimeInterval(-3_600)
    let stale = OpenClawChatMessage(
      role: .user,
      content: "Rebuilt the app mid-turn",
      createdAt: earlier,
      deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        executionHostRef: hostRef,
        executionHostName: "AiroPress",
        acceptedAt: earlier
      )
    )
    let cold = OpenClawChatThread(
      title: "Cold mid-turn restart",
      createdAt: earlier,
      updatedAt: earlier,
      runtime: .openCode,
      destinationID: "missing-destination",
      sessionKey: "cold-mid-turn",
      messages: [stale]
    )
    let fillers = (0..<(AIChatTranscriptStore.eagerWorkingSetLimit + 4)).map { index in
      OpenClawChatThread(
        title: "Recent \(index)",
        sessionKey: "recent-\(index)",
        messages: [OpenClawChatMessage(role: .user, content: "hello \(index)")]
      )
    }
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: fillers + [cold],
        selectedThreadID: fillers[0].id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )

    let store = try makeStore(transcriptURL: transcriptURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(
      store.openClawChatThreads.first(where: { $0.id == cold.id })?.messages.count,
      0,
      "The fixture thread must start cold"
    )

    let hydrated = await store.hydratedAIChatThreadForDetail(cold.id)
    XCTAssertNotNil(hydrated)
    try await store.waitForAIChatTranscriptPersistenceForTesting()

    XCTAssertFalse(store.isAIChatThreadRunning(cold.id))
    XCTAssertEqual(
      store.openClawChatThreads.first(where: { $0.id == cold.id })?.messages.first?.deliveryStatus,
      .interrupted
    )
    let persisted = AIChatTranscriptStore.shared.loadThread(
      id: cold.id,
      metadata: cold.metadataOnly(),
      legacyURL: transcriptURL
    )
    XCTAssertEqual(persisted?.messages.first?.deliveryStatus, .interrupted)
  }

  /// A saved remote OpenCode turn is resumed (reattached) after relaunch
  /// rather than failed as an unavailable destination.
  @MainActor
  func testRemoteOpenCodePendingTurnIsRecoveredAfterRelaunch() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let destination = AIChatDestinationConfiguration(
      name: "OpenCode",
      mention: "opencode-press",
      adapter: .openCodeRemote,
      endpoint: "press"
    )
    let user = OpenClawChatMessage(role: .user, content: "Keep going", deliveryStatus: .sending)
    let pendingTurn = OpenClawPendingTurn(
      userMessageID: user.id,
      runID: user.id.uuidString.lowercased(),
      agentID: "opencode",
      destinationID: destination.id,
      gatewayMessage: ""
    )
    let thread = OpenClawChatThread(
      title: "Remote turn",
      runtime: .openCode,
      destinationID: destination.id,
      sessionKey: "remote-turn",
      messages: [user],
      pendingTurn: pendingTurn
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [thread],
        selectedThreadID: thread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let recovered = RecoveredTurnLog()
    let suite = "detached-turn-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      openClawRecoveryHandler: { turn, _ in
        await recovered.append(turn.runID)
        return "Finished while OpenOrg restarted"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.updateAIChatDestination(destination)

    await store.recoverPendingOpenClawTurns()

    let runIDs = await recovered.values
    XCTAssertEqual(runIDs, [pendingTurn.runID])
    let messages = store.openClawChatThreads.first(where: { $0.id == thread.id })?.messages ?? []
    XCTAssertEqual(messages.map(\.content), ["Keep going", "Finished while OpenOrg restarted"])
    XCTAssertEqual(messages.first?.deliveryStatus, .sent)
    XCTAssertNil(store.openClawChatThreads.first(where: { $0.id == thread.id })?.pendingTurn)
    XCTAssertFalse(store.isAIChatThreadRunning(thread.id))
  }

  // MARK: Remote OpenCode supervisor

  /// Runs the real remote supervisor scripts against a fake `opencode`: the
  /// turn keeps running after OpenOrg's channel closes, and `attach` replays
  /// its whole event stream and exit status.
  func testRemoteTurnOutlivesItsChannelAndAttachReplaysIt() throws {
    let python = try pythonExecutable()
    let environment = try fakeOpenCodeEnvironment(runScript: """
      echo '{"type":"step_start","sessionID":"ses_detached","part":{}}'
      echo '{"type":"text","sessionID":"ses_detached","part":{"text":"Partial"}}'
      sleep 1
      echo '{"type":"text","sessionID":"ses_detached","part":{"text":" and done."}}'
      """)
    let threadID = UUID().uuidString.lowercased()

    let run = try startPython(
      python,
      source: OpenCodeClient.managedRemotePythonBootstrap,
      input: runPayload(threadID: threadID, token: "turn-1"),
      environment: environment
    )
    // Read until the turn starts streaming, then disappear like a quitting app.
    let firstLines = try readLines(run.output, count: 2)
    XCTAssertTrue(firstLines[0].contains("openorg_server"))
    XCTAssertTrue(firstLines[1].contains("ses_detached"))
    try run.output.close()
    run.process.waitUntilExit()

    let attach = try runPython(
      python,
      source: OpenCodeClient.managedRemoteAttachPythonBootstrap,
      input: #"{"threadID":"\#(threadID)","runToken":"turn-1"}"#,
      environment: environment
    )
    XCTAssertEqual(attach.status, 0)
    XCTAssertTrue(attach.output.contains("Partial"))
    XCTAssertTrue(attach.output.contains(" and done."))

    let again = try runPython(
      python,
      source: OpenCodeClient.managedRemoteAttachPythonBootstrap,
      input: #"{"threadID":"\#(threadID)","runToken":"turn-1"}"#,
      environment: environment
    )
    XCTAssertEqual(again.status, OpenCodeClient.detachedRunMissingStatus)
  }

  func testRemoteStopEndsADetachedTurn() throws {
    let python = try pythonExecutable()
    let environment = try fakeOpenCodeEnvironment(runScript: """
      echo '{"type":"step_start","sessionID":"ses_stop","part":{}}'
      exec sleep 60
      """)
    let threadID = UUID().uuidString.lowercased()
    let run = try startPython(
      python,
      source: OpenCodeClient.managedRemotePythonBootstrap,
      input: runPayload(threadID: threadID, token: "turn-2"),
      environment: environment
    )
    _ = try readLines(run.output, count: 2)

    let stop = try runPython(
      python,
      source: OpenCodeClient.managedRemoteStopPythonBootstrap,
      input: #"{"threadID":"\#(threadID)"}"#,
      environment: environment
    )
    XCTAssertEqual(stop.status, 0)
    let deadline = Date().addingTimeInterval(10)
    while run.process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    XCTAssertFalse(run.process.isRunning, "stop must end the supervisor and its turn")
    if run.process.isRunning { run.process.terminate() }
  }

  func testAttachReportsAMissingTurn() throws {
    let python = try pythonExecutable()
    let environment = try fakeOpenCodeEnvironment(runScript: "true")
    let attach = try runPython(
      python,
      source: OpenCodeClient.managedRemoteAttachPythonBootstrap,
      input: #"{"threadID":"\#(UUID().uuidString.lowercased())"}"#,
      environment: environment
    )
    XCTAssertEqual(attach.status, OpenCodeClient.detachedRunMissingStatus)
  }

  // MARK: Helpers

  @MainActor
  private func makeStore(transcriptURL: URL) throws -> WorkspaceStore {
    let suite = "detached-turn-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    return store
  }

  private func pythonExecutable() throws -> URL {
    for path in ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"]
    where FileManager.default.isExecutableFile(atPath: path) {
      let probe = Process()
      probe.executableURL = URL(fileURLWithPath: path)
      probe.arguments = ["-c", "import sys"]
      probe.standardOutput = FileHandle.nullDevice
      probe.standardError = FileHandle.nullDevice
      try? probe.run()
      probe.waitUntilExit()
      if probe.terminationStatus == 0 { return URL(fileURLWithPath: path) }
    }
    throw XCTSkip("python3 is not available")
  }

  private func fakeOpenCodeEnvironment(runScript: String) throws -> [String: String] {
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let opencode = bin.appendingPathComponent("opencode")
    try """
      #!/bin/sh
      if [ "$1" = "serve" ]; then
        echo "server listening on http://127.0.0.1:4096"
        exec sleep 60
      fi
      \(runScript)
      """.write(to: opencode, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opencode.path)
    return [
      "PATH": "\(bin.path):/usr/bin:/bin",
      "HOME": root.path,
      "XDG_STATE_HOME": root.appendingPathComponent("state").path
    ]
  }

  private func runPayload(threadID: String, token: String) -> String {
    let workspace = root.appendingPathComponent("workspace").path
    return #"{"workspacePath":"\#(workspace)","threadID":"\#(threadID)","runToken":"\#(token)","arguments":["run","--format","json"],"message":"hi","configuration":"{}","serverPassword":"pw","attachments":[]}"#
  }

  private func startPython(
    _ python: URL,
    source: String,
    input: String,
    environment: [String: String]
  ) throws -> (process: Process, output: FileHandle) {
    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    process.executableURL = python
    process.arguments = ["-c", source]
    process.environment = environment
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = FileHandle.nullDevice
    try process.run()
    try standardInput.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try standardInput.fileHandleForWriting.close()
    addTeardownBlock { if process.isRunning { process.terminate() } }
    return (process, standardOutput.fileHandleForReading)
  }

  private func runPython(
    _ python: URL,
    source: String,
    input: String,
    environment: [String: String]
  ) throws -> (status: Int32, output: String) {
    let run = try startPython(python, source: source, input: input, environment: environment)
    let data = try run.output.readToEnd() ?? Data()
    run.process.waitUntilExit()
    return (run.process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private func readLines(_ handle: FileHandle, count: Int) throws -> [String] {
    var lines: [String] = []
    var buffer = Data()
    while lines.count < count, let byte = try handle.read(upToCount: 1), !byte.isEmpty {
      if byte[byte.startIndex] == 0x0A {
        lines.append(String(decoding: buffer, as: UTF8.self))
        buffer.removeAll()
      } else {
        buffer.append(byte)
      }
    }
    return lines
  }
}
