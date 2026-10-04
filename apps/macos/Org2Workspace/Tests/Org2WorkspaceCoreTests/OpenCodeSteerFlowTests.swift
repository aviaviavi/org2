import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Drives a real OpenCode chat turn against a fake `opencode` executable so the
/// steer → reply → next-message flow exercises the store's actual OpenCode
/// path instead of test-only send and steer handlers.
final class OpenCodeSteerFlowTests: XCTestCase {
  private var root: URL!
  private var previousExecutable: String?

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-opencode-steer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    previousExecutable = ProcessInfo.processInfo.environment["ORG2_OPENCODE_EXECUTABLE"]
  }

  override func tearDownWithError() throws {
    if let previousExecutable {
      setenv("ORG2_OPENCODE_EXECUTABLE", previousExecutable, 1)
    } else {
      unsetenv("ORG2_OPENCODE_EXECUTABLE")
    }
    unsetenv("ORG2_FAKE_OPENCODE_DIR")
    try? FileManager.default.removeItem(at: root)
  }

  /// `run` emits its session, waits for a steer, then finishes. `api` records
  /// the steer. Each `run` prints the prompt it was given as its reply.
  private func installFakeOpenCode() throws -> URL {
    let state = root.appendingPathComponent("fake", isDirectory: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("opencode")
    try """
      #!/bin/sh
      dir="$ORG2_FAKE_OPENCODE_DIR"
      case "$1" in
        serve)
          echo "server listening on http://127.0.0.1:4096"
          exec sleep 120
          ;;
        api)
          for arg in "$@"; do last="$arg"; done
          printf '%s\\n' "$last" >> "$dir/steers"
          echo '{"data":{"id":"msg_steer","type":"user","delivery":"steer"}}'
          exit 0
          ;;
        run)
          for arg in "$@"; do last="$arg"; done
          count=$(cat "$dir/runs" 2>/dev/null || echo 0)
          count=$((count + 1))
          echo "$count" > "$dir/runs"
          if [ -f "$dir/session-delay" ]; then sleep "$(cat "$dir/session-delay")"; fi
          echo '{"type":"step_start","sessionID":"ses_fake","part":{}}'
          if [ "$count" = "1" ]; then
            i=0
            while [ ! -s "$dir/steers" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
            echo '{"type":"text","sessionID":"ses_fake","part":{"text":"finished after steering"}}'
          else
            echo '{"type":"text","sessionID":"ses_fake","part":{"text":"next reply"}}'
          fi
          exit 0
          ;;
      esac
      exit 0
      """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    setenv("ORG2_OPENCODE_EXECUTABLE", executable.path, 1)
    setenv("ORG2_FAKE_OPENCODE_DIR", state.path, 1)
    return state
  }

  @MainActor
  private func waitFor(
    _ description: String,
    timeout: TimeInterval = 15,
    _ condition: @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("Timed out waiting for \(description)")
    throw CancellationError()
  }

  @MainActor
  func testSteerReachesRunningOpenCodeTurnAndThreadSettlesAfterReply() async throws {
    let state = try installFakeOpenCode()
    let corpus = root.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    let suite = "opencode-steer-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(corpus, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    let destination = AIChatDestinationConfiguration(
      name: "OpenCode",
      mention: "opencode-test",
      adapter: .openCodeLocal,
      endpoint: ""
    )
    store.updateAIChatDestination(destination)
    let threadID = store.createAIChatThread(destinationID: destination.id)
    store.selectAIChatThread(threadID)

    store.sendComposedAIChatMessage(text: "first request")
    try await waitFor("OpenCode to start the turn") {
      FileManager.default.fileExists(atPath: state.appendingPathComponent("runs").path)
    }

    store.sendComposedAIChatMessage(text: "change direction", delivery: .steer)
    let steer = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertEqual(steer.deliveryKind, .steer)
    XCTAssertFalse(store.isAIChatMessageQueued(steer.id), "a steer is not queued")

    try await waitFor("the turn to finish") {
      store.aiChatMessages.contains { $0.role == .assistant }
        && !store.isAIChatThreadRunning(threadID)
    }
    let steers = (try? String(contentsOf: state.appendingPathComponent("steers"), encoding: .utf8)) ?? ""
    XCTAssertTrue(steers.contains("change direction"), "the guidance reached OpenCode")
    XCTAssertEqual(store.aiChatMessages.map(\.deliveryStatus), [.sent, .sent, .sent])
    XCTAssertEqual(store.aiChatMessages.last?.content, "finished after steering")

    store.sendComposedAIChatMessage(text: "next question")
    try await waitFor("the next message to be answered") {
      store.aiChatMessages.last?.content == "next reply"
    }
    try await waitFor("the thread to settle after the next reply") {
      !store.isAIChatThreadRunning(threadID)
    }
    XCTAssertEqual(
      store.aiChatMessages.map { "\($0.role.rawValue):\($0.deliveryKind):\($0.deliveryStatus):\($0.content)" },
      [
        "user:turn:sent:first request",
        "user:steer:sent:change direction",
        "assistant:turn:sent:finished after steering",
        "user:turn:sent:next question",
        "assistant:turn:sent:next reply"
      ]
    )
  }

  @MainActor
  private func makeOpenCodeStore() async throws -> (WorkspaceStore, UUID) {
    let corpus = root.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    let suite = "opencode-steer-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(corpus, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    let destination = AIChatDestinationConfiguration(
      name: "OpenCode",
      mention: "opencode-test",
      adapter: .openCodeLocal,
      endpoint: ""
    )
    store.updateAIChatDestination(destination)
    let threadID = store.createAIChatThread(destinationID: destination.id)
    store.selectAIChatThread(threadID)
    return (store, threadID)
  }

  @MainActor
  private func assertSettlesAndAnswersNextMessage(
    _ store: WorkspaceStore,
    threadID: UUID,
    state: URL
  ) async throws {
    try await waitFor("the turn to finish and the thread to settle") {
      store.aiChatMessages.contains { $0.role == .assistant }
        && !store.isAIChatThreadRunning(threadID)
    }
    let steers = (try? String(contentsOf: state.appendingPathComponent("steers"), encoding: .utf8)) ?? ""
    XCTAssertTrue(steers.contains("change direction"), "the guidance reached OpenCode")
    store.sendComposedAIChatMessage(text: "next question")
    try await waitFor("the next message to be answered") {
      store.aiChatMessages.last?.content == "next reply"
    }
    try await waitFor("the thread to settle after the next reply") {
      !store.isAIChatThreadRunning(threadID)
    }
    XCTAssertEqual(
      store.aiChatMessages.map { "\($0.role.rawValue):\($0.deliveryKind):\($0.deliveryStatus):\($0.content)" },
      [
        "user:turn:sent:first request",
        "user:steer:sent:change direction",
        "assistant:turn:sent:finished after steering",
        "user:turn:sent:next question",
        "assistant:turn:sent:next reply"
      ]
    )
  }

  /// OpenCode can take longer than the generic readiness deadline to report
  /// its session (private server, MCP servers, SSH for remote turns). An early
  /// steer must keep waiting for that session instead of landing as queued.
  @MainActor
  func testEarlySteerWaitsForSlowOpenCodeSessionInsteadOfQueueing() async throws {
    let state = try installFakeOpenCode()
    try "1.5".write(to: state.appendingPathComponent("session-delay"), atomically: true, encoding: .utf8)
    let (store, threadID) = try await makeOpenCodeStore()
    store.aiChatSteerReadinessTimeout = .milliseconds(300)

    store.sendComposedAIChatMessage(text: "first request")
    try await waitFor("OpenCode to start the turn") {
      FileManager.default.fileExists(atPath: state.appendingPathComponent("runs").path)
    }
    store.sendComposedAIChatMessage(text: "change direction", delivery: .steer)
    let steer = try XCTUnwrap(store.aiChatMessages.last)
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertFalse(store.isAIChatMessageQueued(steer.id), "the steer is not downgraded to a follow-up")
    XCTAssertEqual(store.aiChatMessages.last?.deliveryKind, .steer)

    try await assertSettlesAndAnswersNextMessage(store, threadID: threadID, state: state)
  }

  /// The reported bug: a message queued during an OpenCode turn and then
  /// steered reached the turn, but afterwards the chat stayed "working" and
  /// later messages never sent.
  @MainActor
  func testQueuedMessageSteeredIntoTurnLetsTheThreadSettleAndAcceptNextMessage() async throws {
    let state = try installFakeOpenCode()
    try "0.5".write(to: state.appendingPathComponent("session-delay"), atomically: true, encoding: .utf8)
    let (store, threadID) = try await makeOpenCodeStore()

    store.sendComposedAIChatMessage(text: "first request")
    try await waitFor("OpenCode to start the turn") {
      FileManager.default.fileExists(atPath: state.appendingPathComponent("runs").path)
    }
    store.sendComposedAIChatMessage(text: "change direction")
    let queued = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertTrue(store.isAIChatMessageQueued(queued.id))
    try await waitFor("the queued message to become steerable") {
      store.canSteerQueuedAIChatMessage(queued.id)
    }
    await store.steerQueuedAIChatMessage(queued.id)

    try await assertSettlesAndAnswersNextMessage(store, threadID: threadID, state: state)
  }

  // MARK: Stale replicas

  /// Another host (the headless server beside the OpenCode harness) wrote the
  /// chat before it saw this Mac's reply. Merging that older copy reopened
  /// the answered prompt, so the chat showed "working" forever and every
  /// later message queued behind it.
  func testStaleReplicaCannotReopenAnAnsweredPrompt() {
    let prompt = AIChatMessage(role: .user, content: "remove the old refs", deliveryStatus: .sending)
    let steer = AIChatMessage(
      role: .user,
      content: "(push to main)",
      deliveryStatus: .sent,
      deliveryKind: .steer
    )
    let reply = AIChatMessage(
      id: WorkspaceStore.openCodeRemoteReplyID(for: prompt.id),
      role: .assistant,
      content: "Done and pushed."
    )
    let answered = [prompt.replacingDeliveryStatus(.sent), steer, reply]
    let stale = [prompt, steer]

    let merged = AIChatTranscriptStore.threeWayMergeForTesting(
      local: answered,
      remote: stale,
      base: answered
    )
    XCTAssertEqual(merged.map(\.id), answered.map(\.id))
    XCTAssertEqual(merged.map(\.deliveryStatus), [.sent, .sent, .sent])

    // A replica that really retried a failed prompt still wins.
    let failed = prompt.replacingDeliveryStatus(.failed, sendFailure: "offline")
    let retried = AIChatTranscriptStore.threeWayMergeForTesting(
      local: [failed],
      remote: [prompt],
      base: [failed]
    )
    XCTAssertEqual(retried.map(\.deliveryStatus), [.sending])
  }

  /// Transcripts already damaged by a stale replica heal when they load: a
  /// remote OpenCode reply's derived ID proves its prompt was delivered.
  func testAnsweredOpenCodeRemotePromptIsSettledOnLoad() {
    let answeredPrompt = AIChatMessage(role: .user, content: "first", deliveryStatus: .sending)
    let reply = AIChatMessage(
      id: WorkspaceStore.openCodeRemoteReplyID(for: answeredPrompt.id),
      role: .assistant,
      content: "answered"
    )
    let waiting = AIChatMessage(
      role: .user,
      content: "still waiting",
      deliveryStatus: .sending,
      deliveryKind: .followUp
    )
    let thread = AIChatThread(
      title: "Remote",
      runtime: .openCode,
      sessionKey: "remote",
      messages: [answeredPrompt, reply, waiting],
      pendingTurn: AIChatPendingTurn(
        userMessageID: answeredPrompt.id,
        runID: answeredPrompt.id.uuidString.lowercased(),
        agentID: "opencode",
        gatewayMessage: ""
      )
    )

    let result = WorkspaceStore.settlingAnsweredOpenCodeRemoteTurns(in: [thread])
    XCTAssertTrue(result.changed)
    let settled = result.threads[0]
    XCTAssertEqual(settled.messages.map(\.deliveryStatus), [.sent, .sent, .sending])
    XCTAssertNil(settled.pendingTurn)
    XCTAssertFalse(WorkspaceStore.settlingAnsweredOpenCodeRemoteTurns(in: [settled]).changed)
  }
}
