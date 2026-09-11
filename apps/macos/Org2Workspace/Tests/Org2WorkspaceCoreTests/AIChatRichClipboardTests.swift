import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatRichClipboardTests: XCTestCase {
  func testMessageCopyWritesAlignedOrgAndHTMLTable() throws {
    let raw = """
    Costs:

    | Cost item | Monthly | Annual |
    |---+---+---|
    | Hosting | $40,000 | $480,000 |
    | Total | $71,667 | $860,000 |

    A < B & C.
    """
    let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(OpenClawMessageClipboard.copy(.init(role: .assistant, content: raw), to: pasteboard))
    let plain = try XCTUnwrap(pasteboard.string(forType: .string))
    XCTAssertTrue(plain.contains("| Cost item | Monthly | Annual   |"))
    XCTAssertTrue(plain.contains("|-----------+---------+----------|"))
    XCTAssertTrue(plain.contains("| Hosting   | $40,000 | $480,000 |"))
    XCTAssertTrue(plain.hasSuffix("A < B & C."))
    XCTAssertEqual(AIChatRichClipboard.alignedMessage(plain), plain)
    let html = try XCTUnwrap(pasteboard.string(forType: .html))
    XCTAssertTrue(html.contains("<table"))
    XCTAssertTrue(html.contains("<th style="))
    XCTAssertTrue(html.contains("border:1px solid"))
    XCTAssertTrue(html.contains("A &lt; B &amp; C."))
    // AppKit's rich-text importer must recognize actual table cells (as Mail does).
    let rich = try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
    var hasTable = false
    rich.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
      if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { hasTable = true }
    }
    XCTAssertTrue(hasTable)
  }

  func testAlignmentDoesNotRewriteIdenticalSourceBlockContents() {
    let table = "| A | Longer |\n|---+---|\n| x | y |"
    let code = "#+begin_src text\n" + table + "\n#+end_src"
    let result = AIChatRichClipboard.alignedMessage(table + "\n\n" + code)
    XCTAssertTrue(result.hasSuffix(code))
    XCTAssertTrue(result.hasPrefix("| A | Longer |\n|---+--------|"))
    XCTAssertEqual(AIChatRichClipboard.alignedMessage(code), code)
  }

  func testSelectedCellsRetainRowsHeadersAndMessageBoundaries() throws {
    let table = UUID(), message = UUID(), nextMessage = UUID()
    let fragments: [AIChatRichClipboard.Fragment] = [
      .init(text: "Costs", cell: nil, messageID: message),
      .init(text: "Item", cell: .init(tableID: table, row: 0, column: 0, isHeader: true), messageID: message),
      .init(text: "USD", cell: .init(tableID: table, row: 0, column: 1, isHeader: true), messageID: message),
      .init(text: "Hosting", cell: .init(tableID: table, row: 2, column: 0, isHeader: false), messageID: message),
      .init(text: "$40,000", cell: .init(tableID: table, row: 2, column: 1, isHeader: false), messageID: message),
      .init(text: "Next agent", cell: nil, messageID: nextMessage),
    ]
    XCTAssertEqual(AIChatRichClipboard.selectionText(fragments), "Costs\n| Item    | USD     |\n|---------+---------|\n| Hosting | $40,000 |\n\nNext agent")
    let html = AIChatRichClipboard.selectionHTML(fragments)
    XCTAssertEqual(html.components(separatedBy: "<tr>").count - 1, 2)
    XCTAssertTrue(html.contains("</table><div>Next agent</div>"))
    XCTAssertFalse(html.contains("|---"))
  }

}
