import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatDocumentTests: XCTestCase {
  private func document(_ html: String) async throws -> WKWebView {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
    view.loadHTMLString("<html><head><style>\(AIChatDocumentHTML.style)</style></head><body><main></main></body></html>", baseURL: nil)
    for _ in 0..<100 {
      if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    // The production handler reports geometry to SwiftUI; this fixture keeps a fixed viewport.
    try await view.evaluateJavaScript("window.webkit = {messageHandlers: {chatHeight: {postMessage: function() {}}}}; null;")
    try await view.evaluateJavaScript(AIChatDocumentHTML.updateScript)
    try await view.callAsyncJavaScript("window.__chatUpdate(html)", arguments: ["html": html], in: nil, in: .page)
    return view
  }

  func testSharedRendererKeepsBulletsAndTextOnTheSameLine() async throws {
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML("Added in Preview:\n\n- Subtle press feedback.\n- Smooth thread settlement and reopening.\n- Reduce Motion support.\n\nBuild checks pass.", sourcePath: "/tmp/chat-test.org")
    let view = try await document(html)
    let result = try await view.evaluateJavaScript("""
      (() => {
        const items = [...document.querySelectorAll('li')];
        return {count:items.length, inline:items.every(li => {
          const range=document.createRange(); range.selectNodeContents(li);
          return Math.abs(range.getBoundingClientRect().top-li.getBoundingClientRect().top)<8;
        }), text:document.body.innerText};
      })()
      """) as? [String: Any]
    XCTAssertEqual(result?["count"] as? Int, 3)
    XCTAssertEqual(result?["inline"] as? Bool, true)
    XCTAssertTrue((result?["text"] as? String)?.contains("Reduce Motion support.") == true)
  }

  func testSelectionSpansParagraphsListsAndTablesAndSurvivesUpdates() async throws {
    let view = try await document("<main><p>First paragraph.</p><ul><li>Second item.</li></ul><table><tr><td>Third cell.</td></tr></table></main>")
    let selected = try await view.evaluateJavaScript("""
      const range=document.createRange(); range.selectNodeContents(document.querySelector('main'));
      getSelection().removeAllRanges(); getSelection().addRange(range); getSelection().toString();
      """) as? String
    XCTAssertTrue(selected?.contains("First paragraph.") == true)
    XCTAssertTrue(selected?.contains("Second item.") == true)
    XCTAssertTrue(selected?.contains("Third cell.") == true)
    try await view.callAsyncJavaScript("window.__chatUpdate(html)", arguments: ["html": "<main><p>Updated response.</p></main>"], in: nil, in: .page)
    let retained = try await view.evaluateJavaScript("getSelection().toString()") as? String
    XCTAssertEqual(retained, selected)
    try await view.evaluateJavaScript("getSelection().removeAllRanges(); document.dispatchEvent(new Event('selectionchange'));")
    let updated = try await view.evaluateJavaScript("document.body.innerText") as? String
    XCTAssertEqual(updated?.trimmingCharacters(in: .whitespacesAndNewlines), "Updated response.")
  }

  func testPlainFallbackEscapesMarkupAndPreservesWhitespace() {
    let html = AIChatDocumentHTML.plain("<script>alert(1)</script>\n  literal")
    XCTAssertFalse(html.contains("<script>"))
    XCTAssertTrue(html.contains("&lt;script&gt;"))
    XCTAssertTrue(html.contains("\n  literal"))
  }
  func testWrappedProseAndTablesExpandAndCodeKeepsNaturalLines() async throws {
    let prose = String(repeating: "A sentence that should wrap naturally. ", count: 20)
    let raw = prose + "\n\n| First | Second |\n|---+---|\n| " + prose + " | A cell |\n\n#+begin_src text\n" + String(repeating: "x", count: 180) + "\n#+end_src"
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML(raw, sourcePath: "/tmp/chat-test.org")
    let view = try await document(html)
    let result = try await view.evaluateJavaScript("""
      (() => { const pre=document.querySelector('pre'); const table=document.querySelector('table');
        return {height:document.querySelector('main').getBoundingClientRect().height,
          tableHeight:table.getBoundingClientRect().height, scrolls:pre.scrollWidth>pre.clientWidth,
          copyButtons:document.querySelectorAll('.chat-copy-code').length}; })()
      """) as? [String: Any]
    XCTAssertGreaterThan(result?["height"] as? Double ?? 0, 300)
    XCTAssertGreaterThan(result?["tableHeight"] as? Double ?? 0, 100)
    XCTAssertEqual(result?["scrolls"] as? Bool, true)
    XCTAssertEqual(result?["copyButtons"] as? Int, 1)
  }

}
