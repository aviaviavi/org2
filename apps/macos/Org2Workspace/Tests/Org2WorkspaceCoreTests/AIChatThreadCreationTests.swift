import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AIChatThreadCreationTests: XCTestCase {
  @MainActor
  private func makeStore(threads: [OpenClawChatThread]) throws -> (WorkspaceStore, UserDefaults, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-create-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: threads.first?.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let suiteName = "AIChatThreadCreationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    return (store, defaults, root)
  }

  @MainActor
  func testCreatingThreadInsertsIncrementallyWithoutFullSidebarRebuild() async throws {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    var threads: [OpenClawChatThread] = (0..<400).map { index in
      OpenClawChatThread(
        title: "Thread \(index)",
        updatedAt: base.addingTimeInterval(TimeInterval(-index)),
        sessionKey: "session-\(index)",
        messages: (0..<40).map { OpenClawChatMessage(role: .user, content: "m\($0)") }
      )
    }
    threads[5] = threads[5].replacingOpenClawChatMetadata(isPinned: true)
    let (store, defaults, root) = try makeStore(threads: threads)
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: defaults.description)
    }
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(store.openClawChatThreads.count, 400)
    let rebuildCount = store.aiChatFullDisplayRebuildCountForTesting
    let clock = ContinuousClock()
    let started = clock.now
    var created: [UUID] = []
    for _ in 0..<20 {
      created.append(store.createAIChatThread(destinationID: AIChatDestinationConfiguration.localCodexID))
    }
    let duration = started.duration(to: clock.now)

    XCTAssertEqual(store.aiChatFullDisplayRebuildCountForTesting, rebuildCount)
    XCTAssertEqual(store.selectedOpenClawChatThreadID, created.last)
    XCTAssertEqual(store.openClawChatThreads.count, 420)
    // Pinned threads stay first; the newest new chat follows them.
    XCTAssertTrue(store.visibleOpenClawChatThreads.first?.isPinned == true)
    XCTAssertEqual(store.visibleOpenClawChatThreads[1].id, created.last)
    XCTAssertEqual(
      store.visibleOpenClawChatThreads.map(\.id),
      store.visibleOpenClawChatThreads.sorted {
        if $0.isPinned != $1.isPinned { return $0.isPinned }
        return $0.updatedAt > $1.updatedAt
      }.map(\.id)
    )
    XCTAssertLessThan(duration, .milliseconds(500))
  }

  @MainActor
  func testRemoteThreadCreationWithClientIDIsIdempotent() throws {
    let (store, defaults, root) = try makeStore(threads: [])
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: defaults.description)
    }
    let id = UUID()
    XCTAssertEqual(store.createAIChatRemoteThread(destinationID: AIChatDestinationConfiguration.localCodexID, id: id), id)
    XCTAssertEqual(store.createAIChatRemoteThread(destinationID: AIChatDestinationConfiguration.localCodexID, id: id), id)
    XCTAssertEqual(store.openClawChatThreads.filter { $0.id == id }.count, 1)
  }

  func testCreateThreadRequestDecodesWithAndWithoutClientThreadID() throws {
    let legacy = try JSONDecoder().decode(
      MobileRemoteCreateThreadRequest.self,
      from: Data(#"{"runtime":"codex"}"#.utf8)
    )
    XCTAssertNil(legacy.threadID)
    let id = UUID()
    let current = try JSONDecoder().decode(
      MobileRemoteCreateThreadRequest.self,
      from: JSONEncoder().encode(MobileRemoteCreateThreadRequest(runtime: "codex", threadID: id))
    )
    XCTAssertEqual(current.threadID, id)
    let status = MobileRemoteServerStatus(serverName: "Mac", corpusName: nil, threadCount: 0, runningThreadCount: 0)
    XCTAssertEqual(status.supportsClientThreadIDs, true)
  }

  @MainActor
  func testNodeBriefConfigurationPersistsAndForcesNewThread() throws {
    let (store, defaults, root) = try makeStore(threads: [])
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: defaults.description)
    }
    store.openClawBriefsStartNewThread = false
    XCTAssertFalse(store.nodeBriefStartsNewThread)

    store.nodeBriefConfiguration = NodeBriefAIConfiguration(
      destinationID: AIChatDestinationConfiguration.localCodexID,
      model: "  gpt-5.5 ",
      reasoningEffort: "high"
    )
    XCTAssertEqual(store.nodeBriefConfiguration.model, "gpt-5.5")
    XCTAssertTrue(store.nodeBriefStartsNewThread)
    XCTAssertEqual(store.nodeBriefDestination.id, AIChatDestinationConfiguration.localCodexID)

    let reloaded = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      legacyDefaultsDomains: []
    )
    XCTAssertEqual(reloaded.nodeBriefConfiguration, store.nodeBriefConfiguration)

    XCTAssertTrue(NodeBriefAIConfiguration(destinationID: " ", model: "", reasoningEffort: nil).isDefault)
  }
}
