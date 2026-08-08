import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceListSelectionTests: XCTestCase {
  func testMainWorkspaceAvoidsUnreadableNativeListSelection() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcesRoot = packageRoot.appendingPathComponent("Sources", isDirectory: true)
    let nativeSelection = try NSRegularExpression(
      pattern: #"\bList\s*\(\s*selection\s*:"#,
      options: []
    )
    let sourceFiles = try XCTUnwrap(
      FileManager.default.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: nil
      )?.allObjects as? [URL]
    )
    var offenders: [String] = []
    for sourceFile in sourceFiles where sourceFile.pathExtension == "swift" {
      let source = try String(contentsOf: sourceFile, encoding: .utf8)
      if nativeSelection.firstMatch(
        in: source,
        options: [],
        range: NSRange(source.startIndex..., in: source)
      ) != nil {
        offenders.append(sourceFile.path.replacingOccurrences(of: packageRoot.path + "/", with: ""))
      }
    }

    XCTAssertTrue(
      offenders.isEmpty,
      "Use readable explicit selection instead of native List selection highlighting: \(offenders.joined(separator: ", "))"
    )
  }

  func testSidebarSelectionAddsVerticalPaddingWithoutChangingOtherLists() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentView = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentView, encoding: .utf8)

    XCTAssertTrue(
      source.contains(
        """
        ReadableListSelectionModifier(
                        isSelected: store.selectedSurface == surface,
                        verticalPadding: 4
                      )
        """
      )
    )
    XCTAssertTrue(source.contains("var verticalPadding: CGFloat = 0"))
    XCTAssertEqual(
      source.components(separatedBy: ".workspaceSelectableRow(").count - 1,
      6,
      "Every selected-row implementation should use the shared gutter and marker chrome"
    )
    XCTAssertFalse(source.contains("WorkspaceSelectionMarker()"))
  }

  func testOrgSyntaxMarkersStayCompact() {
    XCTAssertEqual(WorkspaceSyntax.selectionMarker, "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 0), "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 1), "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 2), "**")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 8), "***")
    XCTAssertEqual(WorkspaceDesign.selectionMarkerGutterWidth, 22)
    XCTAssertEqual(WorkspaceDesign.selectionMarkerVerticalOffset, -1)
  }

  func testSettledThreadDisclosurePreservesTheUsersChoice() {
    XCTAssertFalse(
      OpenClawSettledThreadDisclosure.updated(isExpanded: false, settledThreadCount: 3)
    )
    XCTAssertTrue(
      OpenClawSettledThreadDisclosure.updated(isExpanded: true, settledThreadCount: 4)
    )
    XCTAssertFalse(
      OpenClawSettledThreadDisclosure.updated(isExpanded: true, settledThreadCount: 0)
    )
  }

  func testChatThreadContextMenusStayBoundToTheirOwnRow() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentView = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentView, encoding: .utf8)

    XCTAssertFalse(source.contains("contextualThreadID"))
    XCTAssertFalse(source.contains("contextThread:"))
    XCTAssertTrue(source.contains("rename(thread.id)"))
    XCTAssertTrue(source.contains("OpenClawSidebarThreadContextMenuTarget("))
    XCTAssertTrue(source.contains("NSApp.currentEvent?.type == .rightMouseDown"))
    XCTAssertTrue(source.contains("rename?(threadID)"))
    XCTAssertTrue(source.contains("presenting: renameRequest"))
    XCTAssertTrue(source.contains("let threadID = request.threadID"))
    XCTAssertTrue(source.contains("store.renameOpenClawChatThread(threadID, title: title)"))
    XCTAssertGreaterThanOrEqual(
      source.components(separatedBy: "renameRequest = nil").count - 1,
      2,
      "Both cancel and commit must clear the previous rename request explicitly"
    )
    XCTAssertEqual(
      source.components(separatedBy: #".alert("Rename Thread""#).count - 1,
      0,
      "Thread rows must not each install an alert; SwiftUI can hoist the first pinned row's alert"
    )
    XCTAssertTrue(source.contains("if thread.isSettled"))
  }
}
