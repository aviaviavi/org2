import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AIChatTranscriptStoreTests: XCTestCase {
  func testShardedStorePreservesLegacyAndLoadsAttachmentBlobsLazily() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-shards-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    let legacyData = Data("{\"version\":6,\"threads\":[]}".utf8)
    try legacyData.write(to: transcriptURL)

    let attachmentData = Data(repeating: 0x5a, count: 256 * 1_024)
    let selected = OpenClawChatThread(
      title: "Selected",
      sessionKey: "selected",
      messages: [
        OpenClawChatMessage(
          role: .user,
          content: "Inspect this artifact",
          attachments: [OpenClawChatAttachment(
            fileName: "artifact.bin",
            mimeType: "application/octet-stream",
            data: attachmentData
          )]
        )
      ]
    )
    let archived = OpenClawChatThread(
      title: "Archived",
      sessionKey: "archived",
      messages: [OpenClawChatMessage(role: .assistant, content: "Cold history")],
      isArchived: true
    )
    let snapshot = AIChatTranscriptSnapshot(
      threads: [selected, archived],
      selectedThreadID: selected.id,
      settlementSettings: OpenClawThreadSettlementSettings()
    )

    try AIChatTranscriptStore.shared.flush(snapshot, legacyURL: transcriptURL)

    XCTAssertEqual(try Data(contentsOf: transcriptURL), legacyData)
    let storeDirectory = AIChatTranscriptStore.storeDirectory(for: transcriptURL)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: storeDirectory.appendingPathComponent("manifest.json").path
    ))
    let blobs = try FileManager.default.contentsOfDirectory(
      at: storeDirectory.appendingPathComponent("attachments"),
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(blobs.count, 1)
    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(blobs.first)), attachmentData)

    let loaded = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: transcriptURL)
    )
    XCTAssertEqual(loaded.snapshot.threads.first?.messages.first?.content, "Inspect this artifact")
    XCTAssertEqual(
      try loaded.snapshot.threads.first?.messages.first?.attachments.first?.loadData(),
      attachmentData
    )
    XCTAssertTrue(loaded.unloadedThreadIDs.contains(archived.id))
    let archivedMetadata = try XCTUnwrap(
      loaded.snapshot.threads.first(where: { $0.id == archived.id })
    )
    XCTAssertTrue(archivedMetadata.messages.isEmpty)
    XCTAssertEqual(archivedMetadata.messageCount, 1)
    let hydratedArchive = try XCTUnwrap(AIChatTranscriptStore.shared.loadThread(
      id: archived.id,
      metadata: archivedMetadata,
      legacyURL: transcriptURL
    ))
    XCTAssertEqual(hydratedArchive.messages.first?.content, "Cold history")
  }

  func testRealisticThreadCountHasBoundedStartupHydration() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-scale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    let threads = (0..<360).map { index in
      OpenClawChatThread(
        title: "Thread \(index)",
        sessionKey: "thread-\(index)",
        messages: [
          OpenClawChatMessage(role: .user, content: String(repeating: "question \(index) ", count: 20)),
          OpenClawChatMessage(role: .assistant, content: String(repeating: "answer \(index) ", count: 20)),
        ],
        isArchived: index >= 12
      )
    }
    let selectedID = try XCTUnwrap(threads.first?.id)
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: selectedID,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )

    let loaded = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: transcriptURL)
    )
    XCTAssertEqual(loaded.snapshot.threads.count, 360)
    XCTAssertEqual(loaded.unloadedThreadIDs.count, 348)
    XCTAssertEqual(
      loaded.snapshot.threads.filter { !$0.messages.isEmpty }.map(\.id),
      Array(threads.prefix(12).map(\.id))
    )
    let manifest = AIChatTranscriptStore.storeDirectory(for: transcriptURL)
      .appendingPathComponent("manifest.json")
    let manifestBytes = try XCTUnwrap(
      try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize
    )
    XCTAssertLessThan(manifestBytes, 1_500_000)
  }

  @MainActor
  func testPersistingAfterLazyLoadPreservesUnhydratedThreadShards() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-lazy-preservation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    let selected = OpenClawChatThread(
      title: "Selected",
      sessionKey: "selected",
      messages: [OpenClawChatMessage(role: .user, content: "Selected history")]
    )
    let cold = OpenClawChatThread(
      title: "Cold",
      sessionKey: "cold",
      messages: [OpenClawChatMessage(role: .assistant, content: "Must survive a metadata-only save")],
      isArchived: true
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [selected, cold],
        selectedThreadID: selected.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )

    let suiteName = "AIChatTranscriptStoreTests.LazyPreservation.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    let coldPlaceholder = try XCTUnwrap(
      store.openClawChatThreads.first(where: { $0.id == cold.id })
    )
    XCTAssertTrue(coldPlaceholder.messages.isEmpty)
    XCTAssertEqual(coldPlaceholder.messageCount, 1)

    // A normal application save must update the manifest without interpreting
    // a cold placeholder as an intentionally empty, hydrated thread.
    store.flushDeferredAIChatTranscriptPersistence()

    let reloaded = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: transcriptURL)
    )
    let reloadedMetadata = try XCTUnwrap(
      reloaded.snapshot.threads.first(where: { $0.id == cold.id })
    )
    XCTAssertEqual(reloadedMetadata.messageCount, 1)
    let hydrated = try XCTUnwrap(AIChatTranscriptStore.shared.loadThread(
      id: cold.id,
      metadata: reloadedMetadata,
      legacyURL: transcriptURL
    ))
    XCTAssertEqual(hydrated.messages.map(\.content), ["Must survive a metadata-only save"])
  }

  func testPendingSnapshotDerivesUnloadedIDsAndHydratesSelectedAndPendingThreads() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-pending-snapshot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    let selected = OpenClawChatThread(
      title: "Selected",
      sessionKey: "selected",
      messages: [OpenClawChatMessage(role: .assistant, content: "selected payload")]
    )
    let pendingMessage = OpenClawChatMessage(
      role: .user,
      content: "pending payload",
      deliveryStatus: .sending
    )
    let pending = OpenClawChatThread(
      title: "Pending",
      sessionKey: "pending",
      messages: [pendingMessage],
      isArchived: true,
      pendingTurn: OpenClawPendingTurn(
        userMessageID: pendingMessage.id,
        runID: "run-pending",
        agentID: "main",
        gatewayMessage: "pending payload"
      )
    )
    let cold = OpenClawChatThread(
      title: "Cold",
      sessionKey: "cold",
      messages: [OpenClawChatMessage(role: .assistant, content: "cold payload")],
      isArchived: true
    )
    let initial = AIChatTranscriptSnapshot(
      threads: [selected, pending, cold],
      selectedThreadID: selected.id,
      settlementSettings: OpenClawThreadSettlementSettings()
    )
    try AIChatTranscriptStore.shared.flush(initial, legacyURL: transcriptURL)
    let metadataOnly = AIChatTranscriptSnapshot(
      threads: initial.threads.map { $0.metadataOnly() },
      selectedThreadID: selected.id,
      settlementSettings: initial.settlementSettings
    )

    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(true, legacyURL: transcriptURL)
    defer {
      AIChatTranscriptStore.shared.setWritesSuspendedForTesting(false, legacyURL: transcriptURL)
    }
    _ = AIChatTranscriptStore.shared.enqueue(metadataOnly, legacyURL: transcriptURL)
    let loaded = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: transcriptURL)
    )

    XCTAssertEqual(
      loaded.snapshot.threads.first(where: { $0.id == selected.id })?.messages.first?.content,
      "selected payload"
    )
    XCTAssertEqual(
      loaded.snapshot.threads.first(where: { $0.id == pending.id })?.messages.first?.content,
      "pending payload"
    )
    XCTAssertEqual(
      loaded.snapshot.threads.first(where: { $0.id == cold.id })?.messages,
      []
    )
    XCTAssertEqual(loaded.unloadedThreadIDs, [cold.id])
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(false, legacyURL: transcriptURL)
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
  }

  func testDurabilityBarrierIsCommittedBeforeLaterCoalescedSnapshot() async throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let barrierThread = fixture.thread.replacingMessages([
      OpenClawChatMessage(role: .assistant, content: "durability barrier")
    ])
    let laterThread = fixture.thread.replacingMessages([
      OpenClawChatMessage(role: .assistant, content: "later coalesced state")
    ])
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(true, legacyURL: fixture.transcriptURL)
    let barrierGeneration = AIChatTranscriptStore.shared.enqueueDurabilityBarrier(
      AIChatTranscriptSnapshot(
        threads: [barrierThread],
        selectedThreadID: barrierThread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    _ = AIChatTranscriptStore.shared.enqueue(
      AIChatTranscriptSnapshot(
        threads: [laterThread],
        selectedThreadID: laterThread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(false, legacyURL: fixture.transcriptURL)
    try await AIChatTranscriptStore.shared.waitUntilPersisted(
      generation: barrierGeneration,
      legacyURL: fixture.transcriptURL
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()

    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    let marker = try markerObject(storeURL: storeURL)
    let currentName = try XCTUnwrap(marker["currentManifest"] as? String)
    try Data("corrupt latest".utf8).write(
      to: storeURL.appendingPathComponent("manifests/\(currentName)"),
      options: .atomic
    )
    try Data("corrupt latest".utf8).write(
      to: storeURL.appendingPathComponent("manifest.json"),
      options: .atomic
    )
    let recovered = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    XCTAssertEqual(
      recovered.snapshot.threads.first?.messages.first?.content,
      "durability barrier"
    )
  }

  func testCrashBeforeMarkerCommitLeavesLegacyEligibleForMigration() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let legacyData = try JSONEncoder().encode(LegacyTranscriptFixture(
      version: 6,
      threads: [fixture.thread],
      selectedThreadID: fixture.thread.id,
      settlementSettings: OpenClawThreadSettlementSettings()
    ))
    try legacyData.write(to: fixture.transcriptURL)
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    let orphanDirectory = storeURL.appendingPathComponent("manifests", isDirectory: true)
    try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
    try Data("uncommitted manifest".utf8).write(
      to: orphanDirectory.appendingPathComponent("orphan.json")
    )

    XCTAssertNil(AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL))
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [fixture.thread],
        selectedThreadID: fixture.thread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    let migrated = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    XCTAssertEqual(migrated.snapshot.threads.first?.id, fixture.thread.id)
    XCTAssertEqual(try Data(contentsOf: fixture.transcriptURL), legacyData)
  }

  func testCorruptCurrentManifestRecoversPreviousCommit() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = AIChatTranscriptSnapshot(
      threads: [fixture.thread.replacingMessages([
        OpenClawChatMessage(role: .assistant, content: "first committed payload")
      ])],
      selectedThreadID: fixture.thread.id,
      settlementSettings: OpenClawThreadSettlementSettings()
    )
    try AIChatTranscriptStore.shared.flush(first, legacyURL: fixture.transcriptURL)
    let second = AIChatTranscriptSnapshot(
      threads: [fixture.thread.replacingMessages([
        OpenClawChatMessage(role: .assistant, content: "second committed payload")
      ])],
      selectedThreadID: fixture.thread.id,
      settlementSettings: OpenClawThreadSettlementSettings()
    )
    try AIChatTranscriptStore.shared.flush(second, legacyURL: fixture.transcriptURL)
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()

    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    let marker = try markerObject(storeURL: storeURL)
    let currentName = try XCTUnwrap(marker["currentManifest"] as? String)
    try Data("corrupt current".utf8).write(
      to: storeURL.appendingPathComponent("manifests/\(currentName)"),
      options: .atomic
    )
    try Data("corrupt current view".utf8).write(
      to: storeURL.appendingPathComponent("manifest.json"),
      options: .atomic
    )

    let recovered = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    XCTAssertEqual(recovered.recoveryStatus, .recoveredPreviousManifest)
    XCTAssertEqual(recovered.snapshot.threads.first?.messages.first?.content, "first committed payload")
  }

  func testCorruptCurrentShardRecoversPreviousCompleteCommit() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try writeTwoRecoveryCommits(fixture)
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    try Data("corrupt current shard".utf8).write(
      to: try currentShardURL(storeURL: storeURL),
      options: .atomic
    )

    let recovered = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    XCTAssertEqual(recovered.recoveryStatus, .recoveredPreviousManifest)
    XCTAssertEqual(recovered.snapshot.threads.first?.messages.first?.content, "first committed payload")
  }

  func testDeletedCurrentShardRecoversPreviousCompleteCommit() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try writeTwoRecoveryCommits(fixture)
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    try FileManager.default.removeItem(at: try currentShardURL(storeURL: storeURL))

    let recovered = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    XCTAssertEqual(recovered.recoveryStatus, .recoveredPreviousManifest)
    XCTAssertEqual(recovered.snapshot.threads.first?.messages.first?.content, "first committed payload")
  }

  func testMissingOnlyCommittedShardBlocksMetadataWrites() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = AIChatTranscriptSnapshot(
      threads: [fixture.thread],
      selectedThreadID: fixture.thread.id,
      settlementSettings: OpenClawThreadSettlementSettings()
    )
    try AIChatTranscriptStore.shared.flush(snapshot, legacyURL: fixture.transcriptURL)
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    try FileManager.default.removeItem(at: try currentShardURL(storeURL: storeURL))

    let unavailable = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    XCTAssertTrue(unavailable.recoveryStatus.blocksWrites)
    XCTAssertThrowsError(
      try AIChatTranscriptStore.shared.flush(
        AIChatTranscriptSnapshot(
          threads: [fixture.thread.metadataOnly()],
          selectedThreadID: fixture.thread.id,
          settlementSettings: OpenClawThreadSettlementSettings()
        ),
        legacyURL: fixture.transcriptURL
      )
    )
  }

  func testCorruptPrimaryMarkerRecoversRedundantMarker() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [fixture.thread],
        selectedThreadID: fixture.thread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    try Data("corrupt marker".utf8).write(
      to: storeURL.appendingPathComponent("migration-marker.json"),
      options: .atomic
    )

    let recovered = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    XCTAssertEqual(recovered.recoveryStatus, .recoveredPreviousManifest)
    XCTAssertEqual(recovered.snapshot.threads.first?.messages.first?.content, "original")
  }

  @MainActor
  func testCorruptDerivedMarkersRecoverAndNormalizeImmutableCommit() async throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let canonicalThread = fixture.thread.replacingMessages([
      OpenClawChatMessage(role: .assistant, content: "canonical marker recovery")
    ])
    let derivedOnlyThread = OpenClawChatThread(
      title: "Newer derived-only thread",
      sessionKey: "newer-derived-marker",
      messages: [OpenClawChatMessage(role: .assistant, content: "newer than legacy")]
    )
    let canonicalData = try encodedLegacyTranscript([canonicalThread])
    try canonicalData.write(to: fixture.transcriptURL, options: .atomic)
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [canonicalThread, derivedOnlyThread],
        selectedThreadID: canonicalThread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()

    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    for name in [
      "migration-marker.json", "migration-marker.previous.json",
      "manifest.json", "manifest.previous.json",
    ] {
      let candidate = storeURL.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: candidate.path) {
        try Data("corrupt \(name)".utf8).write(to: candidate, options: .atomic)
      }
    }
    let suiteName = "AIChatTranscriptStoreTests.CanonicalMarkerRecovery.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: fixture.transcriptURL,
      legacyDefaultsDomains: []
    )
    await store.waitForAIChatTranscriptLoadForTesting()
    try await store.waitForAIChatTranscriptPersistenceForTesting()

    XCTAssertEqual(Set(store.openClawChatThreads.map(\.id)), Set([canonicalThread.id, derivedOnlyThread.id]))
    XCTAssertNil(store.aiChatTranscriptRecoveryNotice)
    XCTAssertEqual(try Data(contentsOf: fixture.transcriptURL), canonicalData)
    XCTAssertEqual(try quarantinedStoreDirectories(for: fixture.transcriptURL).count, 0)
    let normalized = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    XCTAssertEqual(normalized.recoveryStatus, .healthy)
    XCTAssertEqual(Set(normalized.snapshot.threads.map(\.id)), Set([canonicalThread.id, derivedOnlyThread.id]))
  }

  func testRecoveryReconcilesNewestValidThreadFromDivergentBranches() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    let secondID = UUID()
    func thread(_ id: UUID, title: String, date: Date, content: String) -> OpenClawChatThread {
      OpenClawChatThread(
        id: id,
        title: title,
        createdAt: baseDate,
        updatedAt: date,
        sessionKey: id.uuidString.lowercased(),
        messages: [OpenClawChatMessage(role: .assistant, content: content)]
      )
    }
    let baseA = thread(fixture.thread.id, title: "A", date: baseDate, content: "base A")
    let baseB = thread(secondID, title: "B", date: baseDate, content: "base B")
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [baseA, baseB],
        selectedThreadID: baseA.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    let branchB = thread(
      secondID,
      title: "B",
      date: baseDate.addingTimeInterval(30),
      content: "newest B"
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [baseA, branchB],
        selectedThreadID: baseA.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    let branchA = thread(
      fixture.thread.id,
      title: "A",
      date: baseDate.addingTimeInterval(40),
      content: "newest A"
    )
    let supersededB = thread(
      secondID,
      title: "B",
      date: baseDate.addingTimeInterval(20),
      content: "incomplete branch B"
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [branchA, supersededB],
        selectedThreadID: branchA.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    let currentManifest = try currentManifestObject(storeURL: storeURL)
    let entries = try XCTUnwrap(currentManifest["threads"] as? [[String: Any]])
    let brokenEntry = try XCTUnwrap(entries.first(where: { entry in
      ((entry["metadata"] as? [String: Any])?["id"] as? String)?.lowercased()
        == secondID.uuidString.lowercased()
    }))
    let brokenShard = try XCTUnwrap(brokenEntry["shard"] as? String)
    try FileManager.default.removeItem(at: storeURL.appendingPathComponent(brokenShard))

    let recovered = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    XCTAssertEqual(recovered.recoveryStatus, .recoveredPreviousManifest)
    let hydrated = AIChatTranscriptStore.shared.loadAllThreads(
      replacingMetadata: recovered.snapshot.threads,
      legacyURL: fixture.transcriptURL
    )
    XCTAssertEqual(
      hydrated.first(where: { $0.id == branchA.id })?.messages.first?.content,
      "newest A"
    )
    XCTAssertEqual(
      hydrated.first(where: { $0.id == branchB.id })?.messages.first?.content,
      "newest B"
    )
  }

  @MainActor
  func testRetryClearsReadOnlyRecoveryStateAfterShardArrives() async throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [fixture.thread],
        selectedThreadID: fixture.thread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    let shardURL = try currentShardURL(storeURL: storeURL)
    let shardData = try Data(contentsOf: shardURL)
    try FileManager.default.removeItem(at: shardURL)

    let suiteName = "AIChatTranscriptStoreTests.RetryRecovery.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: fixture.transcriptURL,
      legacyDefaultsDomains: []
    )
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertNotNil(store.aiChatTranscriptRecoveryNotice)

    try shardData.write(to: shardURL, options: .atomic)
    store.retryAIChatTranscriptRecovery()
    await store.waitForAIChatTranscriptLoadForTesting()

    XCTAssertNil(store.aiChatTranscriptRecoveryNotice)
    XCTAssertEqual(store.openClawMessages.first?.content, "original")
  }

  @MainActor
  func testCorruptOnlyDerivedShardDisplaysValidatedLegacyTranscriptReadOnly() async throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let canonicalThread = fixture.thread.replacingMessages([
      OpenClawChatMessage(role: .assistant, content: "canonical shard recovery")
    ])
    let derivedOnlyThread = OpenClawChatThread(
      title: "Newer derived-only thread",
      sessionKey: "newer-derived-shard",
      messages: [OpenClawChatMessage(role: .assistant, content: "newer than legacy")]
    )
    let canonicalData = try encodedLegacyTranscript([canonicalThread])
    try canonicalData.write(to: fixture.transcriptURL, options: .atomic)
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [canonicalThread, derivedOnlyThread],
        selectedThreadID: canonicalThread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    try Data("corrupt only shard".utf8).write(
      to: try currentShardURL(storeURL: storeURL),
      options: .atomic
    )
    let derivedStoreBeforeLoad = try storeDirectorySnapshot(storeURL)

    let suiteName = "AIChatTranscriptStoreTests.CanonicalShardRecovery.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: fixture.transcriptURL,
      legacyDefaultsDomains: []
    )
    await store.waitForAIChatTranscriptLoadForTesting()

    XCTAssertEqual(store.openClawChatThreads.map(\.id), [canonicalThread.id])
    XCTAssertEqual(store.openClawMessages.map(\.content), ["canonical shard recovery"])
    XCTAssertTrue(store.aiChatTranscriptRecoveryNotice?.contains("validated legacy") == true)
    XCTAssertTrue(store.aiChatTranscriptRecoveryNotice?.contains("read-only") == true)
    XCTAssertEqual(try Data(contentsOf: fixture.transcriptURL), canonicalData)
    XCTAssertEqual(try quarantinedStoreDirectories(for: fixture.transcriptURL).count, 0)
    XCTAssertEqual(try storeDirectorySnapshot(storeURL), derivedStoreBeforeLoad)
    let stillBlocked = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    XCTAssertTrue(stillBlocked.recoveryStatus.blocksWrites)

    _ = store.createOpenClawChatThread()
    store.flushDeferredAIChatTranscriptPersistence()
    XCTAssertTrue(store.errorText?.contains("writes are disabled") == true)
    XCTAssertEqual(try storeDirectorySnapshot(storeURL), derivedStoreBeforeLoad)
  }

  @MainActor
  func testCorruptDerivedStoreDoesNotRollbackToEmptyCanonicalTranscript() async throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let emptyCanonical = Data("{\"version\":6,\"threads\":[]}".utf8)
    try emptyCanonical.write(to: fixture.transcriptURL, options: .atomic)
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [fixture.thread],
        selectedThreadID: fixture.thread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    try Data("corrupt only shard".utf8).write(
      to: try currentShardURL(storeURL: storeURL),
      options: .atomic
    )
    let derivedStoreBeforeLoad = try storeDirectorySnapshot(storeURL)

    let suiteName = "AIChatTranscriptStoreTests.EmptyCanonicalRecovery.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: fixture.transcriptURL,
      legacyDefaultsDomains: []
    )
    await store.waitForAIChatTranscriptLoadForTesting()

    XCTAssertTrue(store.openClawChatThreads.isEmpty)
    XCTAssertTrue(store.aiChatTranscriptRecoveryNotice?.contains("not loaded") == true)
    XCTAssertEqual(try quarantinedStoreDirectories(for: fixture.transcriptURL).count, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    XCTAssertEqual(try Data(contentsOf: fixture.transcriptURL), emptyCanonical)
    XCTAssertEqual(try storeDirectorySnapshot(storeURL), derivedStoreBeforeLoad)
  }

  func testUnrecoverableMigratedStoreNeverFallsBackOrAcceptsWrites() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let staleLegacy = Data("{\"version\":6,\"threads\":[]}".utf8)
    try staleLegacy.write(to: fixture.transcriptURL)
    let snapshot = AIChatTranscriptSnapshot(
      threads: [fixture.thread],
      selectedThreadID: fixture.thread.id,
      settlementSettings: OpenClawThreadSettlementSettings()
    )
    try AIChatTranscriptStore.shared.flush(snapshot, legacyURL: fixture.transcriptURL)
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    let marker = try markerObject(storeURL: storeURL)
    let currentName = try XCTUnwrap(marker["currentManifest"] as? String)
    try Data("broken".utf8).write(
      to: storeURL.appendingPathComponent("manifests/\(currentName)"),
      options: .atomic
    )
    try Data("broken".utf8).write(
      to: storeURL.appendingPathComponent("manifest.json"),
      options: .atomic
    )

    let blocked = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    XCTAssertTrue(blocked.recoveryStatus.blocksWrites)
    XCTAssertTrue(blocked.snapshot.threads.isEmpty)
    XCTAssertThrowsError(
      try AIChatTranscriptStore.shared.flush(snapshot, legacyURL: fixture.transcriptURL)
    )
    XCTAssertEqual(try Data(contentsOf: fixture.transcriptURL), staleLegacy)
  }

  func testPostCommitGarbageCollectionBoundsImmutableStoreGrowth() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    for index in 0..<12 {
      let attachment = OpenClawChatAttachment(
        fileName: "artifact-\(index).bin",
        mimeType: "application/octet-stream",
        data: Data(repeating: UInt8(index), count: 1_024)
      )
      let thread = fixture.thread.replacingMessages([
        OpenClawChatMessage(
          role: .assistant,
          content: "revision \(index)",
          attachments: [attachment]
        )
      ])
      try AIChatTranscriptStore.shared.flush(
        AIChatTranscriptSnapshot(
          threads: [thread],
          selectedThreadID: thread.id,
          settlementSettings: OpenClawThreadSettlementSettings()
        ),
        legacyURL: fixture.transcriptURL
      )
    }
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    try ageFilesRecursively(in: storeURL, by: 31 * 24 * 60 * 60)
    let finalThread = fixture.thread.replacingMessages([
      OpenClawChatMessage(role: .assistant, content: "final revision")
    ])
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [finalThread],
        selectedThreadID: finalThread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    XCTAssertLessThanOrEqual(try fileCount(storeURL.appendingPathComponent("manifests")), 2)
    XCTAssertLessThanOrEqual(try fileCount(storeURL.appendingPathComponent("threads")), 2)
    XCTAssertLessThanOrEqual(try fileCount(storeURL.appendingPathComponent("attachments")), 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.transcriptURL.path))
  }

  func testGarbageCollectionPreservesFreshUnreferencedSyncArtifacts() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try writeTwoRecoveryCommits(fixture)
    let storeURL = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
    let orphan = storeURL.appendingPathComponent("threads/fresh-sync-artifact.json")
    try Data("still syncing".utf8).write(to: orphan, options: .atomic)

    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [fixture.thread.replacingMessages([
          OpenClawChatMessage(role: .assistant, content: "third committed payload")
        ])],
        selectedThreadID: fixture.thread.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()

    XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
  }

  func testCorruptAttachmentBlobThrowsAndIsNeverRewrittenAsEmpty() throws {
    let fixture = try makeRecoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let bytes = Data(repeating: 0x7f, count: 4_096)
    let thread = fixture.thread.replacingMessages([
      OpenClawChatMessage(
        role: .assistant,
        content: "attachment",
        attachments: [OpenClawChatAttachment(
          fileName: "artifact.bin",
          mimeType: "application/octet-stream",
          data: bytes
        )]
      )
    ])
    let snapshot = AIChatTranscriptSnapshot(
      threads: [thread],
      selectedThreadID: thread.id,
      settlementSettings: OpenClawThreadSettlementSettings()
    )
    try AIChatTranscriptStore.shared.flush(snapshot, legacyURL: fixture.transcriptURL)
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let attachmentDirectory = AIChatTranscriptStore.storeDirectory(for: fixture.transcriptURL)
      .appendingPathComponent("attachments")
    let blob = try XCTUnwrap(
      try FileManager.default.contentsOfDirectory(
        at: attachmentDirectory,
        includingPropertiesForKeys: nil
      ).first
    )
    let corrupt = Data("not the claimed blob".utf8)
    try corrupt.write(to: blob, options: .atomic)
    let loaded = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: fixture.transcriptURL)
    )
    let lazyAttachment = try XCTUnwrap(
      loaded.snapshot.threads.first?.messages.first?.attachments.first
    )
    XCTAssertThrowsError(try lazyAttachment.loadData())
    XCTAssertThrowsError(
      try AIChatTranscriptStore.shared.flush(loaded.snapshot, legacyURL: fixture.transcriptURL)
    )
    XCTAssertEqual(try Data(contentsOf: blob), corrupt)
  }

  @MainActor
  func testAttachmentBearingColdThreadHydratesOnSwitch() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-attachment-switch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    let selected = OpenClawChatThread(
      title: "Selected",
      sessionKey: "selected",
      messages: [OpenClawChatMessage(role: .assistant, content: "selected")]
    )
    let attachmentBytes = Data(repeating: 0x42, count: 32_768)
    let cold = OpenClawChatThread(
      title: "Attachment archive",
      sessionKey: "attachment-archive",
      messages: [OpenClawChatMessage(
        role: .assistant,
        content: "archived attachment",
        attachments: [OpenClawChatAttachment(
          fileName: "archive.bin",
          mimeType: "application/octet-stream",
          data: attachmentBytes
        )]
      )],
      isArchived: true
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [selected, cold],
        selectedThreadID: selected.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let suiteName = "AIChatTranscriptStoreTests.AttachmentSwitch.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    XCTAssertTrue(store.unloadedAIChatThreadIDsForTesting.contains(cold.id))

    store.selectOpenClawChatThread(cold.id)
    await store.waitForAIChatThreadHydrationForTesting(cold.id)

    XCTAssertEqual(
      try store.openClawMessages.first?.attachments.first?.loadData(),
      attachmentBytes
    )
    XCTAssertFalse(store.unloadedAIChatThreadIDsForTesting.contains(cold.id))
  }

  @MainActor
  func testForkingColdThreadHydratesAndPreservesHistory() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-cold-fork-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    let selected = OpenClawChatThread(
      title: "Selected",
      sessionKey: "selected",
      messages: [OpenClawChatMessage(role: .assistant, content: "selected")]
    )
    let coldMessages = [
      OpenClawChatMessage(role: .user, content: "Question from cold storage"),
      OpenClawChatMessage(role: .assistant, content: "Answer from cold storage"),
    ]
    let cold = OpenClawChatThread(
      title: "Cold fork source",
      sessionKey: "cold-fork-source",
      messages: coldMessages,
      isArchived: true
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [selected, cold],
        selectedThreadID: selected.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let suiteName = "AIChatTranscriptStoreTests.ColdFork.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    XCTAssertTrue(store.unloadedAIChatThreadIDsForTesting.contains(cold.id))

    let loadedForkID = await store.forkAIChatThread(cold.id, selectsThread: false)
    let forkID = try XCTUnwrap(loadedForkID)
    let fork = try XCTUnwrap(store.openClawChatThreads.first(where: { $0.id == forkID }))

    XCTAssertEqual(fork.messages.map(\.content), coldMessages.map(\.content))
    XCTAssertFalse(store.unloadedAIChatThreadIDsForTesting.contains(cold.id))
  }

  @MainActor
  func testColdMobileRemoteDetailHydratesBeforeProjectingMessages() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-cold-mobile-detail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    let selected = OpenClawChatThread(
      title: "Selected",
      sessionKey: "selected",
      messages: [OpenClawChatMessage(role: .assistant, content: "selected")]
    )
    let coldMessage = OpenClawChatMessage(
      role: .assistant,
      content: "Complete remote detail from the cold shard"
    )
    let cold = OpenClawChatThread(
      title: "Cold mobile detail",
      sessionKey: "cold-mobile-detail",
      messages: [coldMessage],
      isArchived: true
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [selected, cold],
        selectedThreadID: selected.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let suiteName = "AIChatTranscriptStoreTests.ColdMobileDetail.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    XCTAssertTrue(store.unloadedAIChatThreadIDsForTesting.contains(cold.id))

    let loadedThread = await store.hydratedAIChatThreadForDetail(cold.id)
    let hydrated = try XCTUnwrap(loadedThread)
    let response = await MobileRemoteBackgroundWork().threadDetailResponse(
      thread: hydrated,
      context: MobileRemoteThreadDetailProjectionContext(
        threads: MobileRemoteThreadProjectionContext(
          destinationNamesByID: [:],
          runningThreadIDs: []
        ),
        activeDestinationName: nil,
        streamingReply: "",
        reasoning: "",
        activities: [],
        connectionState: "disconnected",
        connectionDetail: nil
      )
    )
    let detail = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteThreadDetail.self,
      from: response.body
    )

    XCTAssertEqual(detail.messages.map(\.content), [coldMessage.content])
    XCTAssertFalse(store.unloadedAIChatThreadIDsForTesting.contains(cold.id))
  }

  func testDetachedInitialPresentationPreparationIsBoundedAndAttachmentFree() async {
    let messages = (0..<232).map { index in
      OpenClawChatMessage(
        role: index.isMultiple(of: 2) ? .user : .assistant,
        content: index == 231
          ? String(repeating: "L", count: 1_694_760)
          : "Message \(index) " + String(repeating: "body ", count: 40),
        attachments: index == 231
          ? [OpenClawChatAttachment(
              fileName: "large.bin",
              mimeType: "application/octet-stream",
              data: Data(repeating: 0x42, count: 512 * 1_024)
            )]
          : []
      )
    }

    let prepared = await Task.detached {
      WorkspaceStore.prepareInitialOpenClawMessagePresentations(
        messages: messages,
        isSharedRoom: false
      )
    }.value

    XCTAssertEqual(prepared.count, OpenClawChatTranscriptWindow.initialLimit)
    XCTAssertEqual(prepared.map(\.messageID), messages.suffix(24).map(\.id))
    let heavy = prepared.last?.value.body
    XCTAssertTrue(heavy?.isTruncated == true)
    XCTAssertEqual(
      heavy?.displayedText.utf8.count,
      OpenClawMessageBodyExcerpt.collapsedUTF8ByteLimit
    )
    XCTAssertLessThan(
      prepared.reduce(0) { $0 + $1.estimatedCost },
      messages.suffix(24).reduce(0) { $0 + $1.content.utf8.count } * 4
    )
  }

  @MainActor
  func testAbandonedColdHydrationStillInstallsBoundedPresentationsForReselection() async throws {
    OpenClawMessagePresentationCache.removeAllForTesting()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-abandoned-hydration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    let selected = OpenClawChatThread(
      title: "Selected",
      sessionKey: "selected",
      messages: [OpenClawChatMessage(role: .assistant, content: "selected")]
    )
    let coldMessage = OpenClawChatMessage(
      role: .assistant,
      content: "* Cold prepared result"
    )
    let cold = OpenClawChatThread(
      title: "Cold",
      sessionKey: "cold",
      messages: [coldMessage],
      isArchived: true
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [selected, cold],
        selectedThreadID: selected.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let suiteName = "AIChatTranscriptStoreTests.AbandonedHydration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    let preparedOffMain = expectation(description: "cold shard and presentation prepared")
    store.openClawThreadHydrationDelayNanosecondsForTesting = 200_000_000
    store.openClawThreadHydrationDidLoadForTesting = { id in
      if id == cold.id { preparedOffMain.fulfill() }
    }

    store.selectOpenClawChatThread(cold.id)
    await fulfillment(of: [preparedOffMain], timeout: 2)
    store.selectOpenClawChatThread(selected.id)
    await store.waitForAIChatThreadHydrationForTesting(cold.id)

    let cached = try XCTUnwrap(
      OpenClawMessagePresentationCache.cachedPresentationForTesting(
        messageID: coldMessage.id
      )
    )
    XCTAssertEqual(cached.rawText, coldMessage.content)

    store.selectOpenClawChatThread(cold.id)
    XCTAssertEqual(store.openClawMessages.map(\.content), [coldMessage.content])
    XCTAssertTrue(OpenClawMessagePresentationCache.presentation(for: coldMessage) === cached)
  }

  @MainActor
  func testDelayedColdThreadHydrationCannotOverwriteConcurrentLocalMutation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-hydration-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    let selected = OpenClawChatThread(
      title: "Selected",
      sessionKey: "selected",
      messages: [OpenClawChatMessage(role: .assistant, content: "selected")]
    )
    let staleMessage = OpenClawChatMessage(role: .assistant, content: "stale disk payload")
    let cold = OpenClawChatThread(
      title: "Cold",
      sessionKey: "cold",
      messages: [staleMessage],
      isArchived: true
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [selected, cold],
        selectedThreadID: selected.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let suiteName = "AIChatTranscriptStoreTests.HydrationRace.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    OpenClawMessagePresentationCache.removeAllForTesting()
    let diskLoadFinished = expectation(description: "detached hydration loaded the cold shard")
    var hydrationLoadCount = 0
    store.openClawThreadHydrationDelayNanosecondsForTesting = 250_000_000
    store.openClawThreadHydrationDidLoadForTesting = { id in
      guard id == cold.id else { return }
      hydrationLoadCount += 1
      if hydrationLoadCount == 1 { diskLoadFinished.fulfill() }
    }

    store.selectOpenClawChatThread(cold.id)
    store.selectOpenClawChatThread(cold.id)
    await fulfillment(of: [diskLoadFinished], timeout: 2)
    store.openClawMessages = [OpenClawChatMessage(role: .user, content: "live mutation")]
    try await Task.sleep(nanoseconds: 350_000_000)

    XCTAssertEqual(store.openClawMessages.map(\.content), ["live mutation"])
    XCTAssertEqual(hydrationLoadCount, 1)
    XCTAssertFalse(store.unloadedAIChatThreadIDsForTesting.contains(cold.id))
    XCTAssertNil(OpenClawMessagePresentationCache.cachedPresentationForTesting(
      messageID: staleMessage.id
    ))
  }

  @MainActor
  func testSendAcceptedDuringDelayedHydrationPreservesDiskHistory() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-hydration-send-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    let selected = OpenClawChatThread(
      title: "Selected",
      sessionKey: "selected",
      messages: [OpenClawChatMessage(role: .assistant, content: "selected")]
    )
    let warm = (0..<15).map { index in
      OpenClawChatThread(
        title: "Warm \(index)",
        sessionKey: "warm-\(index)",
        messages: [OpenClawChatMessage(role: .assistant, content: "warm \(index)")]
      )
    }
    let cold = OpenClawChatThread(
      title: "Cold send",
      sessionKey: "cold-send",
      messages: [OpenClawChatMessage(role: .assistant, content: "disk history")]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [selected] + warm + [cold],
        selectedThreadID: selected.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let suiteName = "AIChatTranscriptStoreTests.HydrationSend.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      openClawSendHandler: { _, _, _, _ in "test reply" },
      legacyDefaultsDomains: []
    )
    XCTAssertTrue(store.unloadedAIChatThreadIDsForTesting.contains(cold.id))
    let diskLoadFinished = expectation(description: "cold send shard loaded")
    store.openClawThreadHydrationDelayNanosecondsForTesting = 200_000_000
    store.openClawThreadHydrationDidLoadForTesting = { id in
      if id == cold.id { diskLoadFinished.fulfill() }
    }

    store.selectOpenClawChatThread(cold.id)
    await fulfillment(of: [diskLoadFinished], timeout: 2)
    store.sendComposedOpenClawMessage(text: "new while loading")
    for _ in 0..<200 {
      let contents = store.openClawMessages.map(\.content)
      if contents.contains("test reply") { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(
      store.openClawMessages.map(\.content),
      ["disk history", "new while loading", "test reply"]
    )
  }

  @MainActor
  func testColdAlphaComposerSendCannotAppendToWarmBetaWithSameThreadUUID() async throws {
    OpenClawMessagePresentationCache.removeAllForTesting()
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-cold-corpus-race-\(UUID().uuidString)", isDirectory: true)
    let alpha = base.appendingPathComponent("alpha", isDirectory: true)
    let beta = base.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let alphaTranscript = alpha.appendingPathComponent(".org2/openclaw-chat.json")
    let betaTranscript = beta.appendingPathComponent(".org2/openclaw-chat.json")
    let sameID = UUID()
    let sameMessageID = UUID()
    let selected = OpenClawChatThread(
      title: "Alpha selected",
      sessionKey: "alpha-selected",
      messages: [OpenClawChatMessage(role: .assistant, content: "selected")]
    )
    let warm = (0..<16).map { index in
      OpenClawChatThread(
        title: "Warm \(index)",
        sessionKey: "warm-\(index)",
        messages: [OpenClawChatMessage(role: .assistant, content: "warm \(index)")]
      )
    }
    let alphaCold = OpenClawChatThread(
      id: sameID,
      title: "Alpha cold",
      sessionKey: "alpha-cold",
      messages: [OpenClawChatMessage(
        id: sameMessageID,
        role: .assistant,
        content: "alpha history"
      )]
    )
    let betaWarm = OpenClawChatThread(
      id: sameID,
      title: "Beta warm",
      sessionKey: "beta-warm",
      messages: [OpenClawChatMessage(
        id: sameMessageID,
        role: .assistant,
        content: "beta history"
      )]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [selected] + warm + [alphaCold],
        selectedThreadID: selected.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: alphaTranscript
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [betaWarm],
        selectedThreadID: sameID,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: betaTranscript
    )
    let suiteName = "AIChatTranscriptStoreTests.ColdCorpusRace.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawFallbackTranscriptURL: base.appendingPathComponent("fallback.json"),
      openClawSendHandler: { _, _, _, _ in "unexpected reply" },
      legacyDefaultsDomains: [],
      automaticStarterCorpusURL: nil
    )
    store.setCorpusRoot(alpha, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertTrue(store.unloadedAIChatThreadIDsForTesting.contains(sameID))

    let shardLoaded = expectation(description: "alpha cold shard loaded")
    let composerResolved = expectation(description: "deferred composer superseded")
    store.openClawThreadHydrationDelayNanosecondsForTesting = 1_000_000_000
    store.openClawThreadHydrationDidLoadForTesting = { id in
      if id == sameID { shardLoaded.fulfill() }
    }
    store.aiChatDeferredComposerDidResolveForTesting = { composerResolved.fulfill() }
    store.selectOpenClawChatThread(sameID)
    await fulfillment(of: [shardLoaded], timeout: 2)
    store.openClawDraft = "alpha pending draft"
    store.attachOpenClawAttachment(data: Data("alpha".utf8), fileName: "alpha.txt", mimeType: "text/plain")
    store.sendComposedOpenClawMessage(text: "alpha pending draft")

    store.setCorpusRoot(beta, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.publishOpenClawComposerDraft("beta newer typing")
    store.attachOpenClawAttachment(data: Data("beta".utf8), fileName: "beta.txt", mimeType: "text/plain")
    await fulfillment(of: [composerResolved], timeout: 2)

    XCTAssertEqual(store.openClawMessages.map(\.content), ["beta history"])
    XCTAssertEqual(store.openClawDraft, "beta newer typing")
    XCTAssertEqual(store.openClawPendingAttachments.map(\.fileName), ["beta.txt"])
    XCTAssertEqual(
      OpenClawMessagePresentationCache.cachedPresentationForTesting(
        messageID: sameMessageID
      )?.rawText,
      "beta history",
      "A canceled alpha hydration must not install stale same-ID presentation data"
    )

    store.setCorpusRoot(alpha, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.selectOpenClawChatThread(sameID)
    XCTAssertEqual(store.openClawDraft, "alpha pending draft")
    XCTAssertEqual(store.openClawPendingAttachments.map(\.fileName), ["alpha.txt"])
  }

  @MainActor
  func testLongHistoryThreadSwitchDoesNotRebuildEverySidebarSummary() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-switch-scale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    func messages(_ prefix: String) -> [OpenClawChatMessage] {
      (0..<8_000).map { index in
        OpenClawChatMessage(
          role: index.isMultiple(of: 2) ? .user : .assistant,
          content: "\(prefix)-\(index)-" + String(repeating: "history ", count: 16)
        )
      }
    }
    let first = OpenClawChatThread(
      title: "First long history",
      sessionKey: "first-long",
      messages: messages("first")
    )
    let second = OpenClawChatThread(
      title: "Second long history",
      sessionKey: "second-long",
      messages: messages("second"),
      unreadMessageCount: 7
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [first, second],
        selectedThreadID: first.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let suiteName = "AIChatTranscriptStoreTests.SwitchScale.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    let rebuildCount = store.aiChatFullDisplayRebuildCountForTesting
    let clock = ContinuousClock()
    let started = clock.now
    for index in 0..<40 {
      store.selectOpenClawChatThread(index.isMultiple(of: 2) ? second.id : first.id)
    }
    let duration = started.duration(to: clock.now)

    XCTAssertEqual(store.aiChatFullDisplayRebuildCountForTesting, rebuildCount)
    XCTAssertEqual(
      store.openClawChatThreads.first(where: { $0.id == second.id })?.unreadMessageCount,
      0
    )
    XCTAssertLessThan(duration, .milliseconds(300))
  }

  @MainActor
  func testMessageMutationDuringDelayedTranscriptLoadIsReplayedAndPersisted() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-delayed-load-\(UUID().uuidString)", isDirectory: true)
    let stateDirectory = root.appendingPathComponent(".org2", isDirectory: true)
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = stateDirectory.appendingPathComponent("openclaw-chat.json")
    let original = OpenClawChatThread(
      title: "Delayed",
      sessionKey: "delayed",
      messages: [OpenClawChatMessage(role: .user, content: "original")]
    )
    try JSONEncoder().encode(LegacyTranscriptFixture(
      version: 6,
      threads: [original],
      selectedThreadID: original.id,
      settlementSettings: OpenClawThreadSettlementSettings()
    )).write(to: transcriptURL)
    let suiteName = "AIChatTranscriptStoreTests.DelayedLoad.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    store.openClawTranscriptLoadDelayNanosecondsForTesting = 200_000_000

    store.setCorpusRoot(root, persistsDefault: false)
    XCTAssertTrue(store.isLoadingAIChatTranscript)
    store.openClawMessages = [OpenClawChatMessage(role: .user, content: "edited during load")]
    await store.waitForAIChatTranscriptLoadForTesting()
    try await store.waitForAIChatTranscriptPersistenceForTesting()

    XCTAssertEqual(store.openClawMessages.map(\.content), ["edited during load"])
    let reloaded = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: transcriptURL)
    )
    XCTAssertEqual(reloaded.snapshot.threads.first?.messages.map(\.content), ["edited during load"])
  }

  @MainActor
  func testSessionHydrationLRUStaysBoundedAndProtectsSelectedAndPendingThreads() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-hydration-lru-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("openclaw-chat.json")
    let pendingMessage = OpenClawChatMessage(
      role: .user,
      content: "pending",
      deliveryStatus: .sending
    )
    let pendingThread = OpenClawChatThread(
      title: "Pending",
      sessionKey: "pending",
      messages: [pendingMessage],
      isArchived: true,
      pendingTurn: OpenClawPendingTurn(
        userMessageID: pendingMessage.id,
        runID: "pending-run",
        agentID: "main",
        gatewayMessage: "pending"
      )
    )
    let ordinary = (0..<32).map { index in
      OpenClawChatThread(
        title: "Thread \(index)",
        sessionKey: "thread-\(index)",
        messages: [OpenClawChatMessage(role: .assistant, content: "payload \(index)")],
        isArchived: true
      )
    }
    let threads = [pendingThread] + ordinary
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: ordinary[0].id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let suiteName = "AIChatTranscriptStoreTests.HydrationLRU.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )

    for thread in ordinary {
      store.selectOpenClawChatThread(thread.id)
      await store.waitForAIChatThreadHydrationForTesting(thread.id)
    }

    XCTAssertLessThanOrEqual(
      store.hydratedAIChatThreadCountForTesting,
      AIChatTranscriptStore.eagerWorkingSetLimit + 2
    )
    XCTAssertFalse(store.unloadedAIChatThreadIDsForTesting.contains(ordinary.last!.id))
    XCTAssertFalse(store.unloadedAIChatThreadIDsForTesting.contains(pendingThread.id))
  }

  @MainActor
  func testCorpusSelectionDoesNotSynchronouslyDecodeLegacyMonolith() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-legacy-async-\(UUID().uuidString)", isDirectory: true)
    let stateDirectory = root.appendingPathComponent(".org2", isDirectory: true)
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = stateDirectory.appendingPathComponent("openclaw-chat.json")
    let message = OpenClawChatMessage(
      role: .user,
      content: String(repeating: "large legacy transcript payload ", count: 800_000)
    )
    let thread = OpenClawChatThread(
      title: "Legacy scale fixture",
      sessionKey: "legacy-scale",
      messages: [message]
    )
    try JSONEncoder().encode(LegacyTranscriptFixture(
      version: 6,
      threads: [thread],
      selectedThreadID: thread.id,
      settlementSettings: OpenClawThreadSettlementSettings()
    )).write(to: transcriptURL)
    let suiteName = "AIChatTranscriptStoreTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])

    let clock = ContinuousClock()
    let started = clock.now
    store.setCorpusRoot(root, persistsDefault: false)
    let synchronousDuration = started.duration(to: clock.now)

    XCTAssertLessThan(synchronousDuration, .milliseconds(150))
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(store.openClawMessages.first?.content.count, message.content.count)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: AIChatTranscriptStore.storeDirectory(for: transcriptURL)
        .appendingPathComponent("manifest.json").path
    ))
  }
}

private extension AIChatTranscriptStoreTests {
  struct RecoveryFixture {
    let root: URL
    let transcriptURL: URL
    let thread: OpenClawChatThread
  }

  func makeRecoveryFixture() throws -> RecoveryFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return RecoveryFixture(
      root: root,
      transcriptURL: root.appendingPathComponent("openclaw-chat.json"),
      thread: OpenClawChatThread(
        title: "Recovery",
        sessionKey: "recovery",
        messages: [OpenClawChatMessage(role: .assistant, content: "original")]
      )
    )
  }

  func markerObject(storeURL: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: storeURL.appendingPathComponent("migration-marker.json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func encodedLegacyTranscript(_ threads: [OpenClawChatThread]) throws -> Data {
    try JSONEncoder().encode(LegacyTranscriptFixture(
      version: 6,
      threads: threads,
      selectedThreadID: threads.first?.id,
      settlementSettings: OpenClawThreadSettlementSettings()
    ))
  }

  func quarantinedStoreDirectories(for transcriptURL: URL) throws -> [URL] {
    let storeURL = AIChatTranscriptStore.storeDirectory(for: transcriptURL)
    let prefix = "\(storeURL.lastPathComponent).corrupt-"
    return try FileManager.default.contentsOfDirectory(
      at: storeURL.deletingLastPathComponent(),
      includingPropertiesForKeys: [.isDirectoryKey]
    ).filter { $0.lastPathComponent.hasPrefix(prefix) }
  }

  func storeDirectorySnapshot(_ storeURL: URL) throws -> [String: Data] {
    guard let enumerator = FileManager.default.enumerator(
      at: storeURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      XCTFail("Could not enumerate derived AI chat store")
      return [:]
    }
    var snapshot: [String: Data] = [:]
    for case let fileURL as URL in enumerator {
      guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        continue
      }
      let relativePath = String(fileURL.path.dropFirst(storeURL.path.count + 1))
      snapshot[relativePath] = try Data(contentsOf: fileURL)
    }
    return snapshot
  }

  func writeTwoRecoveryCommits(_ fixture: RecoveryFixture) throws {
    let first = fixture.thread.replacingMessages([
      OpenClawChatMessage(role: .assistant, content: "first committed payload")
    ])
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [first],
        selectedThreadID: first.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    let second = fixture.thread.replacingMessages([
      OpenClawChatMessage(role: .assistant, content: "second committed payload")
    ])
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [second],
        selectedThreadID: second.id,
        settlementSettings: OpenClawThreadSettlementSettings()
      ),
      legacyURL: fixture.transcriptURL
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
  }

  func currentShardURL(storeURL: URL) throws -> URL {
    let manifest = try currentManifestObject(storeURL: storeURL)
    let threads = try XCTUnwrap(manifest["threads"] as? [[String: Any]])
    let shard = try XCTUnwrap(threads.first?["shard"] as? String)
    return storeURL.appendingPathComponent(shard)
  }

  func currentManifestObject(storeURL: URL) throws -> [String: Any] {
    let marker = try markerObject(storeURL: storeURL)
    let currentName = try XCTUnwrap(marker["currentManifest"] as? String)
    let manifestData = try Data(
      contentsOf: storeURL.appendingPathComponent("manifests/\(currentName)")
    )
    return try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
  }

  func ageFilesRecursively(in directory: URL, by interval: TimeInterval) throws {
    let date = Date().addingTimeInterval(-interval)
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    for case let url as URL in enumerator {
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
      }
    }
  }

  func fileCount(_ directory: URL) throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).count
  }
}

private struct LegacyTranscriptFixture: Encodable {
  let version: Int
  let threads: [OpenClawChatThread]
  let selectedThreadID: UUID?
  let settlementSettings: OpenClawThreadSettlementSettings
}
