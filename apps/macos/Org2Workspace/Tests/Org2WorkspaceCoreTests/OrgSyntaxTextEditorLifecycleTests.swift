import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class OrgSyntaxTextEditorLifecycleTests: XCTestCase {
  func testImmediateDismantleCheckpointsPendingLargeDocumentEditOffMain() async {
    let original = largeSourceText()
    var boundText = original
    var ownerDraft: String?
    var ownerIsEditing = true
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false,
      onLocalTextChange: { text in
        guard ownerIsEditing else { return }
        ownerDraft = text
      }
    )
    let mounted = mount(editor, text: original)

    applyInsertion("x", to: mounted.textView, coordinator: mounted.coordinator)

    XCTAssertTrue(mounted.coordinator.hasUnpublishedLocalText)
    XCTAssertEqual(mounted.coordinator.fullDocumentSnapshotCount, 0)
    OrgSyntaxTextEditor.dismantleNSView(
      mounted.scrollView,
      coordinator: mounted.coordinator
    )

    XCTAssertEqual(mounted.coordinator.mainActorFullDocumentSnapshotCount, 0)
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()

    XCTAssertTrue(boundText.hasSuffix("x"))
    XCTAssertEqual(ownerDraft, boundText)
    XCTAssertEqual(mounted.coordinator.fullDocumentSnapshotCount, 1)
    XCTAssertEqual(mounted.coordinator.mainActorFullDocumentSnapshotCount, 0)
    XCTAssertFalse(mounted.coordinator.hasUnpublishedLocalText)
    XCTAssertNil(mounted.textView.delegate)
    ownerIsEditing = false
  }

  func testOwnerFlushBridgePreservesDraftBeforeNavigationResetsOwnerState() {
    let original = largeSourceText()
    var interactionText = original
    var ownerDraft: String?
    var ownerIsEditing = true
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { interactionText },
        set: { interactionText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false,
      onLocalTextChange: { text in
        // Mirrors WorkspaceStore.noteSourceEditorLocalTextChanged, which
        // deliberately ignores writes after edit state has been reset.
        guard ownerIsEditing else { return }
        ownerDraft = text
      }
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }

    applyInsertion("x", to: mounted.textView, coordinator: mounted.coordinator)
    XCTAssertTrue(OrgSyntaxTextEditorLifecycle.hasPendingTextChanges)

    // This is the required first line of an owner navigation/reset path.
    XCTAssertEqual(OrgSyntaxTextEditorLifecycle.flushPendingTextChanges(), 1)
    ownerIsEditing = false
    interactionText = "replacement document"

    XCTAssertTrue(ownerDraft?.hasSuffix("x") == true)
    XCTAssertEqual(mounted.coordinator.fullDocumentSnapshotCount, 1)
    XCTAssertFalse(mounted.coordinator.hasUnpublishedLocalText)
    XCTAssertFalse(OrgSyntaxTextEditorLifecycle.hasPendingTextChanges)
  }

  func testOwnerPublicationBarrierCapturesLatestTextWithoutInvokingSaveOrNavigation() async {
    let original = largeSourceText(lineCount: 80_000)
    var boundText = original
    var ownerDraft: String?
    var navigationCheckpointCount = 0
    var saveCount = 0
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false,
      onLocalTextChange: { ownerDraft = $0 },
      documentIdentity: "owner-publication-test",
      onCheckpointText: { _ in navigationCheckpointCount += 1 },
      onSaveCommand: { _ in
        saveCount += 1
        return true
      }
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }

    applyInsertion(" latest", to: mounted.textView, coordinator: mounted.coordinator)
    XCTAssertEqual(OrgSyntaxTextEditorLifecycle.publishPendingTextChanges(), 1)
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()

    XCTAssertTrue(boundText.hasSuffix(" latest"))
    XCTAssertEqual(ownerDraft, boundText)
    XCTAssertEqual(navigationCheckpointCount, 0)
    XCTAssertEqual(saveCount, 0)
    XCTAssertEqual(mounted.coordinator.mainActorFullDocumentSnapshotCount, 0)
  }

  func testSameDocumentCheckpointsCannotCompleteOutOfRevisionOrder() async throws {
    let original = largeSourceText(lineCount: 80_000)
    var firstBinding = original
    var secondBinding = original
    var delivered: [String] = []
    let identity = "ordered-checkpoint-document"
    let first = mount(OrgSyntaxTextEditor(
      text: Binding(get: { firstBinding }, set: { firstBinding = $0 }),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false,
      documentIdentity: identity,
      onCheckpointText: { delivered.append($0) }
    ), text: original)
    let second = mount(OrgSyntaxTextEditor(
      text: Binding(get: { secondBinding }, set: { secondBinding = $0 }),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false,
      documentIdentity: identity,
      onCheckpointText: { delivered.append($0) }
    ), text: original)
    let gate = OrderedEditorCheckpointGate()
    let firstDraft = original + " first"
    let secondDraft = original + " second"
    first.coordinator.checkpointSnapshotForTesting = { capture in
      await gate.holdFirst(OrgSyntaxTextBufferSession.Snapshot(
        text: firstDraft,
        revision: capture.revision
      ))
    }
    second.coordinator.checkpointSnapshotForTesting = { capture in
      await gate.recordSecond(OrgSyntaxTextBufferSession.Snapshot(
        text: secondDraft,
        revision: capture.revision
      ))
    }

    applyInsertion(" first", to: first.textView, coordinator: first.coordinator)
    first.coordinator.prepareForDismantle(first.textView)
    let firstDeadline = Date().addingTimeInterval(2)
    var firstDidStart = await gate.firstStarted
    while Date() < firstDeadline, !firstDidStart {
      try await Task.sleep(nanoseconds: 5_000_000)
      firstDidStart = await gate.firstStarted
    }
    XCTAssertTrue(firstDidStart)

    applyInsertion(" second", to: second.textView, coordinator: second.coordinator)
    second.coordinator.prepareForDismantle(second.textView)
    try await Task.sleep(nanoseconds: 50_000_000)
    let secondDidStartEarly = await gate.secondStarted
    XCTAssertFalse(
      secondDidStartEarly,
      "A later checkpoint must await the earlier checkpoint for the same document"
    )

    await gate.releaseFirst()
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()

    XCTAssertEqual(delivered, [firstDraft, secondDraft])
    XCTAssertEqual(firstBinding, firstDraft)
    XCTAssertEqual(secondBinding, secondDraft)
  }

  func testPassiveResignCheckpointsLargeDraftOffMain() async {
    let original = largeSourceText(lineCount: 80_000)
    var boundText = original
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }
    applyInsertion("x", to: mounted.textView, coordinator: mounted.coordinator)

    let startedAt = CACurrentMediaTime()
    mounted.coordinator.requestLifecycleCheckpoint(from: mounted.textView)
    let synchronousElapsed = CACurrentMediaTime() - startedAt

    XCTAssertLessThan(synchronousElapsed, 1.0 / 60.0)
    XCTAssertEqual(mounted.coordinator.mainActorFullDocumentSnapshotCount, 0)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, !boundText.hasSuffix("x") {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(boundText.hasSuffix("x"))
    XCTAssertEqual(mounted.coordinator.fullDocumentSnapshotCount, 1)
    XCTAssertEqual(mounted.coordinator.mainActorFullDocumentSnapshotCount, 0)
  }

  func testSameSizeExternalReplacementPublishesOutgoingDraftThenAcceptsReplacement() async {
    let original = largeSourceText()
    var boundText = original
    var bindingWrites: [String] = []
    var ownerDraft: String?
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: {
          boundText = $0
          bindingWrites.append($0)
        }
      ),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false,
      onLocalTextChange: { ownerDraft = $0 }
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }

    let replacementRange = NSRange(
      location: (mounted.textView.textStorage?.length ?? 1) - 1,
      length: 1
    )
    applyReplacement(
      "x",
      range: replacementRange,
      to: mounted.textView,
      coordinator: mounted.coordinator
    )
    let outgoingDraft = mounted.textView.string
    let externalText = String(repeating: "z", count: (original as NSString).length)
    XCTAssertEqual((externalText as NSString).length, (original as NSString).length)

    // Model an owner update without going through the editor Binding setter.
    boundText = externalText
    XCTAssertTrue(mounted.coordinator.hasExternalBoundTextChange(externalText))
    let resolvedDraft = mounted.coordinator.resolvePendingLocalText(
      beforeApplyingExternalText: externalText,
      from: mounted.textView
    )

    // Large drafts are captured synchronously by revision, then materialized
    // away from the main actor before the authoritative replacement proceeds.
    XCTAssertNil(resolvedDraft)
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()
    XCTAssertEqual(ownerDraft, outgoingDraft)
    XCTAssertTrue(bindingWrites.isEmpty)
    XCTAssertEqual(boundText, externalText)
    XCTAssertFalse(mounted.coordinator.hasUnpublishedLocalText)
    XCTAssertEqual(mounted.coordinator.fullDocumentSnapshotCount, 1)
  }

  func testCleanDismantleDoesNotSnapshotLargeDocument() {
    let original = largeSourceText()
    var boundText = original
    var bindingWriteCount = 0
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: {
          boundText = $0
          bindingWriteCount += 1
        }
      ),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false
    )
    let mounted = mount(editor, text: original)

    OrgSyntaxTextEditor.dismantleNSView(
      mounted.scrollView,
      coordinator: mounted.coordinator
    )

    XCTAssertEqual(mounted.coordinator.fullDocumentSnapshotCount, 0)
    XCTAssertEqual(bindingWriteCount, 0)
    XCTAssertEqual(boundText, original)
  }

  func testLargeScrollingEditorUsesViewportHighlightingWithoutResettingFarStorage() {
    let original = largeSourceText()
    var boundText = original
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      showsScrollers: true,
      liveHighlighting: true,
      incrementalHighlighting: true
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }
    let sentinel = NSAttributedString.Key("OrgSyntaxTextEditorLifecycleTests.sentinel")
    let finalRange = NSRange(
      location: (mounted.textView.textStorage?.length ?? 1) - 1,
      length: 1
    )
    mounted.textView.textStorage?.addAttribute(sentinel, value: true, range: finalRange)

    mounted.coordinator.applyHighlighting(to: mounted.textView)

    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldUseViewportOnlyHighlighting(
      utf16Length: original.utf16.count,
      showsScrollers: true
    ))
    XCTAssertEqual(
      mounted.textView.textStorage?.attribute(sentinel, at: finalRange.location, effectiveRange: nil) as? Bool,
      true,
      "Opening a large scrolling file must not reset attributes across the full storage"
    )
    XCTAssertEqual(mounted.coordinator.fullDocumentSnapshotCount, 0)
  }

  func testLargeDocumentSemanticFallbackStartsAfterIdle() {
    XCTAssertEqual(
      OrgSyntaxTextEditor.Coordinator.initialSemanticAnalysisDelayMilliseconds(
        utf16Length: 4_000_000,
        configuredDelayMilliseconds: 900
      ),
      900
    )
    XCTAssertEqual(
      OrgSyntaxTextEditor.Coordinator.initialSemanticAnalysisDelayMilliseconds(
        utf16Length: 4_000_000,
        configuredDelayMilliseconds: 0
      ),
      OrgSyntaxTextEditor.Coordinator.largeDocumentInitialSemanticIdleDelayMilliseconds
    )
    XCTAssertEqual(
      OrgSyntaxTextEditor.Coordinator.initialSemanticAnalysisDelayMilliseconds(
        utf16Length: 4_000,
        configuredDelayMilliseconds: 900
      ),
      0
    )
  }

  func testVisibleCaretLineLookupUsesIndexWithoutDocumentSnapshot() {
    let original = largeSourceText(lineCount: 100_000)
    var boundText = original
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }

    let line = mounted.coordinator.sourceLine(
      atUTF16Offset: max(0, (original as NSString).length - 1),
      in: mounted.textView
    )

    XCTAssertEqual(line, 100_000)
    XCTAssertEqual(mounted.coordinator.fullDocumentSnapshotCount, 0)
  }

  func testStaleLargeSemanticCommandDefersWithoutSnapshotOrScan() {
    let original = largeSourceText(lineCount: 100_000)
    var boundText = original
    var commandStatus: String?
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      orgWritingCommands: true,
      onCommandStatus: { commandStatus = $0 }
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }
    let textLength = mounted.textView.textStorage?.length ?? 0
    mounted.textView.setSelectedRange(NSRange(location: max(0, textLength - 1), length: 0))

    let startedAt = CACurrentMediaTime()
    XCTAssertTrue(mounted.coordinator.performSourceEditorCommand(
      .toggleFold,
      in: mounted.textView
    ))
    let elapsed = CACurrentMediaTime() - startedAt

    XCTAssertLessThan(elapsed, 1.0 / 60.0)
    XCTAssertEqual(commandStatus, "Source structure is still being analyzed; try again shortly")
    XCTAssertEqual(mounted.textView.textStorage?.length, textLength)
    XCTAssertEqual(mounted.coordinator.fullDocumentSnapshotCount, 0)
    XCTAssertEqual(mounted.coordinator.mainActorFullDocumentSnapshotCount, 0)
  }

  func testDeepCursorStructuralCommandUsesLineIndexAndMutableStorage() {
    let original = largeSourceText(lineCount: 100_000)
    var boundText = original
    var commandStatus: String?
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      orgWritingCommands: true,
      onCommandStatus: { commandStatus = $0 }
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }
    let storage = try! XCTUnwrap(mounted.textView.textStorage?.mutableString)
    let finalHeading = storage.range(of: "* Heading", options: .backwards)
    XCTAssertNotEqual(finalHeading.location, NSNotFound)
    mounted.textView.setSelectedRange(NSRange(location: finalHeading.location, length: 0))

    let lookupIndex = OrgSourceLineIndex(text: storage)
    let lookupStartedAt = CACurrentMediaTime()
    let indexedReplacement = OrgSourceTextEditing.todoCycleReplacement(
      in: storage,
      selectedRange: mounted.textView.selectedRange(),
      snapshot: nil,
      lineIndex: lookupIndex
    )
    let lookupElapsed = CACurrentMediaTime() - lookupStartedAt
    XCTAssertNotNil(indexedReplacement)
    XCTAssertLessThan(
      lookupElapsed,
      1.0 / 60.0,
      "Deep structural lookup must fit within one frame independent of cursor depth"
    )

    let startedAt = CACurrentMediaTime()
    XCTAssertTrue(mounted.coordinator.performSourceEditorCommand(
      .cycleTodo,
      in: mounted.textView
    ))
    let elapsed = CACurrentMediaTime() - startedAt

    XCTAssertLessThan(
      elapsed,
      0.1,
      "End-to-end command dispatch must remain bounded even when debug AppKit relayout is included"
    )
    XCTAssertEqual(commandStatus, "Cycle TODO")
    XCTAssertEqual(
      storage.substring(with: NSRange(location: finalHeading.location, length: 14)),
      "* TODO Heading"
    )
    XCTAssertEqual(mounted.coordinator.fullDocumentSnapshotCount, 0)
    XCTAssertEqual(mounted.coordinator.mainActorFullDocumentSnapshotCount, 0)
  }

  func testLargeFoldAndAutomaticUnfoldReuseCurrentSemanticsAndLineIndex() {
    let original = largeSourceText(lineCount: 100_000)
    var boundText = original
    var commandStatus: String?
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      orgWritingCommands: true,
      onCommandStatus: { commandStatus = $0 }
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }
    let finalHeadingLine = 99_999
    let finalHeadingOffset = (mounted.textView.textStorage?.mutableString.range(
      of: "* Heading",
      options: .backwards
    ).location) ?? 0
    mounted.coordinator.installSemanticSnapshotForTesting(
      OrgSourceEditorSemanticSnapshot(regions: [
        OrgSourceSemanticRegion(
          kind: .headline,
          startLine: finalHeadingLine,
          endLine: 100_000,
          level: 1,
          todo: nil
        )
      ])
    )
    mounted.textView.setSelectedRange(NSRange(location: finalHeadingOffset, length: 0))

    XCTAssertTrue(mounted.coordinator.performSourceEditorCommand(
      .toggleFold,
      in: mounted.textView
    ))
    XCTAssertEqual(commandStatus, "Collapsed source heading")

    let bodyRange = mounted.textView.textStorage?.mutableString.range(
      of: "Body with enough text for the large editor lifecycle path.",
      options: .backwards
    ) ?? NSRange(location: finalHeadingOffset, length: 0)
    mounted.textView.setSelectedRange(NSRange(location: bodyRange.location, length: 0))
    mounted.coordinator.textViewDidChangeSelection(Notification(
      name: NSTextView.didChangeSelectionNotification,
      object: mounted.textView
    ))

    XCTAssertEqual(commandStatus, "Expanded source heading for editing")
    XCTAssertEqual(mounted.coordinator.fullDocumentSnapshotCount, 0)
    XCTAssertEqual(mounted.coordinator.mainActorFullDocumentSnapshotCount, 0)
  }

  func testLargeSemanticPresentationAppliesOnlyVisibleViewport() {
    let original = largeSourceText(lineCount: 100_000)
    var boundText = original
    let editor = OrgSyntaxTextEditor(
      text: Binding(get: { boundText }, set: { boundText = $0 }),
      showsScrollers: true,
      liveHighlighting: false
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }
    let regions = stride(from: 1, through: 100_000, by: 2).map { line in
      OrgSourceSemanticRegion(
        kind: .properties,
        startLine: line,
        endLine: line,
        level: nil,
        todo: nil
      )
    }
    mounted.coordinator.installSemanticSnapshotForTesting(
      OrgSourceEditorSemanticSnapshot(regions: regions)
    )

    let startedAt = CACurrentMediaTime()
    mounted.coordinator.refreshSemanticPresentationForTesting(in: mounted.textView)
    let elapsed = CACurrentMediaTime() - startedAt

    XCTAssertLessThan(elapsed, 0.1)
    XCTAssertLessThan(
      mounted.coordinator.semanticPresentationRangeCountForTesting,
      500,
      "Semantic completion must not install temporary attributes across the full document"
    )
  }

  func testLargeViewportLineLookupDefersUntilBackgroundIndexIsReady() {
    let textView = OrgSyntaxTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
    textView.isVerticallyResizable = true
    textView.textContainer?.widthTracksTextView = true
    textView.layoutManager?.allowsNonContiguousLayout = true
    textView.string = largeSourceText(lineCount: 100_000)

    XCTAssertNil(
      OrgSyntaxTextEditor.Coordinator.visibleSourceLine(of: textView),
      "A scroll callback must not synchronously construct a full large-file line index"
    )
  }

  func testEditPreflightWithoutCommitDoesNotChangeMirroredText() {
    var boundText = "alpha"
    let editor = OrgSyntaxTextEditor(text: Binding(
      get: { boundText },
      set: { boundText = $0 }
    ), liveHighlighting: false)
    let mounted = mount(editor, text: boundText)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }

    XCTAssertTrue(mounted.coordinator.textView(
      mounted.textView,
      shouldChangeTextIn: NSRange(location: 0, length: 5),
      replacementString: "discarded"
    ))
    applyInsertion("!", to: mounted.textView, coordinator: mounted.coordinator)

    XCTAssertEqual(boundText, "alpha!")
  }

  func testCommittedSameLengthEditBypassingPreflightUpdatesMirror() {
    var boundText = "alpha"
    let editor = OrgSyntaxTextEditor(text: Binding(
      get: { boundText },
      set: { boundText = $0 }
    ), liveHighlighting: false)
    let mounted = mount(editor, text: boundText)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }

    mounted.textView.textStorage?.replaceCharacters(
      in: NSRange(location: 0, length: 5),
      with: "omega"
    )
    mounted.coordinator.textDidChange(Notification(
      name: NSText.didChangeNotification,
      object: mounted.textView
    ))

    XCTAssertEqual(boundText, "omega")
  }

  func testCommittedUndoRedoStyleEditsBypassingPreflightStayExact() {
    var boundText = "before"
    let editor = OrgSyntaxTextEditor(text: Binding(
      get: { boundText },
      set: { boundText = $0 }
    ), liveHighlighting: false)
    let mounted = mount(editor, text: boundText)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }

    for expected in ["after", "before", "after"] {
      mounted.textView.textStorage?.replaceCharacters(
        in: NSRange(location: 0, length: mounted.textView.textStorage?.length ?? 0),
        with: expected
      )
      mounted.coordinator.textDidChange(Notification(
        name: NSText.didChangeNotification,
        object: mounted.textView
      ))
      XCTAssertEqual(boundText, expected)
    }
  }

  func testMarkedTextCompositionPublishesCommittedStorageState() {
    var boundText = "prefix "
    let editor = OrgSyntaxTextEditor(text: Binding(
      get: { boundText },
      set: { boundText = $0 }
    ), liveHighlighting: false)
    let mounted = mount(editor, text: boundText)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }
    mounted.textView.setSelectedRange(NSRange(location: 7, length: 0))

    mounted.textView.setMarkedText(
      "かな",
      selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    mounted.coordinator.textDidChange(Notification(
      name: NSText.didChangeNotification,
      object: mounted.textView
    ))

    XCTAssertEqual(boundText, mounted.textView.string)
    XCTAssertTrue(boundText.contains("かな"))
  }

  func testAsyncSnapshotCannotOverwriteAChangedOwnerBinding() async throws {
    let original = largeSourceText(lineCount: 80_000)
    var boundText = original
    var bindingGeneration: UInt64 = 0
    var recoveredDraft: String?
    let gate = DeferredEditorSnapshotGate()
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 0),
      liveHighlighting: false,
      incrementalHighlighting: false,
      bindingGeneration: { bindingGeneration },
      onTextPublicationConflict: { recoveredDraft = $0 }
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }
    let outgoingDraft = original + "x"
    mounted.coordinator.deferredTextSnapshotForTesting = {
      await gate.waitForRelease()
    }

    applyInsertion("x", to: mounted.textView, coordinator: mounted.coordinator)
    let deadline = Date().addingTimeInterval(2)
    var snapshotStarted = await gate.hasStarted
    while Date() < deadline, !snapshotStarted {
      try await Task.sleep(nanoseconds: 5_000_000)
      snapshotStarted = await gate.hasStarted
    }
    XCTAssertTrue(snapshotStarted)

    let incoming = String(repeating: "z", count: (original as NSString).length)
    bindingGeneration &+= 1
    boundText = incoming
    await gate.release(OrgSyntaxTextBufferSession.Snapshot(
      text: outgoingDraft,
      revision: 1
    ))

    let recoveryDeadline = Date().addingTimeInterval(2)
    while Date() < recoveryDeadline, recoveredDraft == nil {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertEqual(boundText, incoming)
    XCTAssertEqual(recoveredDraft, outgoingDraft)
    XCTAssertFalse(mounted.coordinator.hasUnpublishedLocalText)
  }

  func testLargeDirtyExternalReplacementCheckpointsWithoutMainActorSnapshot() async throws {
    let original = largeSourceText(lineCount: 80_000)
    var outgoingBoundText = original
    var incomingBoundText = ""
    var recoveredDraft: String?
    var incomingCheckpoint: String?
    let gate = DeferredEditorSnapshotGate()
    let editor = OrgSyntaxTextEditor(
      text: Binding(get: { outgoingBoundText }, set: { outgoingBoundText = $0 }),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false,
      documentIdentity: "outgoing-external-replacement-checkpoint",
      onCheckpointText: { recoveredDraft = $0 }
    )
    let mounted = mount(editor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }
    let exactDraft = original + " local"
    mounted.coordinator.checkpointSnapshotForTesting = { _ in
      await gate.waitForRelease()
    }
    applyInsertion(" local", to: mounted.textView, coordinator: mounted.coordinator)

    let external = String(repeating: "z", count: (original as NSString).length)
    incomingBoundText = external
    let incomingEditor = OrgSyntaxTextEditor(
      text: Binding(get: { incomingBoundText }, set: { incomingBoundText = $0 }),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false,
      documentIdentity: "incoming-external-replacement-checkpoint",
      onCheckpointText: { incomingCheckpoint = $0 }
    )
    let pendingTextOwner = mounted.coordinator.updateParent(incomingEditor)
    let startedAt = CACurrentMediaTime()
    let synchronousDraft = mounted.coordinator.resolvePendingLocalText(
      beforeApplyingExternalText: external,
      from: mounted.textView,
      ownedBy: pendingTextOwner
    )
    let elapsed = CACurrentMediaTime() - startedAt

    XCTAssertNil(synchronousDraft)
    XCTAssertLessThan(elapsed, 1.0 / 60.0)
    XCTAssertEqual(mounted.coordinator.mainActorFullDocumentSnapshotCount, 0)
    let checkpointDeadline = Date().addingTimeInterval(2)
    var checkpointStarted = await gate.hasStarted
    while Date() < checkpointDeadline, !checkpointStarted {
      try await Task.sleep(nanoseconds: 5_000_000)
      checkpointStarted = await gate.hasStarted
    }
    guard checkpointStarted else {
      XCTFail("The detached external-replacement checkpoint did not start")
      return
    }
    await gate.release(OrgSyntaxTextBufferSession.Snapshot(text: exactDraft, revision: 1))
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()
    XCTAssertEqual(recoveredDraft, exactDraft)
    XCTAssertNil(incomingCheckpoint)
    XCTAssertEqual(incomingBoundText, external)
  }

  func testLargeCSVExternalReplacementPreservesDiskAndOutgoingDraftConflict() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-large-csv-external-replacement-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let csv = root.appendingPathComponent("large.csv")
    let rows = (0..<12_000).map { "row-\($0),value-\($0)" }
    let original = (["name,value"] + rows).joined(separator: "\n")
    XCTAssertGreaterThan((original as NSString).length, 64_000)
    try original.write(to: csv, atomically: true, encoding: .utf8)

    let suiteName = "org2-large-csv-external-replacement-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.formatOrgFilesOnSave = false

    let outgoingSource = EntrySource(
      file: csv.path,
      startLine: 1,
      endLineExclusive: rows.count + 2,
      text: original,
      isSubtree: false
    )
    var outgoingBoundText = original
    var outgoingCheckpointCount = 0
    let outgoingEditor = OrgSyntaxTextEditor(
      text: Binding(get: { outgoingBoundText }, set: { outgoingBoundText = $0 }),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false,
      documentIdentity: outgoingSource.id,
      onCheckpointText: { draft in
        outgoingCheckpointCount += 1
        store.persistSourceEditorCheckpoint(draft, source: outgoingSource, kind: "live-file")
      },
      onTextPublicationConflict: { draft in
        store.preserveSourceEditorDraftAfterPublicationConflict(draft, source: outgoingSource)
      }
    )
    let mounted = mount(outgoingEditor, text: original)
    defer {
      OrgSyntaxTextEditor.dismantleNSView(
        mounted.scrollView,
        coordinator: mounted.coordinator
      )
    }

    let localSuffix = "\nlocal-row,local-value"
    applyInsertion(localSuffix, to: mounted.textView, coordinator: mounted.coordinator)
    let exactDraft = original + localSuffix
    XCTAssertTrue(mounted.coordinator.hasUnpublishedLocalText)

    let external = original.replacingOccurrences(of: "row-0,value-0", with: "row-0,remote-value")
    try external.write(to: csv, atomically: true, encoding: .utf8)
    let incomingSource = EntrySource(
      file: csv.path,
      startLine: outgoingSource.startLine,
      endLineExclusive: outgoingSource.endLineExclusive,
      text: external,
      isSubtree: false
    )
    var incomingBoundText = external
    var incomingCheckpointCount = 0
    let incomingEditor = OrgSyntaxTextEditor(
      text: Binding(get: { incomingBoundText }, set: { incomingBoundText = $0 }),
      textPublishing: .deferred(milliseconds: 10_000),
      liveHighlighting: false,
      incrementalHighlighting: false,
      documentIdentity: incomingSource.id,
      onCheckpointText: { draft in
        incomingCheckpointCount += 1
        store.persistSourceEditorCheckpoint(draft, source: incomingSource, kind: "live-file")
      },
      onTextPublicationConflict: { draft in
        store.preserveSourceEditorDraftAfterPublicationConflict(draft, source: incomingSource)
      }
    )

    // This is the representable update ordering that previously replaced the
    // persistence closure before the pending native buffer was captured.
    let pendingTextOwner = mounted.coordinator.updateParent(incomingEditor)
    let resolvedDraft = mounted.coordinator.resolvePendingLocalText(
      beforeApplyingExternalText: external,
      from: mounted.textView,
      ownedBy: pendingTextOwner
    )
    XCTAssertNil(resolvedDraft)

    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()
    let persistenceSucceeded = await store.waitForPendingEditorPersistenceForTesting()

    XCTAssertFalse(persistenceSucceeded)
    XCTAssertEqual(outgoingCheckpointCount, 1)
    XCTAssertEqual(incomingCheckpointCount, 0)
    XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), external)
    XCTAssertEqual(store.failedEditorPersistenceDraftForTesting(file: csv.path), exactDraft)
    XCTAssertEqual(store.editorSaveConflict?.file, csv.path)
    XCTAssertFalse(store.editorSaveConflict?.canOverwrite ?? true)
    XCTAssertEqual(incomingBoundText, external)
  }

  private func mount(
    _ editor: OrgSyntaxTextEditor,
    text: String
  ) -> (
    scrollView: NSScrollView,
    textView: OrgSyntaxTextView,
    coordinator: OrgSyntaxTextEditor.Coordinator
  ) {
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
    let textView = OrgSyntaxTextView(frame: scrollView.bounds)
    textView.isVerticallyResizable = true
    textView.textContainer?.widthTracksTextView = true
    textView.layoutManager?.allowsNonContiguousLayout = true
    textView.string = text
    textView.delegate = coordinator
    scrollView.documentView = textView
    coordinator.attach(to: textView)
    coordinator.recordKnownText(text, utf16Length: textView.textStorage?.length)
    coordinator.resetLineIndex(from: textView)
    return (scrollView, textView, coordinator)
  }

  private func applyInsertion(
    _ replacement: String,
    to textView: NSTextView,
    coordinator: OrgSyntaxTextEditor.Coordinator
  ) {
    applyReplacement(
      replacement,
      range: NSRange(location: textView.textStorage?.length ?? 0, length: 0),
      to: textView,
      coordinator: coordinator
    )
  }

  private func applyReplacement(
    _ replacement: String,
    range: NSRange,
    to textView: NSTextView,
    coordinator: OrgSyntaxTextEditor.Coordinator
  ) {
    XCTAssertTrue(coordinator.textView(
      textView,
      shouldChangeTextIn: range,
      replacementString: replacement
    ))
    textView.textStorage?.replaceCharacters(in: range, with: replacement)
    textView.setSelectedRange(NSRange(
      location: range.location + (replacement as NSString).length,
      length: 0
    ))
    coordinator.textDidChange(Notification(
      name: NSText.didChangeNotification,
      object: textView
    ))
  }

  private func largeSourceText(lineCount: Int = 8_000) -> String {
    String(
      repeating: "* Heading\nBody with enough text for the large editor lifecycle path.\n",
      count: lineCount / 2
    )
  }
}

private actor DeferredEditorSnapshotGate {
  private var continuation: CheckedContinuation<OrgSyntaxTextBufferSession.Snapshot, Never>?
  private(set) var hasStarted = false

  func waitForRelease() async -> OrgSyntaxTextBufferSession.Snapshot {
    hasStarted = true
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func release(_ snapshot: OrgSyntaxTextBufferSession.Snapshot) {
    continuation?.resume(returning: snapshot)
    continuation = nil
  }
}

private actor OrderedEditorCheckpointGate {
  private var firstContinuation: CheckedContinuation<OrgSyntaxTextBufferSession.Snapshot, Never>?
  private var firstSnapshot: OrgSyntaxTextBufferSession.Snapshot?
  private(set) var firstStarted = false
  private(set) var secondStarted = false

  func holdFirst(
    _ snapshot: OrgSyntaxTextBufferSession.Snapshot
  ) async -> OrgSyntaxTextBufferSession.Snapshot {
    firstStarted = true
    firstSnapshot = snapshot
    return await withCheckedContinuation { continuation in
      firstContinuation = continuation
    }
  }

  func recordSecond(
    _ snapshot: OrgSyntaxTextBufferSession.Snapshot
  ) -> OrgSyntaxTextBufferSession.Snapshot {
    secondStarted = true
    return snapshot
  }

  func releaseFirst() {
    guard let firstSnapshot else { return }
    firstContinuation?.resume(returning: firstSnapshot)
    firstContinuation = nil
    self.firstSnapshot = nil
  }
}
