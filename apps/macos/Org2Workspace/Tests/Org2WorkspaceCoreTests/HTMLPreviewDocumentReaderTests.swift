import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

/// The document reader loads compiler output directly, so live HTML previews
/// run as `srcdoc` frames and the renderer's own document script sizes them.
@MainActor
final class HTMLPreviewDocumentReaderTests: XCTestCase {
  func testReaderRunsHTMLPreviewScriptsInAnIsolatedAutoSizedFrame() async throws {
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML("""
    * Board

    #+begin_src html
    <div id="board" style="height:20px"></div>
    <script>
      document.getElementById('board').style.height = '520px';
      let isolated = false;
      try { void parent.document.body; } catch { isolated = true; }
      parent.postMessage({type: 'probe', isolated}, '*');
    </script>
    #+end_src
    """, sourcePath: "/tmp/reader-html.org")
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 900), configuration: configuration)
    let probe = WKUserScript(
      source: "window.frameMessages=[]; addEventListener('message', e => { if (e.data && e.data.type === 'probe') frameMessages.push(e.data); });",
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true
    )
    configuration.userContentController.addUserScript(probe)
    view.loadHTMLString(html, baseURL: URL(fileURLWithPath: "/tmp"))
    var result: [String: Any]?
    for _ in 0..<150 {
      try await Task.sleep(for: .milliseconds(30))
      result = try? await view.evaluateJavaScript("""
        (() => {
          const frame = document.querySelector('.org2-html-preview iframe');
          return {messages: JSON.stringify(window.frameMessages || []), height: frame ? frame.getBoundingClientRect().height : 0};
        })()
        """) as? [String: Any]
      if let height = result?["height"] as? Double, height > 500 { break }
    }
    XCTAssertEqual(result?["messages"] as? String, #"[{"type":"probe","isolated":true}]"#)
    let height = try XCTUnwrap(result?["height"] as? Double)
    XCTAssertGreaterThan(height, 515)
    XCTAssertLessThan(height, 580)
  }
}
