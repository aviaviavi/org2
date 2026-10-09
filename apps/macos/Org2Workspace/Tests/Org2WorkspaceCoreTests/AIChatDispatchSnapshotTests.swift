import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Before each OpenCode, Claude Code, Pi, or OpenClaw turn, the app records the
/// corpus text so it can summarize the agent's edits afterwards. On a large
/// corpus that read took tens of seconds and held the turn at "Connecting".
/// Dispatch must not wait for it.
@MainActor
final class AIChatDispatchSnapshotTests: XCTestCase {
  private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      if isOpen { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
      isOpen = true
      waiters.forEach { $0.resume() }
      waiters = []
    }
  }

  func testTurnStartsWithoutWaitingForTheCorpusSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-dispatch-snapshot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("notes"),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try "* Existing\n".write(
      to: root.appendingPathComponent("notes/existing.org"),
      atomically: true,
      encoding: .utf8
    )
    let suiteName = "AIChatDispatchSnapshotTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let gate = Gate()
    let created = root.appendingPathComponent("notes/created.org")
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chats.json"),
      claudeSendHandlerForTesting: { _, _, _ in
        // The snapshot is still blocked here, so the turn started without it.
        // Write a file before the snapshot reaches it, then let it continue.
        try "* Created by the agent\n".write(to: created, atomically: true, encoding: .utf8)
        await gate.open()
        return ClaudeCodeTurnResult(
          sessionID: "claude-session",
          reply: "Created [[file:notes/created.org][the note]]."
        )
      },
      legacyDefaultsDomains: []
    )
    store.aiChatCorpusSnapshotGateForTesting = { await gate.wait() }
    store.setCorpusRoot(root)
    var claude = try XCTUnwrap(
      AIChatDestinationConfiguration.defaults.first(where: {
        $0.id == AIChatDestinationConfiguration.localClaudeID
      })
    )
    claude.isEnabled = true
    store.updateAIChatDestination(claude)
    let threadID = store.createAIChatThread(destinationID: AIChatDestinationConfiguration.localClaudeID)

    // The old code awaited the snapshot before dispatch; with the gate only
    // opened by the turn itself, that would never finish.
    let send = Task { await store.sendAIChatMessage(text: "Make a note") }
    let finished = await withTaskGroup(of: Bool.self) { group in
      group.addTask { await send.value; return true }
      group.addTask {
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    if !finished { await gate.open() }
    XCTAssertTrue(finished, "The turn must dispatch while the corpus snapshot is still pending")

    let thread = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID }))
    let reply = try XCTUnwrap(thread.messages.last(where: { $0.role == .assistant }))
    XCTAssertEqual(reply.content, "Created [[file:notes/created.org][the note]].")
    // The snapshot read the corpus after the agent created the note, but the
    // note did not exist before the turn, so it is still reported as created.
    let change = try XCTUnwrap(reply.changeSummary?.files.first(where: { $0.relativePath.hasSuffix("notes/created.org") }))
    XCTAssertEqual(change.status, .created)
    XCTAssertFalse(
      reply.changeSummary?.files.contains(where: { $0.relativePath.hasSuffix("notes/existing.org") }) ?? false,
      "Untouched files are not reported"
    )
  }
}
