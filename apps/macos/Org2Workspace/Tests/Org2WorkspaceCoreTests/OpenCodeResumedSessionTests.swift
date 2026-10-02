import XCTest
@testable import Org2WorkspaceCore

final class OpenCodeResumedSessionTests: XCTestCase {
  private let destination = "opencode-press"

  private func reply(_ text: String) -> AIChatMessage {
    AIChatMessage(role: .assistant, content: text, authorRuntime: .openCode, authorDestinationID: destination)
  }

  func testResumedSessionReceivesOnlyMessagesItHasNotSeen() throws {
    let current = AIChatMessage(role: .user, content: "Next step?")
    let report = AIChatMessage(role: .assistant, content: "swift build finished: 0 errors", authorLabel: "openorg-bg")
    let messages = [
      AIChatMessage(role: .user, content: "Build it"),
      reply("Started the build in the background."),
      AIChatMessage(role: .user, content: "Thanks"),
      report,
      current,
    ]
    let updates = try XCTUnwrap(WorkspaceStore.openCodeResumedSessionUpdates(
      in: messages, destinationID: destination, excludingMessageID: current.id
    ))
    XCTAssertEqual(updates.map(\.id), [report.id])

    let turn = WorkspaceStore.openCodeTurnMessage("Next step?", prefixing: updates)
    XCTAssertTrue(turn.hasPrefix("Thread updates since your last reply in this session (oldest to newest):\n<message role=\"assistant\">\n[Authored by another participant: openorg-bg]\nswift build finished: 0 errors\n</message>"), turn)
    XCTAssertTrue(turn.hasSuffix("\n\nNext step?"))
    XCTAssertEqual(WorkspaceStore.openCodeTurnMessage("Next step?", prefixing: []), "Next step?")
  }

  func testUncertainSessionHistoryKeepsTheFullTranscriptExcerpt() {
    let current = AIChatMessage(role: .user, content: "Continue")
    // No earlier OpenCode reply: the session may predate this thread's history.
    XCTAssertNil(WorkspaceStore.openCodeResumedSessionUpdates(
      in: [AIChatMessage(role: .user, content: "Hi"), current],
      destinationID: destination, excludingMessageID: current.id
    ))
    // A failed turn after the last reply may not have reached the session.
    XCTAssertNil(WorkspaceStore.openCodeResumedSessionUpdates(
      in: [
        reply("Done"),
        AIChatMessage(role: .user, content: "Again"),
        AIChatMessage(role: .system, content: "OpenCode could not respond", authorRuntime: .openCode, authorDestinationID: destination),
        current,
      ],
      destinationID: destination, excludingMessageID: current.id
    ))
    // Another agent answered prompts this session never received.
    XCTAssertNil(WorkspaceStore.openCodeResumedSessionUpdates(
      in: [
        reply("Done"),
        AIChatMessage(role: .user, content: "What does Codex think?"),
        AIChatMessage(role: .assistant, content: "Codex view", authorRuntime: .codex, authorDestinationID: "codex"),
        current,
      ],
      destinationID: destination, excludingMessageID: current.id
    ))
  }
}
