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
    XCTAssertTrue(source.contains("WorkspaceSelectionMarker()"))
  }

  func testOrgSyntaxMarkersStayCompact() {
    XCTAssertEqual(WorkspaceSyntax.selectionMarker, "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 0), "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 1), "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 2), "**")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 8), "***")
    XCTAssertEqual(WorkspaceDesign.selectionMarkerLeadingInset, 4)
    XCTAssertEqual(WorkspaceDesign.selectionMarkerWidth, 14)
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
}
