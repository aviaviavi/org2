import XCTest
@testable import Org2WorkspaceCore

private actor HandoffSendCounter {
  private(set) var prompts: [String] = []
  func record(_ prompt: String) { prompts.append(prompt) }
}

@MainActor
final class AIChatExecutionHandoffTests: XCTestCase {
  nonisolated(unsafe) private var root: URL!
  private let press = AIChatHostIdentity(ref: "press", name: "OpenOrg on press", kind: .server)

  nonisolated override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: root.appendingPathComponent("org2.json"))
  }

  nonisolated override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func makeStore(counter: HandoffSendCounter) throws -> (WorkspaceStore, URL, AIChatThread) {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let thread = AIChatThread(title: "Detachable", runtime: .codex, sessionKey: "detach")
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: AIChatThreadSettlementSettings()),
      legacyURL: transcriptURL
    )
    let suite = "handoff-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL,
      codexSendHandlerForTesting: { messages, _, _ in
        await counter.record(messages.last?.content ?? "")
        return "answered here"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    return (store, transcriptURL, thread)
  }

  func testNewTurnsRunOnThePreferredServerSoTheMacCanDetach() async throws {
    let counter = HandoffSendCounter()
    let (store, transcriptURL, thread) = try makeStore(counter: counter)
    await store.waitForAIChatTranscriptLoadForTesting()
    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(writerID: "press-writer", host: press, enabledDestinationIDs: [thread.destinationID]),
      transcriptURL: transcriptURL
    )
    await store.refreshAIChatRemoteLiveHosts()
    XCTAssertEqual(store.aiChatExecutionHostCandidates.map(\.hostRef), ["press"])
    store.aiChatPreferredExecutionHostRef = "press"

    await store.sendAIChatMessage(text: "run this on the server")
    let routed = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertEqual(routed.provenance?.executionHostRef, "press")
    XCTAssertNil(routed.provenance?.acceptedAt, "the server accepts the hand-off")
    let prompts = await counter.prompts
    XCTAssertTrue(prompts.isEmpty, "this Mac does not run a turn it handed to the server")
  }

  func testADrainingServerIsSkippedAndItsPendingHandoffsAreReclaimed() async throws {
    let counter = HandoffSendCounter()
    let (store, transcriptURL, thread) = try makeStore(counter: counter)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.aiChatPreferredExecutionHostRef = "press"
    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(writerID: "press-writer", host: press, enabledDestinationIDs: [thread.destinationID], isDraining: true),
      transcriptURL: transcriptURL
    )
    await store.refreshAIChatRemoteLiveHosts()
    let hosts = store.activityHosts()
    XCTAssertTrue(hosts.first { $0.id == "press" }?.stateReason.contains("Restarting") == true)

    await store.sendAIChatMessage(text: "server is restarting")
    for _ in 0..<100 {
      if await !counter.prompts.isEmpty { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let prompts = await counter.prompts
    XCTAssertEqual(prompts.last, "server is restarting", "a draining server takes no new turns; this Mac runs it")
    XCTAssertEqual(store.aiChatMessages.first { $0.role == .user }?.provenance?.executionHostRef, store.aiChatHostIdentity.ref)
  }

  func testDrainingThisHostAnnouncesItAndWaitsForTurns() async throws {
    let counter = HandoffSendCounter()
    let (store, transcriptURL, _) = try makeStore(counter: counter)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertFalse(store.isAIChatDraining)
    store.beginAIChatDrain()
    XCTAssertTrue(store.isAIChatDraining)
    let records = AIChatLiveHostDirectory.readAll(transcriptURL: transcriptURL, excludingWriterID: nil)
    for _ in 0..<50 where AIChatLiveHostDirectory.readAll(transcriptURL: transcriptURL, excludingWriterID: nil).isEmpty {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let published = AIChatLiveHostDirectory.readAll(transcriptURL: transcriptURL, excludingWriterID: nil)
    XCTAssertEqual((published.isEmpty ? records : published).first?.isDraining, true)
    let remaining = await store.waitForAIChatTurnsToFinish(timeout: 1, pollInterval: 0.05)
    XCTAssertEqual(remaining, 0)
    store.endAIChatDrain()
    XCTAssertFalse(store.isAIChatDraining)
  }
}
