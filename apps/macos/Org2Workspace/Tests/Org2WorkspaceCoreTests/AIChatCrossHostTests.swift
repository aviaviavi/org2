import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor CrossHostSendCounter {
  private(set) var prompts: [String] = []

  func record(_ prompt: String) {
    prompts.append(prompt)
  }
}

/// Two OpenOrg hosts (a laptop and a headless server) sharing one corpus
/// through a file replicator such as Syncthing.
final class AIChatCrossHostTests: XCTestCase {
  private var root: URL!
  private let laptop = AIChatTranscriptWriterIdentity(id: "laptop-writer", label: "AiroPress")
  private let server = AIChatTranscriptWriterIdentity(id: "server-writer", label: "OpenOrg on press")
  private let settings = OpenClawThreadSettlementSettings()

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-cross-host-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: Storage

  func testWritersNeverShareAMutableCommitFile() throws {
    let laptopURL = root.appendingPathComponent("laptop.json")
    let serverURL = root.appendingPathComponent("server.json")
    configureWriters(laptopURL: laptopURL, serverURL: serverURL)
    let thread = OpenClawChatThread(title: "Shared", sessionKey: "shared", messages: [
      OpenClawChatMessage(role: .user, content: "hello")
    ])
    try flush([thread], to: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)
    let markerBefore = try Data(contentsOf: storeURL(laptopURL).appendingPathComponent("migration-marker.json"))
    for index in 0..<3 {
      try flush([thread.replacingMessages(thread.messages + [
        OpenClawChatMessage(role: .assistant, content: "laptop \(index)")
      ])], to: laptopURL)
      try flush([thread.replacingMessages(thread.messages + [
        OpenClawChatMessage(role: .assistant, content: "server \(index)")
      ])], to: serverURL)
    }
    let laptopFiles = try mutablePaths(laptopURL)
    let serverFiles = try mutablePaths(serverURL)
    XCTAssertEqual(laptopFiles, ["heads/laptop-writer.json"])
    XCTAssertEqual(serverFiles, ["heads/server-writer.json"])
    XCTAssertTrue(laptopFiles.isDisjoint(with: serverFiles), "No path is rewritten by both hosts")
    XCTAssertEqual(
      try Data(contentsOf: storeURL(laptopURL).appendingPathComponent("migration-marker.json")),
      markerBefore,
      "The historical marker is created once for older builds and never rewritten"
    )
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: storeURL(laptopURL).appendingPathComponent("manifest.json").path
    ))
  }

  func testConcurrentTurnsInOneConversationKeepBothHostsMessages() throws {
    let laptopURL = root.appendingPathComponent("laptop.json")
    let serverURL = root.appendingPathComponent("server.json")
    configureWriters(laptopURL: laptopURL, serverURL: serverURL)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let first = OpenClawChatMessage(role: .user, content: "base", createdAt: start)
    let thread = OpenClawChatThread(
      title: "Shared", createdAt: start, updatedAt: start, sessionKey: "shared", messages: [first]
    )
    try flush([thread], to: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)

    let fromPhone = OpenClawChatMessage(
      role: .user, content: "phone via server", createdAt: start.addingTimeInterval(10)
    )
    let serverReply = OpenClawChatMessage(
      role: .assistant, content: "server reply", createdAt: start.addingTimeInterval(20)
    )
    let fromLaptop = OpenClawChatMessage(
      role: .user, content: "typed on the laptop", createdAt: start.addingTimeInterval(15)
    )
    try flush([thread.replacingMessages([first, fromPhone, serverReply])], to: serverURL)
    try flush([thread.replacingMessages([first, fromLaptop])], to: laptopURL)

    // Both directions replicate. Neither side has seen the other's commit.
    try syncAll(from: serverURL, to: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)
    for url in [laptopURL, serverURL] {
      let loaded = try XCTUnwrap(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: url))
      XCTAssertEqual(loaded.recoveryStatus, .healthy)
      let messages = try XCTUnwrap(loaded.snapshot.threads.first).messages.map(\.content)
      XCTAssertEqual(messages, ["base", "phone via server", "typed on the laptop", "server reply"])
    }
  }

  func testStaleLocalWriteCannotEraseAReplicaReply() throws {
    let laptopURL = root.appendingPathComponent("laptop.json")
    let serverURL = root.appendingPathComponent("server.json")
    configureWriters(laptopURL: laptopURL, serverURL: serverURL)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let question = OpenClawChatMessage(
      role: .user, content: "question", createdAt: start, deliveryStatus: .sending
    )
    let thread = OpenClawChatThread(
      title: "Remote turn", createdAt: start, updatedAt: start, sessionKey: "remote", messages: [question]
    )
    try flush([thread], to: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)
    let reply = OpenClawChatMessage(role: .assistant, content: "answer", createdAt: start.addingTimeInterval(5))
    try flush([thread.replacingMessages([
      question.replacingDeliveryStatus(.sent), reply,
    ])], to: serverURL)
    try syncAll(from: serverURL, to: laptopURL)

    // The laptop still holds its original copy (for example because a local
    // edit protected the conversation) and saves an unrelated change.
    try flush([thread.replacingOpenClawChatMetadata(title: "Renamed on laptop")], to: laptopURL)
    let loaded = try XCTUnwrap(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: laptopURL))
    let saved = try XCTUnwrap(loaded.snapshot.threads.first)
    XCTAssertEqual(saved.messages.map(\.content), ["question", "answer"])
    XCTAssertEqual(saved.messages.first?.deliveryStatus, .sent, "A finished remote turn is not stuck as sending")
  }

  func testLocalDeletionIsNotResurrectedByAReplica() throws {
    let laptopURL = root.appendingPathComponent("laptop.json")
    let serverURL = root.appendingPathComponent("server.json")
    configureWriters(laptopURL: laptopURL, serverURL: serverURL)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let first = OpenClawChatMessage(role: .user, content: "keep", createdAt: start)
    let queued = OpenClawChatMessage(
      role: .user, content: "queued then removed", createdAt: start.addingTimeInterval(1),
      deliveryStatus: .sending, deliveryKind: .followUp
    )
    let thread = OpenClawChatThread(
      title: "Queue", createdAt: start, updatedAt: start, sessionKey: "queue", messages: [first, queued]
    )
    try flush([thread], to: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)
    let serverNote = OpenClawChatMessage(role: .assistant, content: "server note", createdAt: start.addingTimeInterval(2))
    try flush([thread.replacingMessages([first, queued, serverNote])], to: serverURL)
    try flush([thread.replacingMessages([first])], to: laptopURL)
    try syncAll(from: serverURL, to: laptopURL)

    let loaded = try XCTUnwrap(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: laptopURL))
    XCTAssertEqual(
      loaded.snapshot.threads.first?.messages.map(\.content),
      ["keep", "server note"]
    )
  }

  // MARK: Presence and routing

  @MainActor
  func testRemoteLiveTurnIsVisibleAsRunningOnAnotherHost() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let thread = OpenClawChatThread(title: "Automation: digest", runtime: .codex, sessionKey: "auto")
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    let store = try makeStore(transcriptURL: transcriptURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertFalse(store.isAIChatThreadRunning(thread.id))

    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(
        writerID: "server-writer",
        host: AIChatHostIdentity(ref: "press", name: "OpenOrg on press", kind: .server),
        enabledDestinationIDs: [thread.destinationID],
        turns: [AIChatLiveTurnRecord(
          threadID: thread.id,
          destinationName: "Codex",
          startedAt: Date(),
          streamingReply: "Collecting today's items…"
        )]
      ),
      transcriptURL: transcriptURL
    )
    await store.refreshAIChatRemoteLiveHosts()
    XCTAssertTrue(store.isAIChatThreadRunning(thread.id))
    XCTAssertFalse(store.isAIChatThreadRunningOnCurrentHost(thread.id))
    XCTAssertEqual(store.aiChatRemoteLiveTurn(for: thread.id)?.turn.streamingReply, "Collecting today's items…")
    XCTAssertEqual(store.aiChatExecutionHostName(for: thread.id), "OpenOrg on press")

    let stopped = await store.stopAIChatRemoteRun(threadID: thread.id)
    XCTAssertFalse(stopped, "Another host's provider run is not stopped from this copy")

    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(
        writerID: "server-writer",
        host: AIChatHostIdentity(ref: "press", name: "OpenOrg on press", kind: .server),
        updatedAt: Date().addingTimeInterval(-600),
        turns: [AIChatLiveTurnRecord(threadID: thread.id)]
      ),
      transcriptURL: transcriptURL
    )
    await store.refreshAIChatRemoteLiveHosts()
    XCTAssertNil(store.aiChatRemoteLiveTurn(for: thread.id), "Stale presence is ignored")
  }

  @MainActor
  func testFollowUpRoutesToTheHostRunningTheConversationAndFallsBackWhenItIsOffline() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let press = AIChatHostIdentity(ref: "press", name: "OpenOrg on press", kind: .server)
    let earlier = Date().addingTimeInterval(-300)
    let thread = OpenClawChatThread(
      title: "Server conversation", createdAt: earlier, updatedAt: earlier, runtime: .codex,
      sessionKey: "server-owned",
      messages: [
        OpenClawChatMessage(role: .user, content: "start", createdAt: earlier),
        OpenClawChatMessage(
          role: .assistant, content: "started on press", createdAt: earlier.addingTimeInterval(1),
          provenance: AIChatMessageProvenance(executionHostRef: press.ref, executionHostName: press.name)
        ),
      ]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(writerID: "server-writer", host: press, enabledDestinationIDs: [thread.destinationID]),
      transcriptURL: transcriptURL
    )
    let counter = CrossHostSendCounter()
    let store = try makeStore(transcriptURL: transcriptURL) { messages, _, _ in
      await counter.record(messages.last?.content ?? "")
      return "answered here"
    }
    await store.waitForAIChatTranscriptLoadForTesting()
    await store.refreshAIChatRemoteLiveHosts()

    await store.sendOpenClawMessage(text: "follow up from the laptop")
    let routed = try XCTUnwrap(store.openClawMessages.last)
    XCTAssertEqual(routed.content, "follow up from the laptop")
    XCTAssertEqual(routed.deliveryStatus, .sending)
    XCTAssertEqual(routed.provenance?.executionHostRef, "press")
    XCTAssertNil(routed.provenance?.acceptedAt)
    XCTAssertEqual(routed.provenance?.receivedByHostRef, store.aiChatHostIdentity.ref)
    XCTAssertTrue(store.isAIChatThreadRunning(thread.id))
    let promptsWhileRouted = await counter.prompts
    XCTAssertTrue(promptsWhileRouted.isEmpty, "The laptop must not run a server-owned turn")

    // press stops publishing presence (asleep, crashed, or unsynchronized).
    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(writerID: "server-writer", host: press, isOnline: false),
      transcriptURL: transcriptURL
    )
    await store.refreshAIChatRemoteLiveHosts()
    store.processAIChatHandoffs()
    for _ in 0..<300 {
      if store.openClawMessages.last?.role == .assistant { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let prompts = await counter.prompts
    XCTAssertEqual(prompts.count, 1)
    XCTAssertEqual(store.openClawMessages.last?.content, "answered here")
    XCTAssertEqual(store.openClawMessages.last?.provenance?.executionHostRef, store.aiChatHostIdentity.ref)
    let reclaimed = try XCTUnwrap(store.openClawMessages.first { $0.id == routed.id })
    XCTAssertEqual(reclaimed.deliveryStatus, .sent)
    XCTAssertEqual(reclaimed.provenance?.executionHostRef, store.aiChatHostIdentity.ref)
    XCTAssertNotNil(reclaimed.provenance?.acceptedAt)
  }

  @MainActor
  func testHostAcceptsAHandOffExactlyOnce() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let handedOff = OpenClawChatMessage(
      role: .user, content: "continue on press", deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        originClient: .mobile, originDeviceName: "Avi's iPhone",
        receivedByHostRef: "desktop-laptop", receivedByHostName: "AiroPress",
        executionHostRef: "press", executionHostName: "OpenOrg on press"
      )
    )
    let thread = OpenClawChatThread(
      title: "Handed off", runtime: .codex, sessionKey: "handoff", messages: [handedOff]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    let counter = CrossHostSendCounter()
    let store = try makeStore(transcriptURL: transcriptURL) { messages, _, _ in
      await counter.record(messages.last?.content ?? "")
      return "ran on press"
    }
    store.configureAIChatHost(AIChatHostIdentity(ref: "press", name: "OpenOrg on press", kind: .server))
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(
      store.openClawMessages.first?.deliveryStatus, .sending,
      "An unstarted hand-off is not an interrupted local send"
    )
    store.processAIChatHandoffs()
    for _ in 0..<300 {
      if store.openClawMessages.last?.role == .assistant { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    store.processAIChatHandoffs()
    try await Task.sleep(for: .milliseconds(50))
    let prompts = await counter.prompts
    XCTAssertEqual(prompts, ["continue on press"])
    let accepted = try XCTUnwrap(store.openClawMessages.first)
    XCTAssertEqual(accepted.deliveryStatus, .sent)
    XCTAssertNotNil(accepted.provenance?.acceptedAt)
    XCTAssertEqual(accepted.provenance?.originDeviceName, "Avi's iPhone")
    let reply = try XCTUnwrap(store.openClawMessages.last)
    XCTAssertEqual(reply.provenance?.executionHostName, "OpenOrg on press")
    XCTAssertEqual(
      accepted.provenance?.caption(role: .user),
      "Avi's iPhone via AiroPress · runs on OpenOrg on press"
    )
    XCTAssertEqual(reply.provenance?.caption(role: .assistant), "ran on OpenOrg on press")
  }

  @MainActor
  func testAnotherHostsInFlightTurnIsNotMarkedInterruptedOrRedispatched() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let remoteTurn = OpenClawChatMessage(
      role: .user, content: "running on press", deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        receivedByHostRef: "other-host", receivedByHostName: "Other host",
        executionHostRef: "other-host", executionHostName: "Other host", acceptedAt: Date()
      )
    )
    let thread = OpenClawChatThread(title: "Remote", runtime: .codex, sessionKey: "remote", messages: [remoteTurn])
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    let counter = CrossHostSendCounter()
    let store = try makeStore(transcriptURL: transcriptURL) { messages, _, _ in
      await counter.record(messages.last?.content ?? "")
      return "should not run"
    }
    store.aiChatRoutesTurnsToThreadHost = false
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(store.openClawMessages.first?.deliveryStatus, .sending)
    XCTAssertTrue(store.isAIChatThreadRunning(thread.id))

    // Import it through synchronization, then queue a local follow-up.
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    _ = await store.refreshSyncedAIChatTranscript()
    await store.sendOpenClawMessage(text: "local follow-up")
    try await Task.sleep(for: .milliseconds(100))
    let prompts = await counter.prompts
    XCTAssertFalse(prompts.contains("running on press"), "Another host's turn is never dispatched twice")
  }

  func testPresenceEventsDoNotReloadTheTranscript() {
    let classified = WorkspaceStore.classifyCorpusFileEvents([
      "/tmp/corpus/.org2/openclaw-chat.store/live/server-writer.json",
    ], corpusRoot: URL(fileURLWithPath: "/tmp/corpus"))
    XCTAssertTrue(classified.hasAIChatLiveChanges)
    XCTAssertFalse(classified.hasAIChatTranscriptChanges)
    let head = WorkspaceStore.classifyCorpusFileEvents([
      "/tmp/corpus/.org2/openclaw-chat.store/heads/server-writer.json",
    ], corpusRoot: URL(fileURLWithPath: "/tmp/corpus"))
    XCTAssertTrue(head.hasAIChatTranscriptChanges)
  }

  func testOlderTranscriptsAndMessagesWithoutProvenanceStillDecode() throws {
    let json = """
    {"id":"\(UUID().uuidString)","role":"assistant","content":"legacy","createdAt":0}
    """
    let message = try JSONDecoder().decode(OpenClawChatMessage.self, from: Data(json.utf8))
    XCTAssertNil(message.provenance)
    let encoded = try JSONEncoder().encode(message.replacingProvenance(
      AIChatMessageProvenance(executionHostRef: "press", executionHostName: "press")
    ))
    let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: encoded)
    XCTAssertEqual(decoded.provenance?.executionHostRef, "press")
  }

  // MARK: Helpers

  private func configureWriters(laptopURL: URL, serverURL: URL) {
    AIChatTranscriptStore.shared.setWriterIdentityForTesting(laptop, legacyURL: laptopURL)
    AIChatTranscriptStore.shared.setWriterIdentityForTesting(server, legacyURL: serverURL)
    addTeardownBlock {
      AIChatTranscriptStore.shared.setWriterIdentityForTesting(nil, legacyURL: laptopURL)
      AIChatTranscriptStore.shared.setWriterIdentityForTesting(nil, legacyURL: serverURL)
    }
  }

  private func flush(_ threads: [OpenClawChatThread], to url: URL) throws {
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: threads.first?.id,
        settlementSettings: settings,
        knownThreadIDs: Set(threads.map(\.id))
      ),
      legacyURL: url
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
  }

  private func storeURL(_ transcriptURL: URL) -> URL {
    AIChatTranscriptStore.storeDirectory(for: transcriptURL)
  }

  /// Replicate every file the source has that the target lacks, plus the
  /// source writer's head, the way a file synchronizer would.
  private func syncAll(from source: URL, to target: URL) throws {
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let fileManager = FileManager.default
    let sourceStore = storeURL(source).resolvingSymlinksInPath()
    let targetStore = storeURL(target).resolvingSymlinksInPath()
    guard let enumerator = fileManager.enumerator(at: sourceStore, includingPropertiesForKeys: nil) else { return }
    for case let file as URL in enumerator {
      guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
      let relative = String(file.resolvingSymlinksInPath().path.dropFirst(sourceStore.path.count + 1))
      let destination = targetStore.appendingPathComponent(relative)
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let isMutable = !relative.hasPrefix("threads/") && !relative.hasPrefix("manifests/")
        && !relative.hasPrefix("attachments/")
      if fileManager.fileExists(atPath: destination.path) {
        guard isMutable, relative.hasPrefix("heads/"),
              try Data(contentsOf: destination) != Data(contentsOf: file)
        else { continue }
        try fileManager.removeItem(at: destination)
      }
      try fileManager.copyItem(at: file, to: destination)
    }
  }

  /// Files outside the immutable, content-addressed directories.
  private func mutablePaths(_ transcriptURL: URL) throws -> Set<String> {
    let store = storeURL(transcriptURL).resolvingSymlinksInPath()
    var result = Set<String>()
    guard let enumerator = FileManager.default.enumerator(at: store, includingPropertiesForKeys: nil) else {
      return []
    }
    for case let file as URL in enumerator {
      guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
      let relative = String(file.resolvingSymlinksInPath().path.dropFirst(store.path.count + 1))
      if relative.hasPrefix("threads/") || relative.hasPrefix("manifests/")
        || relative.hasPrefix("attachments/") || relative.hasPrefix("migration-marker") {
        continue
      }
      // Only count files this writer modified after the initial replication.
      if relative.hasPrefix("heads/") {
        let name = String(relative.dropFirst("heads/".count))
        guard name == "laptop-writer.json" && transcriptURL.lastPathComponent == "laptop.json"
          || name == "server-writer.json" && transcriptURL.lastPathComponent == "server.json"
        else { continue }
      }
      result.insert(relative)
    }
    return result
  }

  @MainActor
  private func makeStore(
    transcriptURL: URL,
    codex: (@Sendable ([OpenClawChatMessage], UUID, OpenClawWorkspaceContext) async throws -> String)? = nil
  ) throws -> WorkspaceStore {
    let suite = "cross-host-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      codexSendHandlerForTesting: codex ?? { _, _, _ in "ok" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    return store
  }
}
