import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class OpenClawChatLayoutTests: XCTestCase {
  func testChatThreadSwitchDoesNotRequestAnimatedScrolling() {
    let previous = OpenClawChatScrollUpdate(
      threadID: UUID(),
      messageCount: 3,
      isSending: false
    )
    let next = OpenClawChatScrollUpdate(
      threadID: UUID(),
      messageCount: 12,
      isSending: true
    )

    XCTAssertNil(next.animatedTarget(after: previous))
  }

  func testChatActivityWithinAThreadStillRequestsAnimatedScrolling() {
    let threadID = UUID()
    let idle = OpenClawChatScrollUpdate(
      threadID: threadID,
      messageCount: 3,
      isSending: false
    )
    let appended = OpenClawChatScrollUpdate(
      threadID: threadID,
      messageCount: 4,
      isSending: false
    )
    let sending = OpenClawChatScrollUpdate(
      threadID: threadID,
      messageCount: 4,
      isSending: true
    )

    XCTAssertEqual(appended.animatedTarget(after: idle), .latestMessage)
    XCTAssertEqual(sending.animatedTarget(after: appended), .typingIndicator)
  }

  func testChatScrollRestorationDefaultsUnsavedThreadsToMostRecentMessage() {
    let threadID = UUID()
    let unsaved = OpenClawChatScrollRestoration(
      threadID: threadID,
      selectionGeneration: 1,
      savedPosition: nil
    )
    let saved = OpenClawChatScrollRestoration(
      threadID: threadID,
      selectionGeneration: 1,
      savedPosition: 0.42
    )

    XCTAssertEqual(unsaved.position, 1)
    XCTAssertEqual(saved.position, 0.42, accuracy: 0.001)
  }

  func testChatScrollRestorationRestartsWhenThreadOrSelectionChanges() {
    let firstThreadID = UUID()
    let secondThreadID = UUID()
    let initial = OpenClawChatScrollRestoration(
      threadID: firstThreadID,
      selectionGeneration: 1,
      savedPosition: nil
    )
    let sameSelection = OpenClawChatScrollRestoration(
      threadID: firstThreadID,
      selectionGeneration: 1,
      savedPosition: 0.42
    )
    let reselectedThread = OpenClawChatScrollRestoration(
      threadID: firstThreadID,
      selectionGeneration: 2,
      savedPosition: nil
    )
    let nextThread = OpenClawChatScrollRestoration(
      threadID: secondThreadID,
      selectionGeneration: 3,
      savedPosition: nil
    )

    XCTAssertFalse(sameSelection.requiresNewRestoration(after: initial))
    XCTAssertTrue(reselectedThread.requiresNewRestoration(after: initial))
    XCTAssertTrue(nextThread.requiresNewRestoration(after: initial))
  }

  func testJumpToBottomAppearsOnlyAboveLatestContent() {
    XCTAssertFalse(OpenClawChatScrollVisibility(position: 0.4, hasContent: false).showsJumpToBottom)
    XCTAssertTrue(OpenClawChatScrollVisibility(position: 0.4, hasContent: true).showsJumpToBottom)
    XCTAssertFalse(OpenClawChatScrollVisibility(position: 0.99, hasContent: true).showsJumpToBottom)
    XCTAssertFalse(OpenClawChatScrollVisibility(position: 1, hasContent: true).showsJumpToBottom)
  }

  func testScrollPositionOnlyUpdatesPresentationAcrossNearBottomBoundary() {
    let aboveLatest = OpenClawChatScrollVisibility(position: 0.4, hasContent: true)
    let stillAboveLatest = OpenClawChatScrollVisibility(position: 0.8, hasContent: true)
    let nearLatest = OpenClawChatScrollVisibility(position: 0.99, hasContent: true)

    XCTAssertNil(aboveLatest.updatedNearBottomState(after: false))
    XCTAssertNil(stillAboveLatest.updatedNearBottomState(after: false))
    XCTAssertEqual(nearLatest.updatedNearBottomState(after: false), true)
    XCTAssertNil(nearLatest.updatedNearBottomState(after: true))
  }

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

  func testChatBubblesKeepPartialTextSelectionEnabled() {
    XCTAssertTrue(ChatBubbleView.managesMessageTextSelection)
  }

  func testLongTranscriptLayoutRemainsResponsiveWithPerMessageSelection() {
    let messages = (0..<120).map { index in
      OpenClawChatMessage(
        role: index.isMultiple(of: 2) ? .user : .assistant,
        content: "Message \(index) has enough text to wrap across multiple lines in a typical chat pane. It remains copyable through the message affordance."
      )
    }
    let view = ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        ForEach(messages) { message in
          ChatBubbleView(message: message)
        }
      }
      // Mirrors the production transcript: selection is disabled at the lazy
      // stack boundary and re-enabled by each realized chat bubble.
      .textSelection(.disabled)
    }
    .frame(width: 720, height: 600)
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 600)

    let startedAt = CFAbsoluteTimeGetCurrent()
    hostingView.layoutSubtreeIfNeeded()
    let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

    XCTAssertLessThan(elapsed, 2)
    XCTAssertEqual(hostingView.fittingSize.width, 720, accuracy: 1)
  }

  func testMessageClipboardCopiesContentWithoutRoleChrome() {
    let message = OpenClawChatMessage(
      role: .assistant,
      content: "First paragraph.\n\nSecond paragraph."
    )
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("org2-chat-copy-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    XCTAssertTrue(OpenClawMessageClipboard.copy(message, to: pasteboard))

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

  func testChatAttachmentPreviewClassifiesImagesPDFsAndTextDocuments() {
    let image = OpenClawChatAttachment(
      fileName: "diagram.png",
      mimeType: "image/png",
      data: Data([0x01])
    )
    let pdf = OpenClawChatAttachment(
      fileName: "report.bin",
      mimeType: "application/pdf",
      data: Data("%PDF-1.4".utf8)
    )
    let text = OpenClawChatAttachment(
      fileName: "results.csv",
      mimeType: "application/octet-stream",
      data: Data("name,value\nalpha,1".utf8)
    )
    let binary = OpenClawChatAttachment(
      fileName: "archive.zip",
      mimeType: "application/zip",
      data: Data([0x50, 0x4b, 0x03, 0x04, 0xff])
    )

    XCTAssertEqual(OpenClawAttachmentPresentation.previewKind(for: image), .image)
    XCTAssertEqual(OpenClawAttachmentPresentation.previewKind(for: pdf), .pdf)
    XCTAssertEqual(OpenClawAttachmentPresentation.previewKind(for: text), .text)
    XCTAssertEqual(OpenClawAttachmentPresentation.decodedText(for: text), "name,value\nalpha,1")
    XCTAssertEqual(OpenClawAttachmentPresentation.previewKind(for: binary), .unsupported)
  }

  func testOpenClawStatusCardUsesOneDynamicStatusLine() {
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

    XCTAssertEqual(activeRun.statusTitle, "OpenClaw is working")
    XCTAssertEqual(startingRun.statusTitle, "Starting OpenClaw")

    let runningTool = OpenClawTypingIndicatorView(
      startedAt: Date(),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [
        OpenClawRunActivity(
          id: "tool-1",
          runID: "run-123",
          kind: .tool,
          title: "bash",
          status: .running
        )
      ],
      compact: false,
      onStop: {}
    )
    XCTAssertEqual(runningTool.statusTitle, "Running shell command")
  }

  func testOpenClawStatusCardSurfacesQuietAndStalledRuns() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let recentlyActive = OpenClawTypingIndicatorView(
      startedAt: now.addingTimeInterval(-30 * 60),
      lastEventAt: now.addingTimeInterval(-30),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )
    let quiet = OpenClawTypingIndicatorView(
      startedAt: now.addingTimeInterval(-30 * 60),
      lastEventAt: now.addingTimeInterval(-3 * 60),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )
    let stalled = OpenClawTypingIndicatorView(
      startedAt: now.addingTimeInterval(-30 * 60),
      lastEventAt: now.addingTimeInterval(-12 * 60),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )

    XCTAssertEqual(recentlyActive.statusTitle(now: now), "OpenClaw is working")
    XCTAssertNil(recentlyActive.statusDetail(now: now))
    XCTAssertEqual(quiet.statusTitle(now: now), "Waiting for OpenClaw")
    XCTAssertEqual(quiet.statusDetail(now: now), "No new activity for 3m. It may still be working.")
    XCTAssertEqual(stalled.statusTitle(now: now), "OpenClaw may be stalled")
    XCTAssertEqual(
      stalled.statusDetail(now: now),
      "No new activity for 12m. The run is saved; the connection or agent may be stalled."
    )
  }

  func testOpenClawStatusCardExplainsSavedRunWhileReconnecting() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let reconnecting = OpenClawTypingIndicatorView(
      startedAt: now.addingTimeInterval(-30 * 60),
      lastEventAt: now,
      connectionState: .reconnecting,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )

    XCTAssertEqual(reconnecting.statusTitle(now: now), "Reconnecting to OpenClaw")
    XCTAssertEqual(
      reconnecting.statusDetail(now: now),
      "The run is saved and will reconnect without being sent twice."
    )
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
    XCTAssertNil(item.latestDetail)
    XCTAssertEqual(item.status, .succeeded)
    XCTAssertFalse(item.detail?.contains("durationMs") == true)
  }

  func testActivityFeedPreservesTheLatestRunningCommandInsideAGroup() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let activities = [
      OpenClawRunActivity(
        id: "tool-1",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        detail: #"{"cmd":"npm run build"}"#,
        status: .succeeded,
        updatedAt: now.addingTimeInterval(-5)
      ),
      OpenClawRunActivity(
        id: "tool-2",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        detail: #"{"cmd":"swift test --filter OpenClawChatLayoutTests"}"#,
        status: .running,
        updatedAt: now
      )
    ]

    let item = try XCTUnwrap(OpenClawActivityFeed.items(from: activities).first)
    XCTAssertEqual(item.title, "2 shell commands")
    XCTAssertEqual(item.detail, "1 completed · 1 running")
    XCTAssertEqual(item.latestDetail, "swift test --filter OpenClawChatLayoutTests")
    XCTAssertEqual(item.status, .running)
    XCTAssertEqual(item.updatedAt, now)
  }

  func testActivityFeedPrefersRunningDetailOverANewerCompletedCommand() throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let activities = [
      OpenClawRunActivity(
        id: "tool-1",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        detail: #"{"cmd":"long-running verification"}"#,
        status: .running,
        updatedAt: now.addingTimeInterval(-10)
      ),
      OpenClawRunActivity(
        id: "tool-2",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        detail: #"{"cmd":"quick status check"}"#,
        status: .succeeded,
        updatedAt: now
      )
    ]

    let item = try XCTUnwrap(OpenClawActivityFeed.items(from: activities).first)
    XCTAssertEqual(item.latestDetail, "long-running verification")
    XCTAssertEqual(item.status, .running)
    XCTAssertEqual(item.updatedAt, now.addingTimeInterval(-10))
  }

  func testActivityFeedOnlyMarksAGroupFailedWhenFailuresAreTheMajority() throws {
    let activities = (0..<10).map { index in
      OpenClawRunActivity(
        id: "tool-\(index)",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        status: index < 6 ? .failed : .succeeded
      )
    }

    let item = try XCTUnwrap(OpenClawActivityFeed.items(from: activities).first)
    XCTAssertEqual(item.detail, "4 completed · 6 failed")
    XCTAssertEqual(item.status, .failed)
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
