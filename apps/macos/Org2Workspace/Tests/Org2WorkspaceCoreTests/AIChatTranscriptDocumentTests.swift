import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatTranscriptDocumentTests: XCTestCase {
  private func entry(_ id: String, _ html: String, role: String = "assistant") -> AIChatTranscriptHTML.Entry {
    .init(id: id, role: role, title: role == "user" ? "You" : "Assistant", timestamp: "Today",
      html: html, attachments: [], failure: nil, queued: false, canSteer: false,
      hasDetails: false, activityCount: 0)
  }
  private func payload(_ entries: [AIChatTranscriptHTML.Entry], thread: String = "thread", search: String? = nil,
    generation: Int = 0, position: Double = 0) -> AIChatTranscriptHTML.Payload {
    .init(thread: thread, entries: entries, earlier: "Show earlier messages", sending: false,
      status: "", search: search, searchGeneration: generation, initialPosition: position, compact: false)
  }
  private func document() async throws -> WKWebView {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
    view.loadHTMLString(AIChatTranscriptHTML.shell, baseURL: nil)
    for _ in 0..<150 {
      if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    try await view.evaluateJavaScript("window.events=[]; window.webkit={messageHandlers:{transcript:{postMessage:x=>events.push(x)},chatCopyCode:{postMessage:x=>events.push({code:x})}}}; null;")
    try await view.evaluateJavaScript(AIChatTranscriptHTML.script)
    return view
  }
  private func update(_ view: WKWebView, _ payload: AIChatTranscriptHTML.Payload) async throws {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
    try await view.callAsyncJavaScript("window.__transcriptUpdate(data)", arguments: ["data": object], in: nil, in: .page)
    try await Task.sleep(for: .milliseconds(80))
  }

  func testNativeSelectionCrossesMessagesAndSurvivesIncomingUpdates() async throws {
    let view = try await document()
    let first = entry("first", "<main><p>Start in the first message.</p></main>", role: "user")
    let second = entry("second", "<main><ul><li>Continue into the second message.</li></ul><pre>let answer = 42</pre></main>")
    try await update(view, payload([first, second]))
    let selected = try await view.evaluateJavaScript("""
      const range=document.createRange();
      range.setStart(document.querySelector('#message-first p').firstChild, 6);
      range.setEnd(document.querySelector('#message-second li').firstChild, 24);
      getSelection().removeAllRanges(); getSelection().addRange(range); getSelection().toString();
      """) as? String
    XCTAssertTrue(selected?.contains("in the first message.") == true)
    XCTAssertTrue(selected?.contains("Continue into the second") == true)
    let third = entry("third", "<main><p>A newly arrived response.</p></main>")
    try await update(view, payload([first, second, third]))
    let retained = try await view.evaluateJavaScript("getSelection().toString()") as? String
    XCTAssertEqual(selected, retained)
    let held = try await view.evaluateJavaScript("document.querySelectorAll('article').length") as? Int
    XCTAssertEqual(held, 2)
    try await view.evaluateJavaScript("getSelection().removeAllRanges(); document.dispatchEvent(new Event('selectionchange')); null;")
    try await Task.sleep(for: .milliseconds(80))
    let applied = try await view.evaluateJavaScript("document.querySelectorAll('article').length") as? Int
    XCTAssertEqual(applied, 3)
  }

  func testSwitchingThreadsClearsOldSelectionAndContents() async throws {
    let view = try await document()
    try await update(view, payload([entry("old", "<main><p>Old thread text.</p></main>")]))
    try await view.evaluateJavaScript("const r=document.createRange(); r.selectNodeContents(document.querySelector('article')); getSelection().addRange(r); null;")
    try await update(view, payload([entry("new", "<main><p>New thread text.</p></main>")], thread: "new-thread"))
    let old = try await view.evaluateJavaScript("!!document.getElementById('message-old')") as? Bool
    let selected = try await view.evaluateJavaScript("getSelection().toString()") as? String
    XCTAssertEqual(old, false)
    XCTAssertEqual(selected, "")
  }

  func testOnlyTheTranscriptScrollsVerticallyIncludingOverCode() async throws {
    let view = try await document()
    let prose = String(repeating: "<p>A paragraph that contributes to the full transcript height.</p>", count: 30)
    let code = (0..<90).map { "line \($0) " + String(repeating: "x", count: 160) }.joined(separator: "\n")
    try await update(view, payload([entry("long", "<main>\(prose)<pre>\(code)</pre></main>")]))
    let result = try await view.evaluateJavaScript("""
      (()=>({height:document.documentElement.scrollHeight,
        nested:[...document.querySelectorAll('body *')].filter(e=>['auto','scroll'].includes(getComputedStyle(e).overflowY)&&e.scrollHeight>e.clientHeight+1).map(e=>e.tagName),
        codeHorizontal:document.querySelector('pre').scrollWidth>document.querySelector('pre').clientWidth}))()
      """) as? [String: Any]
    XCTAssertGreaterThan(result?["height"] as? Double ?? 0, 1000)
    XCTAssertEqual(result?["nested"] as? [String], [])
    XCTAssertEqual(result?["codeHorizontal"] as? Bool, true)
    try await view.evaluateJavaScript("window.scrollBy(0,500); null;")
    try await Task.sleep(for: .milliseconds(80))
    let offset = try await view.evaluateJavaScript("window.scrollY") as? Double
    XCTAssertGreaterThan(offset ?? 0, 400)
    let inner = try await view.evaluateJavaScript("document.querySelector('pre').scrollTop") as? Double
    XCTAssertEqual(inner, 0)
  }

  func testSearchAndPrependingHistoryPreserveTheReadingLocation() async throws {
    let view = try await document()
    let entries = (0..<8).map { entry("m\($0)", "<main>" + String(repeating: "<p>Message \($0) text.</p>", count: 8) + "</main>") }
    try await update(view, payload(entries, position: 1))
    try await update(view, payload(entries, search: "m3", generation: 1))
    let before = try await view.evaluateJavaScript("document.getElementById('message-m3').getBoundingClientRect().top") as? Double
    let earlier = entry("earlier", "<main>" + String(repeating: "<p>Earlier text.</p>", count: 15) + "</main>")
    try await update(view, payload([earlier] + entries, search: "m3", generation: 1))
    let after = try await view.evaluateJavaScript("document.getElementById('message-m3').getBoundingClientRect().top") as? Double
    XCTAssertEqual(before ?? -10000, after ?? 10000, accuracy: 2)
    let highlighted = try await view.evaluateJavaScript("document.querySelector('article.match').id") as? String
    XCTAssertEqual(highlighted, "message-m3")
  }

  func testMessageAndCodeCopyButtonsKeepTheirOwnTargets() async throws {
    let view = try await document()
    try await update(view, payload([entry("copy-me", "<main><pre>first line\nsecond line\n</pre></main>")]))
    try await view.evaluateJavaScript("document.querySelector('.message-header button').click(); document.querySelector('.chat-copy-code').click(); null;")
    let result = try await view.evaluateJavaScript("events") as? [[String: Any]] ?? []
    XCTAssertTrue(result.contains { $0["action"] as? String == "copy" && $0["id"] as? String == "copy-me" })
    XCTAssertTrue(result.contains { $0["code"] as? String == "first line\nsecond line" })
  }
  func testOrgAndLegacyCitationsRenderAsLinksWithExactLineTargets() async throws {
    let raw = "Org [[file:/tmp/note.org::16][project notes]], legacy [source](/tmp/file.swift:42), web [site](https://example.com)."
    let normalized = OpenClawMessageOrgNormalizer.normalized(raw)
    XCTAssertTrue(normalized.contains("[[file:/tmp/file.swift::42][source]]"))
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML(normalized, sourcePath: "/tmp/chat-message.org")
    let view = try await document()
    try await update(view, payload([entry("links", html)]))
    let links = try await view.evaluateJavaScript("[...document.querySelectorAll('main a')].map(a=>({label:a.textContent,href:a.getAttribute('href')}))") as? [[String:String]] ?? []
    XCTAssertEqual(links.map { $0["label"] ?? "" }, ["project notes", "source", "site"])
    XCTAssertTrue(links.contains { ($0["href"]?.removingPercentEncoding ?? "").contains("file:/tmp/file.swift::42") })
    let resolved = await OrgHTMLLinkTarget.resolve("file:/tmp/file.swift::42", relativeTo: "/tmp/chat-message.org", corpusRoot: nil)
    XCTAssertEqual(resolved?.url.path, "/tmp/file.swift")
    XCTAssertEqual(resolved?.line, 42)
  }

  func testCitationCompatibilityLeavesCodeAndExistingOrgLinksLiteral() {
    let literal = "=[example](/tmp/file.org:2)= and ~[example](/tmp/file.org:2)~"
    XCTAssertEqual(AIChatCitationNormalizer.normalized(literal), literal)
    let block = "#+begin_src text\n[example](/tmp/file.org:2)\n#+end_src"
    XCTAssertEqual(AIChatCitationNormalizer.normalized(block), block)
    XCTAssertEqual(AIChatCitationNormalizer.normalized("[[file:/tmp/file.org::2][source]]"), "[[file:/tmp/file.org::2][source]]")
    XCTAssertEqual(AIChatCitationNormalizer.normalized("[source](</tmp/My Note (draft).org:16>)"), "[[file:/tmp/My Note (draft).org::16][source]]")
    XCTAssertEqual(AIChatCitationNormalizer.normalized("[source](/tmp/note.org#L16-L20)"), "[[file:/tmp/note.org::16][source]]")
  }

  func testAllRuntimePromptsRequestOrgCitations() {
    let context = OpenClawWorkspaceContext(localCorpusRoot: "/tmp/corpus", remoteCorpusRoot: "/tmp/corpus",
      selectedSurface: "AI Chat", selectedLocation: nil, selectedEntrySource: nil, backlinks: nil,
      agenda: nil, searchQuery: "", searchResults: [])
    for prompt in [context.systemPrompt(), context.codexSystemPrompt(), context.localAgentSystemPrompt(runtime: "claude", runtimeTitle: "Claude Code")] {
      XCTAssertTrue(prompt.contains("[[file:/absolute/path/note.org::42][source]]"))
      XCTAssertFalse(prompt.contains("use Markdown links"))
      XCTAssertFalse(prompt.contains("Markdown chat transport exception"))
    }
  }

}
