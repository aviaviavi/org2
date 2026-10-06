import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceActivityExplanationTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("activity-explain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("{\"automationHostRef\": \"press\"}\n".utf8).write(to: root.appendingPathComponent("org2.json"))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testHostClassificationMatchesSharedThresholds() {
    let now = Date()
    func state(_ age: TimeInterval, online: Bool = true, auth: Bool = false) -> WorkspaceActivityHost.State {
      WorkspaceActivityHostPolicy.classify(isOnline: online, updatedAt: now.addingTimeInterval(-age), authenticationNeeded: auth, now: now).0
    }
    XCTAssertEqual(state(30), .online)
    XCTAssertEqual(state(30, auth: true), .authenticationNeeded)
    XCTAssertEqual(state(300), .reconnecting)
    XCTAssertEqual(state(3600), .stale)
    XCTAssertEqual(state(10, online: false), .offline)
    XCTAssertEqual(state(-3600), .stale, "a timestamp in the future is not evidence of life")
  }

  func testAuthenticationFailureDetection() {
    XCTAssertTrue(WorkspaceActivityHostPolicy.isAuthenticationFailure("OpenAI Codex token refresh failed (401)"))
    XCTAssertTrue(WorkspaceActivityHostPolicy.isAuthenticationFailure("Claude Code is not logged in"))
    XCTAssertFalse(WorkspaceActivityHostPolicy.isAuthenticationFailure("Context window exceeded"))
  }

  func testPresenceRecordCarriesAuthenticationNeededDestinationsAndStaysCompatible() throws {
    let record = AIChatLiveHostRecord(
      writerID: "w",
      host: AIChatHostIdentity(ref: "press", name: "press", kind: .server),
      enabledDestinationIDs: ["builtin.codex"],
      authenticationNeededDestinationIDs: ["builtin.codex"]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(record)
    XCTAssertEqual(try decoder.decode(AIChatLiveHostRecord.self, from: data).authenticationNeededDestinationIDs, ["builtin.codex"])
    // Records from older builds omit the field.
    let legacy = Data(#"{"schema":"org2:ai-chat-live-host:v1","writerID":"w","hostRef":"h","hostName":"h","hostKind":"desktop","updatedAt":"2026-10-05T00:00:00Z","isOnline":true,"enabledDestinationIDs":[],"turns":[]}"#.utf8)
    XCTAssertNil(try decoder.decode(AIChatLiveHostRecord.self, from: legacy).authenticationNeededDestinationIDs)
    let plain = AIChatLiveHostRecord(writerID: "w", host: AIChatHostIdentity(ref: "h", name: "h", kind: .desktop))
    XCTAssertFalse(String(decoding: try encoder.encode(plain), as: UTF8.self).contains("authenticationNeeded"))
  }

  @MainActor
  func testHostsSectionShowsStaleHostsAsCachedWithFailover() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let thread = AIChatThread(title: "Laptop conversation", runtime: .codex, sessionKey: "laptop")
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: AIChatThreadSettlementSettings()),
      legacyURL: transcriptURL
    )
    let store = try makeStore(transcriptURL: transcriptURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(
        writerID: "laptop-writer",
        host: AIChatHostIdentity(ref: "laptop", name: "Laptop", kind: .desktop),
        updatedAt: Date().addingTimeInterval(-3600),
        enabledDestinationIDs: [thread.destinationID],
        turns: [AIChatLiveTurnRecord(threadID: thread.id, destinationName: "Codex")]
      ),
      transcriptURL: transcriptURL
    )
    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(
        writerID: "press-writer",
        host: AIChatHostIdentity(ref: "press", name: "OpenOrg on press", kind: .server),
        enabledDestinationIDs: [thread.destinationID],
        authenticationNeededDestinationIDs: [thread.destinationID]
      ),
      transcriptURL: transcriptURL
    )
    await store.refreshAIChatRemoteLiveHosts()
    store.refreshCorpusAutomationHostRef()
    XCTAssertEqual(store.corpusAutomationHostRef, "press")

    let hosts = store.activityHosts()
    XCTAssertEqual(hosts.first?.isThisMac, true)
    let laptop = try XCTUnwrap(hosts.first { $0.id == "laptop" })
    XCTAssertEqual(laptop.state, .stale)
    XCTAssertTrue(laptop.isCached)
    XCTAssertEqual(laptop.turns.map(\.title), ["Laptop conversation"], "last-known work stays visible, dimmed")
    XCTAssertTrue(laptop.failoverHostNames.contains("OpenOrg on press"))
    let press = try XCTUnwrap(hosts.first { $0.id == "press" })
    XCTAssertEqual(press.state, .authenticationNeeded)
    XCTAssertTrue(press.isAutomationHost)
    XCTAssertEqual(press.kind, .server)
    XCTAssertFalse(press.isCached)
  }

  @MainActor
  func testExplainStatusAsksTheSharedRuntimeForTheRowTarget() async throws {
    let store = try makeStore(transcriptURL: root.appendingPathComponent("chat.json"))
    let json = #"""
    {"schema":"org2:activity-explanation:v1","generatedAt":"2026-10-05T12:00:00.000Z","corpus":"/c","automationHostRef":"press","hosts":[],
     "items":[{"kind":"run","id":"run-1","title":"Send outreach","state":"needs-you","needsAttention":true,
       "reason":{"code":"waiting-approval","summary":"Waiting for your decision: Email Acme"},
       "reportedBy":{"hostRef":"press","hostName":"OpenOrg on press","hostKind":"server","hostState":"online","runtime":"codex","actor":"Codex"},
       "lastSignal":{"type":"transition","at":"2026-10-05T11:50:00.000Z","ageSeconds":600},
       "confidence":"cached","confidenceReason":"Pending approvals are recorded in the run's event log",
       "blocking":[{"kind":"approval","summary":"Approve: Email Acme","runId":"run-1","approvalId":"approval-1","title":"Email Acme","action":"send email","riskClass":"external-action","fingerprint":"abc","command":"org2 run approval-decide run-1 approval-1 --decision approved --fingerprint abc --actor NAME"}],
       "related":[{"kind":"thread","id":"t","relation":"linked-thread"}],
       "evidence":[{"source":"run-event","ref":"run:run-1#e","at":"2026-10-05T11:50:00.000Z","detail":"running → waiting-approval by Codex"}],
       "futureField":true}],
     "summary":{"working":0,"needsYou":1,"queued":0,"scheduled":0,"uncertain":0}}
    """#
    var requested: [String] = []
    store.activityExplanationLoaderForTesting = { arguments in
      requested = arguments
      return try JSONDecoder().decode(WorkspaceActivityExplanationPayload.self, from: Data(json.utf8))
    }
    let item = WorkspaceActivityItem(id: "run:run-1", kind: .needsYou, title: "Send outreach", detail: "", target: .run("run-1"))
    XCTAssertTrue(store.canExplainActivityItem(item))
    let explanation = try await store.explainActivityItem(item)
    XCTAssertEqual(requested, ["--run", "run-1"])
    XCTAssertEqual(explanation.reason.code, "waiting-approval")
    XCTAssertEqual(explanation.blocking.first?.fingerprint, "abc")
    XCTAssertEqual(explanation.reporterSummary, "OpenOrg on press · codex")
    XCTAssertEqual(explanation.signalLabel, "Last transition")
    XCTAssertNotNil(explanation.signalDate)

    let file = WorkspaceActivityItem(id: "file:a", kind: .changed, title: "a.org", detail: "", target: .file(path: "/a.org", line: nil))
    XCTAssertFalse(store.canExplainActivityItem(file))
    let thread = UUID()
    XCTAssertEqual(
      store.activityExplanationArguments(for: WorkspaceActivityItem(id: "t", kind: .working, title: "t", detail: "", target: .thread(thread))),
      ["--thread", thread.uuidString]
    )
  }

  @MainActor
  private func makeStore(transcriptURL: URL) throws -> WorkspaceStore {
    let suite = "activity-explain-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL,
      codexSendHandlerForTesting: { _, _, _ in "ok" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    return store
  }
}
