import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class OpenClawChatLayoutTests: XCTestCase {
  func testAssistantBubbleExpandsVerticallyForWrappedText() throws {
    let message = OpenClawChatMessage(
      role: .assistant,
      content: """
      The raw version already has the bones of a very good essay. I'd expand facts and examples before editing prose: Scarf's production history, the AI workflow loop, concrete migration outcomes, and a constructive "what Haskell could become" section.
      """
    )
    let view = ChatBubbleView(message: message, compact: true)
      .frame(width: 540, alignment: .leading)
    let hostingView = NSHostingView(rootView: view)

    hostingView.frame = NSRect(x: 0, y: 0, width: 540, height: 1)
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertGreaterThan(hostingView.fittingSize.height, 118)
  }

  func testMessageClipboardCopiesContentWithoutRoleChrome() {
    let message = OpenClawChatMessage(
      role: .assistant,
      content: "First paragraph.\n\nSecond paragraph."
    )
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("org2-chat-copy-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    OpenClawMessageClipboard.copy(message, to: pasteboard)

    XCTAssertEqual(pasteboard.string(forType: .string), "First paragraph.\n\nSecond paragraph.")
  }

  func testAttachmentOnlyMessageHasCopyableFallbackText() {
    let message = OpenClawChatMessage(
      role: .user,
      content: "",
      attachments: [
        OpenClawChatAttachment(
          fileName: "diagram.png",
          mimeType: "image/png",
          data: Data([0x01])
        )
      ]
    )

    XCTAssertEqual(OpenClawMessageClipboard.text(for: message), "[Attachment: diagram.png]")
  }

  func testOpenClawStatusCardOmitsEmptyLiveActivityPlaceholder() {
    let activeRun = OpenClawTypingIndicatorView(
      startedAt: Date(),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )
    let startingRun = OpenClawTypingIndicatorView(
      startedAt: Date(),
      connectionState: .connected,
      connectionDetail: nil,
      runID: nil,
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )

    XCTAssertNil(activeRun.progressSummary)
    XCTAssertEqual(startingRun.progressSummary, "Starting the run…")
  }

  func testOpenClawStatusCardStaysBoundedWithStructuredToolOutput() {
    let result = #"{"content":[{"text":"{\"results\":[{\"path\":\"memory/2026-04-01.md\",\"text\":\""#
      + String(repeating: "unformatted result ", count: 100)
      + #"\"}]}"}]}"#
    let view = OpenClawTypingIndicatorView(
      startedAt: Date(),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "Checking recent notes before answering.",
      activities: [
        OpenClawRunActivity(
          id: "tool-1",
          runID: "run-123",
          kind: .tool,
          title: "memory_search",
          detail: result,
          status: .succeeded
        )
      ],
      compact: false,
      onStop: {}
    )
    .frame(width: 540, alignment: .leading)
    let hostingView = NSHostingView(rootView: view)

    hostingView.frame = NSRect(x: 0, y: 0, width: 540, height: 1)
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertLessThanOrEqual(hostingView.fittingSize.width, 540)
    XCTAssertLessThan(hostingView.fittingSize.height, 260)
  }

  func testActivityFeedGroupsRepeatedShellEventsAndHidesRawCompletionMetadata() throws {
    let activities = (0..<10).map { index in
      OpenClawRunActivity(
        id: "tool-\(index)",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        detail: index == 0
          ? #"{"durationMs":963,"exitCode":5,"status":"failed"}"#
          : #"{"durationMs":121,"exitCode":0,"status":"completed"}"#,
        status: index == 0 ? .failed : .succeeded
      )
    }

    let item = try XCTUnwrap(OpenClawActivityFeed.items(from: activities).first)
    XCTAssertEqual(item.title, "10 shell commands")
    XCTAssertEqual(item.detail, "9 completed · 1 failed")
    XCTAssertEqual(item.status, .failed)
    XCTAssertFalse(item.detail?.contains("durationMs") == true)
  }

  func testActivityUpdateKeepsUsefulArgumentsWhenResultOnlyContainsMetadata() {
    let started = OpenClawRunActivity(
      id: "tool-1",
      runID: "run-1",
      kind: .tool,
      title: "bash",
      detail: #"{"cmd":"rg -n TODO notes"}"#,
      status: .running
    )
    let finished = OpenClawRunActivity(
      id: "tool-1",
      runID: "run-1",
      kind: .tool,
      title: "bash",
      detail: #"{"durationMs":42,"exitCode":0,"status":"completed"}"#,
      status: .succeeded
    )

    let merged = OpenClawActivityFeed.merging(started, with: finished)
    XCTAssertEqual(merged.detail, "rg -n TODO notes")
    XCTAssertEqual(merged.status, .succeeded)
  }

  func testActivityFeedHidesOversizedStructuredToolResults() throws {
    let payload = """
      {"content":[{"text":"\(String(repeating: "Fetched page content. ", count: 30))"}],"status":200,"contentType":"text/html"}
      """
    let activity = OpenClawRunActivity(
      id: "tool-1",
      runID: "run-1",
      kind: .tool,
      title: "web_fetch",
      detail: payload,
      status: .succeeded
    )

    let item = try XCTUnwrap(OpenClawActivityFeed.items(from: [activity]).first)
    XCTAssertEqual(item.title, "Web fetch")
    XCTAssertNil(item.detail)
  }

  func testActivityFeedNeverShowsSmallStructuredToolResultsAsRawJSON() throws {
    let activity = OpenClawRunActivity(
      id: "tool-1",
      runID: "run-1",
      kind: .tool,
      title: "memory_search",
      detail: #"{"content":[{"text":"{\"results\":[{\"path\":\"memory.org\"}]}"}]}"#,
      status: .succeeded
    )

    let item = try XCTUnwrap(OpenClawActivityFeed.items(from: [activity]).first)
    XCTAssertEqual(item.title, "Memory search")
    XCTAssertNil(item.detail)
  }

  func testActivityFeedFormatsSearchArgumentsForPeople() throws {
    let activity = OpenClawRunActivity(
      id: "tool-1",
      runID: "run-1",
      kind: .tool,
      title: "memory_search",
      detail: #"{"query":"monthly revenue"}"#,
      status: .running
    )

    let item = try XCTUnwrap(OpenClawActivityFeed.items(from: [activity]).first)
    XCTAssertEqual(item.detail, "Searching for \u{201c}monthly revenue\u{201d}")
  }

  func testProgressPresentationHidesStructuredReasoningAndBoundsProse() {
    XCTAssertNil(OpenClawProgressPresentation.reasoningText(from: #"{"results":[1,2,3]}"#))

    let prose = String(repeating: "Checking relevant context. ", count: 100)
    let presented = OpenClawProgressPresentation.reasoningText(from: prose)
    XCTAssertNotNil(presented)
    XCTAssertLessThanOrEqual(presented?.count ?? .max, 1_200)
  }

  func testAssistantResponseTraceRoundTripsWithTranscriptMessage() throws {
    let trace = OpenClawResponseTrace(
      reasoning: "Checking the relevant files.",
      activities: [
        OpenClawRunActivity(
          id: "tool-1",
          runID: "run-1",
          kind: .tool,
          title: "read_file",
          detail: "notes/plan.org2",
          status: .succeeded
        )
      ]
    )
    let message = OpenClawChatMessage(
      role: .assistant,
      content: "The plan is ready.",
      responseTrace: trace
    )

    let decoded = try JSONDecoder().decode(
      OpenClawChatMessage.self,
      from: JSONEncoder().encode(message)
    )
    XCTAssertEqual(decoded.responseTrace, trace)
  }
}
