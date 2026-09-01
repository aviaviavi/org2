import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class ParagraphWikiLinkCompletionPerformanceTests: XCTestCase {
  func testBoundedEditorSelectionSnapshotPreservesAbsoluteReplacementRange() throws {
    let localText = "Earlier context\nWallet rec from [[sarah : Secrid"
    let localLength = (localText as NSString).length
    let localStart = 5_500_000
    let snapshot = OrgSyntaxTextEditorSelectionSnapshot(
      selectedRange: NSRange(location: localStart + localLength, length: 0),
      sourceLine: 90_000,
      localText: localText,
      localTextRange: NSRange(location: localStart, length: localLength)
    )

    let match = try XCTUnwrap(ParagraphWikiLinkCompletion.match(in: snapshot))
    let localOpen = (localText as NSString).range(of: "[[", options: .backwards)

    XCTAssertEqual(match.query, "sarah")
    XCTAssertEqual(match.replacementRange.location, localStart + localOpen.location)
    XCTAssertEqual(match.replacementRange.length, ("[[sarah" as NSString).length)
  }

  func testCompletionSearchDoesNotReachPastBoundedLookbehindWindow() {
    let text = "[[" + String(repeating: "a", count: 5_000)

    XCTAssertNil(ParagraphWikiLinkCompletion.match(
      in: text,
      selectedRange: NSRange(location: (text as NSString).length, length: 0)
    ))
  }
}
