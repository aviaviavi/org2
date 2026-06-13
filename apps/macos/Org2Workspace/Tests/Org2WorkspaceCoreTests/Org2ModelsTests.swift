import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

final class Org2ModelsTests: XCTestCase {
  func testDecodesAgendaPayload() throws {
    let json = """
    {
      "$schema": "org2:agenda:v1",
      "range": { "start": "2026-06-12", "end": "2026-06-18", "days": 7 },
      "overdue": [],
      "days": [
        {
          "date": "2026-06-12",
          "weekday": "Fri",
          "items": [
            {
              "todo": "TODO",
              "headline": "Review workspace",
          "kind": "SCHEDULED",
          "file": "/tmp/project.org2",
          "line": 4,
          "body": "Body with [[id:11111111-1111-4111-8111-111111111111][clean label]].",
          "level": 1,
          "tags": ["work"],
          "properties": { "EFFORT": "30m" },
          "priority": "A",
          "time": "09:00",
          "id": "22222222-2222-4222-8222-222222222222"
        }
          ]
        }
      ],
      "skippedFiles": 0
    }
    """

    let payload = try JSONDecoder().decode(AgendaPayload.self, from: Data(json.utf8))

    XCTAssertEqual(payload.totalItemCount, 1)
    XCTAssertEqual(payload.todayItemCount, 1)
    XCTAssertEqual(payload.days[0].items[0].lineForEditor, 5)
    XCTAssertEqual(payload.days[0].items[0].properties["EFFORT"], "30m")
    XCTAssertEqual(payload.days[0].items[0].tags, ["work"])
  }

  func testDecodesSearchAndBacklinksPayloads() throws {
    let searchJSON = """
    {
      "$schema": "org2:search:v1",
      "query": "workspace",
      "mode": "line",
      "sort": "scan",
      "results": [
        {
          "file": "/tmp/project.org2",
          "line": 8,
          "lineEnd": 8,
          "heading": "Review workspace",
          "headingLine": 4,
          "headingLevel": 1,
          "headingAncestry": [],
          "id": "22222222-2222-4222-8222-222222222222",
          "todo": "TODO",
          "tags": [],
          "snippet": "Review workspace",
          "sourceRange": { "startLine": 8, "endLine": 8 },
          "matchedLines": [{ "line": 8, "snippet": "Review workspace" }]
        }
      ]
    }
    """
    let backlinksJSON = """
    {
      "$schema": "org2:backlinks:v1",
      "id": "11111111-1111-4111-8111-111111111111",
      "backlinks": [
        {
          "srcId": null,
          "srcTitle": "Thread",
          "file": "/tmp/thread.org2",
          "line": 3,
          "context": "[[id:11111111-1111-4111-8111-111111111111][Workspace]]"
        }
      ]
    }
    """

    let search = try JSONDecoder().decode(SearchPayload.self, from: Data(searchJSON.utf8))
    let backlinks = try JSONDecoder().decode(BacklinksPayload.self, from: Data(backlinksJSON.utf8))

    XCTAssertEqual(search.results[0].lineForEditor, 8)
    XCTAssertEqual(search.results[0].title, "Review workspace")
    XCTAssertEqual(backlinks.backlinks[0].lineForEditor, 4)
  }

  func testOrg2CLIDrainsLargeJSONOutput() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-large-cli-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    let cli = dist.appendingPathComponent("cli.js")
    try """
    const payload = {
      "$schema": "org2:search:v1",
      query: "large",
      mode: "line",
      sort: "scan",
      results: [{
        file: "/tmp/large.org2",
        line: 1,
        heading: "Large",
        tags: [],
        snippet: "x".repeat(160000)
      }]
    };
    process.stdout.write(JSON.stringify(payload));
    """.write(to: cli, atomically: true, encoding: .utf8)

    let org2 = Org2CLI(repoRoot: root)
    let payload: SearchPayload = try await org2.runJSON(["search", "large"], as: SearchPayload.self)

    XCTAssertEqual(payload.results.count, 1)
    XCTAssertEqual(payload.results[0].snippet.count, 160000)
  }

  func testOrg2CLIParsesCanonicalAstWithBuiltInParser() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-canonical-ast-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("canonical.org2")
    try """
    #+TITLE: Canonical Parser Test

    * TODO Review [[id:11111111-1111-4111-8111-111111111111][Alice]] :work:
    SCHEDULED: <2026-06-12 Fri>
    Body with *bold* and ~code~.
    """.write(to: note, atomically: true, encoding: .utf8)

    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let document: Org2CanonicalDocument = try cli.parseFileJSONSync(note, sourceRanges: true)

    XCTAssertEqual(document.type, "Document")
    XCTAssertEqual(document.version, "0")
    XCTAssertEqual(document.children.count, 2)

    guard case .keywordLine(let title) = document.children[0] else {
      return XCTFail("Expected title keyword")
    }
    XCTAssertEqual(title.keyRaw, "TITLE")
    XCTAssertEqual(title.valueRaw, " Canonical Parser Test")
    XCTAssertEqual(title.sourceRange, Org2CanonicalSourceRange(startLine: 1, endLine: 1))

    guard case .headline(let headline) = document.children[1] else {
      return XCTFail("Expected headline")
    }
    XCTAssertEqual(headline.level, 1)
    XCTAssertEqual(headline.todo, "TODO")
    XCTAssertEqual(headline.tags, ["work"])
    XCTAssertEqual(headline.sourceRange, Org2CanonicalSourceRange(startLine: 3, endLine: 5))
    XCTAssertTrue(headline.title.contains(.link(Org2CanonicalLink(
      type: "Link",
      format: "bracket",
      raw: "[[id:11111111-1111-4111-8111-111111111111][Alice]]",
      targetRaw: "id:11111111-1111-4111-8111-111111111111",
      descriptionRaw: "Alice"
    ))))
    XCTAssertTrue(headline.children.contains(.planning(Org2CanonicalPlanning(
      type: "Planning",
      kind: "SCHEDULED",
      raw: "SCHEDULED: <2026-06-12 Fri>",
      sourceRange: Org2CanonicalSourceRange(startLine: 4, endLine: 4)
    ))))
  }

  func testOrg2CLIParsesCanonicalAstFromTextWithLineOffset() async throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let document: Org2CanonicalDocument = try await cli.parseTextJSON(
      """
      * TODO Offset Test
      Body
      """,
      sourceRanges: true,
      sourceLineOffset: 40
    )

    XCTAssertEqual(document.children.count, 1)
    guard case .headline(let headline) = document.children[0] else {
      return XCTFail("Expected headline")
    }
    XCTAssertEqual(headline.sourceRange, Org2CanonicalSourceRange(startLine: 41, endLine: 42))
    guard case .paragraph(let paragraph) = headline.children[0] else {
      return XCTFail("Expected paragraph")
    }
    XCTAssertEqual(paragraph.sourceRange, Org2CanonicalSourceRange(startLine: 42, endLine: 42))
  }

  func testCanonicalAstRendersEditableBlocksWithFallbackGaps() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-canonical-render-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("render.org2")
    let raw = """
    #+TITLE: Render Test

    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    Body with [[id:11111111-1111-4111-8111-111111111111][Alice]]
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    #+begin_src swift
    let value = 1
    #+end_src
    -----
    - Fallback list item
    """
    try raw.write(to: note, atomically: true, encoding: .utf8)

    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let document: Org2CanonicalDocument = try cli.parseFileJSONSync(note, sourceRanges: true)
    let blocks = OrgEntryRenderer.parseEditable(raw, canonicalDocument: document)

    XCTAssertTrue(blocks.contains {
      if case .keyword(let key, let value) = $0.rendered {
        return key == "TITLE" && value == "Render Test" && $0.displayRange == "1"
      }
      return false
    })
    XCTAssertTrue(blocks.contains {
      if case .table(let table) = $0.rendered {
        return $0.displayRange == "6-8" && table.rows.count == 3
      }
      return false
    })
    XCTAssertTrue(blocks.contains {
      if case .source(let language, let lines) = $0.rendered {
        return $0.displayRange == "9-11" && language == "swift" && lines == ["let value = 1"]
      }
      return false
    })
    XCTAssertTrue(blocks.contains {
      if case .horizontalRule = $0.rendered {
        return $0.displayRange == "12"
      }
      return false
    })
    XCTAssertTrue(blocks.contains {
      if case .listItem(_, _, _, let text) = $0.rendered {
        return $0.displayRange == "13" && text == "Fallback list item"
      }
      return false
    })
  }

  func testOpenClawGatewaySettingsResolveLocalConfig() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-openclaw-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let config = root.appendingPathComponent("clawdbot.json")
    try """
    {
      "gateway": {
        "port": 23456,
        "auth": { "mode": "password", "password": "test-password" },
        "http": { "endpoints": { "chatCompletions": { "enabled": true } } }
      }
    }
    """.write(to: config, atomically: true, encoding: .utf8)

    let settings = OpenClawGatewaySettings.resolve(environment: [:], configURL: config)

    XCTAssertEqual(settings.endpoint.absoluteString, "http://127.0.0.1:23456/v1/chat/completions")
    XCTAssertEqual(settings.bearerToken, "test-password")
    XCTAssertEqual(settings.chatCompletionsEnabled, true)
  }

  func testOpenClawGatewaySettingsUseUserEndpointOverride() {
    let settings = OpenClawGatewaySettings.resolve(
      environment: [:],
      configURL: URL(fileURLWithPath: "/tmp/missing-clawdbot-\(UUID().uuidString).json"),
      userEndpoint: "http://openclaw.local:18789",
      userBearerToken: "secret"
    )

    XCTAssertEqual(settings.endpoint.absoluteString, "http://openclaw.local:18789/v1/chat/completions")
    XCTAssertEqual(settings.bearerToken, "secret")
  }

  func testOpenClawChatCompletionPayloadDecodesAssistantText() throws {
    let json = """
    {
      "choices": [
        { "message": { "role": "assistant", "content": "First" } },
        { "message": { "role": "assistant", "content": "Second" } }
      ]
    }
    """

    let payload = try JSONDecoder().decode(OpenClawChatCompletionPayload.self, from: Data(json.utf8))

    XCTAssertEqual(payload.assistantText, "First\n\nSecond")
  }

  @MainActor
  func testOpenClawChatTranscriptPersistsLocally() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    store.openClawMessages = [
      OpenClawChatMessage(role: .user, content: "Hello OpenClaw"),
      OpenClawChatMessage(role: .assistant, content: "Hello from the workspace")
    ]

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )

    XCTAssertEqual(restored.openClawMessages.map(\.content), ["Hello OpenClaw", "Hello from the workspace"])

    restored.resetOpenClawChat()
    let cleared = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    XCTAssertTrue(cleared.openClawMessages.isEmpty)
  }

  func testOpenClawChatClientNormalizesModelAndAgentNames() {
    XCTAssertEqual(OpenClawChatClient.openClawModelName(for: ""), "openclaw")
    XCTAssertEqual(OpenClawChatClient.openClawModelName(for: "openclaw"), "openclaw")
    XCTAssertEqual(OpenClawChatClient.openClawModelName(for: "org2-workspace"), "openclaw/org2-workspace")
    XCTAssertEqual(OpenClawChatClient.openClawModelName(for: "openclaw/org2-workspace"), "openclaw/org2-workspace")
    XCTAssertEqual(OpenClawChatClient.openClawModelName(for: "clawdbot:org2-workspace"), "openclaw/org2-workspace")

    XCTAssertEqual(OpenClawChatClient.openClawAgentHeaderValue(for: ""), "main")
    XCTAssertEqual(OpenClawChatClient.openClawAgentHeaderValue(for: "openclaw"), "main")
    XCTAssertEqual(OpenClawChatClient.openClawAgentHeaderValue(for: "openclaw/org2-workspace"), "org2-workspace")
  }

  func testOpenClawFileReferenceExtractsOrgPaths() {
    let refs = OpenClawFileReference.extract(from: """
    Check /srv/org2/notes/alice.org2:42 and notes/daily/2026-06-12.org.
    Also [thread](file:///srv/org2/threads/follow-up.org2#9).
    """)

    XCTAssertEqual(refs.map(\.path), [
      "/srv/org2/notes/alice.org2",
      "notes/daily/2026-06-12.org",
      "/srv/org2/threads/follow-up.org2"
    ])
    XCTAssertEqual(refs.map(\.line), [42, nil, 9])
    XCTAssertEqual(refs[0].displayTitle, "alice.org2:42")
  }

  func testOrgInlineParserRendersCodeAndOrgBracketLinks() {
    let spans = OrgInlineParser.parse("Plate `8CJB731` from [[/srv/org2/personal.org:58][personal.org]].")

    XCTAssertEqual(spans, [
      .text("Plate "),
      .code("8CJB731"),
      .text(" from "),
      .link(
        label: "personal.org",
        target: "/srv/org2/personal.org:58",
        fileReference: OpenClawFileReference(path: "/srv/org2/personal.org", line: 58)
      ),
      .text(".")
    ])
  }

  func testOrgInlineParserRendersMarkdownFileCitationsInline() {
    let spans = OrgInlineParser.parse("Found in [personal.org](/Users/avi/avi.org2/personal.org:58).")

    XCTAssertEqual(spans, [
      .text("Found in "),
      .link(
        label: "personal.org",
        target: "/Users/avi/avi.org2/personal.org:58",
        fileReference: OpenClawFileReference(path: "/Users/avi/avi.org2/personal.org", line: 58)
      ),
      .text(".")
    ])
  }

  func testOrgInlineParserFastPathsPlainTextButKeepsRelativeFileReferences() {
    XCTAssertFalse(OrgInlineParser.hasInlineSyntaxCandidate("Plain sentence with no org syntax here."))
    XCTAssertFalse(OrgInlineText.usesAttributedRendering("Plain sentence with no org syntax here."))
    XCTAssertEqual(
      OrgInlineParser.parse("Plain sentence with no org syntax here."),
      [.text("Plain sentence with no org syntax here.")]
    )
    XCTAssertTrue(OrgInlineText.usesAttributedRendering("Review [[id:abc][Alice]] soon."))
    XCTAssertTrue(OrgInlineText.usesAttributedRendering("See agenda.org for context."))
    XCTAssertFalse(OrgInlineText.usesAttributedRendering(String(repeating: "plain text ", count: 1_000)))

    let longLinkedText = "See [[id:abc][Alice]]. " + String(repeating: "plain text ", count: 120)
    XCTAssertTrue(OrgInlineParser.hasInlineSyntaxCandidate(longLinkedText))
    XCTAssertTrue(OrgInlineParser.hasInlineSyntaxCandidate(
      longLinkedText,
      near: NSRange(location: 6, length: 0),
      radius: 64
    ))
    XCTAssertFalse(OrgInlineParser.hasInlineSyntaxCandidate(
      longLinkedText,
      near: NSRange(location: (longLinkedText as NSString).length, length: 0),
      radius: 64
    ))
    XCTAssertFalse(OrgInlineParser.hasInlineSyntaxCandidate(
      longLinkedText,
      near: NSRange(location: (longLinkedText as NSString).length + 10_000, length: 0),
      radius: 64
    ))
    let longTrailingURL = String(repeating: "plain text ", count: 400) + "see HTTPS://example.com"
    XCTAssertTrue(OrgInlineParser.hasInlineSyntaxCandidate(
      longTrailingURL,
      near: NSRange(location: (longTrailingURL as NSString).length - 8, length: 0),
      radius: 64
    ))
    let unicodeLinkedText = String(repeating: "🙂 ", count: 20) + "See [[id:abc][Alice]]."
    XCTAssertTrue(OrgInlineParser.hasInlineSyntaxCandidate(
      unicodeLinkedText,
      near: NSRange(location: (String(repeating: "🙂 ", count: 20) as NSString).length + 8, length: 0),
      radius: 32
    ))
    XCTAssertFalse(OrgInlineParser.hasInlineSyntaxCandidate(
      unicodeLinkedText,
      near: NSRange(location: 1, length: 0),
      radius: 4
    ))

    let spans = OrgInlineParser.parse("See notes/daily/2026-06-12.org:7 for context.")
    XCTAssertEqual(spans, [
      .text("See "),
      .link(
        label: "2026-06-12.org:7",
        target: "notes/daily/2026-06-12.org",
        fileReference: OpenClawFileReference(path: "notes/daily/2026-06-12.org", line: 7)
      ),
      .text(" for context.")
    ])
  }

  func testOrgInlineSyntaxCandidateCacheUsesExactText() {
    let plain = "Plain sentence with no inline syntax."
    let rich = "See [[id:abc][Alice]] and `code`."
    let longPlain = String(repeating: "plain text ", count: 20)
    let longRich = "See [[id:abc][Alice]]. " + String(repeating: "plain text ", count: 20)
    let plainKey = OrgInlineSyntaxCandidateCache.CacheKey(raw: plain)
    let matchingPlainKey = OrgInlineSyntaxCandidateCache.CacheKey(raw: plain)
    let differentKey = OrgInlineSyntaxCandidateCache.CacheKey(raw: plain + " ")

    XCTAssertEqual(plainKey, matchingPlainKey)
    XCTAssertEqual(plainKey.hash, matchingPlainKey.hash)
    XCTAssertNotEqual(plainKey, differentKey)
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.shouldCacheLookup(plain))
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.shouldCacheLookup(rich))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.shouldCacheLookup(longPlain))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.shouldCacheLookup(longRich))
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.containsSyntax(plain))
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.containsSyntax(plain))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.containsSyntax(rich))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.containsSyntax(rich))
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.containsSyntax(longPlain))
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.containsSyntax(longPlain))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.containsSyntax(longRich))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.containsSyntax(longRich))
  }

  func testOrgInlineParserRendersMarkupAndTimestamps() {
    let spans = OrgInlineParser.parse("Review *bold* /soon/ on <2026-06-12 Fri 09:30-10:00> with ~code~.")

    XCTAssertEqual(spans, [
      .text("Review "),
      .bold("bold"),
      .text(" "),
      .italic("soon"),
      .text(" on "),
      .timestamp(OrgInlineTimestamp(
        raw: "<2026-06-12 Fri 09:30-10:00>",
        dateLabel: "Jun 12, 2026",
        timeLabel: "09:30-10:00"
      )),
      .text(" with "),
      .code("code"),
      .text(".")
    ])
  }

  @MainActor
  func testOrgInlineAttributedStringCacheKeysUseExactTextAndFont() {
    let raw = "See [[id:abc][Alice]] and `code`."
    let key = OrgInlineAttributedString.CacheKey(raw: raw, baseFont: .body)
    let matching = OrgInlineAttributedString.CacheKey(raw: raw, baseFont: .body)
    let differentRaw = OrgInlineAttributedString.CacheKey(raw: raw + " ", baseFont: .body)
    let differentFont = OrgInlineAttributedString.CacheKey(raw: raw, fontDescription: "different-font")

    XCTAssertEqual(key, matching)
    XCTAssertEqual(key.hash, matching.hash)
    XCTAssertNotEqual(key, differentRaw)
    XCTAssertNotEqual(key, differentFont)
    XCTAssertEqual(
      OrgInlineAttributedString.cached(raw: raw, baseFont: .body),
      OrgInlineAttributedString.cached(raw: raw, baseFont: .body)
    )

    let longRaw = "See [[id:abc][Alice]]. " + String(repeating: "Long rich line ", count: 300)
    let longKey = OrgInlineAttributedString.CacheKey(raw: longRaw, baseFont: .body)
    let matchingLongKey = OrgInlineAttributedString.CacheKey(raw: longRaw, baseFont: .body)
    XCTAssertEqual(longKey, matchingLongKey)
    XCTAssertEqual(longKey.hash, matchingLongKey.hash)
  }

  func testOrgSyntaxHighlighterFindsEditableDocumentTokens() {
    let raw = """
    * TODO [#A] Review [[id:11111111-1111-4111-8111-111111111111][Alice]] :work:
    SCHEDULED: <2026-06-12 Fri 09:30>
    :OWNER: agent
    Body with `code`, *emphasis*, and [Docs](https://example.com/docs).
    #+begin_src swift
    let value = 1
    #+end_src
    """

    let tokens = OrgSyntaxHighlighter.tokens(in: raw)

    assertToken(.headingStars, "*", in: raw, tokens: tokens)
    assertToken(.todo, "TODO", in: raw, tokens: tokens)
    assertToken(.priority, "[#A]", in: raw, tokens: tokens)
    assertToken(.link, "[[id:11111111-1111-4111-8111-111111111111][Alice]]", in: raw, tokens: tokens)
    assertToken(.linkTarget, "id:11111111-1111-4111-8111-111111111111", in: raw, tokens: tokens)
    assertToken(.link, "[Docs](https://example.com/docs)", in: raw, tokens: tokens)
    assertToken(.linkTarget, "https://example.com/docs", in: raw, tokens: tokens)
    assertToken(.tag, ":work:", in: raw, tokens: tokens)
    assertToken(.planningKeyword, "SCHEDULED", in: raw, tokens: tokens)
    assertToken(.timestamp, "<2026-06-12 Fri 09:30>", in: raw, tokens: tokens)
    assertToken(.propertyKey, "OWNER", in: raw, tokens: tokens)
    assertToken(.code, "`code`", in: raw, tokens: tokens)
    assertToken(.emphasis, "*emphasis*", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, "`", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, "[[", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, "][", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, "]]", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, "<", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, ">", in: raw, tokens: tokens)
    assertToken(.keyword, "begin_src", in: raw, tokens: tokens)
    assertToken(.keyword, "end_src", in: raw, tokens: tokens)
  }

  func testOrgSyntaxHighlighterSkipsPlainBlockLines() {
    XCTAssertFalse(OrgSyntaxHighlighter.lineMayContainBlockSyntax("plain paragraph line"[...]))
    XCTAssertFalse(OrgSyntaxHighlighter.lineMayContainBlockSyntax("  plain indented content"[...]))
    XCTAssertFalse(OrgSyntaxHighlighter.lineMayContainBlockSyntax(""[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("* TODO Heading"[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("#+TITLE: Demo"[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("  :ID: abc"[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("SCHEDULED: <2026-06-13>"[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("  DEADLINE: <2026-06-13>"[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("CLOSED: [2026-06-13]"[...]))
  }

  func testOrgSyntaxHighlighterSkipsPlainInlineRegexPasses() {
    XCTAssertFalse(OrgSyntaxHighlighter.textMayContainInlineSyntax(""))
    XCTAssertFalse(OrgSyntaxHighlighter.textMayContainInlineSyntax("plain paragraph text"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("See [[id:abc][Alice]]"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("Read [Docs](https://example.com)"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("Visit https://example.com"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("Open notes/person.org"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("Use `code`"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("Use =code="))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("*bold* and _underlined_"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("<2026-06-13>"))
  }

  func testOrgSyntaxHighlighterKeepsLineOffsetsAcrossBlankLines() {
    let raw = "Intro\n\n#+begin_quote\nSee [[id:abc][Alice]].\n#+end_quote\n"
    let tokens = OrgSyntaxHighlighter.tokens(in: raw)
    let nsRaw = raw as NSString

    let beginRange = nsRaw.range(of: "begin_quote")
    let linkRange = nsRaw.range(of: "[[id:abc][Alice]]")
    let separatorRange = nsRaw.range(of: "][")

    XCTAssertTrue(tokens.contains(OrgSyntaxHighlightToken(kind: .keyword, range: beginRange)))
    XCTAssertTrue(tokens.contains(OrgSyntaxHighlightToken(kind: .link, range: linkRange)))
    XCTAssertTrue(tokens.contains(OrgSyntaxHighlightToken(kind: .syntaxDelimiter, range: separatorRange)))
  }

  func testOrgSyntaxHighlighterVisuallyRecedesEditableDelimiters() throws {
    let raw = "See [[id:abc][Alice]] and [Docs](https://example.com/docs) and `code`."
    let storage = NSTextStorage(string: raw)
    OrgSyntaxHighlighter.apply(to: storage, monospaced: false)
    let ns = raw as NSString

    let bracketIndex = try XCTUnwrap(optionalLocation(ns.range(of: "[[")))
    let orgTargetIndex = try XCTUnwrap(optionalLocation(ns.range(of: "id:abc")))
    let linkLabelIndex = try XCTUnwrap(optionalLocation(ns.range(of: "Alice")))
    let markdownTargetIndex = try XCTUnwrap(optionalLocation(ns.range(of: "https://example.com/docs")))
    let tickIndex = try XCTUnwrap(optionalLocation(ns.range(of: "`")))
    let codeIndex = try XCTUnwrap(optionalLocation(ns.range(of: "code")))

    let bracketColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: bracketIndex, effectiveRange: nil) as? NSColor)
    let tickColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: tickIndex, effectiveRange: nil) as? NSColor)
    XCTAssertLessThan(bracketColor.alphaComponent, 0.18)
    XCTAssertLessThan(tickColor.alphaComponent, 0.18)

    let labelColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: linkLabelIndex, effectiveRange: nil) as? NSColor)
    XCTAssertEqual(labelColor, NSColor.controlAccentColor)
    let labelUnderline = storage.attribute(.underlineStyle, at: linkLabelIndex, effectiveRange: nil) as? Int
    XCTAssertEqual(labelUnderline, NSUnderlineStyle.single.rawValue)

    let orgTargetColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: orgTargetIndex, effectiveRange: nil) as? NSColor)
    let markdownTargetColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: markdownTargetIndex, effectiveRange: nil) as? NSColor)
    XCTAssertLessThan(orgTargetColor.alphaComponent, 0.24)
    XCTAssertLessThan(markdownTargetColor.alphaComponent, 0.24)
    let targetUnderline = storage.attribute(.underlineStyle, at: orgTargetIndex, effectiveRange: nil) as? Int
    XCTAssertEqual(targetUnderline, 0)

    let bracketUnderline = storage.attribute(.underlineStyle, at: bracketIndex, effectiveRange: nil) as? Int
    XCTAssertEqual(bracketUnderline, 0)

    let codeBackground = storage.attribute(.backgroundColor, at: codeIndex, effectiveRange: nil) as? NSColor
    XCTAssertNotNil(codeBackground)
    let tickBackground = storage.attribute(.backgroundColor, at: tickIndex, effectiveRange: nil) as? NSColor
    XCTAssertEqual(tickBackground, NSColor.clear)
  }

  func testOrgSyntaxHighlighterSkipsLiveTokenizationForLargeBuffers() {
    XCTAssertTrue(OrgSyntaxHighlighter.shouldTokenizeLiveText(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit
    ))
    XCTAssertFalse(OrgSyntaxHighlighter.shouldTokenizeLiveText(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1
    ))
    XCTAssertEqual(OrgSyntaxHighlighter.utf16Length(of: "a😀"), 3)
    XCTAssertEqual(OrgSyntaxHighlighter.utf16Length(of: String(repeating: "a", count: 20), upTo: 5), 5)
    XCTAssertTrue(OrgSyntaxHighlighter.shouldTokenizeLiveText(
      String(repeating: "a", count: OrgSyntaxHighlighter.liveTokenizationUTF16Limit)
    ))
    XCTAssertFalse(OrgSyntaxHighlighter.shouldTokenizeLiveText(
      String(repeating: "a", count: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1)
    ))
    XCTAssertFalse(OrgSyntaxHighlighter.shouldPreserveExistingAttributesAfterEdit(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit,
      hasHighlightedBefore: true,
      monospacedUnchanged: true
    ))
    XCTAssertFalse(OrgSyntaxHighlighter.shouldPreserveExistingAttributesAfterEdit(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1,
      hasHighlightedBefore: false,
      monospacedUnchanged: true
    ))
    XCTAssertFalse(OrgSyntaxHighlighter.shouldPreserveExistingAttributesAfterEdit(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1,
      hasHighlightedBefore: true,
      monospacedUnchanged: false
    ))
    XCTAssertTrue(OrgSyntaxHighlighter.shouldPreserveExistingAttributesAfterEdit(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1,
      hasHighlightedBefore: true,
      monospacedUnchanged: true
    ))

    let smallStorage = NSTextStorage(string: "* TODO Small")
    OrgSyntaxHighlighter.apply(to: smallStorage, monospaced: false)
    let smallColor = smallStorage.attribute(
      .foregroundColor,
      at: 2,
      effectiveRange: nil
    ) as? NSColor
    XCTAssertEqual(smallColor, NSColor.controlAccentColor)

    let largeText = "* TODO Large\n" + String(
      repeating: "Body line with [[id:abc][Alice]] and <2026-06-12 Fri>.\n",
      count: 600
    )
    XCTAssertGreaterThan((largeText as NSString).length, OrgSyntaxHighlighter.liveTokenizationUTF16Limit)
    let largeStorage = NSTextStorage(string: largeText)
    OrgSyntaxHighlighter.apply(to: largeStorage, monospaced: false)
    let largeColor = largeStorage.attribute(
      .foregroundColor,
      at: 2,
      effectiveRange: nil
    ) as? NSColor
    XCTAssertEqual(largeColor, NSColor.textColor)
  }

  @MainActor
  func testSyntaxEditorPreservesLargeBufferAttributesAfterUserEdit() {
    let largeText = "* TODO Large\n" + String(
      repeating: "Body line with [[id:abc][Alice]] and <2026-06-12 Fri>.\n",
      count: 600
    )
    XCTAssertGreaterThan((largeText as NSString).length, OrgSyntaxHighlighter.liveTokenizationUTF16Limit)

    var boundText = largeText
    let editor = OrgSyntaxTextEditor(text: Binding(
      get: { boundText },
      set: { boundText = $0 }
    ))
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = largeText
    coordinator.applyHighlighting(to: textView)

    textView.textStorage?.addAttribute(
      .foregroundColor,
      value: NSColor.systemRed,
      range: NSRange(location: 0, length: 1)
    )
    textView.textStorage?.append(NSAttributedString(string: "x"))

    coordinator.markUserTextChangedForHighlighting(in: textView)
    coordinator.applyHighlightingIfNeeded(to: textView)

    let preservedColor = textView.textStorage?.attribute(
      .foregroundColor,
      at: 0,
      effectiveRange: nil
    ) as? NSColor
    XCTAssertEqual(preservedColor, NSColor.systemRed)
  }

  @MainActor
  func testSyntaxEditorSkipsPlainCaretSelectionPublishing() {
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldPublishSelection(
      NSRange(location: 12, length: 0),
      previousRange: NSRange(location: 11, length: 0),
      text: "Plain paragraph text"
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldPublishSelection(
      NSRange(location: 12, length: 4),
      previousRange: NSRange(location: 11, length: 0),
      text: "Plain paragraph text"
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldPublishSelection(
      NSRange(location: 12, length: 0),
      previousRange: NSRange(location: 11, length: 0),
      text: "See [[id:abc][Alice]]"
    ))

    let longLinkedText = "See [[id:abc][Alice]]. " + String(repeating: "plain text ", count: 120)
    let farCaret = NSRange(location: (longLinkedText as NSString).length, length: 0)
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldPublishSelection(
      farCaret,
      previousRange: NSRange(location: farCaret.location - 1, length: 0),
      text: longLinkedText
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.hasInlineSyntaxNearSelectionWindow(
      longLinkedText,
      selectedRange: NSRange(location: 8, length: 0),
      previousRange: NSRange(location: 9, length: 0)
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.hasInlineSyntaxNearSelectionWindow(
      longLinkedText,
      selectedRange: farCaret,
      previousRange: NSRange(location: farCaret.location - 1, length: 0)
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldPublishSelection(
      farCaret,
      previousRange: NSRange(location: 8, length: 0),
      text: longLinkedText
    ))
  }

  @MainActor
  func testSyntaxEditorSkipsSelectionTextReadWhenUnboundOrUnchanged() {
    var boundText = "Plain paragraph text"
    var selectionRange = NSRange(location: 4, length: 0)
    let unboundEditor = OrgSyntaxTextEditor(text: .constant(boundText))
    let unboundCoordinator = OrgSyntaxTextEditor.Coordinator(parent: unboundEditor)

    XCTAssertFalse(unboundCoordinator.shouldReadTextForSelectionPublishing(
      NSRange(location: 5, length: 0)
    ))

    let boundEditor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      selection: Binding(
        get: { selectionRange },
        set: { selectionRange = $0 }
      )
    )
    let boundCoordinator = OrgSyntaxTextEditor.Coordinator(parent: boundEditor)

    XCTAssertFalse(boundCoordinator.shouldReadTextForSelectionPublishing(
      NSRange(location: 4, length: 0)
    ))
    XCTAssertTrue(boundCoordinator.shouldReadTextForSelectionPublishing(
      NSRange(location: 5, length: 0)
    ))
  }

  @MainActor
  func testSyntaxEditorKnownTextCacheUsesStorageLength() {
    let editor = OrgSyntaxTextEditor(text: .constant("Initial text"))
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)

    coordinator.recordKnownText("Initial text", utf16Length: 12)

    XCTAssertEqual(coordinator.knownText(matchingUTF16Length: 12), "Initial text")
    XCTAssertNil(coordinator.knownText(matchingUTF16Length: 13))
    XCTAssertNil(coordinator.knownText(matchingUTF16Length: nil))

    coordinator.recordKnownText("Updated 😀", utf16Length: 10)

    XCTAssertEqual(coordinator.knownText(matchingUTF16Length: 10), "Updated 😀")
    XCTAssertNil(coordinator.knownText(matchingUTF16Length: 9))
  }

  @MainActor
  func testSyntaxEditorDoesNotApplyStalePlainCaretSelectionWhileFocused() {
    XCTAssertEqual(
      OrgSyntaxTextEditor.clampedRange(NSRange(location: 10, length: 5), utf16Length: 12),
      NSRange(location: 10, length: 2)
    )
    XCTAssertEqual(
      OrgSyntaxTextEditor.clampedRange(NSRange(location: -3, length: 2), utf16Length: 12),
      NSRange(location: 0, length: 2)
    )

    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldApplyExternalSelection(
      requestedSelection: NSRange(location: 2, length: 0),
      currentSelection: NSRange(location: 3, length: 0),
      isFirstResponder: true,
      didApplyProgrammaticText: false
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldApplyExternalSelection(
      requestedSelection: NSRange(location: 2, length: 0),
      currentSelection: NSRange(location: 3, length: 0),
      isFirstResponder: false,
      didApplyProgrammaticText: false
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldApplyExternalSelection(
      requestedSelection: NSRange(location: 2, length: 1),
      currentSelection: NSRange(location: 3, length: 0),
      isFirstResponder: true,
      didApplyProgrammaticText: false
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldApplyExternalSelection(
      requestedSelection: NSRange(location: 2, length: 0),
      currentSelection: NSRange(location: 3, length: 0),
      isFirstResponder: true,
      didApplyProgrammaticText: true
    ))
  }

  @MainActor
  func testSyntaxEditorRestoresVisibleOriginAfterHighlighting() {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
    scrollView.hasVerticalScroller = true
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 1_200))
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.textContainer?.containerSize = NSSize(width: 220, height: CGFloat.greatestFiniteMagnitude)
    textView.string = String(repeating: "* TODO Heading\nBody with [[id:abc][Alice]].\n", count: 80)
    scrollView.documentView = textView

    let targetOrigin = NSPoint(x: 0, y: 160)
    scrollView.contentView.scroll(to: targetOrigin)
    scrollView.reflectScrolledClipView(scrollView.contentView)

    let capturedOrigin = OrgSyntaxTextEditor.Coordinator.visibleOrigin(of: textView)
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)

    OrgSyntaxTextEditor.Coordinator.restoreVisibleOrigin(capturedOrigin, of: textView)

    XCTAssertEqual(scrollView.contentView.bounds.origin.x, targetOrigin.x, accuracy: 0.5)
    XCTAssertEqual(scrollView.contentView.bounds.origin.y, targetOrigin.y, accuracy: 0.5)
  }

  @MainActor
  func testSyntaxEditorDefersTextPublishingWithoutApplyingStaleBoundText() async throws {
    var boundText = "old"
    let liveText = OrgSyntaxTextEditorDraftBuffer()
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 20),
      onLocalTextChange: liveText.update
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = "new"

    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

    XCTAssertEqual(boundText, "old")
    XCTAssertEqual(liveText.current(fallback: ""), "new")
    XCTAssertTrue(coordinator.hasPendingTextPublishing(for: "new"))
    XCTAssertFalse(OrgSyntaxTextEditor.shouldApplyProgrammaticText(
      editorText: "new",
      boundText: "old",
      hasPendingLocalText: true
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.shouldApplyProgrammaticText(
      editorText: "new",
      boundText: "old",
      hasPendingLocalText: false
    ))

    try await Task.sleep(nanoseconds: 60_000_000)
    XCTAssertEqual(boundText, "new")
    XCTAssertFalse(coordinator.hasPendingTextPublishing(for: "new"))
  }

  @MainActor
  func testSyntaxEditorPublishesLatestDeferredTextAfterRapidEdits() async throws {
    var boundText = "old"
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 20)
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()

    textView.string = "first"
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    XCTAssertTrue(coordinator.hasPendingTextPublishing(for: "first"))

    textView.string = "second"
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    XCTAssertFalse(coordinator.hasPendingTextPublishing(for: "first"))
    XCTAssertTrue(coordinator.hasPendingTextPublishing(for: "second"))

    try await Task.sleep(nanoseconds: 70_000_000)
    XCTAssertEqual(boundText, "second")
    XCTAssertFalse(coordinator.hasPendingTextPublishing(for: "second"))
  }

  @MainActor
  func testSyntaxEditorAdaptivePublishingCanBypassDeferredText() {
    var boundText = "old"
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 2_000),
      shouldPublishTextImmediately: { $0.hasPrefix("/") }
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()

    textView.string = "plain"
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    XCTAssertEqual(boundText, "old")
    XCTAssertTrue(coordinator.hasPendingTextPublishing(for: "plain"))

    textView.string = "/todo"
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    XCTAssertEqual(boundText, "/todo")
    XCTAssertFalse(coordinator.hasPendingTextPublishing(for: "/todo"))
  }

  @MainActor
  func testSyntaxEditorDoesNotScheduleDeferredHighlightingForLargeBuffers() {
    let largeText = String(repeating: "Body with [[id:abc][Alice]].\n", count: 2_000)
    XCTAssertGreaterThan((largeText as NSString).length, OrgSyntaxHighlighter.liveTokenizationUTF16Limit)
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: largeText,
      previousHighlightedText: nil,
      monospacedUnchanged: true
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: largeText,
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1,
      previousHighlightedText: nil,
      monospacedUnchanged: true
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: "See [[id:abc][Alice]]",
      utf16Length: 22,
      previousHighlightedText: nil,
      monospacedUnchanged: true
    ))
  }

  @MainActor
  func testSyntaxEditorSkipsDeferredHighlightingForPlainTextEdits() {
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: "Plain paragraph text",
      previousHighlightedText: "Plain paragraph tex",
      monospacedUnchanged: true
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: "Plain paragraph text",
      previousHighlightedText: nil,
      monospacedUnchanged: true
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: "Plain paragraph text",
      previousHighlightedText: "See [[id:abc][Alice]]",
      monospacedUnchanged: true
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: "See [[id:abc][Alice]]",
      previousHighlightedText: "Plain paragraph text",
      monospacedUnchanged: true
    ))
  }

  func testInlineEditorSizingStopsAtVisibleLineCap() {
    XCTAssertEqual(
      InlineEditorSizing.endSelection(in: "abc"),
      NSRange(location: 3, length: 0)
    )
    XCTAssertEqual(
      InlineEditorSizing.endSelection(in: "a😀"),
      NSRange(location: 3, length: 0)
    )
    XCTAssertEqual(
      InlineEditorSizing.cappedLineCount(in: "", minimum: 1, maximum: 15),
      1
    )
    XCTAssertEqual(
      InlineEditorSizing.cappedLineCount(in: "one\ntwo\nthree", minimum: 1, maximum: 15),
      3
    )
    XCTAssertEqual(
      InlineEditorSizing.cappedLineCount(in: "one 😀\ntwo é\nthree", minimum: 1, maximum: 15),
      3
    )
    XCTAssertEqual(
      InlineEditorSizing.cappedLineCount(in: "one", minimum: 3, maximum: 15),
      3
    )
    XCTAssertEqual(
      InlineEditorSizing.cappedLineCount(
        in: (1...1_000).map { "line \($0)" }.joined(separator: "\n"),
        minimum: 1,
        maximum: 15
      ),
      15
    )
  }

  func testInlineEditorChromeKeepsStableHiddenControls() {
    XCTAssertTrue(InlineEditorChrome.rendersControls(true))
    XCTAssertTrue(InlineEditorChrome.rendersControls(false))
    XCTAssertEqual(InlineEditorChrome.controlsOpacity(true), 1)
    XCTAssertEqual(InlineEditorChrome.controlsOpacity(false), 0)
    XCTAssertTrue(InlineEditorChrome.allowsHitTesting(true))
    XCTAssertFalse(InlineEditorChrome.allowsHitTesting(false))
    XCTAssertEqual(InlineEditorChrome.accessoryOpacity(true), 1)
    XCTAssertEqual(InlineEditorChrome.accessoryOpacity(false), 0)
    XCTAssertEqual(InlineEditorChrome.savingIndicatorSize, 14)
    XCTAssertEqual(InlineEditorChrome.savingIndicatorOpacity(true), 1)
    XCTAssertEqual(InlineEditorChrome.savingIndicatorOpacity(false), 0)
  }

  func testParagraphFocusedInlineEditorSkipsPlainText() {
    XCTAssertFalse(ParagraphFocusedInlineEditor.shouldRender(
      text: "Plain paragraph without editable inline syntax",
      showsInlineDetails: false
    ))
    XCTAssertFalse(ParagraphFocusedInlineEditor.shouldRender(
      text: "Review [[id:abc][Alice]]",
      showsInlineDetails: true
    ))
    XCTAssertTrue(ParagraphFocusedInlineEditor.shouldRender(
      text: "Review [[id:abc][Alice]]",
      showsInlineDetails: false
    ))
    XCTAssertTrue(ParagraphFocusedInlineEditor.shouldRender(
      text: "Meet on <2026-06-13 Sat>",
      showsInlineDetails: false
    ))

    let longRichParagraph = "See [[id:abc][Alice]]. " + String(
      repeating: "Long paragraph body ",
      count: 900
    )
    XCTAssertGreaterThan((longRichParagraph as NSString).length, OrgEditableInlineToken.focusedScanUTF16Limit)
    XCTAssertFalse(ParagraphFocusedInlineEditor.shouldRender(
      text: longRichParagraph,
      showsInlineDetails: false
    ))
    XCTAssertNil(ParagraphFocusedInlineEditor.focusedToken(
      text: "Plain paragraph without editable inline syntax",
      selectedRange: NSRange(location: 6, length: 0),
      showsInlineDetails: false
    ))
    XCTAssertNil(ParagraphFocusedInlineEditor.focusedToken(
      text: longRichParagraph,
      selectedRange: NSRange(location: 6, length: 0),
      showsInlineDetails: false
    ))
  }

  func testParagraphFocusedInlineEditorFindsFocusedTokenOnce() {
    let raw = "See [[id:abc][Alice]] and `code`."
    let nsRaw = raw as NSString
    let aliceRange = nsRaw.range(of: "Alice")
    let codeRange = nsRaw.range(of: "code")

    let linkToken = ParagraphFocusedInlineEditor.focusedToken(
      text: raw,
      selectedRange: NSRange(location: aliceRange.location, length: 0),
      showsInlineDetails: false
    )
    if case .link(let link) = linkToken {
      XCTAssertEqual(link.label, "Alice")
      XCTAssertEqual(link.target, "id:abc")
    } else {
      XCTFail("Expected focused link token")
    }

    let hiddenToken = ParagraphFocusedInlineEditor.focusedToken(
      text: raw,
      selectedRange: NSRange(location: codeRange.location, length: 0),
      showsInlineDetails: true
    )
    XCTAssertNil(hiddenToken)
  }

  func testParagraphSlashCommandUsesBoundedPrefixScan() {
    XCTAssertEqual(ParagraphSlashCommand.query(in: "/todo"), "todo")
    XCTAssertEqual(ParagraphSlashCommand.query(in: " \n\t/source swift"), "source")
    XCTAssertEqual(ParagraphSlashCommand.query(in: "/"), "")
    XCTAssertNil(ParagraphSlashCommand.query(in: "Body /todo"))
    XCTAssertNil(ParagraphSlashCommand.query(in: String(
      repeating: " ",
      count: ParagraphSlashCommand.leadingWhitespaceScanLimit + 1
    ) + "/todo"))
    XCTAssertNil(ParagraphSlashCommand.query(in: "/" + String(
      repeating: "x",
      count: ParagraphSlashCommand.commandScanLimit + 1
    )))

    let todoMatch = ParagraphSlashCommand.match(in: "/todo Call Bob")
    XCTAssertEqual(todoMatch.query, "todo")
    XCTAssertEqual(todoMatch.primaryKind, .todo)
    XCTAssertEqual(todoMatch.kinds.first, .todo)

    let emptyMatch = ParagraphSlashCommand.match(in: "/")
    XCTAssertEqual(emptyMatch.query, "")
    XCTAssertEqual(emptyMatch.kinds, OrgInsertBlockKind.allCases)
    XCTAssertNil(emptyMatch.primaryKind)

    let noMatch = ParagraphSlashCommand.match(in: "Body /todo")
    XCTAssertNil(noMatch.query)
    XCTAssertEqual(noMatch.kinds, [])
    XCTAssertNil(noMatch.primaryKind)

    XCTAssertTrue(ParagraphSlashCommandPanelLayout.isVisible(match: todoMatch))
    XCTAssertTrue(ParagraphSlashCommandPanelLayout.isVisible(match: emptyMatch))
    XCTAssertFalse(ParagraphSlashCommandPanelLayout.isVisible(match: noMatch))
    XCTAssertEqual(ParagraphSlashCommandPanelLayout.verticalOffset(editorHeight: 1), 38)
    XCTAssertEqual(ParagraphSlashCommandPanelLayout.verticalOffset(editorHeight: 80), 110)
  }

  func testParagraphEditorTextPublishingPolicyKeepsRichStatesResponsive() {
    XCTAssertFalse(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("Plain paragraph text"))
    XCTAssertTrue(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("/todo"))
    XCTAssertTrue(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("See [[id:abc][Alice]]"))
    XCTAssertTrue(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("Meet <2026-06-12 Fri>"))
    XCTAssertTrue(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("Use `code`"))

    let longRichParagraph = "See [[id:abc][Alice]]. " + String(
      repeating: "Long paragraph body ",
      count: 180
    )
    XCTAssertGreaterThan((longRichParagraph as NSString).length, ParagraphEditorTextPublishingPolicy.richImmediateUTF16Limit)
    XCTAssertFalse(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately(longRichParagraph))
    XCTAssertTrue(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("/todo " + longRichParagraph))
  }

  func testOpenClawFileReferenceDeepLinkRoundTrips() throws {
    let reference = OpenClawFileReference(path: "file:notes/daily.org2#12", line: nil)
    let url = try XCTUnwrap(reference.deepLinkURL)
    let restored = try XCTUnwrap(OpenClawFileReference.fromDeepLinkURL(url))

    XCTAssertEqual(restored.path, "notes/daily.org2")
    XCTAssertEqual(restored.line, 12)
  }

  func testCorpusFileSplitsRelativePath() {
    let rootFile = CorpusFile(path: "/tmp/today.org2", relativePath: "today.org2", modifiedAt: nil, byteCount: 10)
    let nestedFile = CorpusFile(path: "/tmp/notes/people/alice.org2", relativePath: "notes/people/alice.org2", modifiedAt: nil, byteCount: 20)

    XCTAssertEqual(rootFile.directory, "")
    XCTAssertEqual(rootFile.name, "today.org2")
    XCTAssertEqual(nestedFile.directory, "notes/people")
    XCTAssertEqual(nestedFile.name, "alice.org2")
  }

  @MainActor
  func testOpenClawFileReferenceMapsRemotePathIntoDetailPane() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-link-\(UUID().uuidString)", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let note = notes.appendingPathComponent("alice.org2")
    try """
    #+TITLE: Alice

    * TODO Follow up
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.openClawRemoteCorpusPath = "/srv/org2"
    store.openChatFileReference(OpenClawFileReference(path: "/srv/org2/notes/alice.org2", line: 3))

    guard case .openClaw(let thread) = store.selectedLocation else {
      return XCTFail("Expected selected chat file reference")
    }
    XCTAssertEqual(thread.file, note.path)
    XCTAssertEqual(thread.lineForEditor, 3)
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
  }

  @MainActor
  func testCorpusFileBrowserScansFiltersAndOpensFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-files-\(UUID().uuidString)", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    let ignored = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)

    let alice = notes.appendingPathComponent("alice.org2")
    try """
    #+TITLE: Alice
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :END:

    * Note
    Body
    """.write(to: alice, atomically: true, encoding: .utf8)
    try "# Scratch\n".write(to: root.appendingPathComponent("scratch.md"), atomically: true, encoding: .utf8)
    try "ignored\n".write(to: ignored.appendingPathComponent("ignored.org2"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshCorpusFiles()

    XCTAssertEqual(store.corpusFiles.map(\.relativePath), ["notes/alice.org2", "scratch.md"])

    store.quickOpenQuery = "ali"
    XCTAssertEqual(store.quickOpenFiles.first?.relativePath, "notes/alice.org2")

    try await waitForCondition {
      !store.isScanningCorpusFiles
    }
    store.selectCorpusFile(try XCTUnwrap(store.quickOpenFiles.first))
    try await waitForCondition {
      store.selectedEntrySource?.file == alice.path && store.selectedLocation?.idValue == "11111111-1111-4111-8111-111111111111"
    }

    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    XCTAssertEqual(store.selectedEntrySource?.startLine, 1)
  }

  func testOpenClawWorkspaceContextMapsRemotePathsAndIncludesGraphSlice() throws {
    let localRoot = "/local/org2"
    let remoteRoot = "/srv/org2"
    let note = "\(localRoot)/notes/alice.org2"
    let backlinkFile = "\(localRoot)/threads/follow-up.org2"
    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Follow up with [[id:11111111-1111-4111-8111-111111111111][Alice]]",
      "kind": "SCHEDULED",
      "file": "\(note)",
      "line": 3,
      "body": "Fixture body",
      "level": 1,
      "tags": [],
      "properties": {},
      "id": "22222222-2222-4222-8222-222222222222"
    }
    """
    let backlinksJSON = """
    {
      "$schema": "org2:backlinks:v1",
      "id": "22222222-2222-4222-8222-222222222222",
      "backlinks": [
        {
          "srcId": null,
          "srcTitle": "Follow-up thread",
          "file": "\(backlinkFile)",
          "line": 7,
          "context": "Discuss [[id:22222222-2222-4222-8222-222222222222][Alice task]]"
        }
      ]
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let backlinks = try JSONDecoder().decode(BacklinksPayload.self, from: Data(backlinksJSON.utf8))
    let source = EntrySource(
      file: note,
      startLine: 4,
      endLineExclusive: 7,
      text: """
      * TODO Follow up with [[id:11111111-1111-4111-8111-111111111111][Alice]]
      SCHEDULED: <2026-06-12 Fri>
      Fixture body
      """,
      isSubtree: true
    )

    let context = OpenClawWorkspaceContext(
      localCorpusRoot: localRoot,
      remoteCorpusRoot: remoteRoot,
      selectedSurface: "Today",
      selectedLocation: .agenda(item),
      selectedEntrySource: source,
      backlinks: backlinks,
      agenda: nil,
      searchQuery: "",
      searchResults: []
    )

    let prompt = context.systemPrompt()

    XCTAssertTrue(prompt.contains("Remote org2 root for OpenClaw: \(remoteRoot)"))
    XCTAssertTrue(prompt.contains("Do not write generated Backlinks sections"))
    XCTAssertTrue(prompt.contains("org2 search <query> --dir <root>"))
    XCTAssertTrue(prompt.contains("\(remoteRoot)/notes/alice.org2:4"))
    XCTAssertTrue(prompt.contains("\(remoteRoot)/threads/follow-up.org2:8"))
    XCTAssertTrue(prompt.contains("~~~org"))
    XCTAssertFalse(prompt.contains(note))
    XCTAssertFalse(prompt.contains(backlinkFile))
  }

  func testCleansOrgLinksForDisplay() {
    XCTAssertEqual(
      Org2Display.cleanInline("Include [[id:c8277d02-6536-4766-9999-709e059edb47][Slack]] support"),
      "Include Slack support"
    )
    XCTAssertEqual(
      Org2Display.cleanInline("Bare id:c8277d02-6536-4766-9999-709e059edb47"),
      "Bare id:c8277d02"
    )
  }

  func testParsesRenderedOrgBlocks() {
    let blocks = OrgEntryRenderer.parse("""
    * TODO [#A] Parent [[id:c8277d02-6536-4766-9999-709e059edb47][Slack]] :work:
    SCHEDULED: <2026-06-12 Fri>
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :END:
    #+begin_quote
    Quote with [[id:c8277d02-6536-4766-9999-709e059edb47][Slack]]
    #+end_quote
    #+begin_src swift
    let value = 1
    #+end_src
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    -----
    - [ ] Open task
    - [X] Done task
    ** Child
    Body text
    """)

    guard case .heading(let heading) = blocks[0] else {
      return XCTFail("Expected heading")
    }
    XCTAssertEqual(heading.level, 1)
    XCTAssertEqual(heading.todo, "TODO")
    XCTAssertEqual(heading.priority, "A")
    XCTAssertEqual(heading.title, "Parent Slack")
    XCTAssertEqual(heading.tags, ["work"])

    XCTAssertTrue(blocks.contains(.planning(OrgPlanningBlock(kind: "SCHEDULED", value: "<2026-06-12 Fri>"))))
    XCTAssertTrue(blocks.contains(.properties([OrgPropertyRow(key: "ID", value: "11111111-1111-4111-8111-111111111111")])))
    XCTAssertTrue(blocks.contains(.quote(["Quote with Slack"])))
    XCTAssertTrue(blocks.contains(.source(language: "swift", lines: ["let value = 1"])))
    XCTAssertTrue(blocks.contains(.table(OrgTableBlock(rows: [
      .cells(["Name", "Value"]),
      .separator,
      .cells(["Alice", "42"])
    ]))))
    XCTAssertTrue(blocks.contains(.horizontalRule))
    XCTAssertTrue(blocks.contains {
      if case .listItem(0, "-", .unchecked, "Open task") = $0 { return true }
      return false
    })
    XCTAssertTrue(blocks.contains {
      if case .listItem(0, "-", .checked, "Done task") = $0 { return true }
      return false
    })
  }

  func testEditableTableFormatsAndMutatesOrgTableText() {
    var table = OrgEditableTable(rawText: """
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    """)

    XCTAssertEqual(table.columnCount, 2)
    XCTAssertEqual(table.renderedBlock.headerRowIndex, 0)
    XCTAssertEqual(table.formattedRawText, """
    | Name  | Value |
    |-------+-------|
    | Alice | 42    |
    """)

    table.setCell(row: 2, column: 1, value: "43")
    table.addColumn()
    table.setCell(row: 0, column: 2, value: "Owner")
    table.setCell(row: 2, column: 2, value: "Avi")
    table.addRow(after: 2)
    table.setCell(row: 3, column: 0, value: "Bob")
    table.setCell(row: 3, column: 1, value: "12")
    table.removeColumn(1)

    XCTAssertEqual(table.formattedRawText, """
    | Name  | Owner |
    |-------+-------|
    | Alice | Avi   |
    | Bob   |       |
    """)

    XCTAssertNil(OrgEditableTable(rawText: """
    | Name | Value |
    | Alice | 42 |
    """).renderedBlock.headerRowIndex)
  }

  func testEditableTablePastesTabSeparatedGrid() {
    var table = OrgEditableTable(rawText: """
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    """)

    XCTAssertTrue(table.pasteGrid(row: 0, column: 0, rawValue: "Metric\tScore\nQuality\t9\nSpeed\t8\n"))

    XCTAssertEqual(table.formattedRawText, """
    | Metric  | Score |
    |---------+-------|
    | Quality | 9     |
    | Speed   | 8     |
    """)

    XCTAssertFalse(table.pasteGrid(row: 2, column: 1, rawValue: "single cell"))
    table.setCell(row: 2, column: 1, value: "10")
    XCTAssertEqual(table.cell(row: 2, column: 1), "10")
  }

  func testEditablePropertyDrawerFormatsAndMutatesRows() {
    var drawer = OrgEditablePropertyDrawer(rawText: """
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :owner: agent
    :EMPTY:
    :END:
    """)

    XCTAssertEqual(drawer.rows, [
      OrgEditablePropertyRow(key: "ID", value: "11111111-1111-4111-8111-111111111111"),
      OrgEditablePropertyRow(key: "owner", value: "agent"),
      OrgEditablePropertyRow(key: "EMPTY", value: "")
    ])

    drawer.setValue(at: 1, value: "openclaw")
    drawer.removeProperty(at: 2)
    drawer.addProperty(key: "status", value: "active")

    XCTAssertEqual(drawer.formattedRawText, """
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :OWNER: openclaw
    :STATUS: active
    :END:
    """)
    XCTAssertEqual(drawer.renderedRows, [
      OrgPropertyRow(key: "ID", value: "11111111-1111-4111-8111-111111111111"),
      OrgPropertyRow(key: "OWNER", value: "openclaw"),
      OrgPropertyRow(key: "STATUS", value: "active")
    ])
  }

  func testOrgPropertyDrawerRawValueCacheUsesExactText() {
    let raw = """
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :Owner: Alice
    :END:
    """
    let key = OrgPropertyDrawerRawValueCache.CacheKey(rawText: raw)
    let matchingKey = OrgPropertyDrawerRawValueCache.CacheKey(rawText: raw)
    let differentKey = OrgPropertyDrawerRawValueCache.CacheKey(rawText: raw + "\n")

    XCTAssertEqual(key, matchingKey)
    XCTAssertEqual(key.hash, matchingKey.hash)
    XCTAssertNotEqual(key, differentKey)
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(nil), [:])
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(raw)["OWNER"], "Alice")
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(raw)["ID"], "11111111-1111-4111-8111-111111111111")
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(raw)["PROPERTIES"], nil)
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(raw)["END"], nil)
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(raw), OrgPropertyDrawerRawValueCache.values(raw))
  }

  func testEditableInlineLinkSetRewritesLinksInParagraphs() {
    let set = OrgEditableInlineLinkSet(rawText: """
    See [[id:11111111-1111-4111-8111-111111111111][Alice]], [docs](https://example.com/docs), and ~/notes/project.org2:12.
    """)

    XCTAssertEqual(set.links.map(\.kind), [.orgBracket, .markdown, .fileReference])
    XCTAssertEqual(set.links.map(\.label), ["Alice", "docs", "project.org2:12"])
    XCTAssertEqual(set.links.map(\.target), [
      "id:11111111-1111-4111-8111-111111111111",
      "https://example.com/docs",
      "~/notes/project.org2:12"
    ])

    let updatedLabel = set.replacing(link: set.links[0], label: "Alicia")
    XCTAssertTrue(updatedLabel.contains("[[id:11111111-1111-4111-8111-111111111111][Alicia]]"))

    let updatedTarget = set.replacing(link: set.links[1], target: "https://example.com/reference")
    XCTAssertTrue(updatedTarget.contains("[[https://example.com/reference][docs]]"))

    let updatedFile = set.replacing(link: set.links[2], label: "Project")
    XCTAssertTrue(updatedFile.contains("[[~/notes/project.org2:12][Project]]."))
  }

  func testEditableInlineLinkSetTrimsTrailingURLPunctuation() {
    let set = OrgEditableInlineLinkSet(rawText: "Open https://example.com/docs.")

    XCTAssertEqual(set.links.count, 1)
    XCTAssertEqual(set.links[0].target, "https://example.com/docs")
    XCTAssertEqual(
      set.replacing(link: set.links[0], label: "Docs"),
      "Open [[https://example.com/docs][Docs]]."
    )
  }

  func testEditableInlineTimestampSetRewritesTimestampsInParagraphs() {
    let set = OrgEditableInlineTimestampSet(rawText: "Meet <2026-06-12 Fri 09:00-10:00 +1w> and review [2026-06-13 Sat].")

    XCTAssertEqual(set.timestamps.count, 2)
    XCTAssertEqual(set.timestamps[0].date, "2026-06-12")
    XCTAssertEqual(set.timestamps[0].time, "09:00-10:00")
    XCTAssertEqual(set.timestamps[0].detail, "+1w")
    XCTAssertTrue(set.timestamps[0].isActive)
    XCTAssertEqual(set.timestamps[1].date, "2026-06-13")
    XCTAssertEqual(set.timestamps[1].time, "")
    XCTAssertEqual(set.timestamps[1].detail, "")
    XCTAssertFalse(set.timestamps[1].isActive)

    XCTAssertEqual(
      set.replacing(timestamp: set.timestamps[0], date: "2026-06-14", time: "11:30", detail: "+2w"),
      "Meet <2026-06-14 Sun 11:30 +2w> and review [2026-06-13 Sat]."
    )

    XCTAssertEqual(
      set.replacing(timestamp: set.timestamps[1], isActive: true),
      "Meet <2026-06-12 Fri 09:00-10:00 +1w> and review <2026-06-13 Sat>."
    )
  }

  func testEditableInlineTimestampSetAllowsPartialDateDrafts() {
    let set = OrgEditableInlineTimestampSet(rawText: "Due <2026-06-12 Fri>.")

    let updated = set.replacing(timestamp: set.timestamps[0], date: "2026-06")
    XCTAssertEqual(updated, "Due <2026-06>.")

    let partialSet = OrgEditableInlineTimestampSet(rawText: updated)
    XCTAssertEqual(partialSet.timestamps.count, 1)
    XCTAssertEqual(partialSet.timestamps[0].date, "2026-06")
  }

  func testEditableInlineMarkupSetRewritesDelimitedMarkup() {
    let set = OrgEditableInlineMarkupSet(rawText: "Use `code`, *bold*, /italic/, _under_, +gone+, ~verb~, and =lit=.")

    XCTAssertEqual(set.markups.map(\.kind), [.code, .bold, .italic, .underline, .strike, .code, .code])
    XCTAssertEqual(set.markups.map(\.text), ["code", "bold", "italic", "under", "gone", "verb", "lit"])

    XCTAssertEqual(
      set.replacing(markup: set.markups[0], text: "new code"),
      "Use `new code`, *bold*, /italic/, _under_, +gone+, ~verb~, and =lit=."
    )

    XCTAssertEqual(
      set.replacing(markup: set.markups[2], kind: .bold),
      "Use `code`, *bold*, *italic*, _under_, +gone+, ~verb~, and =lit=."
    )
  }

  func testEditableInlineMarkupSetSkipsLinksAndTimestamps() {
    let set = OrgEditableInlineMarkupSet(rawText: "See [[id:abc][*Alice*]], [*docs*](https://example.com), and <2026-06-12 Fri +1w>.")

    XCTAssertTrue(set.markups.isEmpty)
  }

  func testEditableInlineMarkupSetWrapsSelection() {
    let edit = OrgEditableInlineMarkupSet.wrappingSelection(
      in: "hello world",
      range: NSRange(location: 6, length: 5),
      kind: .bold
    )

    XCTAssertEqual(edit.text, "hello *world*")
    XCTAssertEqual(edit.selectedRange, NSRange(location: 7, length: 5))

    let inserted = OrgEditableInlineMarkupSet.wrappingSelection(
      in: "hello world",
      range: NSRange(location: 6, length: 0),
      kind: .code
    )

    XCTAssertEqual(inserted.text, "hello `code`world")
    XCTAssertEqual(inserted.selectedRange, NSRange(location: 7, length: 4))
  }

  func testEditableInlineTokenFindsFocusedTokenAtCaretOrSelection() {
    let raw = "See [[id:abc][Alice]] on <2026-06-12 Fri> with `code`."

    let linkToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: 8, length: 0))
    if case .link(let link) = linkToken {
      XCTAssertEqual(link.label, "Alice")
      XCTAssertEqual(link.target, "id:abc")
    } else {
      XCTFail("Expected focused link token")
    }

    let timestampToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: 27, length: 0))
    if case .timestamp(let timestamp) = timestampToken {
      XCTAssertEqual(timestamp.date, "2026-06-12")
    } else {
      XCTFail("Expected focused timestamp token")
    }

    let markupToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: 52, length: 0))
    if case .markup(let markup) = markupToken {
      XCTAssertEqual(markup.kind, .code)
      XCTAssertEqual(markup.text, "code")
    } else {
      XCTFail("Expected focused markup token")
    }

    let selectedToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: 5, length: 12))
    if case .link = selectedToken {
    } else {
      XCTFail("Expected selected range to focus overlapping link")
    }
  }

  func testEditableInlineTokenSkipsPlainParagraphs() {
    let raw = String(repeating: "plain text without inline org markers ", count: 200)
    let nsRaw = raw as NSString

    XCTAssertFalse(OrgInlineParser.hasInlineSyntaxCandidate(raw))
    XCTAssertEqual(OrgEditableInlineToken.boundedUTF16Length(in: raw), nsRaw.length)
    XCTAssertNil(OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: nsRaw.length / 2, length: 0)))
  }

  func testEditableInlineTokenSkipsFocusedScanForLargeParagraphs() {
    let prefix = String(repeating: "x", count: OrgEditableInlineToken.focusedScanUTF16Limit + 1)
    let raw = "\(prefix) [[id:abc][Alice]]"
    let nsRaw = raw as NSString
    let aliceRange = nsRaw.range(of: "Alice")

    XCTAssertFalse(OrgEditableInlineToken.shouldScanFocusedToken(utf16Length: nsRaw.length))
    XCTAssertNil(OrgEditableInlineToken.boundedUTF16Length(in: raw))
    XCTAssertNil(OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: aliceRange.location, length: 0)))

    let smallRaw = "See [[id:abc][Alice]]"
    let smallNSRaw = smallRaw as NSString
    let smallAliceRange = smallNSRaw.range(of: "Alice")
    let focused = OrgEditableInlineToken.focused(
      in: smallRaw,
      selection: NSRange(location: smallAliceRange.location, length: 0),
      maxUTF16Length: smallNSRaw.length
    )

    if case .link(let link) = focused {
      XCTAssertEqual(link.label, "Alice")
      XCTAssertEqual(link.target, "id:abc")
    } else {
      XCTFail("Expected focused link token when scan limit permits it")
    }
  }

  func testEditingDraftAppendsToHeadingTitlePreservingStructure() {
    let heading = OrgEditableBlock(
      startLine: 3,
      endLineExclusive: 4,
      rawText: "* TODO [#A] Parent :work:",
      rendered: .heading(OrgHeadingBlock(level: 1, todo: "TODO", priority: "A", title: "Parent", tags: ["work"]))
    )
    XCTAssertEqual(
      WorkspaceStore.editingDraft(heading, appending: "!"),
      "* TODO [#A] Parent! :work:"
    )

    let emptyTodo = OrgEditableBlock(
      startLine: 4,
      endLineExclusive: 5,
      rawText: "** TODO",
      rendered: .heading(OrgHeadingBlock(level: 2, todo: "TODO", priority: nil, title: "", tags: []))
    )
    XCTAssertEqual(
      WorkspaceStore.editingDraft(emptyTodo, appending: "Call Bob"),
      "** TODO Call Bob"
    )
  }

  func testEditableInlineTokenUsesBoundedUTF16Length() {
    XCTAssertEqual(
      OrgEditableInlineToken.boundedUTF16Length(in: "abcd", maxUTF16Length: 4),
      4
    )
    XCTAssertNil(OrgEditableInlineToken.boundedUTF16Length(in: "abcde", maxUTF16Length: 4))
    XCTAssertEqual(
      OrgEditableInlineToken.boundedUTF16Length(in: "a😀", maxUTF16Length: 3),
      3
    )
    XCTAssertNil(OrgEditableInlineToken.boundedUTF16Length(in: "a😀", maxUTF16Length: 2))
    XCTAssertNil(OrgEditableInlineToken.boundedUTF16Length(in: "", maxUTF16Length: -1))
  }

  func testEditableInlineTokenUsesLocalScanForLargeParagraphs() {
    let prefix = String(repeating: "x", count: OrgEditableInlineToken.focusedFullParseUTF16Limit + 32)
    let raw = "\(prefix) See [[id:abc][Alice]] on <2026-06-12 Fri> with `code`."
    let nsRaw = raw as NSString

    let aliceRange = nsRaw.range(of: "Alice")
    let linkToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: aliceRange.location, length: 0))
    if case .link(let link) = linkToken {
      XCTAssertEqual(link.id, "link:\(nsRaw.range(of: "[[id:abc][Alice]]").location)")
      XCTAssertEqual(link.label, "Alice")
      XCTAssertEqual(link.target, "id:abc")
    } else {
      XCTFail("Expected focused link token in large paragraph")
    }

    let timestampRange = nsRaw.range(of: "2026-06-12")
    let timestampToken = OrgEditableInlineToken.focused(
      in: raw,
      selection: NSRange(location: timestampRange.location, length: 0)
    )
    if case .timestamp(let timestamp) = timestampToken {
      XCTAssertEqual(timestamp.id, "timestamp:\(nsRaw.range(of: "<2026-06-12 Fri>").location)")
      XCTAssertEqual(timestamp.date, "2026-06-12")
    } else {
      XCTFail("Expected focused timestamp token in large paragraph")
    }

    let codeRange = nsRaw.range(of: "code")
    let markupToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: codeRange.location, length: 0))
    if case .markup(let markup) = markupToken {
      XCTAssertEqual(markup.id, "markup:\(nsRaw.range(of: "`code`").location)")
      XCTAssertEqual(markup.text, "code")
    } else {
      XCTFail("Expected focused markup token in large paragraph")
    }
  }

  func testRenderedEntryMoveAvailabilityUsesStableSignatures() {
    let blocks = [
      OrgEditableBlock(
        id: "heading",
        startLine: 1,
        endLineExclusive: 2,
        rawText: "* Parent",
        rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Parent", tags: []))
      ),
      OrgEditableBlock(
        id: "first",
        startLine: 2,
        endLineExclusive: 3,
        rawText: "First",
        rendered: .paragraph("First")
      ),
      OrgEditableBlock(
        id: "blank",
        startLine: 3,
        endLineExclusive: 4,
        rawText: "",
        rendered: .blank
      ),
      OrgEditableBlock(
        id: "last",
        startLine: 4,
        endLineExclusive: 5,
        rawText: "Last",
        rendered: .paragraph("Last")
      )
    ]
    let source = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 5,
      text: "",
      isSubtree: true
    )
    let sourceContext = OrgRenderedEntrySourceContext(source)

    let availability = OrgRenderedEntryMoveAvailability.make(for: blocks, source: sourceContext)
    XCTAssertEqual(
      availability.signature,
      OrgRenderedEntryMoveAvailability.signature(for: blocks, source: sourceContext)
    )
    XCTAssertNil(availability.values["heading"])
    XCTAssertEqual(availability.values["first"], OrgRenderedEntryBlockMoveAvailability(up: false, down: true))
    XCTAssertNil(availability.values["blank"])
    XCTAssertEqual(availability.values["last"], OrgRenderedEntryBlockMoveAvailability(up: true, down: false))

    let readOnlySource = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 5,
      text: "",
      isSubtree: true,
      isEditable: false
    )
    XCTAssertTrue(
      OrgRenderedEntryMoveAvailability.make(
        for: blocks,
        source: OrgRenderedEntrySourceContext(readOnlySource)
      ).values.isEmpty
    )
  }

  func testRenderedEntryMoveAvailabilityOnlyStoresVisibleRows() {
    let blocks = [
      OrgEditableBlock(
        id: "heading",
        startLine: 1,
        endLineExclusive: 2,
        rawText: "* Parent",
        rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Parent", tags: []))
      ),
      OrgEditableBlock(
        id: "first",
        startLine: 2,
        endLineExclusive: 3,
        rawText: "First",
        rendered: .paragraph("First")
      ),
      OrgEditableBlock(
        id: "middle",
        startLine: 3,
        endLineExclusive: 4,
        rawText: "Middle",
        rendered: .paragraph("Middle")
      ),
      OrgEditableBlock(
        id: "last",
        startLine: 4,
        endLineExclusive: 5,
        rawText: "Last",
        rendered: .paragraph("Last")
      )
    ]
    let source = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 5,
      text: "",
      isSubtree: true
    )
    let sourceContext = OrgRenderedEntrySourceContext(source)

    let availability = OrgRenderedEntryMoveAvailability.make(
      for: blocks,
      source: sourceContext,
      visibleRange: 2..<3
    )

    XCTAssertEqual(
      availability.signature,
      OrgRenderedEntryMoveAvailability.signature(for: blocks, source: sourceContext, visibleRange: 2..<3)
    )
    XCTAssertNil(availability.values["first"])
    XCTAssertEqual(availability.values["middle"], OrgRenderedEntryBlockMoveAvailability(up: true, down: true))
    XCTAssertNil(availability.values["last"])
  }

  func testRenderedEntryMoveAvailabilityWindowsLargePages() {
    let blocks = (1...1_500).map { index in
      OrgEditableBlock(
        id: "block-\(index)",
        startLine: index,
        endLineExclusive: index + 1,
        rawText: "Block \(index)",
        rendered: .paragraph("Block \(index)")
      )
    }
    let source = EntrySource(
      file: "/tmp/large.org2",
      startLine: 1,
      endLineExclusive: 1_501,
      text: "",
      isSubtree: false
    )

    let availability = OrgRenderedEntryMoveAvailability.make(
      for: blocks,
      source: OrgRenderedEntrySourceContext(source),
      visibleRange: 700..<704
    )

    XCTAssertEqual(Set(availability.values.keys), Set(["block-701", "block-702", "block-703", "block-704"]))
    XCTAssertEqual(availability.values["block-701"], OrgRenderedEntryBlockMoveAvailability(up: true, down: true))
    XCTAssertNil(availability.values["block-1"])
    XCTAssertNil(availability.values["block-1500"])
  }

  func testRenderedEntryMoveAvailabilitySignatureChangesWhenEditabilityChanges() {
    let editableBlock = OrgEditableBlock(
      id: "middle",
      startLine: 2,
      endLineExclusive: 3,
      rawText: "Middle",
      rendered: .paragraph("Middle")
    )
    let blankBlock = OrgEditableBlock(
      id: "middle",
      startLine: 2,
      endLineExclusive: 3,
      rawText: "",
      rendered: .blank
    )
    let source = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 4,
      text: "",
      isSubtree: false
    )
    let sourceContext = OrgRenderedEntrySourceContext(source)

    XCTAssertNotEqual(
      OrgRenderedEntryMoveAvailability.signature(for: [editableBlock], source: sourceContext),
      OrgRenderedEntryMoveAvailability.signature(for: [blankBlock], source: sourceContext)
    )
  }

  func testRenderedEntryWindowResetKeyIgnoresEditedSourceLength() {
    let source = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 50,
      text: "",
      isSubtree: false
    )
    let editedSource = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 54,
      text: "",
      isSubtree: false
    )
    let differentStart = EntrySource(
      file: "/tmp/test.org2",
      startLine: 4,
      endLineExclusive: 54,
      text: "",
      isSubtree: false
    )
    let readOnlySource = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 54,
      text: "",
      isSubtree: false,
      isEditable: false
    )

    XCTAssertEqual(
      OrgRenderedEntryView.renderWindowResetKey(for: source),
      OrgRenderedEntryView.renderWindowResetKey(for: editedSource)
    )
    XCTAssertNotEqual(
      OrgRenderedEntryView.renderWindowResetKey(for: source),
      OrgRenderedEntryView.renderWindowResetKey(for: differentStart)
    )
    XCTAssertNotEqual(
      OrgRenderedEntryView.renderWindowResetKey(for: source),
      OrgRenderedEntryView.renderWindowResetKey(for: readOnlySource)
    )
    XCTAssertEqual(OrgRenderedEntryView.renderWindowResetKey(for: nil as EntrySource?), "none")
  }

  func testRenderedEntryWindowAnchorsDeepSelections() {
    let blocks = (1...500).map { line in
      OrgEditableBlock(
        id: "block-\(line)",
        startLine: line,
        endLineExclusive: line + 1,
        rawText: "Line \(line)",
        rendered: .paragraph("Line \(line)")
      )
    }

    let topWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: nil,
      blocks: blocks,
      selectedBlockIndex: nil
    )
    XCTAssertEqual(topWindow.range.lowerBound, 0)
    XCTAssertEqual(topWindow.range.upperBound, 80)
    XCTAssertLessThan(topWindow.range.upperBound, blocks.count)
    XCTAssertFalse(topWindow.hasPrevious)
    XCTAssertTrue(topWindow.hasNext)
    XCTAssertFalse(OrgRenderedEntryView.allowsHoverChrome(blockCount: blocks.count))
    XCTAssertTrue(OrgRenderedEntryView.allowsHoverChrome(blockCount: 80))
    XCTAssertTrue(OrgRenderedEntryView.shouldAutoExpandNextFooter(visibleWindow: topWindow))

    let selectedIndex = 360
    let anchoredWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: nil,
      blocks: blocks,
      selectedBlockIndex: selectedIndex
    )
    XCTAssertTrue(anchoredWindow.range.contains(selectedIndex))
    XCTAssertGreaterThan(anchoredWindow.range.lowerBound, 0)
    XCTAssertLessThan(anchoredWindow.range.upperBound, blocks.count)
    XCTAssertLessThan(anchoredWindow.range.count, topWindow.range.upperBound)
    XCTAssertTrue(anchoredWindow.hasPrevious)
    XCTAssertTrue(anchoredWindow.hasNext)
    XCTAssertFalse(OrgRenderedEntryView.shouldAutoExpandNextFooter(visibleWindow: anchoredWindow))
  }

  func testRenderedRowChromeUsesStableHiddenState() {
    XCTAssertTrue(RenderedRowChrome.rendersControls(isVisible: true))
    XCTAssertTrue(RenderedRowChrome.rendersControls(isVisible: false))
    XCTAssertEqual(RenderedRowChrome.controlsOpacity(isVisible: true), 1)
    XCTAssertEqual(RenderedRowChrome.controlsOpacity(isVisible: false), 0)
    XCTAssertTrue(RenderedRowChrome.allowsHitTesting(isVisible: true))
    XCTAssertFalse(RenderedRowChrome.allowsHitTesting(isVisible: false))
    XCTAssertTrue(RenderedRowChrome.rendersControlLayer(
      isSourceEditable: true,
      allowsHoverChrome: true,
      isSelected: false
    ))
    XCTAssertFalse(RenderedRowChrome.rendersControlLayer(
      isSourceEditable: true,
      allowsHoverChrome: false,
      isSelected: false
    ))
    XCTAssertTrue(RenderedRowChrome.rendersControlLayer(
      isSourceEditable: true,
      allowsHoverChrome: false,
      isSelected: true
    ))
    XCTAssertFalse(RenderedRowChrome.rendersControlLayer(
      isSourceEditable: false,
      allowsHoverChrome: true,
      isSelected: true
    ))
    XCTAssertEqual(
      RenderedRowChrome.contentTrailingPadding(
        isSourceEditable: true,
        allowsHoverChrome: true,
        isSelected: false
      ),
      RenderedRowChrome.controlsReserveWidth
    )
    XCTAssertEqual(
      RenderedRowChrome.contentTrailingPadding(
        isSourceEditable: true,
        allowsHoverChrome: false,
        isSelected: false
      ),
      0
    )
    XCTAssertEqual(
      RenderedRowChrome.contentTrailingPadding(
        isSourceEditable: true,
        allowsHoverChrome: false,
        isSelected: true
      ),
      RenderedRowChrome.controlsReserveWidth
    )
    XCTAssertEqual(
      RenderedRowChrome.contentTrailingPadding(
        isSourceEditable: false,
        allowsHoverChrome: true,
        isSelected: true
      ),
      0
    )
  }

  @MainActor
  func testRenderedBlockViewEqualityUsesCachedRenderIdentity() {
    let longBody = String(repeating: "Long plain paragraph body.\n", count: 1_500)
    let updatedBody = longBody + "Updated"
    let initialBlock = OrgEditableBlock(
      id: "paragraph",
      startLine: 12,
      endLineExclusive: 1_512,
      rawText: longBody,
      rendered: .paragraph(longBody)
    )
    let sameBlock = OrgEditableBlock(
      id: "paragraph",
      startLine: 12,
      endLineExclusive: 1_512,
      rawText: longBody,
      rendered: .paragraph(longBody)
    )
    let updatedBlock = OrgEditableBlock(
      id: "paragraph",
      startLine: 12,
      endLineExclusive: 1_512,
      rawText: updatedBody,
      rendered: .paragraph(updatedBody)
    )

    XCTAssertEqual(initialBlock.renderIdentity, sameBlock.renderIdentity)
    XCTAssertNotEqual(initialBlock.renderIdentity, updatedBlock.renderIdentity)
    XCTAssertEqual(
      RenderedBlockView(block: initialBlock.rendered, rawText: initialBlock.rawText, editableBlock: initialBlock),
      RenderedBlockView(block: sameBlock.rendered, rawText: sameBlock.rawText, editableBlock: sameBlock)
    )
    XCTAssertNotEqual(
      RenderedBlockView(block: initialBlock.rendered, rawText: initialBlock.rawText, editableBlock: initialBlock),
      RenderedBlockView(block: updatedBlock.rendered, rawText: updatedBlock.rawText, editableBlock: updatedBlock)
    )
  }

  @MainActor
  func testRenderedEntryViewEqualityUsesRenderContext() {
    let source = EntrySource(
      file: "/tmp/render-context.org2",
      startLine: 1,
      endLineExclusive: 3,
      text: "Alpha\nBeta",
      isSubtree: false
    )
    let sourceContext = OrgRenderedEntrySourceContext(source)
    let editedTextSourceContext = OrgRenderedEntrySourceContext(EntrySource(
      file: "/tmp/render-context.org2",
      startLine: 1,
      endLineExclusive: 3,
      text: "Alpha\nBeta\nEdited",
      isSubtree: false
    ))
    let blocks = [
      OrgEditableBlock(
        id: "alpha",
        startLine: 1,
        endLineExclusive: 2,
        rawText: "Alpha",
        rendered: .paragraph("Alpha")
      ),
      OrgEditableBlock(
        id: "source",
        startLine: 2,
        endLineExclusive: 3,
        rawText: "#+begin_src sh\necho hi\n#+end_src",
        rendered: .source(language: "sh", lines: ["echo hi"])
      )
    ]
    let signature = WorkspaceStore.renderedBlocksRenderSignature(for: blocks)
    let base = OrgRenderedEntryView(
      blocks: blocks,
      blocksRenderSignature: signature,
      source: sourceContext,
      corpusRoot: nil,
      selectedBlockID: nil,
      selectedBlockIndex: nil,
      editingBlockID: nil,
      sourceBlockRuns: [:]
    )

    XCTAssertEqual(
      base,
      OrgRenderedEntryView(
        blocks: blocks,
        blocksRenderSignature: signature,
        source: editedTextSourceContext,
        corpusRoot: nil,
        selectedBlockID: nil,
        selectedBlockIndex: nil,
        editingBlockID: nil,
        sourceBlockRuns: [:]
      )
    )

    var updatedBlocks = blocks
    updatedBlocks[0] = OrgEditableBlock(
      id: "alpha",
      startLine: 1,
      endLineExclusive: 2,
      rawText: "Alpha updated",
      rendered: .paragraph("Alpha updated")
    )
    XCTAssertNotEqual(
      base,
      OrgRenderedEntryView(
        blocks: updatedBlocks,
        blocksRenderSignature: WorkspaceStore.renderedBlocksRenderSignature(for: updatedBlocks),
        source: sourceContext,
        corpusRoot: nil,
        selectedBlockID: nil,
        selectedBlockIndex: nil,
        editingBlockID: nil,
        sourceBlockRuns: [:]
      )
    )

    XCTAssertNotEqual(
      base,
      OrgRenderedEntryView(
        blocks: blocks,
        blocksRenderSignature: signature,
        source: sourceContext,
        corpusRoot: nil,
        selectedBlockID: "alpha",
        selectedBlockIndex: 0,
        editingBlockID: nil,
        sourceBlockRuns: [:]
      )
    )

    XCTAssertEqual(
      base,
      OrgRenderedEntryView(
        blocks: blocks,
        blocksRenderSignature: signature,
        source: sourceContext,
        corpusRoot: nil,
        selectedBlockID: nil,
        selectedBlockIndex: nil,
        editingBlockID: nil,
        sourceBlockRuns: [:]
      )
    )

    XCTAssertNotEqual(
      base,
      OrgRenderedEntryView(
        blocks: blocks,
        blocksRenderSignature: signature,
        source: sourceContext,
        corpusRoot: nil,
        selectedBlockID: nil,
        selectedBlockIndex: nil,
        editingBlockID: nil,
        sourceBlockRuns: [
          "/tmp/render-context.org2:source": SourceBlockRunState(
            status: .succeeded,
            language: "sh",
            commandLabel: "sh",
            stdout: "hi\n"
          )
        ]
      )
    )
  }

  func testRenderedEntryWindowExpandsAndKeepsSelectionVisible() {
    let blocks = (1...500).map { line in
      OrgEditableBlock(
        id: "block-\(line)",
        startLine: line,
        endLineExclusive: line + 1,
        rawText: "Line \(line)",
        rendered: .paragraph("Line \(line)")
      )
    }

    let selectedIndex = 360
    let anchoredWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: nil,
      blocks: blocks,
      selectedBlockIndex: selectedIndex
    )
    let expandedPrevious = anchoredWindow.expanding(.previous, by: 50, totalCount: blocks.count)
    XCTAssertLessThan(expandedPrevious.lowerBound, anchoredWindow.range.lowerBound)
    XCTAssertEqual(expandedPrevious.upperBound, anchoredWindow.range.upperBound)

    let expandedNext = anchoredWindow.expanding(.next, by: 50, totalCount: blocks.count)
    XCTAssertEqual(expandedNext.lowerBound, anchoredWindow.range.lowerBound)
    XCTAssertGreaterThan(expandedNext.upperBound, anchoredWindow.range.upperBound)
    XCTAssertFalse(OrgRenderedEntryView.shouldAutoExpandNextFooter(
      visibleWindow: OrgRenderedBlockWindow(range: expandedNext, totalCount: blocks.count)
    ))

    let requestedWindow = 0..<40
    let correctedWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: requestedWindow,
      blocks: blocks,
      selectedBlockIndex: selectedIndex
    )
    XCTAssertTrue(correctedWindow.range.contains(selectedIndex))
    XCTAssertGreaterThan(correctedWindow.range.lowerBound, requestedWindow.lowerBound)
  }

  func testRenderedEntryWindowUsesSmallerPagesForLargeDocuments() {
    let blocks = (1...1_500).map { line in
      OrgEditableBlock(
        id: "block-\(line)",
        startLine: line,
        endLineExclusive: line + 1,
        rawText: "Line \(line)",
        rendered: .paragraph("Line \(line)")
      )
    }

    XCTAssertEqual(OrgRenderedEntryView.initialRenderedBlockLimit(for: 500), 80)
    XCTAssertEqual(OrgRenderedEntryView.initialRenderedBlockLimit(for: blocks.count), 48)
    XCTAssertEqual(OrgRenderedEntryView.renderedBlockPageSize(for: blocks.count), 48)

    let topWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: nil,
      blocks: blocks,
      selectedBlockIndex: nil
    )
    XCTAssertEqual(topWindow.range, 0..<48)
    XCTAssertFalse(OrgRenderedEntryView.shouldAutoExpandNextFooter(visibleWindow: topWindow))

    let expandedNext = topWindow.expanding(
      .next,
      by: OrgRenderedEntryView.renderedBlockPageSize(for: blocks.count),
      totalCount: blocks.count
    )
    XCTAssertEqual(expandedNext, 0..<96)
    XCTAssertFalse(OrgRenderedEntryView.shouldAutoExpandNextFooter(
      visibleWindow: OrgRenderedBlockWindow(range: expandedNext, totalCount: blocks.count)
    ))
  }

  @MainActor
  func testSelectedRenderedBlocksMetadataTracksAssignmentsAndMutations() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let initialSignature = store.selectedRenderedBlocksSignature
    XCTAssertTrue(store.selectedRenderedBlockIndexes.isEmpty)
    let firstBlock = OrgEditableBlock(
      id: "first",
      startLine: 1,
      endLineExclusive: 2,
      rawText: "First",
      rendered: .paragraph("First")
    )
    let secondBlock = OrgEditableBlock(
      id: "second",
      startLine: 2,
      endLineExclusive: 3,
      rawText: "Second",
      rendered: .paragraph("Second")
    )

    store.selectedRenderedBlocks = [firstBlock]
    let assignedSignature = store.selectedRenderedBlocksSignature

    store.selectedRenderedBlocks.append(secondBlock)

    XCTAssertNotEqual(initialSignature, assignedSignature)
    XCTAssertNotEqual(assignedSignature, store.selectedRenderedBlocksSignature)
    XCTAssertEqual(store.selectedRenderedBlockIndexes["first"], 0)
    XCTAssertEqual(store.selectedRenderedBlockIndexes["second"], 1)

    store.selectedBlockID = "second"
    XCTAssertEqual(store.selectedBlock?.id, "second")
  }

  func testRenderedLineDisplayCacheUsesRawTextAndFallbacks() {
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.headingTitle(
        rawText: "* TODO [#A] Review [[id:abc][Alice]] :work:\nBody",
        fallback: "Review Alice"
      ),
      "Review [[id:abc][Alice]]"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.headingTitle(rawText: "Not a heading", fallback: "Fallback title"),
      "Fallback title"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.headingTitle(rawText: "Not a heading", fallback: "Current title"),
      "Current title"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.listText(rawText: "  - [X] Finish task\ncontinued", fallback: "Finish task"),
      "Finish task"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.listText(rawText: "not-list", fallback: "Fallback item"),
      "Fallback item"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.keywordValue(rawText: "#+TITLE: Project Plan\nBody", fallback: "Project Plan"),
      "Project Plan"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.keywordValue(rawText: "not-keyword", fallback: "Fallback value"),
      "Fallback value"
    )
  }

  func testHeadingTodoStatusCycle() {
    XCTAssertEqual(WorkspaceStore.nextHeadingTodoStatus(after: "TODO"), "DONE")
    XCTAssertEqual(WorkspaceStore.nextHeadingTodoStatus(after: "IN_PROGRESS"), "DONE")
    XCTAssertEqual(WorkspaceStore.nextHeadingTodoStatus(after: "DONE"), "TODO")
    XCTAssertEqual(WorkspaceStore.nextHeadingTodoStatus(after: "CANCELED"), "TODO")
    XCTAssertNil(WorkspaceStore.nextHeadingTodoStatus(after: "NOTE"))
  }

  func testEditableSourceBlockFormatsAndSwitchesKind() {
    var source = OrgEditableSourceBlock(rawText: """
    #+BEGIN_SRC swift :results output
    let value = 1
    #+END_SRC
    """)

    XCTAssertEqual(source.beginKeyword, "#+begin_src")
    XCTAssertEqual(source.endKeyword, "#+end_src")
    XCTAssertEqual(source.language, "swift")
    XCTAssertEqual(source.parameters, ":results output")
    XCTAssertEqual(source.body, "let value = 1")

    source.language = "python"
    source.parameters = ":results replace"
    source.body = "print(42)"
    XCTAssertEqual(source.formattedRawText, """
    #+begin_src python :results replace
    print(42)
    #+end_src
    """)

    source.setBeginKeyword("#+begin_example")
    XCTAssertEqual(source.language, "")
    XCTAssertEqual(source.formattedRawText, """
    #+begin_example :results replace
    print(42)
    #+end_example
    """)
  }

  func testSourceBlockLineWindowLimitsCollapsedLargeBlocks() {
    let lines = (1...120).map { "line \($0)" }

    let collapsed = SourceBlockLineWindow.make(lines: lines, isExpanded: false, limit: 80)
    XCTAssertEqual(collapsed.visibleLines.count, 80)
    XCTAssertEqual(collapsed.visibleLines.first, "line 1")
    XCTAssertEqual(collapsed.visibleLines.last, "line 80")
    XCTAssertTrue(collapsed.isTruncated)
    XCTAssertEqual(collapsed.hiddenLineCount, 40)

    let expanded = SourceBlockLineWindow.make(lines: lines, isExpanded: true, limit: 80)
    XCTAssertEqual(expanded.visibleLines.count, 120)
    XCTAssertTrue(expanded.isTruncated)
    XCTAssertEqual(expanded.hiddenLineCount, 0)

    let partial = SourceBlockLineWindow.make(lines: lines, visibleLimit: 100)
    XCTAssertEqual(partial.visibleLines.count, 100)
    XCTAssertEqual(partial.visibleLines.last, "line 100")
    XCTAssertTrue(partial.isTruncated)
    XCTAssertEqual(partial.hiddenLineCount, 20)
  }

  func testQuoteLineWindowLimitsLargeQuotes() {
    let lines = (1...90).map { "quote \($0)" }

    let collapsed = QuoteLineWindow.make(lines: lines, visibleLimit: 40)
    XCTAssertEqual(collapsed.visibleLines.count, 40)
    XCTAssertEqual(collapsed.visibleLines.first, "quote 1")
    XCTAssertEqual(collapsed.visibleLines.last, "quote 40")
    XCTAssertTrue(collapsed.isTruncated)
    XCTAssertEqual(collapsed.hiddenLineCount, 50)

    let partial = QuoteLineWindow.make(lines: lines, visibleLimit: 70)
    XCTAssertEqual(partial.visibleLines.count, 70)
    XCTAssertEqual(partial.visibleLines.last, "quote 70")
    XCTAssertTrue(partial.isTruncated)
    XCTAssertEqual(partial.hiddenLineCount, 20)

    let expanded = QuoteLineWindow.make(lines: lines, visibleLimit: 120)
    XCTAssertEqual(expanded.visibleLines.count, 90)
    XCTAssertFalse(expanded.isTruncated)
    XCTAssertEqual(expanded.hiddenLineCount, 0)

    let plainRaw = """
    #+begin_quote
    Plain quote body
    Second line
    #+end_quote
    """
    XCTAssertFalse(QuoteLineWindow.rawBodyMayContainInlineSyntax(plainRaw))
    XCTAssertEqual(
      QuoteLineWindow.displayLines(rawText: plainRaw, fallback: ["Plain quote body", "Second line"]),
      ["Plain quote body", "Second line"]
    )
    XCTAssertEqual(
      QuoteLineWindow.displayLines(rawText: plainRaw, fallback: ["Current fallback"]),
      ["Current fallback"]
    )

    let richRaw = """
    #+begin_quote
    See [[id:abc][Alice]]
    Use `code`
    #+end_quote
    """
    XCTAssertTrue(QuoteLineWindow.rawBodyMayContainInlineSyntax(richRaw))
    XCTAssertEqual(
      QuoteLineWindow.displayLines(rawText: richRaw, fallback: ["See Alice", "Use `code`"]),
      ["See [[id:abc][Alice]]", "Use `code`"]
    )
    XCTAssertEqual(
      QuoteLineWindow.displayLines(rawText: richRaw, fallback: ["Cached fallback should not win"]),
      ["See [[id:abc][Alice]]", "Use `code`"]
    )
  }

  func testSourceBlockLineWindowLeavesSmallBlocksWhole() {
    let lines = ["one", "two", "three"]

    let collapsed = SourceBlockLineWindow.make(lines: lines, isExpanded: false, limit: 80)
    XCTAssertEqual(collapsed.visibleLines, lines)
    XCTAssertFalse(collapsed.isTruncated)
    XCTAssertEqual(collapsed.hiddenLineCount, 0)
  }

  func testTableRowWindowLimitsCollapsedLargeTables() {
    let rows = (1...60).map { OrgTableRow.cells(["row \($0)"]) }

    let collapsed = TableRowWindow.make(rows: rows, headerRowIndex: nil, isExpanded: false, limit: 40)
    XCTAssertEqual(collapsed.visibleRows.count, 40)
    XCTAssertEqual(collapsed.visibleRows.first?.index, 0)
    XCTAssertEqual(collapsed.visibleRows.last?.index, 39)
    XCTAssertTrue(collapsed.isTruncated)
    XCTAssertEqual(collapsed.hiddenRowCount, 20)

    let expanded = TableRowWindow.make(rows: rows, headerRowIndex: nil, isExpanded: true, limit: 40)
    XCTAssertEqual(expanded.visibleRows.count, 60)
    XCTAssertTrue(expanded.isTruncated)
    XCTAssertEqual(expanded.hiddenRowCount, 0)

    let partial = TableRowWindow.make(rows: rows, headerRowIndex: nil, visibleLimit: 50)
    XCTAssertEqual(partial.visibleRows.count, 50)
    XCTAssertEqual(partial.visibleRows.first?.index, 0)
    XCTAssertEqual(partial.visibleRows.last?.index, 49)
    XCTAssertTrue(partial.isTruncated)
    XCTAssertEqual(partial.hiddenRowCount, 10)
  }

  func testTableRowWindowKeepsHeaderAndSeparatorVisible() {
    let rows: [OrgTableRow] = [
      .cells(["intro"]),
      .cells(["row 2"]),
      .cells(["row 3"]),
      .cells(["Header"]),
      .separator,
      .cells(["row 6"])
    ]

    let collapsed = TableRowWindow.make(rows: rows, headerRowIndex: 3, isExpanded: false, limit: 2)
    XCTAssertEqual(collapsed.visibleRows.map(\.index), [0, 1, 3, 4])
    XCTAssertTrue(collapsed.isTruncated)
    XCTAssertEqual(collapsed.hiddenRowCount, 2)
  }

  func testTableColumnWindowLimitsWideTables() {
    let collapsed = TableColumnWindow.make(columnCount: 40, visibleLimit: 12)
    XCTAssertEqual(collapsed.visibleColumns, Array(0..<12))
    XCTAssertEqual(collapsed.hiddenColumnCount, 28)

    let partial = TableColumnWindow.make(columnCount: 40, visibleLimit: 24)
    XCTAssertEqual(partial.visibleColumns.count, 24)
    XCTAssertEqual(partial.visibleColumns.last, 23)
    XCTAssertEqual(partial.hiddenColumnCount, 16)

    let complete = TableColumnWindow.make(columnCount: 5, visibleLimit: 12)
    XCTAssertEqual(complete.visibleColumns, Array(0..<5))
    XCTAssertEqual(complete.hiddenColumnCount, 0)
  }

  func testSourceBlockRunPlanSupportsCommonLanguages() {
    XCTAssertEqual(SourceBlockRunPlan.plan(for: "sh")?.executable, "/bin/sh")
    XCTAssertEqual(SourceBlockRunPlan.plan(for: "python")?.arguments, ["python3"])
    XCTAssertEqual(SourceBlockRunPlan.plan(for: "js")?.scriptExtension, "mjs")
    XCTAssertNil(SourceBlockRunPlan.plan(for: "mermaid"))
  }

  func testSourceRunOutputPresentationParsesJSONBars() {
    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: #"{"A":2,"B":3.5}"#),
      .bars([
        SourceRunBar(label: "A", value: 2),
        SourceRunBar(label: "B", value: 3.5)
      ])
    )

    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: #"[{"name":"A","value":2},{"name":"B","value":3}]"#),
      .bars([
        SourceRunBar(label: "A", value: 2),
        SourceRunBar(label: "B", value: 3)
      ])
    )
  }

  func testSourceRunOutputPresentationCacheUsesExactOutput() {
    let raw = #"{"A":2,"B":3.5}"#
    let key = SourceRunOutputPresentationCache.CacheKey(raw: raw)
    let matching = SourceRunOutputPresentationCache.CacheKey(raw: raw)
    let different = SourceRunOutputPresentationCache.CacheKey(raw: raw + "\n")

    XCTAssertEqual(key, matching)
    XCTAssertEqual(key.hash, matching.hash)
    XCTAssertNotEqual(key, different)
    XCTAssertEqual(
      SourceRunOutputPresentationCache.presentation(from: raw),
      .bars([
        SourceRunBar(label: "A", value: 2),
        SourceRunBar(label: "B", value: 3.5)
      ])
    )
    XCTAssertEqual(
      SourceRunOutputPresentationCache.presentation(from: raw),
      SourceRunOutputPresentationCache.presentation(from: raw)
    )
    XCTAssertEqual(
      SourceRunOutputPresentationCache.presentation(from: "plain output"),
      .text("plain output")
    )
  }

  func testSourceRunOutputPresentationParsesJSONObjectsAsTable() {
    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: #"[{"name":"A","status":"ready","value":2},{"name":"B","status":"done","value":3}]"#),
      .table(SourceRunTable(
        columns: ["name", "status", "value"],
        rows: [
          ["A", "ready", "2"],
          ["B", "done", "3"]
        ]
      ))
    )

    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: #"[{"active":true,"name":"A"},{"active":false,"name":"B"}]"#),
      .table(SourceRunTable(
        columns: ["active", "name"],
        rows: [
          ["1", "A"],
          ["0", "B"]
        ]
      ))
    )
  }

  func testSourceRunOutputPresentationParsesDelimitedTables() {
    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: """
      Name,Value
      A,2
      B,3
      """),
      .table(SourceRunTable(
        columns: ["Name", "Value"],
        rows: [
          ["A", "2"],
          ["B", "3"]
        ]
      ))
    )

    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: "Name\tValue\nA\t2\nB\t3"),
      .table(SourceRunTable(
        columns: ["Name", "Value"],
        rows: [
          ["A", "2"],
          ["B", "3"]
        ]
      ))
    )
  }

  func testSourceRunOutputPresentationParsesLineCharts() {
    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: """
      x,y
      1,2
      2,4
      3,8
      """),
      .line(SourceRunLineChart(
        xLabel: "x",
        yLabel: "y",
        points: [
          SourceRunLinePoint(x: 1, y: 2),
          SourceRunLinePoint(x: 2, y: 4),
          SourceRunLinePoint(x: 3, y: 8)
        ]
      ))
    )

    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: #"[{"x":1,"y":2},{"x":2,"y":4}]"#),
      .line(SourceRunLineChart(
        xLabel: "x",
        yLabel: "y",
        points: [
          SourceRunLinePoint(x: 1, y: 2),
          SourceRunLinePoint(x: 2, y: 4)
        ]
      ))
    )
  }

  func testSourceRunOutputPresentationParsesPipeTable() {
    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: """
      | Name | Value |
      |------+-------|
      | A    | 2     |
      | B    | 3     |
      """),
      .table(SourceRunTable(
        columns: ["Name", "Value"],
        rows: [
          ["A", "2"],
          ["B", "3"]
        ]
      ))
    )
  }

  func testExecutesSourceBlockAndCapturesOutput() throws {
    let source = OrgEditableSourceBlock(rawText: """
    #+begin_src sh
    printf hello
    #+end_src
    """)
    let plan = try XCTUnwrap(SourceBlockRunPlan.plan(for: source.language))
    let result = try WorkspaceStore.executeSourceBlock(
      source,
      plan: plan,
      workingDirectory: FileManager.default.temporaryDirectory,
      timeout: 2
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "hello")
    XCTAssertEqual(result.stderr, "")
    XCTAssertFalse(result.timedOut)
  }

  @MainActor
  func testRunsEditedSourceBlockDraftWithoutSavingFirst() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-source-draft-run-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("source-draft.org2")
    try """
    #+TITLE: Source Draft

    * Code
    #+begin_src sh
    printf saved
    #+end_src
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": null,
      "headline": "Code",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let sourceBlock = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .source = $0.rendered { return true }
      return false
    })

    await store.runSourceBlock(sourceBlock, rawText: """
    #+begin_src sh
    printf draft
    #+end_src
    """)

    try await waitForCondition {
      store.sourceBlockRunState(for: sourceBlock)?.stdout == "draft"
    }
    XCTAssertEqual(store.sourceBlockRunState(for: sourceBlock)?.status, .succeeded)

    let saved = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(saved.contains("printf saved"))
    XCTAssertFalse(saved.contains("printf draft"))
  }

  @MainActor
  func testAutosavesSourceBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-source-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("source-autosave.org2")
    try """
    #+TITLE: Source Autosave

    * Code
    #+begin_src sh
    printf old
    #+end_src
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": null,
      "headline": "Code",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let sourceBlock = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .source = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(sourceBlock)
    let replacement = """
    #+begin_src python :results output
    print("new")
    print("line two")
    #+end_src
    """
    store.updateEditingBlockDraft(sourceBlock, draft: replacement)
    await store.autosaveEditedBlock(sourceBlock, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("print(\"new\")\nprint(\"line two\")\n#+end_src\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertEqual(store.editableBlockText, replacement)
    XCTAssertNotNil(store.editingBlockID)
    guard case .source(let language, let lines) = store.selectedBlock?.rendered else {
      return XCTFail("Expected source block")
    }
    XCTAssertEqual(language, "python")
    XCTAssertEqual(lines, ["print(\"new\")", "print(\"line two\")"])
  }

  func testParsesEditableOrgBlocksWithSourceRanges() {
    let blocks = OrgEntryRenderer.parseEditable("""
    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    -----
    Body one
    Body two
    #+begin_src swift
    let value = 1
    #+end_src
    """, baseLine: 42)

    XCTAssertEqual(blocks.map(\.displayRange), ["42", "43", "44-46", "47", "48-49", "50-52"])
    XCTAssertEqual(blocks.map(\.rawText), [
      "* TODO Parent",
      "SCHEDULED: <2026-06-12 Fri>",
      "| Name | Value |\n|------+-------|\n| Alice | 42 |",
      "-----",
      "Body one\nBody two",
      "#+begin_src swift\nlet value = 1\n#+end_src"
    ])

    guard case .table(let table) = blocks[2].rendered else {
      return XCTFail("Expected table")
    }
    XCTAssertEqual(table.rows, [
      .cells(["Name", "Value"]),
      .separator,
      .cells(["Alice", "42"])
    ])

    guard case .horizontalRule = blocks[3].rendered else {
      return XCTFail("Expected horizontal rule")
    }

    guard case .paragraph(let paragraph) = blocks[4].rendered else {
      return XCTFail("Expected paragraph")
    }
    XCTAssertEqual(paragraph, "Body one\nBody two")
  }

  func testEditableParagraphPreservesRawInlineMarkupForEditing() {
    let blocks = OrgEntryRenderer.parseEditable("""
    Body with [[id:11111111-1111-4111-8111-111111111111][Alice]] and ~code~.
    Second /line/.
    """, baseLine: 12)

    XCTAssertEqual(blocks.count, 1)
    XCTAssertEqual(blocks[0].displayRange, "12-13")
    XCTAssertEqual(blocks[0].rawText, """
    Body with [[id:11111111-1111-4111-8111-111111111111][Alice]] and ~code~.
    Second /line/.
    """)

    guard case .paragraph(let paragraph) = blocks[0].rendered else {
      return XCTFail("Expected paragraph")
    }
    XCTAssertEqual(paragraph, "Body with Alice and ~code~.\nSecond /line/.")
  }

  func testOrgMediaAttachmentDetectsStandaloneLocalMediaLinks() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-media-\(UUID().uuidString)", isDirectory: true)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

    let image = assets.appendingPathComponent("diagram.png")
    let video = notes.appendingPathComponent("clip.mov")
    let note = notes.appendingPathComponent("daily.org2")
    try Data().write(to: image)
    try Data().write(to: video)
    try Data().write(to: note)

    XCTAssertFalse(OrgMediaAttachment.mayContainStandaloneMedia("Plain paragraph with no media link."))
    XCTAssertFalse(OrgMediaAttachment.mayContainStandaloneMedia("See [[file:../assets/diagram.png][System Diagram]]"))
    XCTAssertFalse(OrgMediaAttachment.mayContainStandaloneMedia("https://example.com/image.png"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("[[file:../assets/diagram.png][System Diagram]]"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("[Clip](clip.mov)"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("assets/diagram.png"))

    let bracket = try XCTUnwrap(OrgMediaAttachment.standalone(
      raw: "[[file:../assets/diagram.png][System Diagram]]",
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(bracket.kind, .image)
    XCTAssertEqual(bracket.displayName, "System Diagram")
    XCTAssertEqual(bracket.resolvedPath, image.standardizedFileURL.path)

    let markdown = try XCTUnwrap(OrgMediaAttachment.standalone(
      raw: "[Clip](clip.mov)",
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(markdown.kind, .video)
    XCTAssertEqual(markdown.displayName, "Clip")
    XCTAssertEqual(markdown.resolvedPath, video.standardizedFileURL.path)

    XCTAssertNil(OrgMediaAttachment.standalone(
      raw: "See [[file:../assets/diagram.png][System Diagram]]",
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertNil(OrgMediaAttachment.standalone(raw: "https://example.com/image.png"))
  }

  func testOrgMediaAttachmentRenderCacheUsesExactSourceContext() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-media-cache-\(UUID().uuidString)", isDirectory: true)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

    let image = assets.appendingPathComponent("diagram.png")
    let note = notes.appendingPathComponent("daily.org2")
    try Data().write(to: image)
    try Data().write(to: note)

    let raw = "[[file:../assets/diagram.png][System Diagram]]"
    let key = OrgMediaAttachmentRenderCache.CacheKey(raw: raw, sourceFile: note.path, corpusRoot: root)
    let matching = OrgMediaAttachmentRenderCache.CacheKey(raw: raw, sourceFile: note.path, corpusRoot: root)
    let differentSource = OrgMediaAttachmentRenderCache.CacheKey(raw: raw, sourceFile: image.path, corpusRoot: root)

    XCTAssertEqual(key, matching)
    XCTAssertEqual(key.hash, matching.hash)
    XCTAssertNotEqual(key, differentSource)

    XCTAssertFalse(OrgMediaAttachmentRenderCache.shouldAttemptStandaloneLookup(raw: "Plain paragraph"))
    XCTAssertFalse(OrgMediaAttachmentRenderCache.shouldAttemptStandaloneLookup(
      raw: "See [[file:../assets/diagram.png][System Diagram]]"
    ))
    XCTAssertFalse(OrgMediaAttachmentRenderCache.shouldAttemptStandaloneLookup(
      raw: "https://example.com/image.png"
    ))
    XCTAssertTrue(OrgMediaAttachmentRenderCache.shouldAttemptStandaloneLookup(raw: raw))

    let first = try XCTUnwrap(OrgMediaAttachmentRenderCache.standalone(raw: raw, sourceFile: note.path, corpusRoot: root))
    let second = try XCTUnwrap(OrgMediaAttachmentRenderCache.standalone(raw: raw, sourceFile: note.path, corpusRoot: root))
    XCTAssertEqual(first, second)
    XCTAssertEqual(second.resolvedPath, image.standardizedFileURL.path)

    XCTAssertNil(OrgMediaAttachmentRenderCache.standalone(raw: "Plain paragraph", sourceFile: note.path, corpusRoot: root))
    XCTAssertNil(OrgMediaAttachmentRenderCache.standalone(raw: "Plain paragraph", sourceFile: note.path, corpusRoot: root))
  }

  func testEditableMediaLinkFormatsOrgBracketLinks() throws {
    XCTAssertEqual(
      OrgEditableMediaLink(kind: .image, target: "images/diagram.png", label: "System Diagram").formattedRawText,
      "[[file:images/diagram.png][System Diagram]]"
    )

    XCTAssertEqual(
      OrgEditableMediaLink(kind: .video, target: "file:clips/demo.mp4").formattedRawText,
      "[[file:clips/demo.mp4][demo.mp4]]"
    )

    let markdown = try XCTUnwrap(OrgEditableMediaLink(rawText: "[Clip](clip.mov)"))
    XCTAssertEqual(markdown.kind, .video)
    XCTAssertEqual(markdown.target, "clip.mov")
    XCTAssertEqual(markdown.label, "Clip")
    XCTAssertEqual(markdown.formattedRawText, "[[file:clip.mov][Clip]]")

    let bracket = try XCTUnwrap(OrgEditableMediaLink(rawText: "[[file:../assets/diagram.png][Diagram]]"))
    XCTAssertEqual(bracket.kind, .image)
    XCTAssertEqual(bracket.target, "file:../assets/diagram.png")
    XCTAssertEqual(bracket.label, "Diagram")
    XCTAssertEqual(bracket.formattedRawText, "[[file:../assets/diagram.png][Diagram]]")
  }

  func testMediaAttachmentInfersKindFromTargets() {
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "images/diagram.webp"), .image)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "file:clips/demo.webm"), .video)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "/tmp/movie.MP4#clip"), .video)
    XCTAssertNil(OrgMediaAttachment.kind(forTarget: "notes/project.org2"))
  }

  func testRenderedMediaDoesNotAutoloadVideoPlayers() {
    XCTAssertFalse(RenderedMediaPreviewPolicy.autoloadsVideoPlayerOnAppear)
  }

  @MainActor
  func testAgentHandoffShortcutUpdatesTempNote() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agent.org2")
    try """
    #+TITLE: Agent Test

    * TODO Send to agent
    SCHEDULED: <2026-06-12 Fri>
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Send to agent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.applyAgentHandoffShortcut()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE Send to agent"))
    XCTAssertTrue(updated.contains(":STATUS: ready-for-agent"))
    XCTAssertTrue(updated.contains(":ORG2_AGENT_HANDOFF_AT: <"))
  }

  @MainActor
  func testPriorityAndPropertyShortcutsUpdateTempNote() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-priority-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("priority.org2")
    try """
    #+TITLE: Priority Test

    * TODO Important thing :work:
    SCHEDULED: <2026-06-12 Fri>
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Important thing",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": ["work"],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))

    await store.applyPriorityShortcut("A")
    await store.applyPropertyShortcut(key: "OWNER", value: "agent")

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO [#A] Important thing :work:"))
    XCTAssertTrue(updated.contains(":OWNER: agent"))
  }

  @MainActor
  func testCaptureTodoUsesConfiguredDailiesDir() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-capture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.captureTodo(title: "Captured from app")

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    let daily = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent("\(formatter.string(from: Date())).org2")
    let updated = try String(contentsOf: daily, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Captured from app"))
    XCTAssertTrue(updated.contains("SCHEDULED: <"))
  }

  @MainActor
  func testLoadsAndSavesSelectedEntrySource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("edit.org2")
    try """
    #+TITLE: Edit Test

    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    Body
    ** Child
    Child body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))

    XCTAssertEqual(store.selectedEntrySource?.startLine, 3)
    XCTAssertEqual(store.selectedEntrySource?.displayRange, "3-7")
    XCTAssertTrue(store.selectedEntrySource?.text.contains("** Child") == true)

    XCTAssertFalse(store.canSaveActiveEdit)
    store.beginEditingSelectedEntry()
    XCTAssertTrue(store.canSaveActiveEdit)
    store.editableEntryText = store.editableEntryText.replacingOccurrences(of: "Body", with: "Updated body")
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Updated body"))
    XCTAssertTrue(updated.contains("* Sibling\nSibling body"))
    XCTAssertFalse(store.canSaveActiveEdit)
  }

  @MainActor
  func testLegacyEntryEditStateKeepsRenderedSourceLoaded() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-rendered-entry-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("rendered-entry-edit.org2")
    try """
    #+TITLE: Rendered Entry Edit Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    store.beginEditingSelectedEntry()
    store.selectedRenderedBlocks = []
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    XCTAssertTrue(store.isEditingEntry)
    XCTAssertTrue(store.canSaveActiveEdit)
    XCTAssertFalse(store.selectedRenderedBlocks.isEmpty)
    XCTAssertTrue(store.selectedRenderedBlocks.contains {
      if case .heading(let heading) = $0.rendered {
        return heading.title == "Parent"
      }
      return false
    })
  }

  @MainActor
  func testSavesRenderedBlockInPlace() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-edit.org2")
    try """
    #+TITLE: Block Edit Test

    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    Body
    Second line
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    XCTAssertEqual(paragraph.displayRange, "5-6")

    store.beginEditingBlock(paragraph)
    XCTAssertTrue(store.canSaveActiveEdit)
    store.editableBlockText = "Updated body\nSecond line\nThird line"
    await store.saveActiveEdit()
    try await waitForEntryRender(store)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Updated body\nSecond line\nThird line"))
    XCTAssertTrue(updated.contains("* Sibling\nSibling body"))
    XCTAssertNil(store.editingBlockID)
    XCTAssertFalse(store.canSaveActiveEdit)
    XCTAssertEqual(store.selectedBlock?.rawText, "Updated body\nSecond line\nThird line")
    let shiftedSibling = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered {
        return heading.title == "Sibling"
      }
      return false
    })
    XCTAssertEqual(shiftedSibling.startLine, 8)
  }

  @MainActor
  func testSaveActiveEditUsesLatestInlineDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-save-inline-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("save-inline-draft.org2")
    try """
    #+TITLE: Save Inline Draft Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    XCTAssertEqual(store.editableBlockText, "Body")

    store.updateEditingBlockDraft(paragraph, draft: "Draft from inline editor")
    XCTAssertEqual(store.editableBlockText, "Body")
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nDraft from inline editor\n* Sibling"))
    XCTAssertFalse(updated.contains("* TODO Parent\nBody\n* Sibling"))
    XCTAssertEqual(store.selectedBlock?.rawText, "Draft from inline editor")
    XCTAssertNil(store.editingBlockID)
  }

  @MainActor
  func testSavingRenderedBlockSchedulesAgendaRefreshWithoutBlocking() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-nonblocking-save-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    try """
    setTimeout(() => {
      process.stdout.write(JSON.stringify({
        "$schema": "org2:agenda:v1",
        "range": { "start": "2026-06-12", "end": "2026-06-18", "days": 7 },
        "overdue": [],
        "days": [{ "date": "2026-06-12", "weekday": "Fri", "items": [] }],
        "skippedFiles": 0
      }));
    }, 1800);
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let note = corpus.appendingPathComponent("nonblocking-save.org2")
    try """
    #+TITLE: Nonblocking Save Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot))
    store.setCorpusRoot(corpus)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "Updated body"

    let started = Date()
    await store.saveEditedBlock(paragraph)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertLessThan(elapsed, 1.0)
    XCTAssertTrue(store.statusText.hasPrefix("Saved block"))
    XCTAssertTrue((try String(contentsOf: note, encoding: .utf8)).contains("Updated body"))

    try await waitForCondition(timeout: 5) {
      store.agenda?.totalItemCount == 0 && !store.isLoadingAgenda
    }
    XCTAssertTrue(store.statusText.hasPrefix("Saved block"))
  }

  @MainActor
  func testAutosaveDefersAgendaRefreshUntilBlockEditingEnds() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-autosave-deferred-agenda-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    try """
    setTimeout(() => {
      process.stdout.write(JSON.stringify({
        "$schema": "org2:agenda:v1",
        "range": { "start": "2026-06-12", "end": "2026-06-18", "days": 7 },
        "overdue": [],
        "days": [{ "date": "2026-06-12", "weekday": "Fri", "items": [] }],
        "skippedFiles": 0
      }));
    }, 120);
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let note = corpus.appendingPathComponent("autosave-deferred-agenda.org2")
    try """
    #+TITLE: Autosave Deferred Agenda Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot))
    store.setCorpusRoot(corpus)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.updateEditingBlockDraft(paragraph, draft: "Updated body")
    await store.autosaveEditedBlock(paragraph, replacement: "Updated body")

    XCTAssertFalse(store.isLoadingAgenda)
    XCTAssertNil(store.agenda)
    XCTAssertNotNil(store.editingBlockID)

    try await Task.sleep(nanoseconds: 350_000_000)
    XCTAssertFalse(store.isLoadingAgenda)
    XCTAssertNil(store.agenda)

    store.cancelEditingBlock()
    try await waitForCondition(timeout: 2) {
      store.agenda?.totalItemCount == 0 && !store.isLoadingAgenda
    }
  }

  @MainActor
  func testAutosavesParagraphBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-paragraph-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("paragraph-autosave.org2")
    try """
    #+TITLE: Paragraph Autosave Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    let editingBlockID = try XCTUnwrap(store.editingBlockID)
    store.editableBlockText = "Updated body\nSecond line"
    store.updateEditingBlockDraft(paragraph, draft: "Updated body\nSecond line")
    await store.autosaveEditedBlock(paragraph, replacement: "Updated body\nSecond line")

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Updated body\nSecond line\n* Sibling"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.editingBlockID, editingBlockID)
    XCTAssertEqual(store.selectedBlock?.id, editingBlockID)
    XCTAssertEqual(store.selectedBlock?.endLineExclusive, paragraph.endLineExclusive + 1)
    XCTAssertEqual(store.selectedBlock?.rawText, "Updated body\nSecond line")
    XCTAssertEqual(store.editableBlockText, "Updated body\nSecond line")
    let shiftedSibling = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered {
        return heading.title == "Sibling"
      }
      return false
    })
    XCTAssertEqual(shiftedSibling.startLine, 6)

    let expandedParagraph = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "Updated again\nSecond line"
    store.updateEditingBlockDraft(expandedParagraph, draft: "Updated again\nSecond line")
    await store.autosaveEditedBlock(expandedParagraph, replacement: "Updated again\nSecond line")

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Updated again\nSecond line\n* Sibling"))
    XCTAssertFalse(updated.contains("Updated again\nSecond line\nSecond line"))
    XCTAssertEqual(store.selectedBlock?.rawText, "Updated body\nSecond line")
    XCTAssertEqual(store.editingBlockID, editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, "Updated again\nSecond line")
    XCTAssertNil(store.editingBlockID)
    XCTAssertEqual(store.selectedBlock?.id, editingBlockID)
  }

  @MainActor
  func testSameRangeAutosavePreservesRenderedBlockMetadata() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-same-range-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("same-range-autosave.org2")
    try """
    #+TITLE: Same Range Autosave Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    let originalSignature = store.selectedRenderedBlocksSignature
    let originalIndexes = store.selectedRenderedBlockIndexes

    store.beginEditingBlock(paragraph)
    store.editableBlockText = "Updated body"
    store.updateEditingBlockDraft(paragraph, draft: "Updated body")
    await store.autosaveEditedBlock(paragraph, replacement: "Updated body")

    XCTAssertEqual(store.selectedRenderedBlocksSignature, originalSignature)
    XCTAssertEqual(store.selectedRenderedBlockIndexes, originalIndexes)
    XCTAssertEqual(store.selectedBlock?.id, paragraph.id)
    XCTAssertEqual(store.selectedBlock?.rawText, "Body")
    XCTAssertTrue(store.selectedEntrySource?.text.contains("* TODO Parent\nBody\n* Sibling") == true)
    XCTAssertFalse(store.selectedEntrySource?.text.contains("Updated body") == true)
    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nUpdated body\n* Sibling"))

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedRenderedBlocksSignature, originalSignature)
    XCTAssertEqual(store.selectedRenderedBlockIndexes, originalIndexes)
    XCTAssertEqual(store.selectedBlock?.id, paragraph.id)
    XCTAssertEqual(store.selectedBlock?.rawText, "Updated body")
    XCTAssertTrue(store.selectedEntrySource?.text.contains("* TODO Parent\nUpdated body\n* Sibling") == true)
  }

  @MainActor
  func testStaleAutosaveDoesNotUpdateVisibleEditorState() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-stale-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("stale-autosave.org2")
    try """
    #+TITLE: Stale Autosave Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.updateEditingBlockDraft(paragraph, draft: "Still typing")

    await store.autosaveEditedBlock(paragraph, replacement: "Stale body")

    XCTAssertEqual(store.editingBlockID, paragraph.id)
    XCTAssertEqual(store.editableBlockText, "Body")
    XCTAssertEqual(store.selectedBlock?.rawText, "Body")
    XCTAssertTrue(store.selectedEntrySource?.text.contains("Body") == true)
    XCTAssertFalse(store.selectedEntrySource?.text.contains("Stale body") == true)
    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody\n* Sibling"))
    XCTAssertFalse(updated.contains("Stale body"))
  }

  @MainActor
  func testAutosavesHeadingBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-autosave.org2")
    try """
    #+TITLE: Heading Autosave Test

    * TODO [#A] Parent :work:
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": ["work"],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(heading)
    let replacement = "* DONE [#B] Renamed parent :work:focus:"
    store.updateEditingBlockDraft(heading, draft: replacement)
    await store.autosaveEditedBlock(heading, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE [#B] Renamed parent :work:focus:\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, "* TODO [#A] Parent :work:")
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
    guard case .heading(let renderedHeading) = store.selectedBlock?.rendered else {
      return XCTFail("Expected heading block")
    }
    XCTAssertEqual(renderedHeading.todo, "DONE")
    XCTAssertEqual(renderedHeading.priority, "B")
    XCTAssertEqual(renderedHeading.title, "Renamed parent")
    XCTAssertEqual(renderedHeading.tags, ["work", "focus"])
  }

  @MainActor
  func testAutosavesPlanningBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-planning-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("planning-autosave.org2")
    try """
    #+TITLE: Planning Autosave Test

    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let planning = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .planning = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(planning)
    let replacement = "DEADLINE: <2026-06-15 Mon>"
    store.updateEditingBlockDraft(planning, draft: replacement)
    await store.autosaveEditedBlock(planning, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("DEADLINE: <2026-06-15 Mon>\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, "SCHEDULED: <2026-06-12 Fri>")
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
    guard case .planning(let renderedPlanning) = store.selectedBlock?.rendered else {
      return XCTFail("Expected planning block")
    }
    XCTAssertEqual(renderedPlanning.kind, "DEADLINE")
    XCTAssertEqual(renderedPlanning.value, "<2026-06-15 Mon>")
  }

  @MainActor
  func testAutosavesKeywordBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-keyword-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("keyword-autosave.org2")
    try """
    * TODO Parent
    #+CAPTION: Old Caption
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let keyword = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .keyword(let key, _) = $0.rendered { return key == "CAPTION" }
      return false
    })
    store.beginEditingBlock(keyword)
    let replacement = "#+CAPTION: New Caption"
    store.updateEditingBlockDraft(keyword, draft: replacement)
    await store.autosaveEditedBlock(keyword, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\n#+CAPTION: New Caption\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, "#+CAPTION: Old Caption")
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
    guard case .keyword(let key, let value) = store.selectedBlock?.rendered else {
      return XCTFail("Expected keyword block")
    }
    XCTAssertEqual(key, "CAPTION")
    XCTAssertEqual(value, "New Caption")
  }

  @MainActor
  func testAutosavesPropertyDrawerWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-property-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("property-autosave.org2")
    try """
    * TODO Parent
    :PROPERTIES:
    :OWNER: avi
    :STATUS: draft
    :END:
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": { "OWNER": "avi", "STATUS": "draft" }
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let properties = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .properties = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(properties)
    let replacement = """
    :PROPERTIES:
    :OWNER: openclaw
    :STATUS: active
    :END:
    """
    store.updateEditingBlockDraft(properties, draft: replacement)
    await store.autosaveEditedBlock(properties, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains(":OWNER: openclaw\n:STATUS: active\n:END:\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, properties.rawText)
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
    guard case .properties(let rows) = store.selectedBlock?.rendered else {
      return XCTFail("Expected property drawer")
    }
    XCTAssertEqual(rows, [
      OrgPropertyRow(key: "OWNER", value: "openclaw"),
      OrgPropertyRow(key: "STATUS", value: "active")
    ])
  }

  @MainActor
  func testSetsRenderedPropertyValueInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-rendered-property-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("rendered-property.org2")
    try """
    * TODO Parent
    :PROPERTIES:
    :OWNER: agent
    :ID: 11111111-1111-4111-8111-111111111111
    :END:
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {
        "OWNER": "agent",
        "ID": "11111111-1111-4111-8111-111111111111"
      }
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let properties = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .properties = $0.rendered { return true }
      return false
    })
    await store.setPropertyValue(properties, key: "OWNER", value: "avi")

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains(":OWNER: avi\n:ID: 11111111-1111-4111-8111-111111111111\n:END:\nBody"))
    try await waitForCondition {
      store.selectedRenderedBlocks.contains {
        if case .properties(let rows) = $0.rendered {
          return rows.contains(OrgPropertyRow(key: "OWNER", value: "avi"))
        }
        return false
      }
    }
    let updatedProperties = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .properties = $0.rendered { return true }
      return false
    })
    guard case .properties(let rows) = updatedProperties.rendered else {
      return XCTFail("Expected property drawer")
    }
    XCTAssertEqual(rows, [
      OrgPropertyRow(key: "OWNER", value: "avi"),
      OrgPropertyRow(key: "ID", value: "11111111-1111-4111-8111-111111111111")
    ])
  }

  @MainActor
  func testAutosavesQuoteBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-quote-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("quote-autosave.org2")
    try """
    * TODO Parent
    #+begin_quote
    Old quote
    #+end_quote
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let quote = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .quote = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(quote)
    let replacement = """
    #+begin_quote
    New quote
    With second line
    #+end_quote
    """
    store.updateEditingBlockDraft(quote, draft: replacement)
    await store.autosaveEditedBlock(quote, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("New quote\nWith second line\n#+end_quote\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertEqual(store.editableBlockText, replacement)
    XCTAssertNotNil(store.editingBlockID)
    guard case .quote(let lines) = store.selectedBlock?.rendered else {
      return XCTFail("Expected quote block")
    }
    XCTAssertEqual(lines, ["New quote", "With second line"])
  }

  @MainActor
  func testAutosavesMediaBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-media-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("media-autosave.org2")
    try """
    * TODO Parent
    [[file:images/old.png][Old image]]

    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let media = try XCTUnwrap(store.selectedRenderedBlocks.first {
      OrgEditableMediaLink(rawText: $0.rawText) != nil
    })
    store.beginEditingBlock(media)
    let replacement = "[[file:images/new.png][New image]]"
    store.updateEditingBlockDraft(media, draft: replacement)
    await store.autosaveEditedBlock(media, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\n[[file:images/new.png][New image]]\n\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, media.rawText)
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
    let editedMedia = try XCTUnwrap(OrgEditableMediaLink(rawText: store.selectedBlock?.rawText ?? ""))
    XCTAssertEqual(editedMedia.target, "file:images/new.png")
    XCTAssertEqual(editedMedia.label, "New image")
  }

  @MainActor
  func testAutosavesTableBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-table-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("table-autosave.org2")
    try """
    * TODO Parent
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let table = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .table = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(table)
    let replacement = """
    | Name  | Value | Owner |
    |-------+-------+-------|
    | Alice | 43    | Avi   |
    | Bob   | 12    | Bot   |
    """
    store.updateEditingBlockDraft(table, draft: replacement)
    await store.autosaveEditedBlock(table, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("| Alice | 43    | Avi   |\n| Bob   | 12    | Bot   |\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertEqual(store.editableBlockText, replacement)
    XCTAssertNotNil(store.editingBlockID)
    guard case .table(let renderedTable) = store.selectedBlock?.rendered else {
      return XCTFail("Expected table block")
    }
    XCTAssertEqual(renderedTable.rows, [
      .cells(["Name", "Value", "Owner"]),
      .separator,
      .cells(["Alice", "43", "Avi"]),
      .cells(["Bob", "12", "Bot"])
    ])
  }

  @MainActor
  func testSplitsEditingParagraphAtCaretIntoNewEditableBlock() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-split-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-split.org2")
    try """
    #+TITLE: Block Split Test

    * TODO Parent
    Alpha beta gamma
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Alpha beta gamma",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph(let text) = $0.rendered { return text == "Alpha beta gamma" }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "Alpha beta gamma"

    await store.splitEditingBlock(paragraph, atUTF16Offset: 6)
    try await waitForCondition {
      store.selectedBlock?.rawText == "beta gamma" && store.editingBlockID == store.selectedBlock?.id
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Alpha\n\nbeta gamma\n* Sibling"))
    XCTAssertEqual(store.editableBlockText, "beta gamma")
  }

  @MainActor
  func testSplitsEditingParagraphUsingNonPublishedInlineDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-paragraph-nonpublished-split-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("paragraph-nonpublished-split.org2")
    try """
    #+TITLE: Paragraph Nonpublished Split Test

    * TODO Parent
    Alpha beta gamma
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Alpha beta gamma",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph(let text) = $0.rendered { return text == "Alpha beta gamma" }
      return false
    })
    store.beginEditingBlock(paragraph)
    XCTAssertEqual(store.editableBlockText, "Alpha beta gamma")

    store.updateEditingBlockDraft(paragraph, draft: "Alpha edited beta")
    XCTAssertEqual(store.editableBlockText, "Alpha beta gamma")
    await store.splitEditingBlock(paragraph, atUTF16Offset: 6)
    try await waitForCondition {
      store.selectedBlock?.rawText == "edited beta" && store.editingBlockID == store.selectedBlock?.id
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Alpha\n\nedited beta\n* Sibling"))
  }

  @MainActor
  func testContinuesParagraphWithUnsavedDraftBlock() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-paragraph-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("paragraph-draft.org2")
    try """
    #+TITLE: Paragraph Draft Test

    * TODO Parent
    Alpha beta
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Alpha beta",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph(let text) = $0.rendered { return text == "Alpha beta" }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "Alpha beta"

    await store.splitEditingBlock(paragraph, atUTF16Offset: (store.editableBlockText as NSString).length)
    try await waitForCondition {
      store.selectedBlock?.rawText == "" && store.editingBlockID == store.selectedBlock?.id
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("New text"))
    XCTAssertTrue(updated.contains("Alpha beta\n* Sibling"))

    let draft = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "Next paragraph"
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "Next paragraph"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Alpha beta\n\nNext paragraph\n* Sibling"))
  }

  @MainActor
  func testContinuesEditingChecklistItemWithUncheckedSibling() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-list-continue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("list-continue.org2")
    try """
    #+TITLE: List Continue Test

    * TODO Parent
    - [X] Done task
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "- [X] Done task",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let task = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, .checked, let text) = $0.rendered { return text == "Done task" }
      return false
    })
    store.beginEditingBlock(task)
    store.editableBlockText = "- [X] Done task"

    await store.splitEditingBlock(task, atUTF16Offset: (store.editableBlockText as NSString).length)
    try await waitForCondition {
      store.selectedBlock?.rawText == "- [ ] " && store.editingBlockID == store.selectedBlock?.id
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("New item"))
    XCTAssertTrue(updated.contains("- [X] Done task\n* Sibling"))
    XCTAssertEqual(store.editableBlockText, "- [ ] ")

    let draft = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "- [ ] Follow up"
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "- [ ] Follow up"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- [X] Done task\n- [ ] Follow up\n* Sibling"))
  }

  @MainActor
  func testAutosavesListItemWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-list-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("list-autosave.org2")
    try """
    #+TITLE: List Autosave Test

    * TODO Parent
    - [ ] Open task
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "- [ ] Open task",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let task = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, .unchecked, let text) = $0.rendered { return text == "Open task" }
      return false
    })
    store.beginEditingBlock(task)
    let replacement = "- [X] Closed task"
    store.updateEditingBlockDraft(task, draft: replacement)
    await store.autosaveEditedBlock(task, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- [X] Closed task\n* Sibling"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, task.rawText)
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
  }

  @MainActor
  func testInsertsBlockAfterRenderedBlockInsideSelectedEntry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-insert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-insert.org2")
    try """
    #+TITLE: Block Insert Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    await store.insertBlock(after: paragraph, kind: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO " && store.editingBlockID == store.selectedBlock?.id
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("New task"))
    XCTAssertTrue(updated.contains("Body\n* Sibling"))
    guard case .heading(let selectedHeading) = store.selectedBlock?.rendered else {
      return XCTFail("Expected inserted heading to be selected")
    }
    XCTAssertEqual(selectedHeading.title, "")
    XCTAssertEqual(selectedHeading.todo, "TODO")
    XCTAssertEqual(store.editableBlockText, "** TODO ")

    let draft = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "** TODO Call Bob"
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Call Bob"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\n** TODO Call Bob\n* Sibling"))
  }

  @MainActor
  func testInsertsAndConvertsMediaBlocksAsOrgLinks() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-media-insert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("media-insert.org2")
    try """
    #+TITLE: Media Insert Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })

    await store.insertBlock(after: paragraph, kind: .image)
    try await waitForCondition {
      store.selectedBlock?.rawText == "[[file:images/image.png][Image]]"
        && store.editingBlockID == store.selectedBlockID
    }
    XCTAssertEqual(store.editableBlockText, "[[file:images/image.png][Image]]")

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("images/image.png"))
    let imageDraft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(imageDraft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "[[file:images/image.png][Image]]"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\n[[file:images/image.png][Image]]\n* Sibling"))

    let insertedImage = try XCTUnwrap(store.selectedBlock)
    store.beginEditingBlock(insertedImage)
    store.editableBlockText = "/video media/demo.mp4"

    await store.convertEditingBlock(insertedImage, to: .video)
    try await waitForCondition {
      store.selectedBlock?.rawText == "[[file:media/demo.mp4][demo.mp4]]"
        && store.editingBlockID == store.selectedBlockID
    }
    let videoDraft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(videoDraft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "[[file:media/demo.mp4][demo.mp4]]"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\n[[file:media/demo.mp4][demo.mp4]]\n* Sibling"))
    XCTAssertFalse(updated.contains("images/image.png"))
  }

  @MainActor
  func testInsertsAndConvertsDividerBlocks() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-divider-insert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("divider-insert.org2")
    try """
    #+TITLE: Divider Insert Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })

    await store.insertBlock(after: paragraph, kind: .divider)
    try await waitForCondition {
      store.selectedBlock?.rawText == "-----" && store.editingBlockID == store.selectedBlockID
    }
    guard case .horizontalRule = store.selectedBlock?.rendered else {
      return XCTFail("Expected divider draft")
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("-----"))
    let dividerDraft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(dividerDraft)
    try await waitForCondition {
      if case .horizontalRule = store.selectedBlock?.rendered {
        return store.selectedBlock?.rawText == "-----"
      }
      return false
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\n-----\n* Sibling"))

    let divider = try XCTUnwrap(store.selectedBlock)
    store.beginEditingBlock(divider)
    store.editableBlockText = "/todo Replace divider"
    await store.convertEditingBlock(divider, to: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Replace divider" && store.editingBlockID == store.selectedBlockID
    }
    let todoDraft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(todoDraft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Replace divider"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\n** TODO Replace divider\n* Sibling"))
    XCTAssertFalse(updated.contains("-----"))
  }

  @MainActor
  func testConvertsEditingParagraphWithSlashCommand() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-convert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-convert.org2")
    try """
    #+TITLE: Block Convert Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "/todo Call Bob"

    await store.convertEditingBlock(paragraph, to: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Call Bob" && store.editingBlockID == store.selectedBlockID
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody\n* Sibling"))
    XCTAssertFalse(updated.contains("** TODO Call Bob"))
    XCTAssertEqual(store.editableBlockText, "** TODO Call Bob")

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedRenderedBlocks.first(where: { $0.id == paragraph.id })?.rawText, "Body")
    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody\n* Sibling"))

    store.beginEditingBlock(paragraph)
    store.editableBlockText = "/todo Call Bob"
    await store.convertEditingBlock(paragraph, to: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Call Bob" && store.editingBlockID == store.selectedBlockID
    }
    let draft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Call Bob"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\n** TODO Call Bob\n* Sibling"))
    XCTAssertNil(store.editingBlockID)
  }

  @MainActor
  func testConvertsEditingParagraphUsingNonPublishedInlineDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-convert-nonpublished-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("convert-nonpublished-draft.org2")
    try """
    #+TITLE: Convert Nonpublished Draft Test

    * TODO Parent
    Body
    * Sibling
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    XCTAssertEqual(store.editableBlockText, "Body")

    store.updateEditingBlockDraft(paragraph, draft: "/todo Call Bob")
    XCTAssertEqual(store.editableBlockText, "Body")
    await store.convertEditingBlock(paragraph, to: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Call Bob" && store.editingBlockID == store.selectedBlockID
    }
  }

  @MainActor
  func testEmptySlashTodoDraftDoesNotSavePlaceholderHeading() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-empty-slash-todo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("empty-slash-todo.org2")
    try """
    #+TITLE: Empty Slash TODO Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "/todo"

    await store.convertEditingBlock(paragraph, to: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO " && store.editingBlockID == store.selectedBlockID
    }

    let draft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(draft)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody\n* Sibling"))
    XCTAssertFalse(updated.contains("New task"))
    XCTAssertFalse(updated.contains("** TODO \n"))
    XCTAssertEqual(store.selectedRenderedBlocks.first(where: { $0.id == paragraph.id })?.rawText, "Body")
  }

  @MainActor
  func testDuplicatesDeletesAndMovesRenderedBlocks() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-actions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-actions.org2")
    try """
    #+TITLE: Block Actions Test

    * TODO Parent
    Body
    - One
    - Two
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let one = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, _, let text) = $0.rendered { return text == "One" }
      return false
    })
    XCTAssertTrue(store.canMoveBlock(one, direction: .down))

    await store.moveBlock(one, direction: .down)
    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- Two\n- One\n* Sibling"))
    XCTAssertEqual(store.selectedBlock?.rawText, "- One")
    XCTAssertEqual(store.selectedBlock?.startLine, one.startLine + 1)
    XCTAssertEqual(store.selectedEntrySource?.displayRange, "3-6")

    let movedOne = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, _, let text) = $0.rendered { return text == "One" }
      return false
    })
    await store.duplicateBlock(movedOne)
    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- Two\n- One\n\n- One\n* Sibling"))
    XCTAssertEqual(store.selectedBlock?.rawText, "- One")
    XCTAssertEqual(store.selectedBlock?.startLine, movedOne.endLineExclusive + 1)
    XCTAssertEqual(store.selectedEntrySource?.displayRange, "3-8")

    let duplicatedOne = try XCTUnwrap(store.selectedRenderedBlocks
      .filter {
        if case .listItem(_, _, _, let text) = $0.rendered { return text == "One" }
        return false
      }
      .max { $0.startLine < $1.startLine })
    await store.deleteBlock(duplicatedOne)
    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- Two\n- One\n* Sibling"))
    XCTAssertFalse(updated.contains("- One\n\n- One"))
    XCTAssertEqual(store.selectedBlock?.rawText, "- One")
    XCTAssertEqual(store.selectedEntrySource?.displayRange, "3-6")
  }

  @MainActor
  func testTogglesRenderedListItemCheckboxInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-checkbox-toggle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("checkbox-toggle.org2")
    try """
    #+TITLE: Checkbox Toggle Test

    * TODO Parent
    - [ ] Open task
    - [X] Done task
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "- [ ] Open task",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let openTask = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, .unchecked, let text) = $0.rendered { return text == "Open task" }
      return false
    })

    await store.toggleListItemCheckbox(openTask)
    try await waitForCondition {
      store.selectedBlock?.rawText == "- [X] Open task"
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- [X] Open task\n- [X] Done task"))

    let toggledTask = try XCTUnwrap(store.selectedBlock)
    await store.toggleListItemCheckbox(toggledTask)
    try await waitForCondition {
      store.selectedBlock?.rawText == "- [ ] Open task"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- [ ] Open task\n- [X] Done task"))
  }

  @MainActor
  func testTogglesRenderedHeadingTodoInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-todo-toggle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-todo-toggle.org2")
    try """
    #+TITLE: Heading TODO Toggle Test

    * TODO Parent
    Body
    * Sibling
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered { return heading.todo == "TODO" }
      return false
    })

    await store.toggleHeadingTodo(heading)
    try await waitForCondition {
      store.selectedBlock?.rawText == "* DONE Parent"
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE Parent\nBody\n* Sibling"))

    let doneHeading = try XCTUnwrap(store.selectedBlock)
    await store.toggleHeadingTodo(doneHeading)
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO Parent"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody\n* Sibling"))
  }

  @MainActor
  func testSetsRenderedHeadingPriorityInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-priority-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-priority.org2")
    try """
    #+TITLE: Heading Priority Test

    * TODO [#A] Parent :work:
    Body
    * Sibling
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": ["work"],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered { return heading.priority == "A" }
      return false
    })

    await store.setHeadingPriority(heading, priority: "C")
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO [#C] Parent :work:"
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO [#C] Parent :work:\nBody\n* Sibling"))

    let updatedHeading = try XCTUnwrap(store.selectedBlock)
    await store.setHeadingPriority(updatedHeading, priority: nil)
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO Parent :work:"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent :work:\nBody\n* Sibling"))
  }

  @MainActor
  func testSetsRenderedHeadingTagsInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-tags-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-tags.org2")
    try """
    #+TITLE: Heading Tags Test

    * TODO [#A] Parent :work:
    Body
    * Sibling
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": ["work"],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered { return heading.tags == ["work"] }
      return false
    })

    await store.setHeadingTags(heading, tags: ["work", "focus", "work", "bad tag"])
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO [#A] Parent :work:focus:"
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO [#A] Parent :work:focus:\nBody\n* Sibling"))

    let taggedHeading = try XCTUnwrap(store.selectedBlock)
    await store.setHeadingTags(taggedHeading, tags: [])
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO [#A] Parent"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO [#A] Parent\nBody\n* Sibling"))
  }

  @MainActor
  func testSetsRenderedPlanningBlockInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-rendered-planning-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("rendered-planning.org2")
    try """
    #+TITLE: Rendered Planning Test

    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    Body
    * Sibling
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let planning = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .planning(let planning) = $0.rendered { return planning.kind == "SCHEDULED" }
      return false
    })

    await store.setPlanningBlock(planning, kind: "DEADLINE", value: "<2026-06-15 Mon 09:30>")
    try await waitForCondition {
      store.selectedBlock?.rawText == "DEADLINE: <2026-06-15 Mon 09:30>"
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nDEADLINE: <2026-06-15 Mon 09:30>\nBody\n* Sibling"))
  }

  @MainActor
  func testSelectsRenderedBlockAndHandlesDocumentKeyboard() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-selection.org2")
    try """
    #+TITLE: Block Selection Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading = $0.rendered { return true }
      return false
    })
    store.selectBlock(paragraph)
    XCTAssertEqual(store.selectedBlock?.id, paragraph.id)

    XCTAssertTrue(store.canSelectAdjacentBlock(.up))
    XCTAssertFalse(store.canSelectAdjacentBlock(.down))
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "k", keyCode: 40)))
    XCTAssertEqual(store.selectedBlock?.id, heading.id)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 125)))
    XCTAssertEqual(store.selectedBlock?.id, paragraph.id)

    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 53)))
    XCTAssertNil(store.selectedBlockID)

    store.selectBlock(paragraph)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "\r", keyCode: 36)))
    XCTAssertEqual(store.editingBlockID, paragraph.id)
    XCTAssertEqual(store.editableBlockText, "Body")
    XCTAssertTrue(store.hasActiveEdit)
    XCTAssertTrue(store.canSaveActiveEdit)
    XCTAssertFalse(store.handleDocumentKeyDown(keyDown(characters: "\u{7F}", keyCode: 51)))

    store.cancelActiveEdit()
    XCTAssertFalse(store.hasActiveEdit)
    store.selectBlock(paragraph)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "!", keyCode: 18)))
    XCTAssertEqual(store.editingBlockID, paragraph.id)
    XCTAssertEqual(store.editableBlockText, "Body!")
    XCTAssertEqual(store.selectedBlock?.rawText, "Body!")

    store.cancelEditingBlock()
    XCTAssertNil(store.editingBlockID)
    XCTAssertEqual(store.selectedBlock?.rawText, "Body")

    store.selectBlock(heading)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "!", keyCode: 18)))
    XCTAssertEqual(store.editingBlockID, heading.id)
    XCTAssertEqual(store.editableBlockText, "* TODO Parent!")
    XCTAssertEqual(store.selectedBlock?.rawText, "* TODO Parent!")

    store.cancelEditingBlock()
    XCTAssertNil(store.editingBlockID)
    XCTAssertEqual(store.selectedBlock?.rawText, "* TODO Parent")

    store.selectBlock(paragraph)
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "e", keyCode: 14)))
    XCTAssertEqual(store.editingBlockID, paragraph.id)
    XCTAssertEqual(store.editableBlockText, "Body")
    XCTAssertFalse(store.isEditingEntry)

    store.cancelEditingBlock()
    store.clearSelectedBlock()
    store.beginEditingVisibleBlock()
    XCTAssertEqual(store.editingBlockID, heading.id)
    XCTAssertEqual(store.editableBlockText, "* TODO Parent")
    XCTAssertFalse(store.isEditingEntry)
  }

  @MainActor
  func testRepeatBeginEditingActiveBlockPreservesDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-repeat-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("repeat-edit.org2")
    try """
    * TODO Parent
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "Body draft"
    store.updateEditingBlockDraft(paragraph, draft: "Body draft")

    store.beginEditingBlock(paragraph)

    XCTAssertEqual(store.editingBlockID, paragraph.id)
    XCTAssertEqual(store.selectedBlockID, paragraph.id)
    XCTAssertEqual(store.editableBlockText, "Body draft")

    await store.saveEditedBlock(paragraph)
    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody draft"))
  }

  @MainActor
  func testInsertsBlockAfterSelectedBlockFromKeyboard() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-selected-block-insert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("selected-block-insert.org2")
    try """
    #+TITLE: Selected Block Insert Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.selectBlock(paragraph)

    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "/", keyCode: 44)))
    try await waitForCondition {
      store.selectedBlock?.rawText == "/" && store.editingBlockID == store.selectedBlockID
    }
    XCTAssertEqual(store.editableBlockText, "/")
    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n* Sibling"))
    XCTAssertFalse(updated.contains("Body\n\n/\n* Sibling"))

    store.cancelEditingBlock()
    XCTAssertNil(store.selectedBlock)
    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n* Sibling"))

    store.selectBlock(paragraph)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "\r", keyCode: 36, modifiers: [.command])))
    try await waitForCondition {
      store.selectedBlock?.rawText == "" && store.editingBlockID == store.selectedBlockID
    }
    XCTAssertEqual(store.editableBlockText, "")

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("New text"))
    XCTAssertTrue(updated.contains("Body\n* Sibling"))

    store.cancelEditingBlock()
    XCTAssertNil(store.selectedBlock)
    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n* Sibling"))

    store.selectBlock(paragraph)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "\r", keyCode: 36, modifiers: [.command])))
    try await waitForCondition {
      store.selectedBlock?.rawText == "" && store.editingBlockID == store.selectedBlockID
    }

    let draft = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "Inserted paragraph"
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "Inserted paragraph"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\nInserted paragraph\n* Sibling"))
  }

  @MainActor
  func testLoadsSelectedPageSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("page.org2")
    try """
    #+TITLE: Page Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))

    XCTAssertEqual(store.selectedEntrySource?.startLine, 1)
    XCTAssertTrue(store.selectedEntrySource?.text.contains("#+TITLE: Page Test") == true)
    XCTAssertTrue(store.selectedEntrySource?.text.contains("* Sibling") == true)
  }

  @MainActor
  func testLoadsAndRendersLargePageSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-large-page-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("large-page.org2")
    let body = (1...2_500)
      .map { index in
        """
        * TODO Large item \(index)
        Body \(index)
        """
      }
      .joined(separator: "\n")
    try "#+TITLE: Large Page\n\n\(body)\n".write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Large item 1",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body 1",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    XCTAssertEqual(store.selectedEntrySource?.startLine, 1)
    XCTAssertEqual(store.selectedEntrySource?.displayRange, "1-5003")
    XCTAssertGreaterThan(store.selectedRenderedBlocks.count, 4_000)
    XCTAssertFalse(store.isRenderingEntrySource)
  }

  @MainActor
  func testOpenClawThreadsUseConfiguredDirectories() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-openclaw-\(UUID().uuidString)", isDirectory: true)
    let threads = root.appendingPathComponent("threads", isDirectory: true)
    try FileManager.default.createDirectory(at: threads, withIntermediateDirectories: true)
    try #"{"openclaw":{"threadDirs":["threads"]}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)
    try """
    #+TITLE: Agent Thread

    * TODO Follow up
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :END:
    """.write(to: threads.appendingPathComponent("agent-thread.org2"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshOpenClawThreads()

    XCTAssertEqual(store.openClawThreads.count, 1)
    XCTAssertEqual(store.openClawThreads[0].title, "Agent Thread")
    XCTAssertEqual(store.openClawThreads[0].zone, "threads")
    XCTAssertEqual(store.openClawThreads[0].idValue, "11111111-1111-4111-8111-111111111111")
  }

  @MainActor
  private func waitForEntryRender(_ store: WorkspaceStore, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while store.isRenderingEntrySource && Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertFalse(store.isRenderingEntrySource)
  }

  @MainActor
  private func waitForCondition(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(condition())
  }

  private func keyDown(
    characters: String = "",
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = []
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode
    )!
  }

  private func assertToken(
    _ kind: OrgSyntaxHighlightKind,
    _ substring: String,
    in raw: String,
    tokens: [OrgSyntaxHighlightToken],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let range = raw.range(of: substring) else {
      XCTFail("Missing substring \(substring)", file: file, line: line)
      return
    }
    let nsRange = NSRange(range, in: raw)
    XCTAssertTrue(
      tokens.contains { $0.kind == kind && NSEqualRanges($0.range, nsRange) },
      "Missing \(kind) token for \(substring)",
      file: file,
      line: line
    )
  }

  private func optionalLocation(_ range: NSRange) -> Int? {
    range.location == NSNotFound ? nil : range.location
  }
}
