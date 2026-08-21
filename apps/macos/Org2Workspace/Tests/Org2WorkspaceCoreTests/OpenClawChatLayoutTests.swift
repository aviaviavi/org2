import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
private final class ActivitySelectionModel: ObservableObject {
  @Published var selectedIndex = 0
}

private struct ActivitySelectionHarness: View {
  @ObservedObject var model: ActivitySelectionModel

  var body: some View {
    VStack {
      OpenClawSidebarThreadActivityView(isSelected: model.selectedIndex == 0)
      OpenClawSidebarThreadActivityView(isSelected: model.selectedIndex == 1)
    }
  }
}

@MainActor
final class OpenClawChatLayoutTests: XCTestCase {
  func testLiveProgressFeedShowsOnlyCurrentActivityUntilExpanded() {
    let completed = OpenClawActivityFeedItem(
      id: "completed",
      title: "17 shell commands",
      detail: "17 completed",
      latestDetail: nil,
      status: .succeeded,
      count: 17,
      updatedAt: Date()
    )
    let failed = OpenClawActivityFeedItem(
      id: "failed",
      title: "Memory search",
      detail: "Tool call failed",
      latestDetail: nil,
      status: .failed,
      count: 1,
      updatedAt: Date()
    )
    let items = [completed, failed]

    XCTAssertEqual(
      OpenClawProgressFeedPresentation.visibleItems(
        items,
        isLive: true,
        isExpanded: false,
        collapsedItemLimit: 3
      ),
      [failed]
    )
    XCTAssertFalse(OpenClawProgressFeedPresentation.showsReasoning(isLive: true, isExpanded: false))
    XCTAssertTrue(OpenClawProgressFeedPresentation.canExpand(
      itemCount: items.count,
      reasoningLength: 0,
      isLive: true,
      collapsedItemLimit: 3
    ))
    XCTAssertEqual(
      OpenClawProgressFeedPresentation.disclosureTitle(isLive: true, isExpanded: false),
      "Show activity"
    )
    XCTAssertEqual(
      OpenClawProgressFeedPresentation.visibleItems(
        items,
        isLive: true,
        isExpanded: true,
        collapsedItemLimit: 3
      ),
      items
    )
    XCTAssertTrue(OpenClawProgressFeedPresentation.showsReasoning(isLive: true, isExpanded: true))

    let running = OpenClawActivityFeedItem(
      id: "running",
      title: "Editing file",
      detail: "Updating the selected document",
      latestDetail: nil,
      status: .running,
      count: 1,
      updatedAt: Date()
    )
    XCTAssertEqual(
      OpenClawProgressFeedPresentation.visibleItems(
        [running, completed, failed],
        isLive: true,
        isExpanded: false,
        collapsedItemLimit: 3
      ),
      [running]
    )
  }

  func testMessagePresentationCacheReusesParsedContentAndInvalidatesEdits() {
    OpenClawMessagePresentationCache.removeAllForTesting()
    let messageID = UUID()
    let original = OpenClawChatMessage(
      id: messageID,
      role: .assistant,
      content: "* Result\n| Name | Value |\n|------+-------|\n| Alpha | 1 |",
      responseTrace: OpenClawResponseTrace(activities: [
        OpenClawRunActivity(
          id: "tool-1",
          runID: "run-1",
          kind: .tool,
          title: "Shell command",
          status: .succeeded
        )
      ])
    )

    let first = OpenClawMessagePresentationCache.presentation(for: original)
    let second = OpenClawMessagePresentationCache.presentation(for: original)
    XCTAssertTrue(first === second)
    XCTAssertTrue(first.org?.usesStructuredRendering == true)
    XCTAssertEqual(first.activityFeedItems.count, 1)

    let edited = OpenClawChatMessage(
      id: messageID,
      role: .assistant,
      content: "* Changed result"
    )
    let editedPresentation = OpenClawMessagePresentationCache.presentation(for: edited)
    XCTAssertFalse(first === editedPresentation)
    XCTAssertEqual(editedPresentation.context.userText, "* Changed result")
  }

  func testChatTimestampsIncludeUsefulDateContext() throws {
    let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let locale = Locale(identifier: "en_US_POSIX")
    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
      try XCTUnwrap(calendar.date(from: DateComponents(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
      )))
    }
    let now = try date(2026, 8, 17, 15, 0)

    XCTAssertEqual(
      AIChatMessageTimestampPresentation.displayText(
        for: try date(2026, 8, 17, 9, 15),
        relativeTo: now,
        calendar: calendar,
        locale: locale,
        timeZone: timeZone
      ),
      "Today at 9:15\u{202F}AM"
    )
    XCTAssertEqual(
      AIChatMessageTimestampPresentation.displayText(
        for: try date(2026, 8, 16, 21, 5),
        relativeTo: now,
        calendar: calendar,
        locale: locale,
        timeZone: timeZone
      ),
      "Yesterday at 9:05\u{202F}PM"
    )
    XCTAssertEqual(
      AIChatMessageTimestampPresentation.displayText(
        for: try date(2026, 7, 4, 12, 30),
        relativeTo: now,
        calendar: calendar,
        locale: locale,
        timeZone: timeZone
      ),
      "Jul 4 at 12:30\u{202F}PM"
    )
    XCTAssertEqual(
      AIChatMessageTimestampPresentation.displayText(
        for: try date(2025, 12, 31, 23, 59),
        relativeTo: now,
        calendar: calendar,
        locale: locale,
        timeZone: timeZone
      ),
      "Dec 31, 2025 at 11:59\u{202F}PM"
    )
  }

  func testSidebarThreadActivityIndicatorIsExplicitWithoutDominatingTheRow() {
    let view = OpenClawSidebarThreadActivityView()
    XCTAssertEqual(view.statusTitle, "Working")

    let hostingView = NSHostingView(rootView: view)
    hostingView.layoutSubtreeIfNeeded()
    let size = hostingView.fittingSize

    XCTAssertGreaterThan(size.width, 40, "The indicator should include a visible status label")
    XCTAssertLessThan(size.width, 80, "The status should remain compact in the sidebar")
    XCTAssertLessThan(size.height, 28)
  }

  func testSidebarThreadActivityAnimationFollowsSelection() {
    XCTAssertTrue(OpenClawSidebarThreadActivityView(isSelected: true).shouldAnimate)
    XCTAssertFalse(OpenClawSidebarThreadActivityView(isSelected: false).shouldAnimate)
  }

  func testSidebarThreadActivityAnimationTransfersBetweenHostedRows() {
    let model = ActivitySelectionModel()
    let hostingView = NSHostingView(rootView: ActivitySelectionHarness(model: model))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 180, height: 80),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()

    var dots = hostedActivityDots(in: hostingView)
    XCTAssertEqual(dots.count, 2)
    XCTAssertEqual(dots.filter(\.isAnimatingForTesting).count, 1)
    let initiallyAnimatedDot = dots.first(where: \.isAnimatingForTesting)

    model.selectedIndex = 1
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    hostingView.layoutSubtreeIfNeeded()

    dots = hostedActivityDots(in: hostingView)
    XCTAssertEqual(dots.count, 2)
    XCTAssertEqual(dots.filter(\.isAnimatingForTesting).count, 1)
    XCTAssertFalse(
      dots.first(where: \.isAnimatingForTesting) === initiallyAnimatedDot,
      "Selecting another thread must move the native animation to its row"
    )
  }

  func testActivityPulseRunsOnCoreAnimationInsteadOfSwiftUIFrameClock() {
    let view = CoreAnimationActivityDotNSView(frame: NSRect(x: 0, y: 0, width: 5, height: 5))

    view.configure(animates: true, color: .controlAccentColor)
    XCTAssertTrue(view.isAnimatingForTesting)

    view.configure(animates: false, color: .controlAccentColor)
    XCTAssertFalse(view.isAnimatingForTesting)
  }

  private func hostedActivityDots(in view: NSView) -> [CoreAnimationActivityDotNSView] {
    var result = view is CoreAnimationActivityDotNSView
      ? [view as! CoreAnimationActivityDotNSView]
      : []
    for subview in view.subviews {
      result.append(contentsOf: hostedActivityDots(in: subview))
    }
    return result
  }

  func testPeriodicStatusTextUsesAnAppKitLocalTimer() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let view = AppKitPeriodicTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 20))
    window.contentView = view

    view.configure(
      interval: 1,
      font: .systemFont(ofSize: 11),
      color: .secondaryLabelColor,
      textProvider: { _ in "Working locally" }
    )

    XCTAssertEqual(view.stringValue, "Working locally")
    XCTAssertTrue(view.isUpdatingForTesting)

    view.stopUpdating()
    XCTAssertFalse(view.isUpdatingForTesting)
  }

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

  func testThreadFindMatchesVisibleMessageTextCaseInsensitively() {
    let first = OpenClawChatMessage(role: .user, content: "Review the launch checklist")
    let second = OpenClawChatMessage(role: .assistant, content: "The LAUNCH is ready.")
    let unrelated = OpenClawChatMessage(role: .assistant, content: "No blockers remain.")
    let items = AIChatRoomTranscriptPresentation.items(
      messages: [first, second, unrelated],
      isSharedRoom: false
    )

    XCTAssertEqual(
      AIChatThreadSearch.matches(query: "launch", in: items),
      [
        AIChatThreadSearchMatch(messageID: first.id, scrollTargetID: first.id),
        AIChatThreadSearchMatch(messageID: second.id, scrollTargetID: second.id),
      ]
    )
    XCTAssertTrue(AIChatThreadSearch.matches(query: "   ", in: items).isEmpty)
  }

  func testThreadFindTargetsTheContainingSharedRoomRound() {
    let roundID = UUID()
    let trigger = OpenClawChatMessage(
      role: .user,
      content: "Ask both agents",
      audienceDestinationIDs: ["codex", "openclaw"],
      roomRoundID: roundID
    )
    let codex = OpenClawChatMessage(
      role: .assistant,
      content: "Codex found the migration detail.",
      authorDestinationID: "codex",
      roomRoundID: roundID
    )
    let openClaw = OpenClawChatMessage(
      role: .assistant,
      content: "OpenClaw found another detail.",
      authorDestinationID: "openclaw",
      roomRoundID: roundID
    )
    let items = AIChatRoomTranscriptPresentation.items(
      messages: [trigger, codex, openClaw],
      isSharedRoom: true
    )

    XCTAssertEqual(
      AIChatThreadSearch.matches(query: "migration", in: items),
      [AIChatThreadSearchMatch(messageID: codex.id, scrollTargetID: roundID)]
    )
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

  func testAssistantMessagesRenderStructuredOrg2AndRepairCommonFormattingMistakes() {
    let raw = """
    * Does Codex have server mode?

    | Mode | Best use | Recommendation |
    |-------------------------------|
    | Codex Remote | Interactive work | Best starting point |

    ##+begin_src sh
    codex app-server --listen ws://127.0.0.1:4500
    ##+end_src
    """
    let presentation = OpenClawMessageOrgPresentation(raw)

    XCTAssertTrue(presentation.usesStructuredRendering)
    XCTAssertTrue(presentation.normalizedText.contains("#+begin_src sh"))
    XCTAssertTrue(presentation.normalizedText.contains("#+end_src"))
    XCTAssertFalse(presentation.normalizedText.contains("##+begin_src"))
    let hline = presentation.normalizedText
      .split(separator: "\n")
      .map(String.init)
      .first(where: { $0.contains("+") && $0.allSatisfy { $0 == "|" || $0 == "+" || $0 == "-" } })
    XCTAssertEqual(hline?.filter { $0 == "+" }.count, 2)
    XCTAssertTrue(presentation.blocks.contains { block in
      if case .heading = block.rendered { return true }
      return false
    })
    XCTAssertTrue(presentation.blocks.contains { block in
      if case .table = block.rendered { return true }
      return false
    })
    XCTAssertTrue(presentation.blocks.contains { block in
      if case .source = block.rendered { return true }
      return false
    })

    let message = OpenClawChatMessage(role: .assistant, content: raw)
    XCTAssertEqual(OpenClawMessageClipboard.text(for: message), presentation.normalizedText)
  }

  func testAssistantTableRowsExpandForWrappedCells() {
    let wrappedMessage = OpenClawChatMessage(
      role: .assistant,
      content: """
      | Issue | Why |
      |-------+-----|
      | APP-21298 | PR #10422 is contained in the current production revision, whose deployment succeeded August 15, but no post-deployment verification was recorded. |
      | APP-21299 | PR #10434 merged after the current production revision and has not reached production yet. |
      | APP-21174 | PR #10424 is contained in the deployed production revision, but the durable run was not reconciled afterward. |
      """
    )
    let singleLineMessage = OpenClawChatMessage(
      role: .assistant,
      content: """
      | Issue | Why |
      |-------+-----|
      | APP-21298 | Deployed. |
      | APP-21299 | Not deployed. |
      | APP-21174 | Deployed. |
      """
    )

    func fittingHeight(for message: OpenClawChatMessage) -> CGFloat {
      let view = ChatBubbleView(message: message, compact: false)
        .frame(width: 640, alignment: .leading)
      let hostingView = NSHostingView(rootView: view)
      hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 1)
      hostingView.layoutSubtreeIfNeeded()
      return hostingView.fittingSize.height
    }

    XCTAssertGreaterThan(
      fittingHeight(for: wrappedMessage),
      fittingHeight(for: singleLineMessage) + 40
    )
  }

  func testAssistantTableColumnsFitOrdinaryFourColumnChatTables() {
    let rows: [OrgTableRow] = [
      .cells(["Line item", "Monthly quantity", "Unit price", "Annual reference"]),
      .cells([
        "Additional Company Unlocks, units 1,001–2,500",
        "1,500",
        "$0.96/unlock-month",
        "$17,280",
      ]),
    ]
    let widths = RenderedTableColumnWidths.make(
      rows: rows,
      visibleColumns: [0, 1, 2, 3]
    )

    XCTAssertEqual(widths.values.reduce(0, +), RenderedTableColumnWidths.preferredTotal, accuracy: 0.01)
    XCTAssertTrue(widths.values.allSatisfy { $0 >= RenderedTableColumnWidths.minimum })
    XCTAssertTrue(widths.values.allSatisfy { $0 <= RenderedTableColumnWidths.maximum })
  }

  func testAssistantTableKeepsCompactNaturalWidths() {
    let rows: [OrgTableRow] = [
      .cells(["Issue", "State"]),
      .cells(["APP-21298", "Deployed"]),
    ]
    let widths = RenderedTableColumnWidths.make(rows: rows, visibleColumns: [0, 1])

    XCTAssertEqual(widths[0], RenderedTableColumnWidths.minimum)
    XCTAssertEqual(widths[1], RenderedTableColumnWidths.minimum)
  }

  func testAssistantTableUsesWiderAvailableSpaceBeforeScrolling() {
    let rows: [OrgTableRow] = [
      .cells(["", "Annual quantity", "Unit price"]),
      .cells([
        "Company Unlocks with the corrected annual allowance and renewal reference",
        "26,400",
        "$1.1636/unlock-month",
      ]),
    ]
    let narrowWidths = RenderedTableColumnWidths.make(
      rows: rows,
      visibleColumns: [0, 1, 2],
      availableWidth: 360
    )
    let wideWidths = RenderedTableColumnWidths.make(
      rows: rows,
      visibleColumns: [0, 1, 2],
      availableWidth: 900
    )

    XCTAssertEqual(narrowWidths.values.reduce(0, +), 360, accuracy: 0.01)
    XCTAssertGreaterThan(wideWidths.values.reduce(0, +), 360)
    XCTAssertLessThanOrEqual(wideWidths.values.reduce(0, +), 900)
    XCTAssertGreaterThan(wideWidths[0] ?? 0, 260)
  }

  func testPlainAssistantMessagesKeepLightweightInlineRendering() {
    let presentation = OpenClawMessageOrgPresentation("A short answer with *emphasis* and [[recipes.org2][a link]].")

    XCTAssertFalse(presentation.usesStructuredRendering)
    XCTAssertEqual(presentation.blocks.count, 1)
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

  func testStatusCardUsesConfiguredDirectProviderName() {
    let view = OpenClawTypingIndicatorView(
      startedAt: Date(),
      runtime: .openClaw,
      destinationTitle: "Anthropic",
      connectionState: .connected,
      connectionDetail: nil,
      runID: nil,
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )

    XCTAssertEqual(view.statusTitle, "Starting Anthropic")
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
    XCTAssertTrue(reconnecting.canStop)
  }

  func testOpenClawStatusCardAllowsStoppingBeforeAConnectionOrRunIDExists() {
    let connecting = OpenClawTypingIndicatorView(
      startedAt: Date(),
      connectionState: .connecting,
      connectionDetail: nil,
      runID: nil,
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )

    XCTAssertTrue(connecting.canStop)
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

  func testGatewayPreambleItemsBecomeReplaceableProgressActivities() throws {
    let initial = try XCTUnwrap(OpenClawGatewayClient.activity(from: [
      "runId": "run-1",
      "stream": "item",
      "data": [
        "kind": "preamble",
        "itemId": "item-1",
        "progressText": "Checking the relevant files."
      ]
    ]))
    let update = try XCTUnwrap(OpenClawGatewayClient.activity(from: [
      "runId": "run-1",
      "stream": "item",
      "data": [
        "kind": "preamble",
        "itemId": "item-1",
        "progressText": "Checking the relevant files and tests."
      ]
    ]))

    XCTAssertEqual(initial.id, "preamble:item-1")
    XCTAssertEqual(initial.kind, .reasoning)
    XCTAssertEqual(initial.title, "Progress update")
    XCTAssertEqual(initial.detail, "Checking the relevant files.")
    XCTAssertEqual(initial.status, .succeeded)
    XCTAssertEqual(update.id, initial.id)

    let merged = OpenClawActivityFeed.merging(initial, with: update)
    XCTAssertEqual(merged.detail, "Checking the relevant files and tests.")

    let item = try XCTUnwrap(OpenClawActivityFeed.items(from: [merged]).first)
    XCTAssertEqual(item.kind, .reasoning)
    XCTAssertEqual(item.title, "Progress update")
    XCTAssertEqual(item.detail, "Checking the relevant files and tests.")
  }

  func testGatewayAssistantCommentaryAccumulatesAsPreambleProgress() throws {
    var accumulatedTextByItemID: [String: String] = [:]
    let first = try XCTUnwrap(OpenClawGatewayClient.commentaryActivity(
      from: [
        "runId": "run-1",
        "stream": "assistant",
        "data": [
          "phase": "commentary",
          "itemId": "item-1",
          "text": "",
          "delta": "Checking the relevant "
        ]
      ],
      accumulatedTextByItemID: &accumulatedTextByItemID
    ))
    let second = try XCTUnwrap(OpenClawGatewayClient.commentaryActivity(
      from: [
        "runId": "run-1",
        "stream": "assistant",
        "data": [
          "phase": "commentary",
          "itemId": "item-1",
          "text": "",
          "delta": "files and tests."
        ]
      ],
      accumulatedTextByItemID: &accumulatedTextByItemID
    ))

    XCTAssertEqual(first.id, "preamble:item-1")
    XCTAssertEqual(first.kind, .reasoning)
    XCTAssertEqual(first.detail, "Checking the relevant")
    XCTAssertEqual(second.id, first.id)
    XCTAssertEqual(second.detail, "Checking the relevant files and tests.")
  }

  func testGatewayAssistantCommentaryAcceptsCumulativeReplacementSnapshots() throws {
    var accumulatedTextByItemID = ["run-1:item-1": "Old progress"]
    let replacement = try XCTUnwrap(OpenClawGatewayClient.commentaryActivity(
      from: [
        "runId": "run-1",
        "stream": "assistant",
        "data": [
          "phase": "commentary",
          "itemId": "item-1",
          "text": "A corrected progress update.",
          "delta": "",
          "replace": true
        ]
      ],
      accumulatedTextByItemID: &accumulatedTextByItemID
    ))

    XCTAssertEqual(replacement.detail, "A corrected progress update.")
    XCTAssertEqual(accumulatedTextByItemID["run-1:item-1"], "A corrected progress update.")
  }

  func testGatewayIgnoresNonProgressAssistantText() {
    var accumulatedTextByItemID: [String: String] = [:]
    XCTAssertNil(OpenClawGatewayClient.commentaryActivity(
      from: [
        "runId": "run-1",
        "stream": "assistant",
        "data": [
          "phase": "final_answer",
          "itemId": "item-1",
          "delta": "This belongs in the final answer."
        ]
      ],
      accumulatedTextByItemID: &accumulatedTextByItemID
    ))
    XCTAssertTrue(accumulatedTextByItemID.isEmpty)
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

  func testLiveProgressShowsLatestReadableUpdateByDefault() throws {
    let progress = """
      I’ll inspect the current delivery model and locate the relevant code.

      The source repository is available. I’m checking the Mac app package now.

      The implementation is taking shape as an append-only inbox.
      """

    XCTAssertEqual(
      OpenClawProgressPresentation.liveText(from: progress, showsAll: false),
      "The implementation is taking shape as an append-only inbox."
    )
    XCTAssertEqual(
      OpenClawProgressPresentation.liveText(from: progress, showsAll: true),
      progress
    )
    XCTAssertTrue(OpenClawProgressPresentation.hasEarlierLiveText(progress))
  }

  func testLiveProgressBoundsOneOversizedUpdate() throws {
    let progress = String(repeating: "Validating the implementation. ", count: 40)
    let collapsed = try XCTUnwrap(
      OpenClawProgressPresentation.liveText(from: progress, showsAll: false)
    )

    XCTAssertLessThanOrEqual(collapsed.count, 320)
    XCTAssertTrue(collapsed.hasSuffix("\u{2026}"))
    XCTAssertTrue(OpenClawProgressPresentation.hasEarlierLiveText(progress))
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
