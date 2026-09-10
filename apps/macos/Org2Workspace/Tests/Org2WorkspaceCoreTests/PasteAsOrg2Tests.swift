import AppKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class PasteAsOrg2Tests: XCTestCase {
  func testDisabledCommandDoesNotReadClipboardOrStartConverter() {
    let view = OrgSyntaxTextView()
    view.string = "Unchanged"
    view.pasteAsOrg2(nil)
    XCTAssertNil(view.pastePreviewController)
    XCTAssertEqual(view.string, "Unchanged")
  }

  func testInsertIsUndoableAndOneShot() {
    let (window, view) = editor()
    defer { window.close() }
    let controller = PasteAsOrg2Controller(target: view, text: "2½ cups", html: nil)
    view.pastePreviewController = controller
    controller.isLoading = false
    controller.org = "- 2½ cups"
    XCTAssertTrue(controller.insert())
    XCTAssertEqual(view.string, "Start - 2½ cups end")
    XCTAssertNil(view.pastePreviewController)
    XCTAssertFalse(controller.insert())
    view.undoManager?.undo()
    XCTAssertEqual(view.string, "Start old end")
  }

  func testCancelAndStaleDocumentNeverInsert() {
    let (window, view) = editor()
    defer { window.close() }
    for change in ["cancel", "text", "identity", "setting", "generation", "detach"] {
      view.string = "Start old end"
      view.setSelectedRange(NSRange(location: 6, length: 3))
      view.pasteDocumentIdentity = "a"
      view.pasteAsOrgEnabled = { true }
      view.pasteDocumentGeneration = { 1 }
      window.contentView = view
      let controller = PasteAsOrg2Controller(target: view, text: "new", html: nil)
      controller.isLoading = false
      controller.org = "new"
      switch change {
      case "cancel": controller.cancel()
      case "text": view.string = "Changed elsewhere"
      case "identity": view.pasteDocumentIdentity = "b"
      case "setting": view.pasteAsOrgEnabled = { false }
      case "generation": view.pasteDocumentGeneration = { 2 }
      default: view.removeFromSuperview()
      }
      let before = view.string
      XCTAssertFalse(controller.insert(), change)
      XCTAssertEqual(view.string, before, change)
    }
  }

  func testRealWebKitUsesSemanticHTMLAndPreservesQuantities() async throws {
    let start = ContinuousClock.now
    let result = try await PasteAsOrg2Runtime().convert(
      text: "fallback",
      html: "<h2>Ingredients</h2><ul><li>2½ cups milk</li></ul><script>throw new Error('must not run')</script><img src='https://example.invalid/must-not-fetch'>",
      useModel: true
    )
    XCTAssertEqual(result.org, "** Ingredients\n\n- 2½ cups milk")
    XCTAssertTrue(result.warnings.contains { $0.contains("Non-content") })
    print("PASTE_NATIVE_COLD_SECONDS=\(start.duration(to: .now))")
    let plain = try await PasteAsOrg2Runtime().convert(text: "1½ cans chickpeas\r\n2–3 tbsp oil", html: nil, useModel: true)
    XCTAssertTrue(plain.org.contains("1½ cans chickpeas"))
    XCTAssertTrue(plain.org.contains("2–3 tbsp oil"))
  }

  func testOversizeFailsBeforeWebKitStarts() async {
    do {
      _ = try await PasteAsOrg2Runtime().convert(text: String(repeating: "x", count: 200_001), html: nil, useModel: false)
      XCTFail("Oversize input must fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("200,000"))
    }
  }

  private func editor() -> (NSWindow, OrgSyntaxTextView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = OrgSyntaxTextView(frame: window.contentView!.bounds)
    view.isEditable = true
    view.allowsUndo = true
    window.contentView = view
    view.string = "Start old end"
    view.setSelectedRange(NSRange(location: 6, length: 3))
    view.pasteAsOrgEnabled = { true }
    view.pasteDocumentIdentity = "a"
    return (window, view)
  }
}
