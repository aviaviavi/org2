import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor AIChatDefaultDestinationRecorder {
  private var events: [String] = []

  func record(_ runtime: AIChatRuntime) {
    events.append(runtime.rawValue)
  }

  func snapshot() -> [String] {
    events
  }
}

final class AIChatSharedRoomDefaultDestinationTests: XCTestCase {
  @MainActor
  private func makeStore(
    recorder: AIChatDefaultDestinationRecorder
  ) throws -> (WorkspaceStore, () -> Void) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-room-default-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "AIChatSharedRoomDefault.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { _, _, _, _ in
        await recorder.record(.openClaw)
        return "OpenClaw answer"
      },
      codexSendHandlerForTesting: { _, _, _ in
        await recorder.record(.codex)
        return "Codex answer"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    return (store, {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suiteName)
    })
  }

  @MainActor
  func testPingingASecondAgentKeepsTheOriginalAgentAsTheDefault() async throws {
    let recorder = AIChatDefaultDestinationRecorder()
    let (store, cleanup) = try makeStore(recorder: recorder)
    defer { cleanup() }
    _ = store.createAIChatThread(runtime: .openClaw)
    await store.sendAIChatMessage(text: "Start with OpenClaw")
    await store.sendAIChatMessage(text: "@Codex take a look")
    let roomID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertTrue(store.selectedAIChatIsSharedRoom)
    XCTAssertEqual(
      store.selectedAIChatRoomDefaultDestinationID,
      AIChatDestinationConfiguration.openClawID
    )

    await store.sendAIChatMessage(text: "Thanks, carry on")

    var events = await recorder.snapshot()
    XCTAssertEqual(events, ["openClaw", "codex", "openClaw"])
    var room = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == roomID }))
    let followUp = try XCTUnwrap(room.messages.last(where: { $0.role == .user }))
    XCTAssertEqual(followUp.content, "Thanks, carry on")
    XCTAssertEqual(followUp.targetDestinationID, AIChatDestinationConfiguration.openClawID)
    XCTAssertEqual(room.roomDefaultDestination, AIChatDestinationConfiguration.openClawID)

    // Changing the default redirects later un-mentioned messages and persists.
    store.setSelectedAIChatRoomDefaultDestination(AIChatDestinationConfiguration.localCodexID)
    await store.sendAIChatMessage(text: "Codex, keep going")
    events = await recorder.snapshot()
    XCTAssertEqual(events.last, "codex")
    room = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == roomID }))
    let restored = try JSONDecoder().decode(AIChatThread.self, from: JSONEncoder().encode(room))
    XCTAssertEqual(restored.roomDefaultDestinationID, AIChatDestinationConfiguration.localCodexID)
    XCTAssertEqual(restored.roomDefaultDestination, AIChatDestinationConfiguration.localCodexID)

    // An explicit "no agent" choice posts context only.
    store.setSelectedAIChatRoomDefaultDestination(nil)
    XCTAssertNil(store.selectedAIChatRoomDefaultDestinationID)
    await store.sendAIChatMessage(text: "Just context")
    room = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == roomID }))
    XCTAssertEqual(room.messages.last?.audience, .thread)
    XCTAssertEqual(room.messages.last?.deliveryStatus, .sent)
    let finalEvents = await recorder.snapshot()
    XCTAssertEqual(finalEvents.count, events.count)
  }

  @MainActor
  func testBlankRoomAdoptsItsFirstAddressedAgentAsTheDefault() async throws {
    let recorder = AIChatDefaultDestinationRecorder()
    let (store, cleanup) = try makeStore(recorder: recorder)
    defer { cleanup() }
    store.createAIChatSharedRoom()
    XCTAssertNil(store.selectedAIChatRoomDefaultDestinationID)

    await store.sendAIChatMessage(text: "Context before anyone is asked")
    await store.sendAIChatMessage(text: "@codex first question")
    await store.sendAIChatMessage(text: "@openclaw a side question")
    await store.sendAIChatMessage(text: "back to the main thread")

    let events = await recorder.snapshot()
    XCTAssertEqual(events, ["codex", "openClaw", "codex"])
    XCTAssertEqual(
      store.selectedAIChatRoomDefaultDestinationID,
      AIChatDestinationConfiguration.localCodexID
    )
  }

  func testLegacyForkedRoomDefaultsToTheAgentItWasForkedFrom() throws {
    let json = #"""
    {
      "id":"00000000-0000-0000-0000-000000000003",
      "title":"Shared: Legacy",
      "createdAt":0,
      "updatedAt":0,
      "runtime":"codex",
      "destinationID":"remote-codex",
      "sessionKey":"legacy-room",
      "isSharedRoom":true,
      "roomDestinationIDs":["remote-codex","builtin.openclaw"],
      "messages":[
        {"id":"00000000-0000-0000-0000-000000000010","role":"user","content":"hi","createdAt":0},
        {"id":"00000000-0000-0000-0000-000000000011","role":"assistant","content":"hello","createdAt":0,
         "authorRuntime":"codex"}
      ]
    }
    """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let room = try decoder.decode(AIChatThread.self, from: Data(json.utf8))
    XCTAssertNil(room.roomDefaultDestinationID)
    XCTAssertEqual(room.roomDefaultDestination, "remote-codex")

    let single = AIChatThread(
      title: "Single",
      sessionKey: "single",
      roomDefaultDestinationID: "remote-codex"
    )
    XCTAssertNil(single.roomDefaultDestinationID)
    XCTAssertNil(single.roomDefaultDestination)
  }
}
