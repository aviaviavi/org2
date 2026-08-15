import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor AIChatSharedRoomRecorder {
  private var events: [String] = []
  private var prompts: [String: String] = [:]

  func record(runtime: AIChatRuntime, messages: [OpenClawChatMessage]) {
    events.append(runtime.rawValue)
    prompts[runtime.rawValue] = messages.last(where: { $0.role == .user })?.content
  }

  func snapshot() -> (events: [String], prompts: [String: String]) {
    (events, prompts)
  }
}

final class AIChatSharedRoomTests: XCTestCase {
  @MainActor
  func testAskAllUsesOneVisibleQuestionAndTwoAttributedReplies() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-shared-room-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AIChatSharedRoomRecorder()
    let suiteName = "AIChatSharedRoom.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      openClawSendHandler: { messages, _, _, _ in
        await recorder.record(runtime: .openClaw, messages: messages)
        return "OpenClaw answer"
      },
      codexSendHandlerForTesting: { messages, _, _ in
        await recorder.record(runtime: .codex, messages: messages)
        return "Codex answer"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatSharedRoom()

    XCTAssertTrue(store.selectedAIChatIsSharedRoom)
    XCTAssertEqual(store.selectedAIChatAudience, .thread)

    await store.sendOpenClawMessage(text: "@all What do both of you think?")

    let thread = try XCTUnwrap(store.selectedOpenClawChatThread)
    let visibleMessages = thread.messages.filter { !$0.isRoomDispatchCopy }
    XCTAssertEqual(visibleMessages.map(\.content), [
      "@codex @openclaw What do both of you think?",
      "Codex answer",
      "OpenClaw answer"
    ])
    XCTAssertEqual(visibleMessages[0].audience, .everyone)
    XCTAssertEqual(visibleMessages[1].authorRuntime, .codex)
    XCTAssertEqual(visibleMessages[2].authorRuntime, .openClaw)
    XCTAssertEqual(thread.messageCount, 3)
    XCTAssertEqual(thread.messages.filter(\.isRoomDispatchCopy).map(\.targetRuntime), [.openClaw])
    XCTAssertNotNil(visibleMessages[0].roomRoundID)
    XCTAssertEqual(Set(thread.messages.compactMap(\.roomRoundID)).count, 1)

    let recorded = await recorder.snapshot()
    XCTAssertEqual(recorded.events, [AIChatRuntime.codex.rawValue, AIChatRuntime.openClaw.rawValue])
    XCTAssertTrue(recorded.prompts[AIChatRuntime.codex.rawValue]?.contains("Avi → Codex + OpenClaw") == true)
    XCTAssertTrue(recorded.prompts[AIChatRuntime.openClaw.rawValue]?.contains("Codex:\nCodex answer") == true)
  }

  func testSharedRoomMetadataRoundTripsAndLegacyThreadsStaySingleRuntime() throws {
    let room = OpenClawChatThread(
      title: "Room",
      runtime: .openClaw,
      sessionKey: "room-session",
      isSharedRoom: true,
      roomAudience: .codex,
      roomModels: AIChatRoomModelSelection(
        codex: "gpt-5.6-sol",
        openClaw: "openai/gpt-5.6"
      )
    )
    let restored = try JSONDecoder().decode(
      OpenClawChatThread.self,
      from: JSONEncoder().encode(room)
    )
    XCTAssertTrue(restored.isSharedRoom)
    XCTAssertEqual(restored.roomAudience, .codex)
    XCTAssertEqual(restored.model(for: .codex), "gpt-5.6-sol")
    XCTAssertEqual(restored.model(for: .openClaw), "openai/gpt-5.6")
    XCTAssertFalse(restored.canChangeAIRuntime)

    let legacyJSON = #"""
    {
      "id":"00000000-0000-0000-0000-000000000001",
      "title":"Legacy",
      "createdAt":0,
      "updatedAt":0,
      "runtime":"codex",
      "sessionKey":"legacy",
      "messages":[]
    }
    """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let legacy = try decoder.decode(OpenClawChatThread.self, from: Data(legacyJSON.utf8))
    XCTAssertFalse(legacy.isSharedRoom)
    XCTAssertEqual(legacy.roomAudience, .codex)
    XCTAssertTrue(legacy.canChangeAIRuntime)
  }

  @MainActor
  func testExplicitForkCopiesHistoryWithoutReusingRuntimeIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-thread-fork-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatSharedRoom.Fork.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      openClawSendHandler: { _, _, _, _ in "Original reply" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let sourceID = store.createOpenClawChatThread(runtime: .openClaw)
    await store.sendOpenClawMessage(text: "Original question")
    let source = try XCTUnwrap(store.openClawChatThreads.first(where: { $0.id == sourceID }))

    let forkID = try XCTUnwrap(store.forkAIChatThread(sourceID))
    let fork = try XCTUnwrap(store.openClawChatThreads.first(where: { $0.id == forkID }))

    XCTAssertNotEqual(fork.id, source.id)
    XCTAssertNotEqual(fork.sessionKey, source.sessionKey)
    XCTAssertNil(fork.runtimeThreadID)
    XCTAssertEqual(fork.messages.map(\.content), source.messages.map(\.content))
    XCTAssertEqual(fork.messages.map(\.deliveryStatus), [.sent, .sent])
    XCTAssertFalse(fork.isSettled)
    XCTAssertFalse(fork.isPinned)
    XCTAssertEqual(store.selectedOpenClawChatThreadID, forkID)
  }

  @MainActor
  func testMentioningAnotherHarnessForksSingleAgentThreadIntoSharedRoom() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mention-fork-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AIChatSharedRoomRecorder()
    let suiteName = "AIChatSharedRoom.MentionFork.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      openClawSendHandler: { messages, _, _, _ in
        await recorder.record(runtime: .openClaw, messages: messages)
        return "OpenClaw answer"
      },
      codexSendHandlerForTesting: { messages, _, _ in
        await recorder.record(runtime: .codex, messages: messages)
        return "Codex joined"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let sourceID = store.createOpenClawChatThread(runtime: .openClaw)
    await store.sendOpenClawMessage(text: "Start with OpenClaw")

    await store.sendOpenClawMessage(text: "@Codex review this conversation")

    let destinationID = try XCTUnwrap(store.selectedOpenClawChatThreadID)
    XCTAssertNotEqual(destinationID, sourceID)
    let source = try XCTUnwrap(store.openClawChatThreads.first(where: { $0.id == sourceID }))
    let destination = try XCTUnwrap(store.openClawChatThreads.first(where: { $0.id == destinationID }))
    XCTAssertFalse(source.isSharedRoom)
    XCTAssertEqual(source.messages.map(\.content), ["Start with OpenClaw", "OpenClaw answer"])
    XCTAssertTrue(destination.isSharedRoom)
    XCTAssertEqual(destination.messages.filter { !$0.isRoomDispatchCopy }.map(\.content), [
      "Start with OpenClaw",
      "OpenClaw answer",
      "@codex review this conversation",
      "Codex joined"
    ])
    XCTAssertEqual(destination.messages.last?.authorRuntime, .codex)
    XCTAssertEqual(destination.messages.dropLast().last?.audience, .codex)

    let recorded = await recorder.snapshot()
    XCTAssertEqual(recorded.events, [AIChatRuntime.openClaw.rawValue, AIChatRuntime.codex.rawValue])
  }

  @MainActor
  func testSharedRoomStoresAnIndependentModelForEachHarness() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-shared-models-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatSharedRoom.Models.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatSharedRoom()

    store.setSelectedAIChatRoomModel("gpt-5.6-sol", for: .codex)
    store.setSelectedAIChatRoomModel("openai/gpt-5.6", for: .openClaw)

    let thread = try XCTUnwrap(store.selectedOpenClawChatThread)
    XCTAssertEqual(thread.model(for: .codex), "gpt-5.6-sol")
    XCTAssertEqual(thread.model(for: .openClaw), "openai/gpt-5.6")
    XCTAssertEqual(store.selectedAIChatRoomModelLabel(for: .codex), "gpt-5.6-sol")
    XCTAssertEqual(store.selectedAIChatRoomModelLabel(for: .openClaw), "gpt-5.6")
  }

  @MainActor
  func testOneHarnessFailureDoesNotPreventTheOtherHarnessFromReplying() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-shared-room-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AIChatSharedRoomRecorder()
    let suiteName = "AIChatSharedRoom.Failure.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      openClawSendHandler: { messages, _, _, _ in
        await recorder.record(runtime: .openClaw, messages: messages)
        return "OpenClaw recovered the room"
      },
      codexSendHandlerForTesting: { _, _, _ in
        throw CodexAppServerError.invalidResponse("Codex test outage")
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatSharedRoom()

    await store.sendOpenClawMessage(text: "@all Keep going if one of you is unavailable")

    let thread = try XCTUnwrap(store.selectedOpenClawChatThread)
    let visibleMessages = thread.messages.filter { !$0.isRoomDispatchCopy }
    XCTAssertEqual(visibleMessages.map(\.role), [.user, .system, .assistant])
    XCTAssertTrue(visibleMessages[1].content.contains("Codex could not respond"))
    XCTAssertEqual(visibleMessages[2].content, "OpenClaw recovered the room")
    XCTAssertEqual(visibleMessages[2].authorRuntime, .openClaw)
    XCTAssertFalse(store.isSendingOpenClawMessage)

    let recorded = await recorder.snapshot()
    XCTAssertEqual(recorded.events, [AIChatRuntime.openClaw.rawValue])
  }

  func testSharedRoomPromptDoesNotConfuseTheOtherHarnessWithItself() {
    let userID = UUID()
    let messages = [
      OpenClawChatMessage(
        id: userID,
        role: .user,
        content: "Review this plan",
        audience: .everyone,
        targetRuntime: .openClaw
      ),
      OpenClawChatMessage(
        role: .assistant,
        content: "I would simplify it.",
        authorRuntime: .codex
      )
    ]
    let transformed = WorkspaceStore.sharedRoomRequestMessages(
      messages,
      target: .openClaw,
      through: userID
    )
    let prompt = transformed[0].content
    XCTAssertTrue(prompt.contains("You are OpenClaw"))
    XCTAssertTrue(prompt.contains("Do not impersonate the other harness"))
    XCTAssertFalse(prompt.contains("I would simplify it."))
  }

  func testRoomRoutingRequiresExplicitMentionsAndExpandsAll() {
    XCTAssertEqual(AIChatRoomRouting("Context for later").audience, .thread)
    XCTAssertEqual(
      AIChatRoomRouting("Context for later").summary,
      "Posts to thread · no agents invoked"
    )
    XCTAssertEqual(AIChatRoomRouting("@Codex review this").audience, .codex)
    XCTAssertEqual(AIChatRoomRouting("ask @openclaw next").audience, .openClaw)

    let all = AIChatRoomRouting("@all compare approaches")
    XCTAssertEqual(all.audience, .everyone)
    XCTAssertEqual(all.normalizedText, "@Codex @OpenClaw compare approaches")
    XCTAssertEqual(all.summary, "Invokes Codex + OpenClaw")

    let legacyBoth = AIChatRoomRouting("@both compare approaches")
    XCTAssertEqual(legacyBoth.audience, .everyone)
    XCTAssertEqual(legacyBoth.normalizedText, "@Codex @OpenClaw compare approaches")

    XCTAssertEqual(AIChatRoomRouting("mail me@example.com").audience, .thread)
  }

  @MainActor
  func testContextOnlyPostDoesNotInvokeEitherHarness() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-shared-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AIChatSharedRoomRecorder()
    let suiteName = "AIChatSharedRoom.Context.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      openClawSendHandler: { messages, _, _, _ in
        await recorder.record(runtime: .openClaw, messages: messages)
        return "unexpected"
      },
      codexSendHandlerForTesting: { messages, _, _ in
        await recorder.record(runtime: .codex, messages: messages)
        return "unexpected"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatSharedRoom()

    await store.sendOpenClawMessage(text: "This is context for the next round")

    let thread = try XCTUnwrap(store.selectedOpenClawChatThread)
    XCTAssertEqual(thread.messages.count, 1)
    XCTAssertEqual(thread.messages[0].audience, .thread)
    XCTAssertEqual(thread.messages[0].deliveryStatus, .sent)
    XCTAssertNil(thread.messages[0].roomRoundID)
    XCTAssertFalse(store.isSendingOpenClawMessage)
    let recorded = await recorder.snapshot()
    XCTAssertTrue(recorded.events.isEmpty)
  }

  func testMentionCompletionExpandsAllAndFiltersActiveToken() {
    XCTAssertEqual(AIChatMentionSuggestion.suggestions(for: "@").map(\.id), [
      "codex", "openclaw", "all"
    ])
    XCTAssertEqual(AIChatMentionSuggestion.suggestions(for: "Please ask @o").map(\.id), [
      "openclaw"
    ])
    let all = AIChatMentionSuggestion.all.first(where: { $0.id == "all" })
    XCTAssertEqual(all?.completingMention(in: "Please ask @a"), "Please ask @codex @openclaw ")
  }

  @MainActor
  func testTwoCodexDestinationsRemainIndependentInOneRoom() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-two-codex-destinations-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatSharedRoom.TwoCodex.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      openClawSendHandler: { _, _, _, _ in "Unexpected OpenClaw response" },
      codexSendHandlerForTesting: { messages, _, _ in
        let destinationID = messages.last(where: { $0.role == .user })?.targetDestinationID
        return destinationID == AIChatDestinationConfiguration.localCodexID
          ? "Local answer"
          : "Remote answer"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let remoteID = store.addAIChatDestination()
    var remote = try XCTUnwrap(store.aiChatDestination(id: remoteID))
    remote.name = "Codex Remote"
    remote.mention = "codex-remote"
    remote.endpoint = "wss://codex.example.test/ws"
    store.updateAIChatDestination(remote)
    store.createAIChatSharedRoom()

    await store.sendOpenClawMessage(text: "@codex @codex-remote Compare these changes")

    let thread = try XCTUnwrap(store.selectedOpenClawChatThread)
    let visible = thread.messages.filter { !$0.isRoomDispatchCopy }
    XCTAssertEqual(visible.map(\.content), [
      "@codex @codex-remote Compare these changes",
      "Local answer",
      "Remote answer"
    ])
    XCTAssertEqual(visible.compactMap(\.authorDestinationID), [
      AIChatDestinationConfiguration.localCodexID,
      remoteID
    ])
    guard case .round(let round) = try XCTUnwrap(
      AIChatRoomTranscriptPresentation.items(messages: thread.messages, isSharedRoom: true).first
    ) else {
      return XCTFail("Expected a destination round")
    }
    XCTAssertEqual(round.expectedDestinationIDs, [
      AIChatDestinationConfiguration.localCodexID,
      remoteID
    ])
    XCTAssertEqual(round.response(forDestinationID: remoteID)?.content, "Remote answer")
  }

  func testDestinationRoutingSupportsCustomMentionsAndScopedAll() {
    let remote = AIChatDestinationConfiguration(
      id: "remote",
      name: "Codex Remote",
      mention: "codex-remote",
      adapter: .codexRemote,
      endpoint: "wss://codex.example.test/ws"
    )
    let destinations = AIChatDestinationConfiguration.defaults + [remote]
    let direct = AIChatDestinationRouting(
      "Ask @codex-remote to check",
      destinations: destinations
    )
    XCTAssertEqual(direct.destinationIDs, ["remote"])
    XCTAssertEqual(direct.summary, "Invokes Codex Remote")

    let scopedAll = AIChatDestinationRouting(
      "@all compare",
      destinations: destinations,
      allDestinationIDs: [AIChatDestinationConfiguration.localCodexID, "remote"]
    )
    XCTAssertEqual(scopedAll.destinationIDs, [
      AIChatDestinationConfiguration.localCodexID,
      "remote"
    ])
    XCTAssertEqual(scopedAll.normalizedText, "@codex @codex-remote compare")
  }

  func testTranscriptGroupsEachHarnessIntoOneRound() {
    let roundID = UUID()
    let trigger = OpenClawChatMessage(
      id: roundID,
      role: .user,
      content: "@Codex @OpenClaw compare",
      deliveryStatus: .sent,
      audience: .everyone,
      targetRuntime: .codex,
      roomRoundID: roundID
    )
    let hiddenDispatch = OpenClawChatMessage(
      role: .user,
      content: trigger.content,
      deliveryStatus: .sending,
      audience: .everyone,
      targetRuntime: .openClaw,
      isRoomDispatchCopy: true,
      roomRoundID: roundID
    )
    let codexReply = OpenClawChatMessage(
      role: .assistant,
      content: "Codex view",
      authorRuntime: .codex,
      roomRoundID: roundID
    )
    let context = OpenClawChatMessage(role: .user, content: "More context", audience: .thread)
    let items = AIChatRoomTranscriptPresentation.items(
      messages: [trigger, codexReply, hiddenDispatch, context],
      isSharedRoom: true
    )

    XCTAssertEqual(items.count, 2)
    guard case .round(let round) = items[0] else {
      return XCTFail("Expected an agent round")
    }
    XCTAssertEqual(round.expectedRuntimes, [.codex, .openClaw])
    XCTAssertEqual(round.response(for: .codex)?.content, "Codex view")
    XCTAssertNil(round.response(for: .openClaw))
    XCTAssertEqual(round.completedCount, 1)
    XCTAssertFalse(round.isComplete)
    guard case .message(let contextMessage) = items[1] else {
      return XCTFail("Expected the context-only post to remain standalone")
    }
    XCTAssertEqual(contextMessage.id, context.id)
  }
}
