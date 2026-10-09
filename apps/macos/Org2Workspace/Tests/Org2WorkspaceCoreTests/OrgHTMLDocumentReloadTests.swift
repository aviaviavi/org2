import XCTest
@testable import Org2WorkspaceCore

/// Saving a file re-renders the page that is already on screen. That reload
/// must keep the current frame and scroll offset instead of flashing.
final class OrgHTMLDocumentReloadTests: XCTestCase {
  func testReRenderingTheSameFileKeepsTheCurrentFrame() {
    XCTAssertEqual(
      OrgHTMLDocumentReloadStyle.style(
        loadedSourceFile: "daily/2026-10-09.org",
        nextSourceFile: "daily/2026-10-09.org",
        hasLoadedPage: true
      ),
      .preservingFrame
    )
  }

  func testOpeningAnotherFileOrTheFirstLoadIsFresh() {
    XCTAssertEqual(
      OrgHTMLDocumentReloadStyle.style(
        loadedSourceFile: "daily/2026-10-09.org",
        nextSourceFile: "notes/other.org",
        hasLoadedPage: true
      ),
      .fresh
    )
    XCTAssertEqual(
      OrgHTMLDocumentReloadStyle.style(
        loadedSourceFile: nil,
        nextSourceFile: "notes/other.org",
        hasLoadedPage: false
      ),
      .fresh
    )
    XCTAssertEqual(
      OrgHTMLDocumentReloadStyle.style(
        loadedSourceFile: "notes/other.org",
        nextSourceFile: "notes/other.org",
        hasLoadedPage: false
      ),
      .fresh,
      "A page that never finished loading has no frame worth keeping"
    )
  }

  func testLayoutIsPartOfTheFirstPaint() throws {
    let layout = OrgHTMLDocumentLayout(width: .wide, margin: .compact)
    let html = layout.injecting(into: "<html><head><style>:root{--org2-content-width: 960px;}</style></head><body></body></html>")
    let style = "<style id=\"org2-app-layout\">:root { --org2-content-width: \(RenderedDocumentWidth.wide.cssValue); --org2-page-padding: \(RenderedDocumentMargin.compact.cssValue); }</style></head>"
    XCTAssertTrue(html.contains(style), html)
    let defaultRule = try XCTUnwrap(html.range(of: "--org2-content-width: 960px"))
    let injected = try XCTUnwrap(html.range(of: "id=\"org2-app-layout\""))
    XCTAssertLessThan(defaultRule.lowerBound, injected.lowerBound, "The chosen layout overrides the default rule")
  }
}
