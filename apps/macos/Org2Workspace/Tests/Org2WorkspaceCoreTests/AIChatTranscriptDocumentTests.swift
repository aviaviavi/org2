import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatTranscriptDocumentTests: XCTestCase {
  private func entry(
    _ id: String,
    _ html: String,
    role: String = "assistant",
    failure: String? = nil,
    trace: AIChatTranscriptHTML.Trace? = nil,
    changeSummary: AIChatTranscriptHTML.ChangeSummary? = nil
  ) -> AIChatTranscriptHTML.Entry {
    .init(id: id, role: role, title: role == "user" ? "You" : "Assistant", timestamp: "Today",
      html: html, contexts: [], attachments: [], failure: failure, queued: false, canSteer: false,
      isRoomResponse: false, copied: false, isTruncated: false,
      responseTrace: trace, changeSummary: changeSummary)
  }
  private func payload(_ entries: [AIChatTranscriptHTML.Entry], thread: String = "thread", search: String? = nil,
    generation: Int = 0, position: Double = 0, sending: Bool = false,
    live: AIChatTranscriptHTML.Live? = nil) -> AIChatTranscriptHTML.Payload {
    .init(thread: thread, entries: entries, earlier: "Show earlier messages", sending: sending,
      status: "", search: search, searchGeneration: generation, initialPosition: position, compact: false,
      live: live)
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

  func testEstablishedMessageChromeAndInlineSummariesRemainVisible() async throws {
    let trace = AIChatTranscriptHTML.Trace(OpenClawResponseTrace(
      reasoning: "Checked the existing renderer before changing the transcript.",
      activities: [OpenClawRunActivity(
        id: "tool-1", runID: "run", kind: .tool, title: "Read source",
        detail: "/tmp/ContentView.swift", status: .succeeded
      )]
    ))
    let changeSummary = AIChatTranscriptHTML.ChangeSummary(OpenClawCorpusChangeSummary(files: [
      OpenClawCorpusFileChange(relativePath: "ContentView.swift", status: .modified, insertions: 4, deletions: 2)
    ]))
    let view = try await document()
    try await update(view, payload([entry(
      "summaries", "<main><p>Finished the change.</p></main>",
      trace: trace, changeSummary: changeSummary
    )]))
    let result = try await view.evaluateJavaScript("""
      ({copyText:document.querySelector('.message-header button').textContent,
        copyLabel:document.querySelector('.message-header button').getAttribute('aria-label'),
        trace:document.querySelector('.trace').innerText,
        changes:document.querySelector('.change-summary').innerText,
        details:[...document.querySelectorAll('button')].some(b=>b.textContent==='Message details')})
      """) as? [String: Any]
    XCTAssertEqual(result?["copyText"] as? String, "")
    XCTAssertEqual(result?["copyLabel"] as? String, "Copy message")
    XCTAssertTrue((result?["trace"] as? String)?.contains("Approach") == true)
    XCTAssertTrue((result?["trace"] as? String)?.contains("Read source") == true)
    XCTAssertTrue((result?["changes"] as? String)?.contains("ContentView.swift") == true)
    XCTAssertEqual(result?["details"] as? Bool, false)
  }

  func testAuxiliaryControlsKeepIconsTextAndActionsAlignedAtNarrowWidths() async throws {
    let activities = (0..<4).map { index in
      OpenClawRunActivity(
        id: "tool-\(index)", runID: "run", kind: .tool, title: "Activity \(index)",
        detail: "A useful detail", status: .succeeded
      )
    }
    let trace = try XCTUnwrap(AIChatTranscriptHTML.Trace(OpenClawResponseTrace(
      reasoning: "Checked the transcript layout before updating it.",
      activities: activities
    )))
    let view = try await document()
    view.frame.size.width = 300
    try await update(view, payload([
      entry(
        "failure", "<main><p>Request body.</p></main>", role: "user",
        failure: "Codex turn failed: Selected model is at capacity. Please try a different model."
      ),
      entry("trace", "<main><p>Response body.</p></main>", trace: trace),
    ], sending: true))

    let result = try await view.evaluateJavaScript("""
      (()=>{
        const retry=document.querySelector('.failure button');
        const toggle=document.querySelector('.disclosure-button');
        toggle.click();
        const toggleIcon=toggle.querySelector('.glyph').getBoundingClientRect();
        const toggleLabel=toggle.querySelector('span:last-child').getBoundingClientRect();
        const status=document.getElementById('status');
        const style=e=>getComputedStyle(e);
        return {
          failureDisplay:style(document.querySelector('.failure')).display,
          retryWhiteSpace:style(retry).whiteSpace,
          retryFits:retry.scrollWidth<=retry.clientWidth,
          toggleDisplay:style(toggle).display,
          toggleWhiteSpace:style(toggle).whiteSpace,
          toggleText:toggle.textContent,
          toggleCenterDelta:Math.abs((toggleIcon.top+toggleIcon.height/2)-(toggleLabel.top+toggleLabel.height/2)),
          statusDisplay:style(status).display,
          statusAlignment:style(status).alignItems,
          statusText:status.innerText
        };
      })()
      """) as? [String: Any]
    XCTAssertEqual(result?["failureDisplay"] as? String, "grid")
    XCTAssertEqual(result?["retryWhiteSpace"] as? String, "nowrap")
    XCTAssertEqual(result?["retryFits"] as? Bool, true)
    XCTAssertEqual(result?["toggleDisplay"] as? String, "flex")
    XCTAssertEqual(result?["toggleWhiteSpace"] as? String, "nowrap")
    XCTAssertEqual(result?["toggleText"] as? String, "Show less")
    XCTAssertLessThan(result?["toggleCenterDelta"] as? Double ?? 100, 1)
    XCTAssertEqual(result?["statusDisplay"] as? String, "flex")
    XCTAssertEqual(result?["statusAlignment"] as? String, "center")
    XCTAssertEqual(result?["statusText"] as? String, "Working…Stop")
  }

  func testLiveAgentUpdatesAndAnimationRemainInsideTheSelectableDocument() async throws {
    func activity(_ title: String, status: OpenClawRunActivity.Status) -> AIChatTranscriptHTML.Activity {
      AIChatTranscriptHTML.Activity(OpenClawActivityFeedItem(
        id: title, title: title, detail: "Started", latestDetail: "Still working",
        status: status, count: 1, updatedAt: Date()
      ))
    }
    func live(_ text: String) -> AIChatTranscriptHTML.Live {
      .init(
        title: "Codex is thinking", detail: nil,
        quietTitle: "Waiting for Codex", quietDetail: "No new activity for 2m. It may still be working.",
        stalledTitle: "Codex may be stalled",
        stalledDetail: "No new activity for 10m. The run is saved; the connection or agent may be stalled.",
        startedAtMilliseconds: Date().addingTimeInterval(-65).timeIntervalSince1970 * 1_000,
        lastEventAtMilliseconds: Date().timeIntervalSince1970 * 1_000,
        usesLivenessThresholds: true, animates: true, text: text,
        hasEarlierText: true, textExpanded: false, reasoning: "Inspecting the relevant implementation.",
        activities: [activity("Read source", status: .succeeded), activity("Run tests", status: .running)],
        activityExpanded: false
      )
    }
    let message = entry("message", "<main><p>Select this message while a live update arrives.</p></main>")
    let firstLive = live("I found the missing live-state bridge.")
    let view = try await document()
    try await update(view, payload([message], sending: true, live: firstLive))

    let visible = try await view.evaluateJavaScript("""
      (()=>({
        hidden:document.getElementById('live').hidden,
        title:document.querySelector('.live-title').textContent,
        text:document.querySelector('.live-text').textContent,
        activities:document.querySelectorAll('.live-feed .activity-row').length,
        activityTitle:document.querySelector('.live-feed .activity-title').textContent,
        animating:document.getElementById('live').classList.contains('animating'),
        elapsed:document.querySelector('.live-elapsed').textContent,
        fallback:document.getElementById('status').innerText
      }))()
      """) as? [String: Any]
    XCTAssertEqual(visible?["hidden"] as? Bool, false)
    XCTAssertEqual(visible?["title"] as? String, "Codex is thinking")
    XCTAssertEqual(visible?["text"] as? String, firstLive.text)
    XCTAssertEqual(visible?["activities"] as? Int, 1)
    XCTAssertEqual(visible?["activityTitle"] as? String, "Run tests")
    XCTAssertEqual(visible?["animating"] as? Bool, true)
    XCTAssertTrue(AIChatTranscriptHTML.style.contains("@keyframes shimmer"))
    XCTAssertTrue((visible?["elapsed"] as? String)?.hasPrefix("1m ") == true)
    XCTAssertEqual(visible?["fallback"] as? String, "")

    try await view.evaluateJavaScript("document.querySelector('.live-stop').click(); document.querySelector('.live-activity-toggle').click(); null;")
    let actions = try await view.evaluateJavaScript("events.map(x=>x.action)") as? [String] ?? []
    XCTAssertTrue(actions.contains("stop"))
    XCTAssertTrue(actions.contains("liveActivityToggle"))

    try await view.evaluateJavaScript("""
      const range=document.createRange(); range.selectNodeContents(document.querySelector('#message-message p'));
      getSelection().removeAllRanges(); getSelection().addRange(range); null;
      """)
    let secondLive = live("The streamed update changed without replacing the selection.")
    let json = try XCTUnwrap(String(data: JSONEncoder().encode(secondLive), encoding: .utf8))
    try await view.evaluateJavaScript("window.__transcriptLiveUpdate(\(json)); null;")
    let heldText = try await view.evaluateJavaScript("document.querySelector('.live-text').textContent") as? String
    XCTAssertEqual(heldText, firstLive.text)
    try await view.evaluateJavaScript("getSelection().removeAllRanges(); document.dispatchEvent(new Event('selectionchange')); null;")
    let updatedText = try await view.evaluateJavaScript("document.querySelector('.live-text').textContent") as? String
    XCTAssertEqual(updatedText, secondLive.text)
    XCTAssertTrue(AIChatTranscriptWebView.documentPayloadMatches(
      payload([message], sending: true, live: firstLive),
      payload([message], sending: true, live: secondLive)
    ))
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
