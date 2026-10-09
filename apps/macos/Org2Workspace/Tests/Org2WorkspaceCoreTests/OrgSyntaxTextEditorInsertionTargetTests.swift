import AppKit
import XCTest
@testable import Org2WorkspaceCore

/// `/image` inserts its link after a modal picker took focus from the editor.
/// Writing the link into the SwiftUI binding could be overwritten by the
/// focus-loss checkpoint, so imported images were copied but never linked.
/// The link now goes through the text view itself.
@MainActor
final class OrgSyntaxTextEditorInsertionTargetTests: XCTestCase {
  private func makeFocusedEditor(text: String, generation: UInt64 = 1) -> (NSWindow, OrgSyntaxTextView) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    let view = OrgSyntaxTextView(frame: window.contentView!.bounds)
    view.allowsUndo = true
    view.string = text
    view.pasteDocumentGeneration = { generation }
    window.contentView!.addSubview(view)
    XCTAssertTrue(window.makeFirstResponder(view))
    return (window, view)
  }

  func testInsertsTheImageLinkAtTheCaretAfterTheSlashCommandIsRemoved() throws {
    let (window, view) = makeFocusedEditor(text: "- See /image here")
    defer { window.close() }
    let target = try XCTUnwrap(OrgSyntaxTextEditorInsertionTarget.focused())

    XCTAssertTrue(target.replace(NSRange(location: 6, length: 6), with: "", expectedPrefix: "/"))
    XCTAssertEqual(view.string, "- See  here")

    // The picker takes focus while the image is chosen and copied.
    window.makeFirstResponder(nil)
    XCTAssertTrue(target.replace(with: "[[file:attachments/shot.png]]"))
    XCTAssertEqual(view.string, "- See [[file:attachments/shot.png]] here")
    XCTAssertEqual(view.selectedRange(), NSRange(location: 35, length: 0))
    XCTAssertTrue(window.firstResponder === view, "Focus returns to the editor")

    // Outside an event loop both edits share one undo group; either way the
    // link is undoable like typing.
    view.undoManager?.undo()
    XCTAssertFalse(view.string.contains("[[file:"), "Inserting the link is undoable")
  }

  func testRefusesToRemoveTextThatIsNoLongerTheSlashCommand() throws {
    let (window, view) = makeFocusedEditor(text: "- plain text")
    defer { window.close() }
    let target = try XCTUnwrap(OrgSyntaxTextEditorInsertionTarget.focused())
    XCTAssertFalse(target.replace(NSRange(location: 2, length: 5), with: "", expectedPrefix: "/"))
    XCTAssertEqual(view.string, "- plain text")
  }

  func testDoesNotInsertIntoAnotherDocument() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = OrgSyntaxTextView(frame: window.contentView!.bounds)
    view.string = "first document"
    final class Generation { var value: UInt64 = 1 }
    let generation = Generation()
    view.pasteDocumentGeneration = { generation.value }
    window.contentView!.addSubview(view)
    XCTAssertTrue(window.makeFirstResponder(view))
    let target = try XCTUnwrap(OrgSyntaxTextEditorInsertionTarget.focused())

    // The editor switched to a different file while the picker was open.
    generation.value = 2
    view.string = "second document"
    XCTAssertFalse(target.isCurrent)
    XCTAssertFalse(target.replace(with: "[[file:attachments/shot.png]]"))
    XCTAssertEqual(view.string, "second document")
  }
}
