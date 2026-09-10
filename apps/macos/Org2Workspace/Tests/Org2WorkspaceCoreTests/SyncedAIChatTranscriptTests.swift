import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor SyncedChatSendGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var opened = false
  private(set) var started = false

  func wait() async {
    started = true
    if opened { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    opened = true
    continuation?.resume()
    continuation = nil
  }
}

final class SyncedAIChatTranscriptTests: XCTestCase {
  @MainActor
  func testReadBadgesStayClearedAcrossRefreshAndRestartWithoutHidingNewReplies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let localURL = root.appendingPathComponent("local.json")
    let remoteURL = root.appendingPathComponent("remote.json")
    let otherURL = root.appendingPathComponent("other.json")
    let readAt = Date(timeIntervalSince1970: 1_000)
    let selected = OpenClawChatThread(title: "Selected", sessionKey: "selected")
    let unread = OpenClawChatThread(
      title: "Background", updatedAt: readAt, sessionKey: "background",
      messages: [OpenClawChatMessage(role: .assistant, content: "Already seen", createdAt: readAt)],
      unreadMessageCount: 1
    )
    let room = OpenClawChatThread(
      title: "Shared room", updatedAt: readAt, sessionKey: "room",
      messages: [OpenClawChatMessage(role: .assistant, content: "Room reply", createdAt: readAt)],
      unreadMessageCount: 1, isSharedRoom: true
    )
    let filler = (0..<20).map { OpenClawChatThread(title: "Other \($0)", sessionKey: "other-\($0)") }
    let settings = OpenClawThreadSettlementSettings()
    let snapshot = AIChatTranscriptSnapshot(
      threads: [selected] + filler + [unread, room], selectedThreadID: selected.id,
      settlementSettings: settings
    )
    try AIChatTranscriptStore.shared.flush(snapshot, legacyURL: localURL)
    try AIChatTranscriptStore.shared.flush(snapshot, legacyURL: otherURL)
    let suite = "synced-chat-read-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults,
      openClawTranscriptURL: localURL
    )
    await store.waitForAIChatTranscriptLoadForTesting()
    try await store.waitForAIChatTranscriptPersistenceForTesting()
    XCTAssertNotNil(store.openClawChatThreads.first { $0.id == unread.id }?.storedMessageCount)
    store.openClawTranscriptPersistenceDelayNanoseconds = 60_000_000_000
    // Defer writes without simulating a corrupt store: a recovery-blocked
    // transcript intentionally reloads instead of taking the normal sync path.
    defer { store.flushDeferredAIChatTranscriptPersistence() }
    let marker = AIChatTranscriptStore.storeDirectory(for: localURL).appendingPathComponent("migration-marker.json")
    let before = try Data(contentsOf: marker)
    for thread in [unread, room] {
      store.selectOpenClawChatThread(thread.id)
      await store.waitForAIChatThreadHydrationForTesting(thread.id)
    }
    store.selectOpenClawChatThread(selected.id)
    XCTAssertEqual(store.openClawUnreadMessageCount, 0)
    for _ in 0..<3 {
      let refreshed = await store.refreshSyncedAIChatTranscript()
      XCTAssertTrue(refreshed)
      XCTAssertEqual(store.openClawUnreadMessageCount, 0, "App activation must not restore dismissed badges")
      XCTAssertTrue(store.sidebarOpenClawChatThreadSummaries.allSatisfy { $0.unreadMessageCount == 0 })
    }
    XCTAssertEqual(try Data(contentsOf: marker), before, "Local read state must not rewrite synced history")

    let reopened = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults,
      openClawTranscriptURL: localURL
    )
    await reopened.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(reopened.openClawUnreadMessageCount, 0, "Read state must survive restarting OpenOrg")
    let otherCorpus = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults,
      openClawTranscriptURL: otherURL
    )
    await otherCorpus.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(otherCorpus.openClawUnreadMessageCount, 2, "Read state is scoped to its transcript")

    // A larger message count must remain unread even when timestamps are equal.
    let reply = OpenClawChatMessage(role: .assistant, content: "A genuinely new reply", createdAt: readAt)
    let newer = unread.replacingMessages(unread.messages + [reply])
    // Also preserve a later revision with the same message count.
    let newerRoom = room.replacingMessages([
      OpenClawChatMessage(role: .assistant, content: "A later room reply", createdAt: readAt.addingTimeInterval(1))
    ])
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [selected] + filler + [newer, newerRoom], selectedThreadID: selected.id,
      settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let refreshed = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(refreshed)
    XCTAssertEqual(store.openClawChatThreads.first { $0.id == unread.id }?.unreadMessageCount, 1)
    XCTAssertEqual(store.openClawChatThreads.first { $0.id == room.id }?.unreadMessageCount, 1)
    XCTAssertEqual(store.openClawUnreadMessageCount, 2)

    store.selectedSurface = .agenda
    let hiddenReply = selected.replacingMessages([
      OpenClawChatMessage(role: .assistant, content: "Unread while viewing the agenda")
    ]).replacingOpenClawChatMetadata(unreadMessageCount: 1)
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [hiddenReply] + filler + [newer, newerRoom], selectedThreadID: selected.id,
      settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let hiddenRefresh = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(hiddenRefresh)
    XCTAssertEqual(store.selectedOpenClawChatThreadID, selected.id)
    XCTAssertEqual(store.selectedOpenClawChatThread?.unreadMessageCount, 1,
                   "Refreshing a chat hidden behind another surface must not mark it read")
    store.makeSurfacePrimary(.openClaw)
    let visibleRefresh = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(visibleRefresh)
    XCTAssertEqual(store.selectedOpenClawChatThread?.unreadMessageCount, 0)
  }

  private func replicate(_ source: URL, to target: URL) throws {
    // flush waits for the commit, but obsolete manifests are collected afterward.
    // Copy the fixture only after that cleanup has finished.
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let fm = FileManager.default
    let sourceStore = AIChatTranscriptStore.storeDirectory(for: source)
    let targetStore = AIChatTranscriptStore.storeDirectory(for: target)
    if fm.fileExists(atPath: targetStore.path) { try fm.removeItem(at: targetStore) }
    try fm.copyItem(at: sourceStore, to: targetStore)
  }

  @MainActor
  func testSyncedThreadRefreshPreservesSelectionDraftAndDoesNotWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let localURL = root.appendingPathComponent("local.json")
    let remoteURL = root.appendingPathComponent("remote.json")
    let original = OpenClawChatThread(title: "Local", sessionKey: "agent:main:local", messages: [])
    let incoming = OpenClawChatThread(title: "Phone via server", sessionKey: "agent:main:server", messages: [
      OpenClawChatMessage(role: .user, content: "From my phone"),
      OpenClawChatMessage(role: .assistant, content: "From the server")
    ])
    let settings = OpenClawThreadSettlementSettings()
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original], selectedThreadID: original.id, settlementSettings: settings
    ), legacyURL: localURL)
    let suite = "synced-chat-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults, openClawTranscriptURL: localURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.publishOpenClawComposerDraft("Keep my unfinished message")
    try await store.waitForAIChatTranscriptPersistenceForTesting()
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, incoming], selectedThreadID: incoming.id, settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let marker = AIChatTranscriptStore.storeDirectory(for: localURL).appendingPathComponent("migration-marker.json")
    let before = try Data(contentsOf: marker)
    XCTAssertFalse(store.hasUnpersistedAIChatTranscriptMutationForTesting)
    let refreshed = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(refreshed)
    XCTAssertEqual(Set(store.openClawChatThreads.map(\.id)), [original.id, incoming.id])
    XCTAssertEqual(store.selectedOpenClawChatThreadID, original.id)
    XCTAssertEqual(store.openClawDraft, "Keep my unfinished message")
    store.selectOpenClawChatThread(incoming.id)
    await store.waitForAIChatThreadHydrationForTesting(incoming.id)
    XCTAssertEqual(store.openClawMessages.map(\.content), ["From my phone", "From the server"])
    XCTAssertEqual(try Data(contentsOf: marker), before, "Viewing a synced conversation must not create a commit")

    let pendingMessage = OpenClawChatMessage(role: .user, content: "Still working", deliveryStatus: .sending)
    let working = OpenClawChatThread(
      id: incoming.id, title: incoming.title, sessionKey: incoming.sessionKey,
      messages: [pendingMessage], pendingTurn: OpenClawPendingTurn(
        userMessageID: pendingMessage.id, runID: "remote-run", agentID: "main", gatewayMessage: "Still working"
      )
    )
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, working], selectedThreadID: incoming.id, settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let importedPending = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(importedPending)
    XCTAssertNotNil(store.openClawChatThreads.first { $0.id == incoming.id }?.pendingTurn)
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, incoming], selectedThreadID: incoming.id, settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let importedCompletion = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(importedCompletion, "A remote pending turn must not prevent refreshing its completion")
    XCTAssertNil(store.openClawChatThreads.first { $0.id == incoming.id }?.pendingTurn)
    XCTAssertEqual(store.openClawMessages.map(\.content), ["From my phone", "From the server"])
  }

  @MainActor
  func testSyncedThreadsArriveDuringLocalTurnAndPendingMetadataSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let localURL = root.appendingPathComponent("local.json")
    let remoteURL = root.appendingPathComponent("remote.json")
    let active = OpenClawChatThread(title: "Working locally", runtime: .codex, sessionKey: "local", messages: [])
    let idle = OpenClawChatThread(title: "Existing phone chat", sessionKey: "idle", messages: [])
    let renamed = OpenClawChatThread(title: "Rename me", sessionKey: "renamed", messages: [])
    let incoming = OpenClawChatThread(title: "New phone chat", sessionKey: "phone", messages: [
      OpenClawChatMessage(role: .assistant, content: "A new conversation from the server")
    ])
    let settings = OpenClawThreadSettlementSettings()
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [active, idle, renamed], selectedThreadID: active.id, settlementSettings: settings
    ), legacyURL: localURL)
    let suite = "synced-active-chat-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = SyncedChatSendGate()
    let store = WorkspaceStore(
      defaults: defaults, openClawTranscriptURL: localURL,
      codexSendHandlerForTesting: { _, _, _ in
        await gate.wait()
        return "Local answer after syncing"
      }, legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    let send = Task { @MainActor in await store.sendOpenClawMessage(text: "Keep working") }
    defer { Task { await gate.open() } }
    for _ in 0..<200 {
      if await gate.started { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let started = await gate.started
    XCTAssertTrue(started)
    XCTAssertTrue(store.isAIChatThreadRunning(active.id))
    try await store.waitForAIChatTranscriptPersistenceForTesting()
    let working = try XCTUnwrap(store.openClawChatThreads.first { $0.id == active.id })
    let revision = store.aiChatThreadMessageMutationVersionForTesting(active.id)
    store.publishOpenClawComposerDraft("Keep this draft while the agent works")
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [active, idle.replacingMessages([
        OpenClawChatMessage(role: .assistant, content: "A remote reply in an existing chat")
      ]), renamed, incoming], selectedThreadID: incoming.id, settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let marker = AIChatTranscriptStore.storeDirectory(for: localURL).appendingPathComponent("migration-marker.json")
    let before = try Data(contentsOf: marker)
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(true, legacyURL: localURL)
    defer { AIChatTranscriptStore.shared.setWritesSuspendedForTesting(false, legacyURL: localURL) }
    store.renameOpenClawChatThread(renamed.id, title: "My unsaved local title")
    XCTAssertTrue(store.hasUnpersistedAIChatTranscriptMutationForTesting)
    let refreshed = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(refreshed, "A running local turn and queued save must not hide unrelated synced chats")
    XCTAssertEqual(Set(store.openClawChatThreads.map(\.id)), [active.id, idle.id, renamed.id, incoming.id])
    XCTAssertEqual(store.openClawChatThreads.first { $0.id == active.id }, working)
    XCTAssertEqual(store.aiChatThreadMessageMutationVersionForTesting(active.id), revision)
    XCTAssertTrue(store.isAIChatThreadRunning(active.id))
    XCTAssertEqual(store.openClawChatThreads.first { $0.id == renamed.id }?.title, "My unsaved local title")
    XCTAssertEqual(store.openClawChatThreads.first { $0.id == idle.id }?.messages.last?.content, "A remote reply in an existing chat")
    XCTAssertEqual(store.selectedOpenClawChatThreadID, active.id)
    XCTAssertEqual(store.openClawDraft, "Keep this draft while the agent works")
    XCTAssertEqual(try Data(contentsOf: marker), before)
    // Repeated refreshes must keep the dirty metadata protected as well.
    let refreshedAgain = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(refreshedAgain)
    XCTAssertEqual(store.openClawChatThreads.first { $0.id == renamed.id }?.title, "My unsaved local title")
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(false, legacyURL: localURL)
    await gate.open()
    await send.value
    XCTAssertFalse(store.isAIChatThreadRunning(active.id))
    XCTAssertEqual(store.openClawMessages.last?.content, "Local answer after syncing")
    store.flushDeferredAIChatTranscriptPersistence()
    try await store.waitForAIChatTranscriptPersistenceForTesting()
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let saved = try XCTUnwrap(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: localURL))
    XCTAssertEqual(Set(saved.snapshot.threads.map(\.id)), [active.id, idle.id, renamed.id, incoming.id])
  }

  func testStaleSnapshotPreservesUnseenThreadsButHonorsKnownDeletion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("chat.json")
    let original = OpenClawChatThread(title: "Known", sessionKey: "known", messages: [])
    let incoming = OpenClawChatThread(title: "Unseen", sessionKey: "unseen", messages: [OpenClawChatMessage(role: .assistant, content: "Preserve me")])
    let settings = OpenClawThreadSettlementSettings()
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, incoming], selectedThreadID: original.id, settlementSettings: settings
    ), legacyURL: url)
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [], selectedThreadID: nil, settlementSettings: settings, knownThreadIDs: [original.id]
    ), legacyURL: url)
    let actual = try XCTUnwrap(AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: url, preferPersisted: true))
    XCTAssertEqual(actual.snapshot.threads.map(\.id), [incoming.id])
    XCTAssertEqual(actual.snapshot.threads.first?.messages.first?.content, "Preserve me")
  }

  func testDeliveryUpdatesNeverMoveActivityTimeBackward() {
    let before = Date(timeIntervalSinceReferenceDate: 1_000)
    let message = OpenClawChatMessage(role: .user, content: "Earlier message", createdAt: before.addingTimeInterval(-10))
    let thread = OpenClawChatThread(title: "Conversation", updatedAt: before, sessionKey: "agent:main:test", messages: [message])
    let changed = WorkspaceStore.updatedOpenClawChatThread(
      thread, messages: [message.replacingDeliveryStatus(.interrupted, sendFailure: "Stopped")],
      newAssistantMessageCount: 0, isThreadOpen: true, pendingTurnUpdate: .replace(nil)
    )
    XCTAssertEqual(changed.updatedAt, before)
    let later = OpenClawChatMessage(role: .assistant, content: "New reply", createdAt: before.addingTimeInterval(10))
    let replied = WorkspaceStore.updatedOpenClawChatThread(
      changed, messages: [message, later], newAssistantMessageCount: 1,
      isThreadOpen: true, pendingTurnUpdate: .preserve
    )
    XCTAssertEqual(replied.updatedAt, later.createdAt)
  }

  func testTranscriptEventsAreRecognizedWithoutRefreshingCanonicalDocuments() {
    let root = URL(fileURLWithPath: "/tmp/corpus")
    let classified = WorkspaceStore.classifyCorpusFileEvents([
      "/tmp/corpus/.org2/openclaw-chat.store/migration-marker.json",
      "/tmp/corpus/.org2/openclaw-chat.store/threads/new.json"
    ], corpusRoot: root)
    XCTAssertTrue(classified.hasAIChatTranscriptChanges)
    XCTAssertTrue(classified.contentPaths.isEmpty)
  }
}
