import PDFKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class Org2PDFExporterTests: XCTestCase {
  func testLargeSourceDisclosurePreservesCopySearchNavigationAndPDFContent() async throws {
    let body = (1...201).map { "Evidence line \($0)" }.joined(separator: "\n")
    let source = "#+TITLE: Audit record\n* Machine state\n#+begin_src json\n\(body)\n#+end_src\n"
    let html = try await Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()).renderAppHTML(
      source, sourcePath: "/tmp/large-source-export-fixture.org"
    )
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056))
    let navigation = PDFTestNavigation()
    webView.navigationDelegate = navigation
    try await navigation.load(html, in: webView)
    let closed = try await webView.evaluateJavaScript("""
    ({ open: document.querySelector('.org2-large-source').open,
       height: document.documentElement.scrollHeight })
    """) as? [String: Any]
    XCTAssertEqual(closed?["open"] as? Bool, false)
    XCTAssertLessThan(try XCTUnwrap(closed?["height"] as? Double), 1500)
    let expanded = try await webView.evaluateJavaScript("""
    (() => {
      const disclosure = document.querySelector('.org2-large-source');
      disclosure.querySelector('summary').click();
      const range = document.createRange();
      range.selectNodeContents(disclosure.querySelector('code'));
      window.getSelection().removeAllRanges();
      window.getSelection().addRange(range);
      return { open: disclosure.open, text: window.getSelection().toString(),
               height: document.documentElement.scrollHeight };
    })()
    """) as? [String: Any]
    XCTAssertEqual(expanded?["open"] as? Bool, true)
    XCTAssertEqual(expanded?["text"] as? String, body)
    XCTAssertGreaterThan(try XCTUnwrap(expanded?["height"] as? Double), 4000)

    _ = try await webView.evaluateJavaScript("document.querySelector('.org2-large-source').open = false")
    for query in ["", "no matching evidence"] {
      _ = try await webView.callAsyncJavaScript(
        OrgHTMLDocumentView.Coordinator.revealSourceSearchMatchesScript,
        arguments: ["query": query], in: nil, contentWorld: .page
      )
      let open = try await webView.evaluateJavaScript("document.querySelector('.org2-large-source').open")
      XCTAssertEqual(open as? Bool, false)
    }
    _ = try await webView.callAsyncJavaScript(
      OrgHTMLDocumentView.Coordinator.revealSourceSearchMatchesScript,
      arguments: ["query": "EVIDENCE LINE 201"], in: nil, contentWorld: .page
    )
    let found = try await webView.find("Evidence line 201", configuration: WKFindConfiguration())
    XCTAssertTrue(found.matchFound)

    _ = try await webView.evaluateJavaScript("document.querySelector('.org2-large-source').open = false")
    let coordinator = OrgHTMLDocumentView.Coordinator()
    coordinator.applyScrollRequest(DetailScrollRequest(id: 1, target: .sourceLine(100)), to: webView)
    var revealed = false
    for _ in 0..<100 {
      revealed = try await webView.evaluateJavaScript("document.querySelector('.org2-large-source').open") as? Bool == true
      if revealed { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(revealed)

    // Export the original, still-collapsed HTML, not the expanded web view.
    let data = try await Org2PDFExporter().data(for: html, baseURL: nil)
    let text = try XCTUnwrap(PDFDocument(data: data)?.string)
    XCTAssertTrue(text.contains("Evidence line 1"))
    XCTAssertTrue(text.contains("Evidence line 201"))
    XCTAssertFalse(text.contains("json source"))
  }

  func testAppHTMLExportsWithoutOutlineChromeAndPreservesContent() async throws {
    let source = """
    #+TITLE: Export agreement
    * Heading one
    :PROPERTIES:
    :PRIVATE: HIDDEN_METADATA
    :END:
    Body one with *bold text* and =literal * asterisk=.
    ** Heading two
    Body two.
    *** Heading three
    Body three.
    **** Heading four
    Body four.
    ***** Heading five
    Body five.
    ****** Heading six
    Body six.
    #+begin_quote
    A quotation keeps its border.
    #+end_quote
    | Name | Value |
    |------+-------|
    | Item | 42 |
    """
    let html = try await Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()).renderAppHTML(
      source, sourcePath: "/tmp/pdf-export-fixture.org"
    )
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056))
    let navigation = PDFTestNavigation()
    webView.navigationDelegate = navigation
    try await navigation.load(html, in: webView)
    let reader = try await styles(in: webView)
    XCTAssertEqual(reader["titleMarker"] as? String, "\"*\"")
    XCTAssertEqual(reader["nestedBorder"] as? String, "1px")

    try await navigation.load(Org2PDFExporter.preparedHTML(for: html), in: webView)
    let pdf = try await styles(in: webView)
    XCTAssertEqual(pdf["titleMarker"] as? String, "none")
    XCTAssertEqual(pdf["headingMarkers"] as? [String], Array(repeating: "none", count: 6))
    XCTAssertEqual(pdf["disclosures"] as? [String], Array(repeating: "none", count: 6))
    XCTAssertEqual(pdf["nestedBorders"] as? [String], Array(repeating: "0px", count: 5))
    XCTAssertEqual(pdf["nestedMargins"] as? [String], Array(repeating: "0px", count: 5))
    XCTAssertEqual(pdf["nestedPadding"] as? [String], Array(repeating: "0px", count: 5))
    XCTAssertEqual(pdf["headingSizes"] as? [String], reader["headingSizes"] as? [String])
    XCTAssertEqual(pdf["quoteBorder"] as? String, reader["quoteBorder"] as? String)
    XCTAssertEqual(pdf["tableBorder"] as? String, reader["tableBorder"] as? String)
    XCTAssertEqual(pdf["hiddenControls"] as? Bool, true)

    let data = try await Org2PDFExporter().data(for: html, baseURL: nil)
    let text = try XCTUnwrap(PDFDocument(data: data)?.string)
    XCTAssertTrue(text.contains("Export agreement"))
    for number in ["one", "two", "three", "four", "five", "six"] {
      XCTAssertTrue(text.contains("Heading \(number)"))
      XCTAssertTrue(text.contains("Body \(number)"))
    }
    XCTAssertTrue(text.contains("literal * asterisk"))
    XCTAssertEqual(text.filter { $0 == "*" }.count, 1, "Only the literal content asterisk survives")
    XCTAssertTrue(text.contains("bold text"))
    XCTAssertTrue(text.contains("Item"))
    XCTAssertTrue(text.contains("42"))
    XCTAssertFalse(text.contains("HIDDEN_METADATA"))
    XCTAssertFalse(text.contains("Ask AI"))
    XCTAssertFalse(text.contains("▼"))
  }

  private func styles(in webView: WKWebView) async throws -> [String: Any] {
    let value = try await webView.evaluateJavaScript(#"""
    (() => {
      const headings = [...document.querySelectorAll('.org2-headline-summary > :is(h1,h2,h3,h4,h5,h6)')];
      const nested = [...document.querySelectorAll('.org2-headline-body > .org2-headline')];
      const controls = [...document.querySelectorAll('.org2-heading-ai-action, .org2-properties-drawer')];
      const style = (selector) => getComputedStyle(document.querySelector(selector));
      return {
        titleMarker: getComputedStyle(document.querySelector('.org2-document-title'), '::before').content,
        headingMarkers: headings.map(h => getComputedStyle(h, '::before').content),
        disclosures: headings.map(h => getComputedStyle(h.parentElement, '::before').content),
        headingSizes: headings.map(h => getComputedStyle(h).fontSize),
        nestedBorder: getComputedStyle(nested[0]).borderLeftWidth,
        nestedBorders: nested.map(h => getComputedStyle(h).borderLeftWidth),
        nestedMargins: nested.map(h => getComputedStyle(h).marginLeft),
        nestedPadding: nested.map(h => getComputedStyle(h).paddingLeft),
        quoteBorder: style('blockquote').borderLeftWidth,
        tableBorder: style('td').borderBottomWidth,
        hiddenControls: controls.length > 0 && controls.every(c => getComputedStyle(c).display === 'none')
      };
    })()
    """#)
    return try XCTUnwrap(value as? [String: Any])
  }
}

@MainActor
private final class PDFTestNavigation: NSObject, WKNavigationDelegate {
  private var continuation: CheckedContinuation<Void, Error>?

  func load(_ html: String, in webView: WKWebView) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      webView.loadHTMLString(html, baseURL: nil)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    continuation?.resume()
    continuation = nil
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }
}
