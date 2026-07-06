import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
private var retainedInteractionWindows: [NSWindow] = []

@MainActor
final class OrgEditorInteractionTests: XCTestCase {
  func testTypingHeadingReturnAndParagraphUsesFreshEditorState() async throws {
    let harness = try await makeHarness(initialText: "")

    try await harness.beginAppendingAtEnd()
    try await harness.type("* testing this 123")
    try await harness.pressReturn()
    try await harness.waitForFocusedEditorText("")
    try await harness.type("follow up paragraph")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertEqual(source.components(separatedBy: "* testing this 123").count - 1, 1)
    XCTAssertTrue(source.contains("* testing this 123\n\nfollow up paragraph"))
    XCTAssertEqual(
      harness.store.selectedRenderedBlocks.filter { $0.rawText == "* testing this 123" }.count,
      1
    )
  }

  func testKeyboardHeadingReturnCreatesParagraphAfterHeading() async throws {
    let harness = try await makeHarness(initialText: "")

    try await harness.beginAppendingAtEnd()
    try await harness.typeKeys("* testing")
    try await harness.pressReturnKey()
    try await harness.waitForFocusedEditorText("")
    try await harness.typeKeys("body")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertEqual(source, "* testing\n\nbody")
  }

  func testReturnOnCollapsedHeadingRevealsNewParagraphEditor() async throws {
    let harness = try await makeHarness(initialText: """
    * Current
    Hidden body
    """)

    let headingBlock = try XCTUnwrap(harness.store.selectedRenderedBlocks.first {
      if case .heading = $0.rendered { return true }
      return false
    })
    harness.store.selectBlock(headingBlock)
    XCTAssertTrue(harness.store.collapseSelectedRenderedBlock())

    let headingEditor = try await harness.syntaxTextView(withExactText: "* Current")
    try await harness.focus(
      headingEditor,
      selection: NSRange(location: ("* Current" as NSString).length, length: 0)
    )
    try await harness.pressReturnKey()
    try await harness.waitForFocusedEditorText("")

    let draftID = try XCTUnwrap(harness.store.selectedBlockID)
    XCTAssertEqual(harness.store.editingBlockID, draftID)
    XCTAssertFalse(harness.store.foldedRenderedBlockIDs.contains(headingBlock.id))
    XCTAssertTrue(OrgRenderedFoldTree.visibleBlocks(
      harness.store.selectedRenderedBlocks,
      foldedBlockIDs: harness.store.foldedRenderedBlockIDs
    ).contains { $0.id == draftID })
  }

  func testTypingHeadingReturnAfterExistingParagraphKeepsHeadingAboveBlankEditor() async throws {
    let harness = try await makeHarness(initialText: "Existing paragraph")

    try await harness.beginAppendingAtEnd()
    try await harness.type("* testing")
    try await harness.pressReturn()
    try await harness.waitForFocusedEditorText("")

    let source = try harness.fileText()
    XCTAssertEqual(source, "Existing paragraph\n\n* testing")
    let selectedBlock = try XCTUnwrap(harness.store.selectedBlock)
    XCTAssertEqual(selectedBlock.rawText, "")
    XCTAssertEqual(selectedBlock.startLine, 4)

    let headingEditor = try await harness.syntaxTextView(withExactText: "* testing")
    let blankEditor = try await harness.focusedEditor()
    XCTAssertEqual(blankEditor.string, "")
    let headingFrame = headingEditor.convert(headingEditor.bounds, to: nil)
    let blankFrame = blankEditor.convert(blankEditor.bounds, to: nil)
    XCTAssertGreaterThan(headingFrame.midY, blankFrame.midY)
  }

  func testArrowUpAtStartMovesCaretToEndOfPreviousRenderedBlockAcrossEntries() async throws {
    let harness = try await makeHarness(initialText: """
    * Alpha
    Alpha body
    * Beta
    Beta body
    """)

    let betaHeading = try await harness.syntaxTextView(withExactText: "* Beta")
    try await harness.focus(betaHeading, selection: NSRange(location: 0, length: 0))
    try await harness.pressMoveUp()

    let focused = try await harness.focusedEditor()
    XCTAssertEqual(focused.string, "Alpha body")
    XCTAssertEqual(focused.selectedRange(), NSRange(location: ("Alpha body" as NSString).length, length: 0))
  }

  func testLiveRenderedEditorsDoNotInstallRenderedActivationOverlays() async throws {
    let harness = try await makeHarness(initialText: """
    * Clickable heading
    Clickable paragraph text

    - Clickable list item
    """)

    _ = try await harness.syntaxTextView(withExactText: "* Clickable heading")
    _ = try await harness.syntaxTextView(withExactText: "Clickable paragraph text")
    _ = try await harness.syntaxTextView(withExactText: "Clickable list item")

    XCTAssertFalse(harness.hasViewType(containing: "RenderedRowTextActivationOverlay"))
  }

  func testArrowDownAtEndMovesCaretToNextRenderedBlockAcrossEntries() async throws {
    let harness = try await makeHarness(initialText: """
    * Alpha
    Alpha body
    * Beta
    Beta body
    """)

    let alphaBody = try await harness.syntaxTextView(withExactText: "Alpha body")
    try await harness.focus(alphaBody, selection: NSRange(location: ("Alpha body" as NSString).length, length: 0))
    try await harness.pressMoveDown()

    let focused = try await harness.focusedEditor()
    XCTAssertEqual(focused.string, "* Beta")
    XCTAssertEqual(focused.selectedRange(), NSRange(location: ("* Beta" as NSString).length, length: 0))
  }

  func testLeftRightArrowsCrossRenderedBlockBoundaries() async throws {
    let harness = try await makeHarness(initialText: """
    * Alpha
    Alpha body
    * Beta
    """)

    let alphaBody = try await harness.syntaxTextView(withExactText: "Alpha body")
    let betaHeading = try await harness.syntaxTextView(withExactText: "* Beta")

    try await harness.focus(betaHeading, selection: NSRange(location: 0, length: 0))
    try await harness.pressMoveLeft()

    var focused = try await harness.focusedEditor()
    XCTAssertEqual(focused.string, "Alpha body")
    XCTAssertEqual(focused.selectedRange(), NSRange(location: ("Alpha body" as NSString).length, length: 0))

    try await harness.focus(alphaBody, selection: NSRange(location: ("Alpha body" as NSString).length, length: 0))
    try await harness.pressMoveRight()

    focused = try await harness.focusedEditor()
    XCTAssertEqual(focused.string, "* Beta")
    XCTAssertEqual(focused.selectedRange(), NSRange(location: 0, length: 0))
  }

  func testTypingParagraphReturnCreatesParagraphAfterCurrentText() async throws {
    let harness = try await makeHarness(initialText: "")

    try await harness.beginAppendingAtEnd()
    try await harness.type("alpha")
    try await harness.pressReturn()
    try await harness.waitForFocusedEditorText("")
    try await harness.type("beta")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertEqual(source, "alpha\n\nbeta")
  }

  func testKeyboardParagraphReturnCreatesParagraphAfterCurrentText() async throws {
    let harness = try await makeHarness(initialText: "")

    try await harness.beginAppendingAtEnd()
    try await harness.typeKeys("alpha")
    try await harness.pressReturnKey()
    try await harness.waitForFocusedEditorText("")
    try await harness.typeKeys("beta")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertEqual(source, "alpha\n\nbeta")
  }

  func testKeyboardReturnAtEndOfExistingParagraphCreatesParagraphAfterCurrentText() async throws {
    let harness = try await makeHarness(initialText: "alpha")

    let paragraph = try XCTUnwrap(harness.store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    harness.store.beginEditingBlock(paragraph)
    try await harness.waitForFocusedEditorText("alpha")
    try await harness.pressReturnKey()
    try await harness.waitForFocusedEditorText("")
    try await harness.typeKeys("beta")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertEqual(source, "alpha\n\nbeta")
  }

  func testDirectTypingIntoSelectedParagraphThenReturnKeepsTextOnCurrentLine() async throws {
    let harness = try await makeHarness(initialText: "alpha")

    let paragraph = try XCTUnwrap(harness.store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    harness.store.selectBlock(paragraph)
    try await harness.sendWorkspaceKey("b")
    try await harness.waitForFocusedEditorText("alphab")
    try await harness.pressReturnKey()
    try await harness.waitForFocusedEditorText("")
    try await harness.typeKeys("next")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertEqual(source, "alphab\n\nnext")
  }

  func testDirectTypingIntoSelectedParagraphThenSavePersistsDraft() async throws {
    let harness = try await makeHarness(initialText: "alpha")

    let paragraph = try XCTUnwrap(harness.store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    harness.store.selectBlock(paragraph)
    try await harness.sendWorkspaceKey("b")
    try await harness.waitForFocusedEditorText("alphab")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertEqual(source, "alphab")
  }

  func testCommandSInApprovalBodyPersistsFocusedEditorDraft() async throws {
    let harness = try await makeHarness(initialText: """
    * TODO Approve reply to Maya
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: draft-needs-review
    :END:

    Draft body
    """)
    let item = ApprovalItem(
      title: "Approve reply to Maya",
      status: "draft-needs-review",
      todo: "TODO",
      level: 1,
      file: harness.file.path,
      line: 1,
      idValue: nil,
      properties: [
        "ASSIGNEE": "Avi",
        "STATUS": "draft-needs-review"
      ],
      body: "Draft body",
      tags: []
    )
    harness.store.selectedSurface = .approvals
    harness.store.selectApprovalItem(item)
    try await waitForCondition {
      harness.store.selectedRenderedBlocks.contains { $0.rawText == "Draft body" }
    }

    let bodyEditor = try await harness.syntaxTextView(withExactText: "Draft body")
    try await harness.focus(
      bodyEditor,
      selection: NSRange(location: ("Draft body" as NSString).length, length: 0)
    )
    try await harness.typeKeys(" updated")
    let saveEvent = try XCTUnwrap(harness.keyEvent("s", keyCode: 1, modifiers: .command))
    XCTAssertTrue(bodyEditor.performKeyEquivalent(with: saveEvent))

    try await waitForCondition {
      (try? harness.fileText().contains("Draft body updated")) == true
        && harness.store.editingBlockID == nil
    }
    XCTAssertFalse(try harness.fileText().contains("\nDraft body\n"))
  }

  func testTypingListReturnAndBackspaceMergesLikeDocumentEditing() async throws {
    let harness = try await makeHarness(initialText: "")

    try await harness.beginAppendingAtEnd()
    try await harness.type("- [ ] first task")
    try await harness.pressReturn()
    try await harness.waitForFocusedEditorText("")
    try await harness.type("second task")
    try await harness.saveActiveBlock()

    var source = try harness.fileText()
    XCTAssertTrue(source.contains("- [ ] first task\n- [ ] second task"))

    try await waitForCondition {
      harness.store.selectedRenderedBlocks.contains { block in
        if case .listItem(_, _, .unchecked, let text) = block.rendered {
          return text == "second task"
        }
        return false
      }
    }
    let second = try XCTUnwrap(harness.store.selectedRenderedBlocks.first { block in
      if case .listItem(_, _, .unchecked, let text) = block.rendered {
        return text == "second task"
      }
      return false
    })
    harness.store.beginEditingBlock(second)
    try await harness.waitForFocusedEditorText("second task")
    try await harness.pressDeleteBackwardAtStart()

    try await waitForCondition {
      harness.store.selectedRenderedBlocks.contains { block in
        block.rawText.contains("first task second task")
      }
    }
    source = try harness.fileText()
    XCTAssertTrue(source.contains("- [ ] first task second task"))
  }

  func testKeyboardListReturnCreatesNextItemAfterCurrentText() async throws {
    let harness = try await makeHarness(initialText: "")

    try await harness.beginAppendingAtEnd()
    try await harness.typeKeys("- [ ] first task")
    try await harness.pressReturnKey()
    try await harness.waitForFocusedEditorText("")
    try await harness.typeKeys("second task")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertEqual(source, "- [ ] first task\n- [ ] second task")
  }

  func testDirectTypingIntoSelectedListItemThenReturnKeepsTextOnCurrentItem() async throws {
    let harness = try await makeHarness(initialText: "- [ ] alpha")

    let item = try XCTUnwrap(harness.store.selectedRenderedBlocks.first {
      if case .listItem = $0.rendered { return true }
      return false
    })
    harness.store.selectBlock(item)
    try await harness.sendWorkspaceKey("b")
    try await harness.waitForFocusedEditorText("alphab")
    try await harness.pressReturnKey()
    try await harness.waitForFocusedEditorText("")
    try await harness.typeKeys("next")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertEqual(source, "- [ ] alphab\n- [ ] next")
  }

  func testReturnFromSecondListItemCreatesThirdListItem() async throws {
    let harness = try await makeHarness(initialText: "")

    try await harness.beginAppendingAtEnd()
    try await harness.type("- [ ] first task")
    try await harness.pressReturn()
    try await harness.waitForFocusedEditorText("")
    try await harness.type("second task")
    try await harness.pressReturn()
    try await harness.waitForFocusedEditorText("")
    try await harness.type("third task")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertTrue(source.hasPrefix("- [ ] first task"), source)
    XCTAssertTrue(source.contains("""
    - [ ] first task
    - [ ] second task
    - [ ] third task
    """), source)
    XCTAssertEqual(source.components(separatedBy: "- [ ]").count - 1, 3)
  }

  func testRepeatedReturnKeepsAddingListItemsPastSixthItem() async throws {
    let harness = try await makeHarness(initialText: "")

    try await harness.beginAppendingAtEnd()
    for index in 1...8 {
      if index == 1 {
        try await harness.typeKeys("- [ ] item 1")
      } else {
        try await harness.typeKeys("item \(index)")
      }
      if index < 8 {
        try await harness.pressReturnKey()
        try await harness.waitForFocusedEditorText("")
      }
    }
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    let expected = (1...8).map { "- [ ] item \($0)" }.joined(separator: "\n")
    XCTAssertEqual(source, expected)
  }

  func testReturnFromSixthExistingListItemCreatesSeventhItem() async throws {
    let harness = try await makeHarness(initialText: """
    * Shopping list
    - chicken thighs
    - babybell cheese
    - yellow mustard
    - red cabbage
    - 2 limes
    - star anise
    """)

    let sixthItem = try await harness.syntaxTextView(withExactText: "star anise")
    try await harness.focus(
      sixthItem,
      selection: NSRange(location: ("star anise" as NSString).length, length: 0)
    )
    try await harness.pressReturnKey()
    try await harness.waitForFocusedEditorText("")
    let draftID = try XCTUnwrap(harness.store.selectedBlockID)
    XCTAssertEqual(harness.store.detailScrollRequest?.target, .revealBlock(draftID))
    try await harness.typeKeys("eggs")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertTrue(source.contains("""
    - 2 limes
    - star anise
    - eggs
    """), source)
  }

  func testHeadingReturnRevealsNextParagraphWithoutCenteredScrollJump() async throws {
    let existingText = (1...18)
      .map { "Existing paragraph \($0)" }
      .joined(separator: "\n\n")
    let harness = try await makeHarness(initialText: existingText)

    try await harness.beginAppendingAtEnd()
    try await harness.typeKeys("* New section")
    try await harness.pressReturnKey()
    try await harness.waitForFocusedEditorText("")

    let draftID = try XCTUnwrap(harness.store.selectedBlockID)
    XCTAssertEqual(harness.store.detailScrollRequest?.target, .revealBlock(draftID))
  }

  func testReturnOnEmptyListItemExitsToParagraph() async throws {
    let harness = try await makeHarness(initialText: "")

    try await harness.beginAppendingAtEnd()
    try await harness.type("- [ ] task")
    try await harness.pressReturn()
    try await harness.waitForFocusedEditorText("")
    try await harness.pressReturn()
    try await harness.waitForFocusedEditorText("")
    try await harness.type("after the list")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertTrue(source.hasPrefix("- [ ] task"), source)
    XCTAssertTrue(source.contains("- [ ] task"), source)
    XCTAssertTrue(source.contains("after the list"), source)
    XCTAssertEqual(source.components(separatedBy: "- [ ]").count - 1, 1)
  }

  func testReturnInMiddleOfListItemSplitsTailIntoNextItem() async throws {
    let harness = try await makeHarness(initialText: """
    - [ ] alpha beta
    """)

    let item = try XCTUnwrap(harness.store.selectedRenderedBlocks.first {
      if case .listItem = $0.rendered { return true }
      return false
    })
    harness.store.beginEditingBlock(item)
    try await harness.waitForFocusedEditorText("alpha beta")
    try await harness.setFocusedEditorSelection(NSRange(location: 5, length: 0))
    try await harness.pressReturn()
    try await harness.waitForFocusedEditorText("beta")

    let source = try harness.fileText()
    XCTAssertTrue(source.contains("""
    - [ ] alpha
    - [ ] beta
    """), source)
    XCTAssertEqual(source.components(separatedBy: "- [ ]").count - 1, 2)
  }

  func testTypingOrgLinkPrettyRendersAfterSaveWithoutLosingSource() async throws {
    let harness = try await makeHarness(initialText: "")

    try await harness.beginAppendingAtEnd()
    let rawLink = "[[id:11111111-1111-4111-8111-111111111111][Alice]]"
    try await harness.type("Talk to \(rawLink) tomorrow")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertTrue(source.contains("Talk to \(rawLink) tomorrow"))
    try await waitForCondition {
      harness.store.selectedRenderedBlocks.contains { block in
        if case .paragraph(let text) = block.rendered {
          return text.contains("Alice")
        }
        return false
      }
    }
    let paragraph = try XCTUnwrap(harness.store.selectedRenderedBlocks.first { block in
      if case .paragraph(let text) = block.rendered {
        return text.contains("Alice")
      }
      return false
    })
    XCTAssertEqual(paragraph.rawText, "Talk to \(rawLink) tomorrow")
  }

  func testEditingExistingHeadingThroughRenderedEditorPersistsOnce() async throws {
    let harness = try await makeHarness(initialText: """
    * Old heading
    Body text
    """)

    let heading = try XCTUnwrap(harness.store.selectedRenderedBlocks.first {
      if case .heading = $0.rendered { return true }
      return false
    })
    harness.store.beginEditingBlock(heading)
    try await harness.waitForFocusedEditorText("* Old heading")
    try await harness.selectAllFocusedEditorText()
    try await harness.type("* New heading")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertEqual(source.components(separatedBy: "* New heading").count - 1, 1)
    XCTAssertFalse(source.contains("* Old heading"))
    XCTAssertTrue(source.contains("* New heading\nBody text"))
  }

  func testCrossEditorSelectionSpansHeadingListItemsAndFollowingParagraph() async throws {
    let harness = try await makeHarness(initialText: """
    * Heading
    - [ ] first
    - [ ] second
    After list
    """)

    let heading = try await harness.syntaxTextView(withExactText: "* Heading")
    let followingParagraph = try await harness.syntaxTextView(withExactText: "After list")

    OrgSyntaxTextSelectionBridge.selectTextAcrossEditors(
      anchorView: heading,
      anchorLocation: 0,
      targetView: followingParagraph,
      targetLocation: (followingParagraph.string as NSString).length
    )

    let expected = """
    * Heading
    first
    second
    After list
    """
    XCTAssertEqual(OrgSyntaxTextSelectionBridge.selectedText(containing: heading), expected)
    XCTAssertEqual(harness.nativeSelectedEditorCount(), 0)

    heading.copy(nil)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
  }

  func testMouseDragCrossEditorSelectionDoesNotActivateEveryInlineToolbar() async throws {
    let harness = try await makeHarness(initialText: """
    * Heading
    - [ ] first
    - [ ] second
    After list
    """)

    let heading = try await harness.syntaxTextView(withExactText: "* Heading")
    let followingParagraph = try await harness.syntaxTextView(withExactText: "After list")
    let downEvent = try harness.mouseEvent(.leftMouseDown, at: harness.windowPoint(in: heading, edge: .leading))
    let dragEvent = try harness.mouseEvent(.leftMouseDragged, at: harness.windowPoint(in: followingParagraph, edge: .trailing))

    OrgSyntaxTextSelectionBridge.beginSelection(in: heading, event: downEvent)
    XCTAssertTrue(OrgSyntaxTextSelectionBridge.updateSelection(from: heading, event: dragEvent))
    XCTAssertTrue(OrgSyntaxTextSelectionBridge.endSelection(from: heading))

    let expected = """
    Heading
    first
    second
    After list
    """
    XCTAssertEqual(OrgSyntaxTextSelectionBridge.selectedText(containing: heading), expected)
    XCTAssertEqual(harness.nativeSelectedEditorCount(), 0)
  }

  func testMouseDownTracksSelectionAcrossMultipleRenderedHeadings() async throws {
    let harness = try await makeHarness(initialText: """
    * First heading
    * Second heading
    * Third heading
    """)

    let firstHeading = try await harness.syntaxTextView(withExactText: "* First heading")
    let thirdHeading = try await harness.syntaxTextView(withExactText: "* Third heading")
    let downEvent = try harness.mouseEvent(.leftMouseDown, at: harness.windowPoint(in: firstHeading, edge: .leading))
    let dragEvent = try harness.mouseEvent(.leftMouseDragged, at: harness.windowPoint(in: thirdHeading, edge: .trailing))
    let upEvent = try harness.mouseEvent(.leftMouseUp, at: harness.windowPoint(in: thirdHeading, edge: .trailing))

    harness.window.postEvent(dragEvent, atStart: false)
    harness.window.postEvent(upEvent, atStart: false)
    firstHeading.mouseDown(with: downEvent)

    let expected = """
    First heading
    * Second heading
    * Third heading
    """
    XCTAssertEqual(OrgSyntaxTextSelectionBridge.selectedText(containing: firstHeading), expected)
    XCTAssertEqual(harness.nativeSelectedEditorCount(), 0)

    NSPasteboard.general.clearContents()
    let copyEvent = try XCTUnwrap(harness.keyEvent("c", keyCode: 8, modifiers: .command))
    XCTAssertTrue(firstHeading.performKeyEquivalent(with: copyEvent))
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
  }

  func testMouseDraggedCrossEntrySelectionDeleteRemovesHighlightedText() async throws {
    let harness = try await makeHarness(initialText: """
    * First heading
    * Second heading
    * Third heading
    """)

    let firstHeading = try await harness.syntaxTextView(withExactText: "* First heading")
    let thirdHeading = try await harness.syntaxTextView(withExactText: "* Third heading")
    let downEvent = try harness.mouseEvent(.leftMouseDown, at: harness.windowPoint(in: firstHeading, edge: .leading))
    let dragEvent = try harness.mouseEvent(.leftMouseDragged, at: harness.windowPoint(in: thirdHeading, edge: .trailing))
    let upEvent = try harness.mouseEvent(.leftMouseUp, at: harness.windowPoint(in: thirdHeading, edge: .trailing))

    harness.window.postEvent(dragEvent, atStart: false)
    harness.window.postEvent(upEvent, atStart: false)
    firstHeading.mouseDown(with: downEvent)

    let selectedText = try XCTUnwrap(OrgSyntaxTextSelectionBridge.selectedText(containing: firstHeading))
    XCTAssertTrue(selectedText.contains("First heading"))
    XCTAssertTrue(selectedText.contains("* Second heading"))
    XCTAssertTrue(selectedText.contains("* Third heading"))

    let deleteEvent = try XCTUnwrap(harness.keyEvent("\u{7F}", keyCode: 51))
    firstHeading.keyDown(with: deleteEvent)

    try await waitForCondition {
      (try? harness.fileText()) == "* "
    }
  }

  func testCommandADeleteRemovesRenderedDocumentTextAndBlankLines() async throws {
    let harness = try await makeHarness(initialText: """
    * First heading

    - [ ] task

    * Second heading
    """)

    let firstHeading = try await harness.syntaxTextView(withExactText: "* First heading")
    let selectAllEvent = try XCTUnwrap(harness.keyEvent("a", keyCode: 0, modifiers: .command))
    XCTAssertTrue(firstHeading.performKeyEquivalent(with: selectAllEvent))

    let selectedText = try XCTUnwrap(OrgSyntaxTextSelectionBridge.selectedText(containing: firstHeading))
    XCTAssertTrue(selectedText.contains("* First heading"))
    XCTAssertTrue(selectedText.contains("task"))
    XCTAssertTrue(selectedText.contains("* Second heading"))

    let deleteEvent = try XCTUnwrap(harness.keyEvent("\u{7F}", keyCode: 51))
    firstHeading.keyDown(with: deleteEvent)

    try await waitForCondition {
      (try? harness.fileText()) == ""
    }
    XCTAssertTrue(harness.store.selectedRenderedBlocks.isEmpty)
  }

  func testCommandAThenTypingReplacesRenderedDocumentText() async throws {
    let harness = try await makeHarness(initialText: """
    * First heading
    - [ ] task
    * Second heading
    """)

    let firstHeading = try await harness.syntaxTextView(withExactText: "* First heading")
    let selectAllEvent = try XCTUnwrap(harness.keyEvent("a", keyCode: 0, modifiers: .command))
    XCTAssertTrue(firstHeading.performKeyEquivalent(with: selectAllEvent))

    let replacementEvent = try XCTUnwrap(harness.keyEvent("x", keyCode: 7))
    firstHeading.keyDown(with: replacementEvent)

    try await waitForCondition {
      (try? harness.fileText()) == "x"
    }
    try await waitForCondition {
      harness.store.selectedRenderedBlocks.contains { block in
        if case .paragraph(let text) = block.rendered {
          return text == "x"
        }
        return false
      }
    }
  }

  func testTypingWordReplacesPartialCrossEntrySelectionAndKeepsEditing() async throws {
    let harness = try await makeHarness(initialText: """
    * Alpha entry
    Alpha body
    * Beta entry
    Beta body
    * Gamma entry
    """)

    let firstHeading = try await harness.syntaxTextView(withExactText: "* Alpha entry")
    let secondHeading = try await harness.syntaxTextView(withExactText: "* Beta entry")
    OrgSyntaxTextSelectionBridge.selectTextAcrossEditors(
      anchorView: firstHeading,
      anchorLocation: 5,
      targetView: secondHeading,
      targetLocation: 4
    )

    try await harness.focus(firstHeading, selection: NSRange(location: 0, length: 0))
    try await harness.typeKeys("the")

    try await waitForCondition {
      (try? harness.fileText()) == """
      * Alptheta entry
      Beta body
      * Gamma entry
      """
    }
    let focused = try await harness.focusedEditor()
    XCTAssertEqual(focused.string, "* Alptheta entry")
    XCTAssertEqual(focused.selectedRange(), NSRange(location: ("* Alpthe" as NSString).length, length: 0))
  }

  func testCrossEditorFullSelectionDeleteRemovesSelectedSourceRows() async throws {
    let original = """
    * First heading
    - [ ] task
    * Second heading
    """
    let harness = try await makeHarness(initialText: original)

    let firstHeading = try await harness.syntaxTextView(withExactText: "* First heading")
    let secondHeading = try await harness.syntaxTextView(withExactText: "* Second heading")
    OrgSyntaxTextSelectionBridge.selectTextAcrossEditors(
      anchorView: firstHeading,
      anchorLocation: 0,
      targetView: secondHeading,
      targetLocation: (secondHeading.string as NSString).length
    )

    let deleteEvent = try XCTUnwrap(harness.keyEvent("\u{7F}", keyCode: 51))
    firstHeading.keyDown(with: deleteEvent)

    try await waitForCondition {
      (try? harness.fileText()) == ""
    }
    XCTAssertTrue(harness.store.selectedRenderedBlocks.isEmpty)
    XCTAssertEqual(try harness.latestRecoveryBackupText(), original)
  }

  func testLiveFileEditorBlocksEmptyAutosaveAndCreatesRecoveryBackup() async throws {
    let original = """
    * Today's note
    Body that should not disappear.
    """
    let harness = try await makeHarness(initialText: original)

    XCTAssertTrue(harness.store.isLiveFileEditorSelected)
    harness.store.noteLiveFileEditorTextChanged("")
    await harness.store.saveLiveFileEditor(explicit: false)

    XCTAssertEqual(try harness.fileText(), original)
    XCTAssertEqual(harness.store.liveFileEditorStatusText, "Autosave failed")
    XCTAssertTrue(harness.store.errorText?.contains("would empty") == true)
    XCTAssertEqual(try harness.latestRecoveryBackupText(), original)

    harness.store.revertLiveFileEditor()
  }

  func testPartialCrossEntrySelectionDeleteRemovesHighlightedSourceRange() async throws {
    let harness = try await makeHarness(initialText: """
    * Alpha entry
    Alpha body
    * Beta entry
    Beta body
    * Gamma entry
    """)

    let firstHeading = try await harness.syntaxTextView(withExactText: "* Alpha entry")
    let secondHeading = try await harness.syntaxTextView(withExactText: "* Beta entry")
    OrgSyntaxTextSelectionBridge.selectTextAcrossEditors(
      anchorView: firstHeading,
      anchorLocation: 5,
      targetView: secondHeading,
      targetLocation: 4
    )

    let selectedText = try XCTUnwrap(OrgSyntaxTextSelectionBridge.selectedText(containing: firstHeading))
    XCTAssertEqual(selectedText, """
    ha entry
    Alpha body
    * Be
    """)

    let deleteEvent = try XCTUnwrap(harness.keyEvent("\u{7F}", keyCode: 51))
    firstHeading.keyDown(with: deleteEvent)

    try await waitForCondition {
      (try? harness.fileText()) == """
      * Alpta entry
      Beta body
      * Gamma entry
      """
    }
  }

  func testCrossEntrySelectionDeleteWorksWhenEventArrivesAtUnselectedDocumentEditor() async throws {
    let harness = try await makeHarness(initialText: """
    * Alpha entry
    Alpha body
    * Beta entry
    Beta body
    * Gamma entry
    """)

    let firstHeading = try await harness.syntaxTextView(withExactText: "* Alpha entry")
    let secondHeading = try await harness.syntaxTextView(withExactText: "* Beta entry")
    let thirdHeading = try await harness.syntaxTextView(withExactText: "* Gamma entry")
    OrgSyntaxTextSelectionBridge.selectTextAcrossEditors(
      anchorView: firstHeading,
      anchorLocation: 5,
      targetView: secondHeading,
      targetLocation: 4
    )

    let deleteEvent = try XCTUnwrap(harness.keyEvent("\u{7F}", keyCode: 51))
    thirdHeading.keyDown(with: deleteEvent)

    try await waitForCondition {
      (try? harness.fileText()) == """
      * Alpta entry
      Beta body
      * Gamma entry
      """
    }
  }

  func testSplittingAndMergingParagraphViaReturnAndBackspace() async throws {
    let harness = try await makeHarness(initialText: """
    Alpha beta
    """)

    let paragraph = try XCTUnwrap(harness.store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    harness.store.beginEditingBlock(paragraph)
    try await harness.waitForFocusedEditorText("Alpha beta")
    try await harness.setFocusedEditorSelection(NSRange(location: 5, length: 0))
    try await harness.pressReturn()
    try await harness.waitForFocusedEditorText("beta")

    var source = try harness.fileText()
    XCTAssertTrue(source.contains("Alpha\n\nbeta"))

    try await harness.pressDeleteBackwardAtStart()
    try await waitForCondition {
      (try? harness.fileText().contains("Alpha beta")) == true
    }
    source = try harness.fileText()
    XCTAssertTrue(source.contains("Alpha beta"))
    XCTAssertFalse(source.contains("Alpha\n\nbeta"))
  }

  func testTypingTableThroughInlineEditorPersistsRows() async throws {
    let harness = try await makeHarness(initialText: """
    | Name | Value |
    |------+-------|
    | A    | 1     |
    """)

    let table = try XCTUnwrap(harness.store.selectedRenderedBlocks.first {
      if case .table = $0.rendered { return true }
      return false
    })
    harness.store.beginEditingBlock(table)
    try await harness.replaceTableCell(containing: "Name", with: "Person")
    try await harness.replaceTableCell(containing: "Value", with: "Score")
    try await harness.replaceTableCell(containing: "A", with: "Alice")
    try await harness.replaceTableCell(containing: "1", with: "2")
    try await harness.saveActiveBlock()

    let source = try harness.fileText()
    XCTAssertTrue(source.contains("| Person | Score |"))
    XCTAssertTrue(source.contains("| Alice  | 2     |"))
    guard case .table(let renderedTable) = harness.store.selectedBlock?.rendered else {
      return XCTFail("Expected table block")
    }
    XCTAssertEqual(renderedTable.rows, [
      .cells(["Person", "Score"]),
      .separator,
      .cells(["Alice", "2"])
    ])
  }

  private func makeHarness(
    initialText: String,
    fileName: String = "interaction.org2"
  ) async throws -> EditorInteractionHarness {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-editor-interaction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent(fileName)
    try initialText.write(to: file, atomically: true, encoding: .utf8)

    let defaults = UserDefaults(suiteName: "org2-editor-interaction-\(UUID().uuidString)") ?? .standard
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: file.path,
      relativePath: file.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForCondition {
      !store.selectedRenderedBlocks.isEmpty || initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    let content = ContentView()
      .environmentObject(store)
      .frame(width: 1280, height: 820)
    let hostingView = NSHostingView(rootView: content)
    hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
    let window = NSWindow(
      contentRect: hostingView.frame,
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = hostingView
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.makeKeyAndOrderFront(nil)
    retainedInteractionWindows.append(window)
    try await pumpRunLoop()

    return EditorInteractionHarness(store: store, root: root, file: file, window: window)
  }
}

@MainActor
private struct EditorInteractionHarness {
  let store: WorkspaceStore
  let root: URL
  let file: URL
  let window: NSWindow

  func beginAppendingAtEnd() async throws {
    await store.beginAppendingSectionAtEnd()
    try await waitForFocusedEditorText("")
  }

  func type(_ text: String) async throws {
    for character in text {
      let textView = try await focusedEditor()
      window.makeFirstResponder(textView)
      let scalar = String(character)
      textView.insertText(scalar, replacementRange: textView.selectedRange())
      try await pumpRunLoop()
    }
  }

  func typeKeys(_ text: String) async throws {
    for character in text {
      try await sendKey(String(character), keyCode: Self.keyCode(for: character))
    }
  }

  func pressReturn() async throws {
    let textView = try await focusedEditor()
    window.makeFirstResponder(textView)
    let start = CACurrentMediaTime()
    textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    try await pumpRunLoop()
    let elapsed = CACurrentMediaTime() - start
    XCTAssertLessThan(elapsed, 0.35, "Return handling should not visibly stall")
  }

  func pressReturnKey() async throws {
    let start = CACurrentMediaTime()
    try await sendKey("\r", keyCode: 36)
    let elapsed = CACurrentMediaTime() - start
    XCTAssertLessThan(elapsed, 0.35, "Return handling should not visibly stall")
  }

  func pressMoveUp() async throws {
    try await sendCommand(#selector(NSResponder.moveUp(_:)))
  }

  func pressMoveDown() async throws {
    try await sendCommand(#selector(NSResponder.moveDown(_:)))
  }

  func pressMoveLeft() async throws {
    try await sendCommand(#selector(NSResponder.moveLeft(_:)))
  }

  func pressMoveRight() async throws {
    try await sendCommand(#selector(NSResponder.moveRight(_:)))
  }

  func sendWorkspaceKey(_ characters: String) async throws {
    guard let first = characters.first,
          let event = Self.keyEvent(
            characters,
            keyCode: Self.keyCode(for: first),
            windowNumber: window.windowNumber
          )
    else {
      return XCTFail("Expected workspace key event for \(characters)")
    }
    XCTAssertTrue(store.handleWorkspaceKeyDown(event), "Expected workspace key to be handled")
    try await pumpRunLoop()
  }

  func pressDeleteBackwardAtStart() async throws {
    let textView = try await focusedEditor()
    window.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
    try await pumpRunLoop()
  }

  func focus(_ textView: NSTextView, selection: NSRange) async throws {
    window.makeFirstResponder(textView)
    textView.setSelectedRange(selection)
    try await pumpRunLoop()
  }

  func saveActiveBlock() async throws {
    guard let block = store.selectedBlock else {
      return XCTFail("Expected selected block")
    }
    await store.saveEditedBlock(block)
    try await pumpRunLoop()
  }

  func selectAllFocusedEditorText() async throws {
    let textView = try await focusedEditor()
    window.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
    try await pumpRunLoop()
  }

  func setFocusedEditorSelection(_ range: NSRange) async throws {
    let textView = try await focusedEditor()
    window.makeFirstResponder(textView)
    textView.setSelectedRange(range)
    try await pumpRunLoop()
  }

  func replaceTableCell(containing currentValue: String, with replacement: String) async throws {
    try await waitForCondition {
      allTextFields(in: window.contentView).contains { $0.stringValue == currentValue }
    }
    let textField = try XCTUnwrap(allTextFields(in: window.contentView).first { $0.stringValue == currentValue })
    window.makeFirstResponder(textField)
    try await pumpRunLoop()
    guard let editor = textField.currentEditor() else {
      return XCTFail("Expected active field editor for \(currentValue)")
    }
    editor.selectedRange = NSRange(location: 0, length: (editor.string as NSString).length)
    editor.insertText(replacement)
    try await pumpRunLoop()
  }

  func waitForFocusedEditorText(_ expected: String) async throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if let textView = focusedEditorIfAvailable(),
         textView.string == expected {
        return
      }
      try await pumpRunLoop()
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let editorTexts = allTextViews(in: window.contentView)
      .filter { $0.window != nil && $0.isEditable }
      .map(\.string)
    let renderedBlocks = store.selectedRenderedBlocks
      .map { "\($0.id):\($0.startLine)-\($0.endLineExclusive):\(String(reflecting: $0.rawText))" }
      .joined(separator: ", ")
    XCTFail("""
    Timed out waiting for focused editor text \(String(reflecting: expected)).
    Editors: \(editorTexts.map { String(reflecting: $0) }.joined(separator: ", "))
    Selected block: \(store.selectedBlock?.rawText ?? "<nil>")
    Rendered blocks: \(renderedBlocks)
    Status: \(store.statusText)
    """)
  }

  func focusedEditor() async throws -> NSTextView {
    try await waitForCondition {
      focusedEditorIfAvailable() != nil
    }
    return try XCTUnwrap(focusedEditorIfAvailable())
  }

  func fileText() throws -> String {
    try String(contentsOf: file, encoding: .utf8)
  }

  func latestRecoveryBackupText() throws -> String {
    let backups = try recoveryBackupURLs()
    let latest = try XCTUnwrap(backups.sorted { $0.lastPathComponent < $1.lastPathComponent }.last)
    return try String(contentsOf: latest, encoding: .utf8)
  }

  private func recoveryBackupURLs() throws -> [URL] {
    let directory = file.deletingLastPathComponent().appendingPathComponent(".org2-recovery", isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter { !$0.hasDirectoryPath }
  }

  func syntaxTextView(withExactText text: String) async throws -> OrgSyntaxTextView {
    try await waitForCondition {
      uniqueSyntaxTextViews().contains { $0.string == text }
    }
    return try XCTUnwrap(uniqueSyntaxTextViews().first { $0.string == text })
  }

  func nativeSelectedEditorCount() -> Int {
    uniqueSyntaxTextViews().filter { $0.selectedRange().length > 0 }.count
  }

  func mouseEvent(_ type: NSEvent.EventType, at windowPoint: NSPoint) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(
      with: type,
      location: windowPoint,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: type == .leftMouseDown ? 1 : 0,
      pressure: type == .leftMouseUp ? 0 : 1
    ))
  }

  func keyEvent(
    _ characters: String,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = []
  ) -> NSEvent? {
    Self.keyEvent(characters, keyCode: keyCode, windowNumber: window.windowNumber, modifiers: modifiers)
  }

  enum TextEdge {
    case leading
    case trailing
  }

  func windowPoint(in textView: NSTextView, edge: TextEdge) -> NSPoint {
    let frame = textView.convert(textView.bounds, to: nil)
    switch edge {
    case .leading:
      return NSPoint(x: frame.minX + 2, y: frame.midY)
    case .trailing:
      return NSPoint(x: frame.maxX - 2, y: frame.midY)
    }
  }

  private func focusedEditorIfAvailable() -> NSTextView? {
    let textViews = allTextViews(in: window.contentView)
      .filter { $0.window != nil && $0.isEditable }
    if let focused = textViews.first(where: { $0.window?.firstResponder === $0 }) {
      return focused
    }
    return textViews.last
  }

  private func allTextViews(in view: NSView?) -> [NSTextView] {
    guard let view else { return [] }
    var result: [NSTextView] = []
    if let textView = view as? NSTextView {
      result.append(textView)
    }
    if let scrollView = view as? NSScrollView,
       let documentView = scrollView.documentView {
      result.append(contentsOf: allTextViews(in: documentView))
    }
    for subview in view.subviews {
      result.append(contentsOf: allTextViews(in: subview))
    }
    return result
  }

  func hasViewType(containing text: String) -> Bool {
    allViews(in: window.contentView).contains {
      String(reflecting: Swift.type(of: $0)).contains(text)
    }
  }

  private func allViews(in view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { allViews(in: $0) }
  }

  private func uniqueSyntaxTextViews() -> [OrgSyntaxTextView] {
    var seen = Set<ObjectIdentifier>()
    return allTextViews(in: window.contentView)
      .compactMap { $0 as? OrgSyntaxTextView }
      .filter { textView in
        let identifier = ObjectIdentifier(textView)
        guard !seen.contains(identifier) else { return false }
        seen.insert(identifier)
        return textView.window != nil && textView.isEditable
      }
  }

  private func allTextFields(in view: NSView?) -> [NSTextField] {
    guard let view else { return [] }
    var result: [NSTextField] = []
    if let textField = view as? NSTextField, textField.isEditable {
      result.append(textField)
    }
    for subview in view.subviews {
      result.append(contentsOf: allTextFields(in: subview))
    }
    return result
  }

  private func sendKey(_ characters: String, keyCode: UInt16) async throws {
    let textView = try await focusedEditor()
    window.makeFirstResponder(textView)
    guard let event = Self.keyEvent(characters, keyCode: keyCode, windowNumber: window.windowNumber) else {
      return XCTFail("Expected key event for \(characters)")
    }
    textView.keyDown(with: event)
    try await pumpRunLoop()
  }

  private func sendCommand(_ selector: Selector) async throws {
    let textView = try await focusedEditor()
    window.makeFirstResponder(textView)
    textView.doCommand(by: selector)
    try await pumpRunLoop()
  }

  private static func keyEvent(
    _ characters: String,
    keyCode: UInt16,
    windowNumber: Int,
    modifiers: NSEvent.ModifierFlags = []
  ) -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: windowNumber,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode
    )
  }

  private static func keyCode(for character: Character) -> UInt16 {
    switch character {
    case "a", "A": 0
    case "b", "B": 11
    case "c", "C": 8
    case "d", "D": 2
    case "e", "E": 14
    case "f", "F": 3
    case "g", "G": 5
    case "h", "H": 4
    case "i", "I": 34
    case "j", "J": 38
    case "k", "K": 40
    case "l", "L": 37
    case "m", "M": 46
    case "n", "N": 45
    case "o", "O": 31
    case "p", "P": 35
    case "q", "Q": 12
    case "r", "R": 15
    case "s", "S": 1
    case "t", "T": 17
    case "u", "U": 32
    case "v", "V": 9
    case "w", "W": 13
    case "x", "X": 7
    case "y", "Y": 16
    case "z", "Z": 6
    case "0": 29
    case "1": 18
    case "2": 19
    case "3": 20
    case "4": 21
    case "5": 23
    case "6": 22
    case "7": 26
    case "8": 28
    case "9": 25
    case " ": 49
    case "-": 27
    case "[": 33
    case "]": 30
    default: 0
    }
  }
}

@MainActor
private func waitForCondition(
  timeout: TimeInterval = 5,
  file: StaticString = #filePath,
  line: UInt = #line,
  _ condition: @escaping @MainActor () -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() {
      return
    }
    try await pumpRunLoop()
    try await Task.sleep(nanoseconds: 20_000_000)
  }
  XCTFail("Timed out waiting for condition", file: file, line: line)
}

@MainActor
private func pumpRunLoop() async throws {
  await Task.yield()
  try await Task.sleep(nanoseconds: 20_000_000)
}
