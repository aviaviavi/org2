import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
private final class TranscriptLayoutProbeCounter {
  var realizedRows = 0
}

private struct TranscriptLayoutProbe: NSViewRepresentable {
  let counter: TranscriptLayoutProbeCounter

  func makeNSView(context: Context) -> NSView {
    counter.realizedRows += 1
    return NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private enum ChatAccessibilityNode {
  case view(NSView)
  case element(NSAccessibilityElement)

  var identity: ObjectIdentifier {
    switch self {
    case .view(let value): ObjectIdentifier(value)
    case .element(let value): ObjectIdentifier(value)
    }
  }

  var accessibilityIdentifier: String? {
    switch self {
    case .view(let value): value.accessibilityIdentifier()
    case .element(let value): value.accessibilityIdentifier()
    }
  }

  var accessibilityLabel: String? {
    switch self {
    case .view(let value): value.accessibilityLabel()
    case .element(let value): value.accessibilityLabel()
    }
  }

  var accessibilityRole: NSAccessibility.Role? {
    switch self {
    case .view(let value): value.accessibilityRole()
    case .element(let value): value.accessibilityRole()
    }
  }

  var children: [Any] {
    switch self {
    case .view(let value):
      // SwiftUI may expose a native accessibility element through either the
      // AppKit view hierarchy or the synthesized accessibility hierarchy,
      // depending on when the hosting view first lays out. Traverse both so
      // this assertion always exercises the real native action rather than a
      // backend-specific tree shape.
      return value.subviews + (value.accessibilityChildren() ?? [])
    case .element(let value): return value.accessibilityChildren() ?? []
    }
  }

  func performPress() -> Bool {
    switch self {
    case .view(let value): value.accessibilityPerformPress()
    case .element(let value): value.accessibilityPerformPress()
    }
  }
}

@MainActor
private func chatAccessibilityNodes(in root: NSView) -> [ChatAccessibilityNode] {
  var result: [ChatAccessibilityNode] = []
  var pending: [ChatAccessibilityNode] = [.view(root)]
  var visited = Set<ObjectIdentifier>()
  while let node = pending.popLast(), result.count < 2_000 {
    guard visited.insert(node.identity).inserted else { continue }
    result.append(node)
    for child in node.children {
      if let view = child as? NSView {
        pending.append(.view(view))
      } else if let element = child as? NSAccessibilityElement {
        pending.append(.element(element))
      }
    }
  }
  return result
}

@MainActor
final class OpenClawChatLayoutTests: XCTestCase {
  func testDefaultSplitProtectsAUsableChatPaneAtLaptopWidth() {
    XCTAssertGreaterThanOrEqual(WorkspaceMainSplitLayout.surfaceMinimumWidth, 300)
    XCTAssertLessThanOrEqual(
      WorkspaceMainSplitLayout.surfaceMinimumWidth + WorkspaceMainSplitLayout.detailMinimumWidth,
      720,
      "The two-pane minimum must fit inside the default compact workspace after navigation chrome"
    )
  }

  func testComposerPreservesNewerNativeTextAcrossDelayedModelUpdates() {
    var synchronization = OpenClawComposerTextSynchronization(initialModelText: "")

    synchronization.nativeTextDidChange("ok")
    synchronization.nativeTextDidChange("ok ")
    synchronization.nativeTextDidChange("ok -")

    XCTAssertEqual(
      synchronization.modelTextUpdate(""),
      .preserveNativeText
    )
    XCTAssertEqual(
      synchronization.modelTextUpdate("ok"),
      .preserveNativeText
    )
    XCTAssertEqual(
      synchronization.modelTextUpdate("ok "),
      .preserveNativeText
    )
    XCTAssertEqual(
      synchronization.modelTextUpdate("ok -"),
      .preserveNativeText
    )
    XCTAssertEqual(
      synchronization.modelTextUpdate("Externally restored draft"),
      .applyModelText
    )
  }

  func testComposerForcedModelUpdateSupersedesPendingNativeText() {
    var synchronization = OpenClawComposerTextSynchronization()
    synchronization.nativeTextDidChange("Send this")

    XCTAssertEqual(
      synchronization.modelTextUpdate("", forced: true),
      .applyModelText
    )
    XCTAssertEqual(
      synchronization.modelTextUpdate("Send this"),
      .applyModelText
    )
  }

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

  func testExpandedProgressFeedKeepsMountedRowsStrictlyBounded() {
    let items = (0..<10_000).map { index in
      OpenClawActivityFeedItem(
        id: "activity-\(index)",
        title: "Activity \(index)",
        detail: nil,
        latestDetail: nil,
        status: .succeeded,
        count: 1,
        updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }

    let visible = OpenClawProgressFeedPresentation.visibleItems(
      items,
      isLive: false,
      isExpanded: true,
      collapsedItemLimit: 3
    )

    XCTAssertEqual(visible.count, OpenClawProgressFeedPresentation.maximumExpandedItemCount)
    XCTAssertEqual(visible.first?.id, "activity-9904")
    XCTAssertEqual(visible.last?.id, "activity-9999")
    XCTAssertEqual(
      OpenClawProgressFeedPresentation.omittedExpandedItemCount(
        itemCount: items.count,
        isExpanded: true
      ),
      10_000 - OpenClawProgressFeedPresentation.maximumExpandedItemCount
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

  func testDetachedMessagePresentationMatchesMainActorFallback() async {
    OpenClawMessagePresentationCache.removeAllForTesting()
    let message = OpenClawChatMessage(
      role: .assistant,
      content: "* Result\n| Name | Value |\n|------+-------|\n| Alpha | *one* |",
      responseTrace: OpenClawResponseTrace(
        reasoning: "Checked the source",
        activities: [
          OpenClawRunActivity(
            id: "tool-1",
            runID: "run-1",
            kind: .tool,
            title: "Read file",
            detail: "Loaded the selected source",
            status: .succeeded
          ),
        ]
      )
    )
    let input = OpenClawMessagePresentationInput(message)
    let prepared = await Task.detached {
      OpenClawMessagePresentationBuilder.prepare(input)
    }.value

    XCTAssertEqual(prepared.messageID, message.id)
    XCTAssertTrue(prepared.value.matches(input))
    XCTAssertEqual(prepared.value.context.userText, message.content)
    XCTAssertTrue(prepared.value.body.org?.usesStructuredRendering == true)
    XCTAssertEqual(prepared.value.activityFeedItems.count, 1)
    XCTAssertGreaterThan(prepared.estimatedCost, message.content.utf8.count)

    OpenClawMessagePresentationCache.install(prepared)
    XCTAssertTrue(OpenClawMessagePresentationCache.presentation(for: message) === prepared.value)
  }

  func testMessagePresentationInputAndCostDoNotDependOnAttachments() {
    let messageID = UUID()
    let content = "A response with [[notes/example.org2][a link]]."
    let smallAttachmentMessage = OpenClawChatMessage(
      id: messageID,
      role: .assistant,
      content: content,
      attachments: [
        OpenClawChatAttachment(
          fileName: "small.bin",
          mimeType: "application/octet-stream",
          data: Data([0x01])
        ),
      ]
    )
    let largeAttachmentMessage = OpenClawChatMessage(
      id: messageID,
      role: .assistant,
      content: content,
      attachments: [
        OpenClawChatAttachment(
          fileName: "large.bin",
          mimeType: "application/octet-stream",
          data: Data(repeating: 0x42, count: 512 * 1_024)
        ),
      ]
    )

    let smallInput = OpenClawMessagePresentationInput(smallAttachmentMessage)
    let largeInput = OpenClawMessagePresentationInput(largeAttachmentMessage)
    XCTAssertEqual(smallInput, largeInput)

    let smallPrepared = OpenClawMessagePresentationBuilder.prepare(smallInput)
    let largePrepared = OpenClawMessagePresentationBuilder.prepare(largeInput)
    XCTAssertEqual(smallPrepared.estimatedCost, largePrepared.estimatedCost)
    XCTAssertEqual(smallPrepared.value.body, largePrepared.value.body)
  }

  func testLargeMessagePresentationUsesUnicodeSafeBoundedPreviewAndFullClipboardText() throws {
    let boundary = OpenClawMessageBodyExcerpt.collapsedUTF8ByteLimit
    let suffix = "🧪 FULL-CONTENT-SENTINEL"
    let content = String(repeating: "a", count: boundary - 1) + suffix
    let message = OpenClawChatMessage(role: .assistant, content: content)
    let prepared = OpenClawMessagePresentationBuilder.prepare(
      OpenClawMessagePresentationInput(message)
    )

    XCTAssertTrue(prepared.value.body.isTruncated)
    XCTAssertLessThanOrEqual(
      prepared.value.body.displayedText.utf8.count,
      OpenClawMessageBodyExcerpt.collapsedUTF8ByteLimit
    )
    XCTAssertFalse(prepared.value.body.displayedText.contains("🧪"))
    XCTAssertTrue(String(data: Data(prepared.value.body.displayedText.utf8), encoding: .utf8) != nil)
    XCTAssertEqual(OpenClawMessageClipboard.text(for: message), content)

    let expanded = try XCTUnwrap(OpenClawMessagePresentationBuilder.prepareExpandedBody(
      sourceText: prepared.value.body.sourceText,
      role: .assistant
    ))
    XCTAssertFalse(expanded.isTruncated)
    XCTAssertEqual(expanded.displayedText, content)
    XCTAssertTrue(expanded.containsInlineSyntax == false)
  }

  func testMultiMegabyteExpandedMessageUsesBoundedNavigablePages() throws {
    let pageLimit = OpenClawExpandedMessageBodyInput.pageCharacterLimit
    let source = String(repeating: "a", count: pageLimit)
      + String(repeating: "b", count: pageLimit)
      + "FINAL-PAGE-SENTINEL"

    let first = try XCTUnwrap(OpenClawMessagePresentationBuilder.prepareExpandedBody(
      sourceText: source,
      role: .assistant,
      pageIndex: 0
    ))
    let second = try XCTUnwrap(OpenClawMessagePresentationBuilder.prepareExpandedBody(
      sourceText: source,
      role: .assistant,
      pageIndex: 1
    ))
    let final = try XCTUnwrap(OpenClawMessagePresentationBuilder.prepareExpandedBody(
      sourceText: source,
      role: .assistant,
      pageIndex: 2
    ))

    XCTAssertEqual(first.displayedText.count, pageLimit)
    XCTAssertEqual(second.displayedText.count, pageLimit)
    XCTAssertTrue(first.isTruncated)
    XCTAssertTrue(second.isTruncated)
    XCTAssertFalse(first.displayedText.contains("FINAL-PAGE-SENTINEL"))
    XCTAssertFalse(second.displayedText.contains("FINAL-PAGE-SENTINEL"))
    XCTAssertEqual(final.displayedText, "FINAL-PAGE-SENTINEL")
    XCTAssertFalse(final.isTruncated)
  }

  func testStructuredMessageBlockPagesRemainStrictlyBounded() {
    let pageSize = OpenClawMessageBodyView.maximumStructuredBlockCountPerPage
    let first = OpenClawMessageBodyView.structuredBlockRange(
      blockCount: 10_000,
      pageIndex: 0
    )
    let middle = OpenClawMessageBodyView.structuredBlockRange(
      blockCount: 10_000,
      pageIndex: 40
    )
    let final = OpenClawMessageBodyView.structuredBlockRange(
      blockCount: 10_000,
      pageIndex: .max
    )

    XCTAssertEqual(first, 0..<pageSize)
    XCTAssertEqual(middle.count, pageSize)
    XCTAssertLessThanOrEqual(final.count, pageSize)
    XCTAssertEqual(final.upperBound, 10_000)
  }

  func testOffMainPresentationRevisionInvalidatesSameLengthMiddleEdit() async throws {
    let messageID = UUID()
    let originalInput = OpenClawMessagePresentationInput(OpenClawChatMessage(
      id: messageID,
      role: .assistant,
      content: "prefix-ORIGINAL-suffix"
    ))
    let editedInput = OpenClawMessagePresentationInput(OpenClawChatMessage(
      id: messageID,
      role: .assistant,
      content: "prefix-CHANGED!-suffix"
    ))
    XCTAssertEqual(originalInput.rawText.count, editedInput.rawText.count)

    let (originalRevision, editedRevision) = await Task.detached {
      (
        OpenClawMessagePresentationRevision(originalInput),
        OpenClawMessagePresentationRevision(editedInput)
      )
    }.value
    XCTAssertNotEqual(originalRevision, editedRevision)

    let original = OpenClawMessagePresentationBuilder.prepare(
      originalInput,
      revision: originalRevision
    )
    let resolved = await OpenClawMessagePresentationPreparationCoordinator.shared.resolve(
      editedInput,
      cachedCandidate: original.value
    )
    XCTAssertEqual(resolved.revision, editedRevision)
    XCTAssertEqual(resolved.value.body.displayedText, editedInput.rawText)
    XCTAssertNotNil(resolved.preparedForCacheInstall)
  }

  func testLargeMessagePreviewExposesNativeShowFullActionAndFindReveal() async throws {
    OpenClawMessagePresentationCache.removeAllForTesting()
    let message = OpenClawChatMessage(
      role: .assistant,
      content: String(
        repeating: "large response ",
        count: OpenClawMessageBodyExcerpt.collapsedUTF8ByteLimit / 8
      )
    )
    let messageIdentifier = message.id.uuidString.lowercased()
    let showFullID = "openclaw-message-show-full-\(messageIdentifier)"
    let showLessID = "openclaw-message-show-less-\(messageIdentifier)"
    let hostingView = NSHostingView(rootView: ChatBubbleView(message: message))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.orderFrontRegardless()
    defer {
      window.contentView = nil
      window.close()
    }

    var showFullNode: ChatAccessibilityNode?
    for _ in 0..<100 {
      hostingView.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      showFullNode = chatAccessibilityNodes(in: hostingView).first {
        $0.accessibilityIdentifier == showFullID
      }
      if showFullNode != nil { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let showFull = try XCTUnwrap(
      showFullNode,
      chatAccessibilityNodes(in: hostingView)
        .compactMap { node -> String? in
          guard node.accessibilityIdentifier != nil || node.accessibilityLabel != nil else {
            return nil
          }
          let identifier = node.accessibilityIdentifier ?? "nil"
          let label = node.accessibilityLabel ?? "nil"
          let role = node.accessibilityRole?.rawValue ?? "nil"
          return "id=\(identifier) label=\(label) role=\(role)"
        }
        .joined(separator: "\n")
    )
    XCTAssertTrue(showFull.performPress())

    var didExposeShowLess = false
    for _ in 0..<100 {
      hostingView.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      if chatAccessibilityNodes(in: hostingView).contains(where: {
        $0.accessibilityIdentifier == showLessID
      }) {
        didExposeShowLess = true
        break
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(didExposeShowLess)

    hostingView.rootView = ChatBubbleView(
      message: message,
      isSelectedSearchMatch: true
    )
    let revealedID = "openclaw-message-full-revealed-\(messageIdentifier)"
    var didRevealSelectedMatch = false
    for _ in 0..<100 {
      hostingView.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      if chatAccessibilityNodes(in: hostingView).contains(where: {
        $0.accessibilityIdentifier == revealedID
      }) {
        didRevealSelectedMatch = true
        break
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(didRevealSelectedMatch)
  }

  func testInstalledPreparedPresentationStillInvalidatesAnEditedSameIDMessage() {
    OpenClawMessagePresentationCache.removeAllForTesting()
    let messageID = UUID()
    let original = OpenClawChatMessage(
      id: messageID,
      role: .assistant,
      content: "Original"
    )
    let prepared = OpenClawMessagePresentationBuilder.prepare(
      OpenClawMessagePresentationInput(original)
    )
    OpenClawMessagePresentationCache.install(prepared)

    let edited = OpenClawChatMessage(
      id: messageID,
      role: .assistant,
      content: "Edited"
    )
    let editedPresentation = OpenClawMessagePresentationCache.presentation(for: edited)

    XCTAssertFalse(editedPresentation === prepared.value)
    XCTAssertEqual(editedPresentation.body.displayedText, "Edited")
  }

  func testConcurrentColdAndExpandedPreparationDeduplicatesWork() async throws {
    let presentationCoordinator = OpenClawMessagePresentationPreparationCoordinator.shared
    let expansionCoordinator = OpenClawExpandedMessageBodyPreparationCoordinator.shared
    await presentationCoordinator.resetForTesting()
    await expansionCoordinator.resetForTesting()
    let message = OpenClawChatMessage(
      role: .assistant,
      content: String(repeating: "long response ", count: 4_000)
    )
    let input = OpenClawMessagePresentationInput(message)

    async let first = presentationCoordinator.prepare(input)
    async let second = presentationCoordinator.prepare(input)
    let (firstPrepared, secondPrepared) = await (first, second)

    XCTAssertTrue(firstPrepared.value === secondPrepared.value)
    let presentationPreparationCount = await presentationCoordinator.countForTesting()
    XCTAssertEqual(presentationPreparationCount, 1)

    let expandedInput = OpenClawExpandedMessageBodyInput(
      messageID: input.messageID,
      role: input.role,
      sourceText: firstPrepared.value.body.sourceText
    )
    async let firstExpanded = expansionCoordinator.prepare(expandedInput)
    async let secondExpanded = expansionCoordinator.prepare(expandedInput)
    let expandedBodies = await (firstExpanded, secondExpanded)

    XCTAssertEqual(try XCTUnwrap(expandedBodies.0), try XCTUnwrap(expandedBodies.1))
    let expansionPreparationCount = await expansionCoordinator.countForTesting()
    XCTAssertEqual(expansionPreparationCount, 1)

    let userExpandedInput = OpenClawExpandedMessageBodyInput(
      messageID: expandedInput.messageID,
      role: .user,
      sourceText: expandedInput.sourceText
    )
    XCTAssertNotEqual(userExpandedInput, expandedInput)
    let userExpandedResult = await expansionCoordinator.prepare(userExpandedInput)
    let userExpanded = try XCTUnwrap(userExpandedResult)
    XCTAssertNil(userExpanded.org)
    let roleSensitivePreparationCount = await expansionCoordinator.countForTesting()
    XCTAssertEqual(roleSensitivePreparationCount, 2)

    await expansionCoordinator.resetForTesting()
    let cancellationTask = Task {
      do {
        try await Task.sleep(nanoseconds: 50_000_000)
      } catch {}
      return await expansionCoordinator.prepare(expandedInput)
    }
    cancellationTask.cancel()
    let cancelledExpansion = await cancellationTask.value
    XCTAssertNil(cancelledExpansion)
  }

  func testStandardPreparationGloballyBoundsWorkersAndSerializesSameMessageEdits() async throws {
    let coordinator = OpenClawMessagePresentationPreparationCoordinator.shared
    await coordinator.resetForTesting()
    await coordinator.setWorkersPausedForTesting(true)
    let messageID = UUID()
    let originalInput = OpenClawMessagePresentationInput(OpenClawChatMessage(
      id: messageID,
      role: .assistant,
      content: "* Original\nOriginal body"
    ))
    let changedInput = OpenClawMessagePresentationInput(OpenClawChatMessage(
      id: messageID,
      role: .assistant,
      content: "* Changed\nChanged body"
    ))
    let secondInput = OpenClawMessagePresentationInput(OpenClawChatMessage(
      role: .assistant,
      content: "Second message"
    ))
    let thirdInput = OpenClawMessagePresentationInput(OpenClawChatMessage(
      role: .assistant,
      content: "Third message"
    ))

    let originalTask = Task { await coordinator.prepare(originalInput) }
    for _ in 0..<100 {
      if await coordinator.activeWorkerCountForTesting() == 1 { break }
      await Task.yield()
    }
    let changedTask = Task { await coordinator.prepare(changedInput) }
    let secondTask = Task { await coordinator.prepare(secondInput) }
    let thirdTask = Task { await coordinator.prepare(thirdInput) }
    var allPreparationsWereScheduled = false
    for _ in 0..<100 {
      if await coordinator.countForTesting() == 4,
         await coordinator.activeWorkerCountForTesting() == 2 {
        allPreparationsWereScheduled = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(allPreparationsWereScheduled)
    let workerLimit = await coordinator.maximumConcurrentWorkerCountForTesting()
    let peakWhilePaused = await coordinator.peakConcurrentWorkerCountForTesting()
    let sameMessagePeakWhilePaused = await coordinator.peakWorkerCountForTesting(
      messageID: messageID
    )
    XCTAssertEqual(workerLimit, 2)
    XCTAssertEqual(peakWhilePaused, workerLimit)
    XCTAssertEqual(sameMessagePeakWhilePaused, 1)

    await coordinator.setWorkersPausedForTesting(false)
    let original = await originalTask.value
    let changed = await changedTask.value
    _ = await secondTask.value
    _ = await thirdTask.value
    XCTAssertEqual(original.value.rawText, originalInput.rawText)
    XCTAssertEqual(changed.value.rawText, changedInput.rawText)
    let preparationCount = await coordinator.countForTesting()
    let finalActiveWorkerCount = await coordinator.activeWorkerCountForTesting()
    let peakWorkerCount = await coordinator.peakConcurrentWorkerCountForTesting()
    let sameMessagePeakWorkerCount = await coordinator.peakWorkerCountForTesting(
      messageID: messageID
    )
    XCTAssertEqual(preparationCount, 4)
    XCTAssertEqual(finalActiveWorkerCount, 0)
    XCTAssertEqual(peakWorkerCount, workerLimit)
    XCTAssertEqual(sameMessagePeakWorkerCount, 1)
  }

  func testExpandedPreparationSerializesRapidCancelRerequestAndChangedInput() async throws {
    let coordinator = OpenClawExpandedMessageBodyPreparationCoordinator.shared
    await coordinator.resetForTesting()
    await coordinator.setWorkersPausedForTesting(true)
    let messageID = UUID()
    let originalInput = OpenClawExpandedMessageBodyInput(
      messageID: messageID,
      role: .assistant,
      sourceText: "* Original\nOriginal body"
    )
    let changedInput = OpenClawExpandedMessageBodyInput(
      messageID: messageID,
      role: .user,
      sourceText: "Changed body"
    )

    let canceledWaiter = Task {
      await coordinator.prepare(originalInput)
    }
    var originalWorkerDidStart = false
    for _ in 0..<100 {
      if await coordinator.activeWorkerCountForTesting() == 1 {
        originalWorkerDidStart = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(originalWorkerDidStart)

    canceledWaiter.cancel()
    async let repeatedResult = coordinator.prepare(originalInput)
    async let changedResult = coordinator.prepare(changedInput)
    var bothRequestsWereQueued = false
    for _ in 0..<100 {
      if await coordinator.countForTesting() == 2 {
        bothRequestsWereQueued = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(bothRequestsWereQueued)
    let activeWorkerCountWhilePaused = await coordinator.activeWorkerCountForTesting()
    let peakWorkerCountWhilePaused = await coordinator.peakConcurrentWorkerCountForTesting()
    XCTAssertEqual(activeWorkerCountWhilePaused, 1)
    XCTAssertEqual(peakWorkerCountWhilePaused, 1)

    await coordinator.setWorkersPausedForTesting(false)
    let canceledResult = await canceledWaiter.value
    let (repeated, changed) = await (repeatedResult, changedResult)
    XCTAssertNil(canceledResult)
    XCTAssertEqual(try XCTUnwrap(repeated).sourceText, originalInput.sourceText)
    XCTAssertEqual(try XCTUnwrap(changed).sourceText, changedInput.sourceText)
    let preparationCount = await coordinator.countForTesting()
    let finalActiveWorkerCount = await coordinator.activeWorkerCountForTesting()
    let peakWorkerCount = await coordinator.peakConcurrentWorkerCountForTesting()
    XCTAssertEqual(preparationCount, 2)
    XCTAssertEqual(finalActiveWorkerCount, 0)
    XCTAssertEqual(peakWorkerCount, 1)
  }

  func testChatBubbleColdPathUsesBoundedAsyncPlaceholderInsteadOfSynchronousCacheMiss() throws {
    let message = OpenClawChatMessage(
      role: .assistant,
      content: String(repeating: "L", count: 1_694_760)
    )
    let input = OpenClawMessagePresentationInput(message)
    let placeholder = OpenClawMessagePresentationBuilder.placeholder(input)

    XCTAssertLessThanOrEqual(placeholder.body.displayedText.utf8.count, 2 * 1_024)
    XCTAssertTrue(placeholder.body.isTruncated)
    XCTAssertNil(placeholder.body.org)
    XCTAssertFalse(placeholder.body.containsInlineSyntax)

    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/Org2WorkspaceCore/OpenClawChatViews.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let bubbleStart = try XCTUnwrap(source.range(of: "struct ChatBubbleView: View"))
    let bubbleEnd = try XCTUnwrap(
      source.range(of: "private var copyButton: some View", range: bubbleStart.upperBound..<source.endIndex)
    )
    let bubbleBody = source[bubbleStart.lowerBound..<bubbleEnd.lowerBound]
    XCTAssertFalse(bubbleBody.contains("OpenClawMessagePresentationCache.presentation(for: message)"))
    XCTAssertTrue(bubbleBody.contains("OpenClawMessagePresentationResolver(input: presentationInput)"))
    XCTAssertTrue(bubbleBody.contains("allowsSynchronousStructuredPresentationFallback: false"))
  }

  func testColdUserPlaceholderNeverExposesAutomaticContextPromptOrUserExcerpt() {
    let secretPrompt = "PRIVATE-AUTOMATIC-CONTEXT-SENTINEL"
    let userText = "PRIVATE-USER-TEXT-SENTINEL"
    let message = OpenClawChatMessage(
      role: .user,
      content: """
      Use selected file “Private” at notes/private.org as context.
      #+begin_org2_ai_context
      \(secretPrompt)
      #+end_org2_ai_context

      \(userText)
      """
    )
    let placeholder = OpenClawMessagePresentationBuilder.placeholder(
      OpenClawMessagePresentationInput(message)
    )

    XCTAssertTrue(placeholder.context.contexts.isEmpty)
    XCTAssertTrue(placeholder.context.userText.isEmpty)
    XCTAssertTrue(placeholder.body.sourceText.isEmpty)
    XCTAssertEqual(placeholder.body.displayedText, "Preparing message…")
    XCTAssertFalse(placeholder.body.displayedText.contains(secretPrompt))
    XCTAssertFalse(placeholder.body.displayedText.contains(userText))
  }

  func testLiveStreamingPresentationIsSerialOffMainAndNeverFallsBackToSynchronousParsing() async throws {
    let coordinator = OpenClawLiveTextPreparationCoordinator.shared
    await coordinator.resetForTesting()
    await coordinator.setWorkersPausedForTesting(true)
    let streamID = UUID()
    let firstInput = OpenClawLiveTextPreparationInput(
      rawText: "First update",
      showsAll: false
    )
    let obsoleteInput = OpenClawLiveTextPreparationInput(
      rawText: "Obsolete queued update",
      showsAll: false
    )
    let latestInput = OpenClawLiveTextPreparationInput(
      rawText: "Latest update",
      showsAll: false
    )
    let firstTask = Task {
      await coordinator.prepare(streamID: streamID, input: firstInput)
    }
    var firstWorkerDidStart = false
    for _ in 0..<100 {
      if await coordinator.activeWorkerCountForTesting() == 1 {
        firstWorkerDidStart = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(firstWorkerDidStart)
    let obsoleteTask = Task {
      await coordinator.prepare(streamID: streamID, input: obsoleteInput)
    }
    for _ in 0..<100 {
      if await coordinator.countForTesting() == 2 { break }
      await Task.yield()
    }
    let latestTask = Task {
      await coordinator.prepare(streamID: streamID, input: latestInput)
    }
    var allInputsWereScheduled = false
    for _ in 0..<100 {
      if await coordinator.countForTesting() == 3 {
        allInputsWereScheduled = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(allInputsWereScheduled)
    await coordinator.setWorkersPausedForTesting(false)
    let first = await firstTask.value
    let obsolete = await obsoleteTask.value
    let latest = await latestTask.value

    XCTAssertEqual(try XCTUnwrap(try XCTUnwrap(first).body).displayedText, firstInput.rawText)
    XCTAssertNil(obsolete)
    XCTAssertEqual(try XCTUnwrap(try XCTUnwrap(latest).body).displayedText, latestInput.rawText)
    let parserInputs = await coordinator.parserInputsForTestingSnapshot()
    XCTAssertEqual(parserInputs, [firstInput, latestInput])
    let preparationCount = await coordinator.countForTesting()
    let finalActiveWorkerCount = await coordinator.activeWorkerCountForTesting()
    let peakWorkerCount = await coordinator.peakConcurrentWorkerCountForTesting()
    XCTAssertEqual(preparationCount, 3)
    XCTAssertEqual(finalActiveWorkerCount, 0)
    XCTAssertEqual(peakWorkerCount, 1)

    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/Org2WorkspaceCore/OpenClawChatViews.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let viewStart = try XCTUnwrap(source.range(of: "struct OpenClawTypingIndicatorView: View"))
    let viewEnd = try XCTUnwrap(
      source.range(of: "  func statusTitle(now: Date)", range: viewStart.upperBound..<source.endIndex)
    )
    let viewSource = source[viewStart.lowerBound..<viewEnd.lowerBound]
    XCTAssertFalse(viewSource.contains("OpenClawProgressPresentation.liveTextPresentation("))
    XCTAssertTrue(viewSource.contains("Task.sleep(for: .milliseconds(24))"))
    XCTAssertTrue(viewSource.contains("OpenClawLiveTextPreparationCoordinator.shared.prepare"))
    XCTAssertTrue(viewSource.contains("allowsSynchronousStructuredPresentationFallback: false"))
  }

  func testLivePreparationBoundsReasoningActivitiesAndRawDetailsBeforeGrouping() async throws {
    let oversizedDetail = String(repeating: "detail ", count: 200_000)
    let activities = (0..<200).map { index in
      OpenClawRunActivity(
        id: "activity-\(index)",
        runID: "run",
        kind: .tool,
        title: "tool",
        detail: oversizedDetail,
        status: index == 199 ? .running : .succeeded
      )
    }
    let input = OpenClawLiveTextPreparationInput(
      rawText: String(repeating: "stream ", count: 100_000),
      showsAll: false,
      hasOmittedPrefix: true,
      reasoning: String(repeating: "reasoning ", count: 100_000),
      reasoningHasOmittedPrefix: true,
      activities: activities
    )

    XCTAssertEqual(input.activities.count, OpenClawLiveTextPreparationInput.maximumActivityCount)
    XCTAssertTrue(input.activities.allSatisfy {
      ($0.detail?.utf8.count ?? 0)
        <= OpenClawLiveTextPreparationInput.maximumActivityDetailUTF8ByteCount
    })
    let preparedResult = await OpenClawLiveTextPreparationCoordinator.shared.prepare(
      streamID: UUID(),
      input: input
    )
    let prepared = try XCTUnwrap(preparedResult)
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(prepared.body).displayedText.count,
      OpenClawProgressPresentation.maximumLiveNormalizationInputCharacterCount
    )
    XCTAssertLessThanOrEqual(prepared.reasoning?.count ?? .max, 1_200)
    XCTAssertLessThanOrEqual(prepared.activityFeedItems.count, input.activities.count)
  }

  func testLiveTypingViewReadsOneBoundedSnapshotAndNeverMaterializesFullRopes() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/Org2WorkspaceCore/OpenClawChatViews.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "struct OpenClawLiveTypingIndicatorView: View"))
    let end = try XCTUnwrap(source.range(
      of: "struct OpenClawLiveTextPreparationInput",
      range: start.upperBound..<source.endIndex
    ))
    let viewSource = source[start.lowerBound..<end.lowerBound]

    XCTAssertEqual(viewSource.components(separatedBy: "presentationSnapshot(for:").count - 1, 1)
    XCTAssertFalse(viewSource.contains("streamingReply(for:"))
    XCTAssertFalse(viewSource.contains("reasoning(for:"))
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

  func testActivityPulseRunsOnCoreAnimationInsteadOfSwiftUIFrameClock() {
    let view = CoreAnimationActivityDotNSView(frame: NSRect(x: 0, y: 0, width: 5, height: 5))

    view.configure(animates: true, color: .controlAccentColor)
    XCTAssertTrue(view.isAnimatingForTesting)

    view.configure(animates: false, color: .controlAccentColor)
    XCTAssertFalse(view.isAnimatingForTesting)
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

  func testChatThreadSwitchDoesNotRequestAutomaticScrolling() {
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

    XCTAssertNil(next.automaticTarget(after: previous))
  }

  func testChatActivityWithinAThreadStillRequestsAutomaticScrolling() {
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

    XCTAssertEqual(appended.automaticTarget(after: idle), .latestMessage)
    XCTAssertEqual(sending.automaticTarget(after: appended), .typingIndicator)
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
        AIChatThreadSearchMatch(
          messageID: first.id,
          scrollTargetID: first.id,
          rawMessageIndex: 0,
          anchorRawMessageIndex: 0
        ),
        AIChatThreadSearchMatch(
          messageID: second.id,
          scrollTargetID: second.id,
          rawMessageIndex: 1,
          anchorRawMessageIndex: 1
        ),
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

  func testThreadFindComputesBoundedExpandedPageForLateLargeMessageMatch() async throws {
    let pageLimit = OpenClawExpandedMessageBodyInput.pageCharacterLimit
    let message = OpenClawChatMessage(
      role: .assistant,
      content: String(repeating: "x", count: pageLimit + 100)
        + " LATE-FIND-SENTINEL"
    )
    let inputs = [AIChatThreadSearchMessageInput(message)]
    let matches = await Task.detached {
      let candidates = AIChatThreadSearch.candidates(
        in: inputs,
        isSharedRoom: false
      )
      return AIChatThreadSearch.matches(query: "LATE-FIND-SENTINEL", in: candidates)
    }.value

    let match = try XCTUnwrap(matches.first)
    XCTAssertEqual(match.messageID, message.id)
    XCTAssertEqual(match.expandedBodyPageIndex, 1)
  }

  func testThreadFindProjectsLargeTranscriptInsideDetachedWorker() async throws {
    let messages = (0..<8_000).map { index in
      OpenClawChatMessage(
        role: index.isMultiple(of: 2) ? .user : .assistant,
        content: index == 7_999 ? "LATE-PROJECTION-SENTINEL" : "Message \(index)",
        attachments: [OpenClawChatAttachment(
          fileName: "attachment-\(index).txt",
          mimeType: "text/plain",
          data: Data()
        )]
      )
    }

    let matches = await Task.detached {
      let candidates = AIChatThreadSearch.candidates(in: messages, isSharedRoom: false)
      return AIChatThreadSearch.matches(query: "LATE-PROJECTION-SENTINEL", in: candidates)
    }.value

    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(matches.first?.rawMessageIndex, 7_999)
  }

  func testLargeSharedRoomTranscriptGroupingRemainsResponsive() {
    var messages: [OpenClawChatMessage] = []
    messages.reserveCapacity(6_000)
    for index in 0..<2_000 {
      let roundID = UUID()
      messages.append(OpenClawChatMessage(
        role: .user,
        content: "Question \(index)",
        audienceDestinationIDs: ["codex", "openclaw"],
        roomRoundID: roundID
      ))
      messages.append(OpenClawChatMessage(
        role: .assistant,
        content: "Codex response \(index)",
        authorDestinationID: "codex",
        roomRoundID: roundID
      ))
      messages.append(OpenClawChatMessage(
        role: .assistant,
        content: "OpenClaw response \(index)",
        authorDestinationID: "openclaw",
        roomRoundID: roundID
      ))
    }

    let startedAt = CFAbsoluteTimeGetCurrent()
    let items = AIChatRoomTranscriptPresentation.items(
      messages: messages,
      isSharedRoom: true
    )
    let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

    XCTAssertEqual(items.count, 2_000)
    XCTAssertLessThan(elapsed, 1)
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

  func testChatScrollGeometryClampsViewportBelowAResizedTranscript() throws {
    let scrollView = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300)
    )
    let transcript = NSView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 350)
    )
    scrollView.documentView = transcript
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 700))

    let constrained = try XCTUnwrap(
      OpenClawChatScrollGeometry.constrainedBounds(in: scrollView)
    )

    XCTAssertEqual(constrained.origin.y, 50, accuracy: 0.5)
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

  func testChatBubblesDeferTextSelectionToTheTranscript() {
    XCTAssertFalse(ChatBubbleView.managesMessageTextSelection)
  }

  func testLongTranscriptLayoutRemainsResponsiveWithUnifiedSelection() {
    let messages = (0..<120).map { index in
      OpenClawChatMessage(
        role: index.isMultiple(of: 2) ? .user : .assistant,
        content: "Message \(index) has enough text to wrap across multiple lines in a typical chat pane. It remains copyable through the message affordance."
      )
    }
    let view = ScrollView {
      OpenClawChatTranscriptStack(spacing: 10) {
        ForEach(messages) { message in
          ChatBubbleView(message: message)
        }
      }
      .textSelection(.enabled)
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

  func testLargeTranscriptWindowOnlyMaterializesNewestPage() {
    let messages = (0..<1_000).map { index in
      OpenClawChatMessage(role: .assistant, content: "Message \(index)")
    }

    let firstWindow = OpenClawChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: OpenClawChatTranscriptWindow.initialLimit
    )

    XCTAssertEqual(firstWindow.visibleItems.count, 24)
    XCTAssertEqual(firstWindow.visibleChatBubbleCount, 24)
    XCTAssertEqual(firstWindow.visibleItems.first?.id, messages[976].id)
    XCTAssertEqual(firstWindow.visibleItems.last?.id, messages[999].id)
    XCTAssertEqual(firstWindow.earlierBatchCount, 40)
    XCTAssertTrue(firstWindow.hasEarlierMessages)
    XCTAssertFalse(firstWindow.contains(messages[0].id))
    XCTAssertTrue(firstWindow.contains(messages[999].id))

    let expandedWindow = OpenClawChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: firstWindow.nextDisplayLimit
    )
    XCTAssertEqual(firstWindow.nextDisplayLimit, 64)
    XCTAssertEqual(expandedWindow.visibleItems.count, 64)
    XCTAssertEqual(expandedWindow.visibleItems.first?.id, messages[936].id)
  }

  func testOffWindowFindRevealUsesCenteredBoundedTranscriptWindow() {
    let messages = (0..<10_000).map { index in
      OpenClawChatMessage(role: .assistant, content: "Message \(index)")
    }
    let targetIndex = 1_234
    let window = OpenClawChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: OpenClawChatTranscriptWindow.maximumDisplayLimit,
      anchor: OpenClawChatTranscriptAnchor(
        itemID: messages[targetIndex].id,
        rawMessageIndex: targetIndex
      )
    )

    XCTAssertTrue(window.contains(messages[targetIndex].id))
    XCTAssertLessThanOrEqual(
      window.visibleChatBubbleCount,
      OpenClawChatTranscriptWindow.maximumDisplayLimit
    )
    XCTAssertEqual(
      window.nextDisplayLimit,
      OpenClawChatTranscriptWindow.maximumDisplayLimit
    )
    XCTAssertNotNil(window.earlierPageAnchor)
  }

  func testSharedRoomWindowBoundsRawGroupingAndDestinationsBeforeMount() {
    var messages: [OpenClawChatMessage] = []
    let destinationIDs = (0..<100).map { "agent-\($0)" }
    for roundIndex in 0..<60 {
      let roundID = UUID()
      messages.append(OpenClawChatMessage(
        role: .user,
        content: "Question \(roundIndex)",
        audienceDestinationIDs: destinationIDs,
        roomRoundID: roundID
      ))
      for destinationID in destinationIDs {
        messages.append(OpenClawChatMessage(
          role: .assistant,
          content: "Response",
          authorDestinationID: destinationID,
          roomRoundID: roundID
        ))
      }
    }

    let window = OpenClawChatTranscriptWindow(
      messages: messages,
      isSharedRoom: true,
      displayLimit: OpenClawChatTranscriptWindow.initialLimit
    )

    XCTAssertLessThanOrEqual(
      window.visibleChatBubbleCount,
      OpenClawChatTranscriptWindow.initialLimit
    )
    XCTAssertTrue(window.hasEarlierMessages)
    XCTAssertTrue(window.visibleItems.allSatisfy {
      $0.visibleChatBubbleCount <= AIChatRoomRoundView.maximumVisibleDestinationCount + 1
    })
    XCTAssertEqual(OpenClawChatTranscriptWindow.maximumRawMessageScanCount, 416)
  }

  func testLargeTranscriptWindowAlsoBoundsDisplayedContentBytes() {
    let largeBody = String(
      repeating: "x",
      count: OpenClawMessageBodyExcerpt.collapsedUTF8ByteLimit * 2
    )
    let messages = (0..<80).map { _ in
      OpenClawChatMessage(role: .assistant, content: largeBody)
    }

    let firstWindow = OpenClawChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: OpenClawChatTranscriptWindow.initialLimit
    )

    XCTAssertEqual(firstWindow.visibleChatBubbleCount, 8)
    XCTAssertEqual(
      firstWindow.displayedContentUTF8ByteCount,
      OpenClawChatTranscriptWindow.initialDisplayedContentUTF8ByteLimit
    )
    XCTAssertEqual(firstWindow.visibleItems.first?.id, messages[72].id)
    XCTAssertEqual(firstWindow.earlierBatchCount, 40)

    let expandedWindow = OpenClawChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: firstWindow.nextDisplayLimit
    )
    XCTAssertEqual(expandedWindow.visibleChatBubbleCount, 48)
    XCTAssertEqual(expandedWindow.visibleItems.first?.id, messages[32].id)
    XCTAssertEqual(
      OpenClawChatTranscriptWindow.displayedContentUTF8ByteLimit(
        forDisplayLimit: firstWindow.nextDisplayLimit
      ),
      OpenClawChatTranscriptWindow.initialDisplayedContentUTF8ByteLimit
        + OpenClawChatTranscriptWindow.pageSize
          * OpenClawMessageBodyExcerpt.collapsedUTF8ByteLimit
    )
  }

  func testLargeTranscriptWindowBoundsExactRowRealization() {
    let messages = (0..<1_000).map { index in
      OpenClawChatMessage(role: .assistant, content: "Message \(index)")
    }
    let window = OpenClawChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: OpenClawChatTranscriptWindow.initialLimit
    )
    let counter = TranscriptLayoutProbeCounter()
    let view = ScrollView {
      OpenClawChatTranscriptStack(spacing: 0) {
        ForEach(window.visibleItems) { _ in
          TranscriptLayoutProbe(counter: counter)
            .frame(height: 24)
        }
      }
    }
    .frame(width: 500, height: 240)
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 240)

    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(counter.realizedRows, 24)
  }

  func testTranscriptUsesExactGeometryForRowsBeyondTheViewport() {
    let counter = TranscriptLayoutProbeCounter()
    let view = ScrollView {
      OpenClawChatTranscriptStack(spacing: 0) {
        ForEach(0..<120, id: \.self) { _ in
          TranscriptLayoutProbe(counter: counter)
            .frame(height: 24)
        }
      }
    }
    .frame(width: 500, height: 240)
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 240)

    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(counter.realizedRows, 120)
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

  func testCodeSnippetClipboardCopiesOnlyTheSnippetBody() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("org2-chat-code-copy-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    XCTAssertTrue(OpenClawMessageClipboard.copyCodeSnippet(
      lines: ["let answer = 42", "print(answer)"],
      to: pasteboard
    ))

    XCTAssertEqual(pasteboard.string(forType: .string), "let answer = 42\nprint(answer)")
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

  func testAssistantTableCellsFillTheTallestWrappedCellInEachRow() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let tableSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/OrgDocumentRenderedBlocks.swift")
    let source = try String(contentsOf: tableSource, encoding: .utf8)

    XCTAssertTrue(
      source.contains(
        """
        .fixedSize(horizontal: false, vertical: true)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                            .background(cellBackground(
        """
      ),
      "Every cell background and divider must fill the GridRow height when a neighboring cell wraps"
    )
  }

  func testAssistantTablesOnlyDrawExplicitOrgHorizontalRules() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let tableSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/OrgDocumentRenderedBlocks.swift")
    let source = try String(contentsOf: tableSource, encoding: .utf8)
    let tableStart = try XCTUnwrap(source.range(of: "private struct RenderedTableView: View"))
    let tableEnd = try XCTUnwrap(
      source.range(of: "private struct RenderedTableAvailableWidthKey", range: tableStart.upperBound..<source.endIndex)
    )
    let renderedTableSource = source[tableStart.lowerBound..<tableEnd.lowerBound]

    XCTAssertFalse(
      renderedTableSource.contains(".overlay(alignment: .bottom)"),
      "Cell rows must not paint implicit horizontal dividers through AI chat table text"
    )
    XCTAssertFalse(
      renderedTableSource.contains("Divider()"),
      "Table cell separators must declare a vertical shape instead of relying on Divider orientation"
    )
    XCTAssertTrue(
      renderedTableSource.contains(".frame(width: 1)"),
      "Table columns should retain an explicitly vertical separator"
    )
    XCTAssertTrue(
      renderedTableSource.contains("case .separator:"),
      "Explicit Org table hlines should remain visible"
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

  func testChatAttachmentPreviewClassifiesImagesPDFsAndTextDocuments() throws {
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
    XCTAssertEqual(
      OpenClawAttachmentPresentation.decodedText(data: try text.loadData()),
      "name,value\nalpha,1"
    )
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

    let omittedSentinel = "OMITTED-LARGE-REASONING-SENTINEL"
    let largeReasoning = String(repeating: "Working through bounded context. ", count: 100_000)
      + omittedSentinel
    let bounded = OpenClawProgressPresentation.reasoningText(from: largeReasoning)
    XCTAssertEqual(OpenClawProgressPresentation.maximumReasoningInputUTF8ByteCount, 8 * 1_024)
    XCTAssertLessThanOrEqual(bounded?.count ?? .max, 1_200)
    XCTAssertTrue(bounded?.hasSuffix("…") == true)
    XCTAssertFalse(bounded?.contains(omittedSentinel) == true)
    XCTAssertNil(OpenClawProgressPresentation.reasoningText(
      from: "{\"results\":[" + String(repeating: "0,", count: 100_000) + "0]}"
    ))
    XCTAssertFalse(OpenClawProgressPresentation.containsNonWhitespace(
      String(repeating: " \n\t", count: 100_000)
    ))
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

  func testLiveProgressPresentationComputesTextAndDisclosureTogether() throws {
    let progress = "First update.\n\nSecond update."
    let presentation = try XCTUnwrap(
      OpenClawProgressPresentation.liveTextPresentation(from: progress, showsAll: false)
    )

    XCTAssertEqual(presentation.text, "Second update.")
    XCTAssertTrue(presentation.hasEarlierText)
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
