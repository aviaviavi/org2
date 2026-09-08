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

  func testNestedRoundUsesNativeGlyphLayoutForTextAndHighlight() async throws {
    let model = AIChatTranscriptSelectionModel()
    let message = UUID()
    let raw = """
    | Cost item | Monthly | Annual |
    |---+---+---|
    | Hosting | $40,000 | $480,000 |
    | Justin | $15,000 | $180,000 |
    | Alex | $16,667 | $200,000 |
    | Total | $71,667 | $860,000 |

    All figures are approximate, in USD. Excludes Avi’s compensation, transition and legal costs, and shared overhead.
    """
    let root = VStack(alignment: .leading) {
      Text("Agent round").font(.headline)
      VStack(alignment: .leading) {
        Text("Codex   Today at 3:22 PM").foregroundStyle(.secondary)
        OpenClawMessageBodyView(rawText: raw, compact: false, managesTextSelection: false,
          rendersStructuredOrg2: true, structuredPresentation: OpenClawMessageOrgPresentation(raw))
      }.padding(12).background(Color(nsColor: .textBackgroundColor)).padding(10)
    }
    .padding(18)
    .environment(\.aiChatTranscriptSelectionModel, model)
    .environment(\.aiChatTranscriptSelectionMessageID, message)
    .onPreferenceChange(AIChatTranscriptSelectableRegionPreferenceKey.self) { model.updateRegions($0) }
    .coordinateSpace(name: AIChatTranscriptSelectionModel.coordinateSpaceName)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.contentView = nil; window.close() }
    for width: CGFloat in [720, 420, 720] {
      window.setContentSize(.init(width: width, height: 600))
      for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
      let first = try XCTUnwrap(model.regions.first)
      let last = try XCTUnwrap(model.regions.last)
      model.applySelection(from: .init(regionID: first.id, utf16Location: 0), to: .init(regionID: last.id, utf16Location: last.layout.attributedText.length))
      for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
      func nativeViews(_ view: NSView) -> [AIChatTranscriptRenderedText.TextView] {
        (view as? AIChatTranscriptRenderedText.TextView).map { [$0] } ?? view.subviews.flatMap(nativeViews)
      }
      let views = nativeViews(host)
      XCTAssertEqual(views.count, model.regions.count)
      XCTAssertGreaterThan(views.count, 15)
      for view in views {
        let layout = try XCTUnwrap(view.textLayout)
        let region = try XCTUnwrap(model.regions.first { $0.text == layout.text })
        XCTAssertEqual(region.frame.width, view.bounds.width, accuracy: 0.5)
        XCTAssertEqual(layout, region.layout)
        XCTAssertNotNil(layout.attributedText.attribute(.font, at: 0, effectiveRange: nil))
        let kit = layout.makeTextKitLayout(width: view.bounds.width)
        XCTAssertLessThanOrEqual(kit.usedRect.height, view.bounds.height + 1)
      }
      let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
      defer { pasteboard.releaseGlobally() }
      XCTAssertTrue(model.copySelection(to: pasteboard))
      XCTAssertTrue(try XCTUnwrap(pasteboard.string(forType: .string)).contains("| Hosting"))
      XCTAssertTrue(try XCTUnwrap(pasteboard.string(forType: .html)).contains("<table"))
      if width == 720, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/openorg-chat-selection.png"))
      }
    }
  }
}
