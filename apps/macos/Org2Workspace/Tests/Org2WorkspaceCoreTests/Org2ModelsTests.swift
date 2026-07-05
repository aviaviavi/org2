import AppKit
@preconcurrency import AVFoundation
import Combine
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

private actor OpenClawQueuedSendRecorder {
  private var calls: [[String]] = []

  func send(messages: [OpenClawChatMessage]) async throws -> String {
    calls.append(messages.map { "\($0.role.rawValue):\($0.content)" })
    try await Task.sleep(nanoseconds: 200_000_000)
    return "reply \(calls.count)"
  }

  func recordedCalls() -> [[String]] {
    calls
  }
}

private actor OpenClawMessageSendRecorder {
  private var calls: [[OpenClawChatMessage]] = []

  func send(messages: [OpenClawChatMessage]) async throws -> String {
    calls.append(messages)
    return "reply \(calls.count)"
  }

  func recordedCalls() -> [[OpenClawChatMessage]] {
    calls
  }
}

private struct OpenClawTestSendError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? {
    message
  }
}

private actor OpenClawRetrySendRecorder {
  private var attempts = 0

  func send(messages: [OpenClawChatMessage]) async throws -> String {
    attempts += 1
    if attempts == 1 {
      throw OpenClawTestSendError(message: "VPN disconnected")
    }
    return "reply after reconnect"
  }

  func attemptCount() -> Int {
    attempts
  }
}

private actor OpenClawSuspendedSendRecorder {
  private var started = false
  private var continuation: CheckedContinuation<String, Never>?

  func send(messages: [OpenClawChatMessage]) async throws -> String {
    started = true
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func hasStarted() -> Bool {
    started
  }

  func finish(reply: String) {
    continuation?.resume(returning: reply)
    continuation = nil
  }
}

final class Org2ModelsTests: XCTestCase {
  private func searchResult(
    file: String,
    line: Int,
    heading: String,
    todo: String?,
    snippet: String = "Matched text"
  ) -> SearchResult {
    SearchResult(
      file: file,
      line: line,
      lineEnd: nil,
      heading: heading,
      headingLine: line,
      headingLevel: 1,
      headingAncestry: nil,
      idValue: nil,
      todo: todo,
      tags: [],
      snippet: snippet,
      sourceRange: nil,
      matchedLines: nil,
      date: nil
    )
  }

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

  func testApprovalItemsUseCanonicalParserSignals() async throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let text = """
    * TODO Review and approve launch email
    :PROPERTIES:
    :ID: approval-1
    :REVIEW_STATUS: review-required
    :END:
    Please review the response draft.

    * TODO Follow up with vendor
    :PROPERTIES:
    :WAITING_ON: Avi approval
    :END:
    Needs a human decision.

    * DONE Review and approve old note
    :PROPERTIES:
    :REVIEW_STATUS: review-required
    :END:
    Already done.
    """
    let document: Org2CanonicalDocument = try await cli.parseTextJSON(text, sourceRanges: true)

    let approvals = WorkspaceStore.approvalItems(
      in: document,
      file: "/tmp/approvals.org2",
      sourceText: text
    )

    XCTAssertEqual(approvals.map(\.title), [
      "Follow up with vendor",
      "Review and approve launch email"
    ])
    XCTAssertEqual(approvals[0].status, "Avi approval")
    XCTAssertEqual(approvals[1].status, "review-required")
    XCTAssertEqual(approvals[1].idValue, "approval-1")
    XCTAssertTrue(approvals[1].body.contains("Please review"))
  }

  func testApprovalCandidatePrefilterSkipsIrrelevantFiles() {
    XCTAssertFalse(WorkspaceStore.approvalCandidateTextMayContainItem("""
    * TODO Write launch email
    :PROPERTIES:
    :STATUS: ready
    :END:
    This mentions review in prose, but it is not approval gated.
    """))

    XCTAssertTrue(WorkspaceStore.approvalCandidateTextMayContainItem("""
    * TODO Review and approve launch email
    :PROPERTIES:
    :REVIEW_STATUS: review-required
    :END:
    """))

    XCTAssertTrue(WorkspaceStore.approvalCandidateTextMayContainItem("""
    * TODO Follow up with vendor
    :PROPERTIES:
    :WAITING_ON: Avi approval
    :END:
    """))
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

  func testCanonicalAstKeepsBeginQuoteBlocksAsQuotes() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-canonical-quote-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("quote.org2")
    let raw = """
    * Follow up
    #+begin_quote
    Quoted body
    #+end_quote
    """
    try raw.write(to: note, atomically: true, encoding: .utf8)

    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let document: Org2CanonicalDocument = try cli.parseFileJSONSync(note, sourceRanges: true)
    let blocks = OrgEntryRenderer.parseEditable(raw, canonicalDocument: document)

    XCTAssertTrue(blocks.contains {
      if case .quote(let lines) = $0.rendered {
        return lines == ["Quoted body"] && $0.displayRange == "2-4"
      }
      return false
    })
    XCTAssertFalse(blocks.contains {
      if case .source = $0.rendered { return true }
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

  func testOpenClawGatewaySettingsNormalizeBearerTokenInputs() throws {
    let missingConfig = URL(fileURLWithPath: "/tmp/missing-clawdbot-\(UUID().uuidString).json")
    let userSettings = OpenClawGatewaySettings.resolve(
      environment: [:],
      configURL: missingConfig,
      userBearerToken: "  Bearer user-secret  "
    )
    XCTAssertEqual(userSettings.bearerToken, "user-secret")

    let environmentSettings = OpenClawGatewaySettings.resolve(
      environment: ["ORG2_WORKSPACE_OPENCLAW_TOKEN": "bearer env-secret"],
      configURL: missingConfig
    )
    XCTAssertEqual(environmentSettings.bearerToken, "env-secret")

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-openclaw-bearer-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let config = root.appendingPathComponent("clawdbot.json")
    try """
    {
      "gateway": {
        "auth": { "mode": "password", "password": "Bearer config-secret" }
      }
    }
    """.write(to: config, atomically: true, encoding: .utf8)

    let configSettings = OpenClawGatewaySettings.resolve(environment: [:], configURL: config)
    XCTAssertEqual(configSettings.bearerToken, "config-secret")
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

  @MainActor
  func testOpenClawChatTranscriptPersistsImageAttachments() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-image-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-image-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let attachment = OpenClawChatAttachment(
      fileName: "diagram.png",
      mimeType: "image/png",
      data: Data([0x89, 0x50, 0x4e, 0x47])
    )
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    store.openClawMessages = [
      OpenClawChatMessage(role: .user, content: "What is in this?", attachments: [attachment])
    ]

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )

    XCTAssertEqual(restored.openClawMessages.first?.attachments, [attachment])
    XCTAssertTrue(attachment.dataURLString.hasPrefix("data:image/png;base64,"))
  }

  @MainActor
  func testOpenClawChatThreadsPersistAndSwitchLocally() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-threads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-threads-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    store.openClawMessages = [
      OpenClawChatMessage(role: .user, content: "First thread question"),
      OpenClawChatMessage(role: .assistant, content: "First thread reply")
    ]
    let firstThreadID = try XCTUnwrap(store.selectedOpenClawChatThreadID)

    store.createOpenClawChatThread()
    let secondThreadID = try XCTUnwrap(store.selectedOpenClawChatThreadID)
    XCTAssertNotEqual(firstThreadID, secondThreadID)
    XCTAssertTrue(store.openClawMessages.isEmpty)

    store.openClawMessages = [
      OpenClawChatMessage(role: .user, content: "Second thread question")
    ]

    store.selectOpenClawChatThread(firstThreadID)
    XCTAssertEqual(store.openClawMessages.map(\.content), ["First thread question", "First thread reply"])

    store.selectOpenClawChatThread(secondThreadID)
    XCTAssertEqual(store.openClawMessages.map(\.content), ["Second thread question"])

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    XCTAssertEqual(restored.openClawChatThreads.count, 2)
    XCTAssertEqual(restored.selectedOpenClawChatThreadID, secondThreadID)
    XCTAssertEqual(restored.openClawMessages.map(\.content), ["Second thread question"])
  }

  func testOpenClawThreadTitleUsesMeaningfulFirstMessageWords() {
    let title = WorkspaceStore.openClawThreadTitle(from: [
      OpenClawChatMessage(
        role: .user,
        content: "can you fix the alignment of the cursor with the tag above it"
      )
    ])

    XCTAssertEqual(title, "Fix alignment cursor tag above")
  }

  func testOpenClawThreadTitleSkipsFillerOpenings() {
    let title = WorkspaceStore.openClawThreadTitle(from: [
      OpenClawChatMessage(
        role: .user,
        content: "sure let's do that to start. also while you're doing that. our thread nav is still a bit clunky."
      )
    ])

    XCTAssertEqual(title, "Thread nav still bit clunky")
  }

  @MainActor
  func testOpenClawChatThreadsPinAndArchivePersistLocally() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-metadata-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-thread-metadata-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    store.openClawMessages = [
      OpenClawChatMessage(role: .user, content: "First pinned thread")
    ]
    let firstThreadID = try XCTUnwrap(store.selectedOpenClawChatThreadID)

    store.createOpenClawChatThread()
    store.openClawMessages = [
      OpenClawChatMessage(role: .user, content: "Second regular thread")
    ]
    let secondThreadID = try XCTUnwrap(store.selectedOpenClawChatThreadID)

    store.toggleOpenClawChatThreadPin(firstThreadID)
    XCTAssertEqual(Array(store.visibleOpenClawChatThreads.map(\.id).prefix(2)), [firstThreadID, secondThreadID])

    store.archiveOpenClawChatThread(firstThreadID)
    XCTAssertFalse(store.visibleOpenClawChatThreads.contains(where: { $0.id == firstThreadID }))
    XCTAssertEqual(store.archivedOpenClawChatThreads.first?.id, firstThreadID)

    store.restoreOpenClawChatThread(firstThreadID)
    XCTAssertEqual(store.visibleOpenClawChatThreads.first?.id, firstThreadID)
    XCTAssertEqual(store.visibleOpenClawChatThreads.first?.isPinned, true)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    XCTAssertEqual(restored.visibleOpenClawChatThreads.first?.id, firstThreadID)
    XCTAssertEqual(restored.visibleOpenClawChatThreads.first?.isPinned, true)
    XCTAssertTrue(restored.archivedOpenClawChatThreads.isEmpty)
  }

  @MainActor
  func testOpenClawChatThreadsTrackUnreadBackgroundRepliesAndSound() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-unread-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-thread-unread-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    var soundCount = 0
    store.openClawIncomingMessageSoundPlayer = {
      soundCount += 1
    }
    store.selectedSurface = .agenda

    store.openClawMessages = [
      OpenClawChatMessage(role: .user, content: "Question while away")
    ]
    let threadID = try XCTUnwrap(store.selectedOpenClawChatThreadID)
    XCTAssertEqual(store.openClawChatThreads.first?.unreadMessageCount, 0)
    XCTAssertEqual(soundCount, 0)

    store.openClawMessages.append(OpenClawChatMessage(role: .assistant, content: "Background reply"))
    XCTAssertEqual(store.openClawChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 1)
    XCTAssertEqual(store.openClawUnreadMessageCount, 1)
    XCTAssertEqual(soundCount, 1)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    XCTAssertEqual(restored.openClawChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 1)

    restored.makeSurfacePrimary(.openClaw)
    XCTAssertEqual(restored.openClawChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 0)
    XCTAssertEqual(restored.openClawUnreadMessageCount, 0)

    let reopened = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    XCTAssertEqual(reopened.openClawChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 0)
  }

  @MainActor
  func testOpenClawChatThreadsDoNotMarkActiveRepliesUnread() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-active-unread-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-thread-active-unread-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    var soundCount = 0
    store.openClawIncomingMessageSoundPlayer = {
      soundCount += 1
    }
    store.makeSurfacePrimary(.openClaw)
    store.openClawMessages = [
      OpenClawChatMessage(role: .user, content: "Question in active chat"),
      OpenClawChatMessage(role: .assistant, content: "Visible reply")
    ]

    XCTAssertEqual(store.openClawUnreadMessageCount, 0)
    XCTAssertEqual(soundCount, 0)
  }

  @MainActor
  func testOpenClawChatThreadsMigrateLegacySingleTranscriptPayload() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-legacy-threads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-legacy-threads-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let payload: [String: Any] = [
      "version": 1,
      "messages": [
        [
          "id": UUID().uuidString,
          "role": "user",
          "content": "Legacy single chat",
          "createdAt": Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: transcript)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )

    XCTAssertEqual(store.openClawChatThreads.count, 1)
    XCTAssertEqual(store.openClawChatThreads.first?.title, "Legacy single chat")
    XCTAssertEqual(store.openClawMessages.map(\.content), ["Legacy single chat"])
  }

  @MainActor
  func testOpenClawChatTranscriptPersistsRealSendsLocally() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-send-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-send-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript,
      openClawSendHandler: { _, _, _, _ in "Hello from restart-safe storage" }
    )
    store.openClawDraft = "Hello OpenClaw"
    await store.sendOpenClawMessage()

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )

    XCTAssertEqual(restored.openClawMessages.map(\.content), ["Hello OpenClaw", "Hello from restart-safe storage"])
  }

  @MainActor
  func testOpenClawSendFailureIsVisiblePersistedAndRetryable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-send-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-send-failure-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let recorder = OpenClawRetrySendRecorder()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript,
      openClawSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.openClawDraft = "Are you reachable?"

    await store.sendOpenClawMessage()

    XCTAssertEqual(store.openClawMessages.map(\.content), ["Are you reachable?"])
    let failedMessage = try XCTUnwrap(store.openClawMessages.first)
    XCTAssertEqual(failedMessage.sendFailure, "VPN disconnected")
    XCTAssertEqual(failedMessage.deliveryStatus, .failed)
    XCTAssertEqual(store.openClawStatusText, "VPN disconnected")
    XCTAssertFalse(store.isSendingOpenClawMessage)
    XCTAssertEqual(store.openClawQueuedMessageCount, 0)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    XCTAssertEqual(restored.openClawMessages.first?.sendFailure, "VPN disconnected")
    XCTAssertEqual(restored.openClawMessages.first?.deliveryStatus, .failed)

    await store.retryOpenClawMessage(failedMessage.id)

    let attemptCount = await recorder.attemptCount()
    XCTAssertEqual(attemptCount, 2)
    XCTAssertEqual(store.openClawMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:Are you reachable?",
      "assistant:reply after reconnect"
    ])
    XCTAssertNil(store.openClawMessages.first?.sendFailure)
    XCTAssertEqual(store.openClawMessages.first?.deliveryStatus, .sent)
    XCTAssertEqual(store.openClawStatusText, "OpenClaw replied")
  }

  @MainActor
  func testOpenClawInFlightSendRestoresAsInterruptedAndRetryable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-send-interrupted-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-send-interrupted-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let recorder = OpenClawSuspendedSendRecorder()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript,
      openClawSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.openClawDraft = "Please do this long running thing"

    let sendTask = Task { await store.sendOpenClawMessage() }
    let deadline = Date().addingTimeInterval(5)
    while !(await recorder.hasStarted()) && Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let didStart = await recorder.hasStarted()
    XCTAssertTrue(didStart)
    XCTAssertEqual(store.openClawMessages.first?.deliveryStatus, .sending)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript,
      openClawSendHandler: { _, _, _, _ in "reply after retry" }
    )
    let interrupted = try XCTUnwrap(restored.openClawMessages.first)
    XCTAssertEqual(interrupted.content, "Please do this long running thing")
    XCTAssertEqual(interrupted.deliveryStatus, .interrupted)
    XCTAssertTrue(interrupted.sendFailure?.contains("restarted") == true)
    XCTAssertEqual(restored.openClawStatusText, "OpenClaw response interrupted; retry the message")

    await restored.retryOpenClawMessage(interrupted.id)
    XCTAssertEqual(restored.openClawMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:Please do this long running thing",
      "assistant:reply after retry"
    ])
    XCTAssertEqual(restored.openClawMessages.first?.deliveryStatus, .sent)
    XCTAssertNil(restored.openClawMessages.first?.sendFailure)

    await recorder.finish(reply: "late original reply")
    await sendTask.value
  }

  @MainActor
  func testMacApprovalsRefreshDiscussAndApproveViaStore() async throws {
    let recorder = OpenClawMessageSendRecorder()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-approvals-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("approvals.org2")
    try """
    * TODO Send approved launch email
    :PROPERTIES:
    :STATUS: waiting
    :END:

    * TODO Review and approve launch email
    :PROPERTIES:
    :ID: approval-1
    :REVIEW_STATUS: review-required
    :PAIRED_SEND_TODO: Send approved launch email
    :END:
    Please review the launch email before sending it.
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      openClawTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      openClawSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.setCorpusRoot(root, persistsDefault: false)

    await store.refreshApprovals(updatesStatus: true)

    let approval = try XCTUnwrap(store.approvalItems.first)
    XCTAssertEqual(approval.title, "Review and approve launch email")
    XCTAssertEqual(approval.status, "review-required")
    XCTAssertEqual(store.statusText, "1 approval")

    await store.discussApprovalInOpenClaw(approval)

    let calls = await recorder.recordedCalls()
    let sentText = try XCTUnwrap(calls.first?.last?.content)
    XCTAssertTrue(sentText.contains("OpenClaw approval thread"))
    XCTAssertTrue(sentText.contains("Please review the launch email"))

    await store.approve(approval)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Send approved launch email"))
    XCTAssertTrue(updated.contains(":STATUS: approved-to-send"))
    XCTAssertTrue(updated.contains(":ASSIGNEE: OpenClaw"))
    XCTAssertTrue(updated.contains("* DONE Review and approve launch email"))
    XCTAssertTrue(updated.contains(":REVIEW_STATUS: approved"))
    XCTAssertTrue(updated.contains(":STATUS: approved"))
    XCTAssertTrue(store.approvalItems.isEmpty)
  }

  @MainActor
  func testLocalCorpusApprovalsRefreshWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rawCorpus = environment["ORG2_WORKSPACE_LOCAL_CORPUS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawCorpus.isEmpty
    else {
      throw XCTSkip("Set ORG2_WORKSPACE_LOCAL_CORPUS to smoke-test approvals against a local corpus.")
    }

    let root = URL(fileURLWithPath: rawCorpus).standardizedFileURL
    let defaults = UserDefaults(suiteName: "org2-workspace-local-approvals-\(UUID().uuidString)") ?? .standard
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent(".org2/local-approval-smoke-openclaw.json")
    )
    store.setCorpusRoot(root, persistsDefault: false)

    let start = Date()
    await store.refreshApprovals(updatesStatus: true)
    let elapsed = Date().timeIntervalSince(start)

    XCTAssertNil(store.errorText)
    XCTAssertFalse(store.isLoadingApprovals)
    XCTAssertTrue(store.statusText.contains("approval"))
    print("Local corpus approvals refresh: \(store.approvalItems.count) approvals in \(String(format: "%.3f", elapsed))s")
  }

  @MainActor
  func testOpenClawComposerSendsPendingImageAttachments() async throws {
    let recorder = OpenClawMessageSendRecorder()
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-image-send-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let imageURL = temp.appendingPathComponent("sketch.png")
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: imageURL)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      openClawTranscriptURL: temp.appendingPathComponent("openclaw-chat.json"),
      openClawSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.attachOpenClawImages(urls: [imageURL])

    XCTAssertEqual(store.openClawPendingAttachments.count, 1)

    await store.sendOpenClawMessage()

    XCTAssertTrue(store.openClawPendingAttachments.isEmpty)
    XCTAssertEqual(store.openClawMessages.first?.attachments.first?.fileName, "sketch.png")
    let calls = await recorder.recordedCalls()
    XCTAssertEqual(calls.first?.last?.attachments.first?.mimeType, "image/png")
  }

  @MainActor
  func testOpenClawReplyRecordsCorpusChangeSummary() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-changes-\(UUID().uuidString)", isDirectory: true)
    let root = temp.appendingPathComponent("corpus", isDirectory: true)
    let transcript = temp.appendingPathComponent("transcript", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let notePath = root.appendingPathComponent("note.org").path
    let createdPath = root.appendingPathComponent("created.org").path
    try "Line one\n".write(toFile: notePath, atomically: true, encoding: .utf8)

    let suiteName = "org2-workspace-chat-changes-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript,
      openClawSendHandler: { _, _, _, _ in
        try "Line one\nLine two\n".write(toFile: notePath, atomically: true, encoding: .utf8)
        try "Alpha\nBeta\n".write(toFile: createdPath, atomically: true, encoding: .utf8)
        return "Updated the corpus"
      }
    )
    store.setCorpusRoot(root)
    store.openClawDraft = "Update these notes"

    await store.sendOpenClawMessage()

    let assistantMessage = try XCTUnwrap(store.openClawMessages.last)
    let summary = try XCTUnwrap(assistantMessage.changeSummary)
    XCTAssertEqual(summary.title, "Edited 2 files")
    XCTAssertEqual(summary.changedFileCount, 2)
    XCTAssertEqual(summary.totalInsertions, 3)
    XCTAssertEqual(summary.totalDeletions, 0)
    XCTAssertEqual(
      summary.files,
      [
        OpenClawCorpusFileChange(relativePath: "created.org", status: .created, insertions: 2, deletions: 0),
        OpenClawCorpusFileChange(relativePath: "note.org", status: .modified, insertions: 1, deletions: 0)
      ]
    )

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript
    )
    XCTAssertEqual(restored.openClawMessages.last?.changeSummary, summary)
  }

  @MainActor
  func testOpenClawReplyAttributesDiffToReferencedFilesWhenBackgroundJobsAlsoWrite() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-attributed-changes-\(UUID().uuidString)", isDirectory: true)
    let root = temp.appendingPathComponent("corpus", isDirectory: true)
    let transcript = temp.appendingPathComponent("transcript", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    let agents = root.appendingPathComponent("agents", isDirectory: true)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)

    let target = agents.appendingPathComponent("account-outreach.org2")
    let background = agents.appendingPathComponent("MeetingBot.org2")
    try "Target one\n".write(to: target, atomically: true, encoding: .utf8)
    try "Background one\n".write(to: background, atomically: true, encoding: .utf8)

    let suiteName = "org2-workspace-chat-attributed-changes-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let targetPath = target.path
    let backgroundPath = background.path
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript,
      openClawSendHandler: { _, _, _, _ in
        try "Target one\nTarget two\n".write(toFile: targetPath, atomically: true, encoding: .utf8)
        try "Background one\nBackground two\n".write(toFile: backgroundPath, atomically: true, encoding: .utf8)
        return "Done. Added the scheduled review TODO in /srv/org2/agents/account-outreach.org2."
      }
    )
    store.setCorpusRoot(root)
    XCTAssertTrue(store.saveOpenClawConfiguration(
      endpoint: store.openClawEndpointText,
      agent: store.openClawAgentID,
      handoffAssignee: store.agentHandoffAssignee,
      remoteCorpusPath: "/srv/org2",
      token: "",
      clearToken: false
    ))
    store.openClawDraft = "Create the TODO"

    await store.sendOpenClawMessage()

    let summary = try XCTUnwrap(store.openClawMessages.last?.changeSummary)
    XCTAssertEqual(summary.changedFileCount, 1)
    XCTAssertEqual(
      summary.files,
      [
        OpenClawCorpusFileChange(
          relativePath: "agents/account-outreach.org2",
          status: .modified,
          insertions: 1,
          deletions: 0
        )
      ]
    )
  }

  @MainActor
  func testOpenClawReplyRetriesBrieflyForDelayedCorpusChanges() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-delayed-changes-\(UUID().uuidString)", isDirectory: true)
    let root = temp.appendingPathComponent("corpus", isDirectory: true)
    let transcript = temp.appendingPathComponent("transcript", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let note = root.appendingPathComponent("agents", isDirectory: true)
      .appendingPathComponent("account-outreach.org2")
    try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "Original\n".write(to: note, atomically: true, encoding: .utf8)

    let suiteName = "org2-workspace-chat-delayed-changes-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let notePath = note.path
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: transcript,
      openClawSendHandler: { _, _, _, _ in
        Task.detached {
          try? await Task.sleep(nanoseconds: 200_000_000)
          try? "Original\nAdded\n".write(toFile: notePath, atomically: true, encoding: .utf8)
        }
        return "Updated later"
      }
    )
    store.setCorpusRoot(root)
    store.openClawDraft = "Update this"

    await store.sendOpenClawMessage()

    let summary = try XCTUnwrap(store.openClawMessages.last?.changeSummary)
    XCTAssertEqual(summary.changedFileCount, 1)
    XCTAssertEqual(summary.totalInsertions, 1)
    XCTAssertEqual(summary.totalDeletions, 0)
    XCTAssertEqual(summary.files.first?.relativePath, "agents/account-outreach.org2")
  }

  @MainActor
  func testOpenClawChatTranscriptPersistsInCorpusStorageAcrossBootstrap() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-corpus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "org2-workspace-chat-corpus-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.setCorpusRoot(root)
    store.openClawMessages = [
      OpenClawChatMessage(role: .user, content: "Remember this corpus chat"),
      OpenClawChatMessage(role: .assistant, content: "Stored with the corpus")
    ]

    let corpusTranscript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: corpusTranscript.path))

    let restored = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    await restored.bootstrap()

    XCTAssertEqual(restored.openClawMessages.map(\.content), ["Remember this corpus chat", "Stored with the corpus"])
  }

  @MainActor
  func testOpenClawChatTranscriptMigratesLegacyAppSupportStorageOnBootstrap() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-migration-\(UUID().uuidString)", isDirectory: true)
    let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
    try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    let legacyTranscript = appSupport.appendingPathComponent("openclaw-chat.json")
    let legacyID = UUID()
    let createdAt = Date().timeIntervalSinceReferenceDate
    try """
    {
      "messages": [
        {
          "content": "Legacy app-support chat",
          "createdAt": \(createdAt),
          "id": "\(legacyID.uuidString)",
          "role": "user"
        }
      ],
      "version": 1
    }
    """.write(to: legacyTranscript, atomically: true, encoding: .utf8)

    let suiteName = "org2-workspace-chat-migration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(root.path, forKey: "Org2Workspace.corpusRoot")
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawFallbackTranscriptURL: legacyTranscript
    )
    await restored.bootstrap()

    let corpusTranscript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    XCTAssertEqual(restored.openClawMessages.map(\.content), ["Legacy app-support chat"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: corpusTranscript.path))
    XCTAssertTrue(try String(contentsOf: corpusTranscript, encoding: .utf8).contains("Legacy app-support chat"))
  }

  @MainActor
  func testAgendaModeDefaultsToFocus() throws {
    let suiteName = "org2-workspace-agenda-mode-default-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertEqual(store.agendaMode, .focus)
  }

  @MainActor
  func testAgendaModePersistsLastSelection() throws {
    let suiteName = "org2-workspace-agenda-mode-persist-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.agendaMode = .range

    let restored = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertEqual(restored.agendaMode, .range)
  }

  @MainActor
  func testAgendaModeKeySelectsAssigned() throws {
    let suiteName = "org2-workspace-agenda-mode-key-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    store.setAgendaModeFromKey("4")

    XCTAssertEqual(store.agendaMode, .assigned)
  }

  @MainActor
  func testAgentHandoffAssigneeDefaultsAndPersistsSeparatelyFromOpenClawChatAgent() throws {
    let suiteName = "org2-workspace-handoff-assignee-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertEqual(store.openClawAgentID, "main")
    XCTAssertEqual(store.agentHandoffAssignee, "OpenClaw")
    XCTAssertEqual(store.personalAssigneeNamesText, "")
    XCTAssertTrue(store.saveOpenClawConfiguration(
      endpoint: store.openClawEndpointText,
      agent: "research-agent",
      handoffAssignee: "OpenClaw",
      personalAssigneeNames: "Avi, avi@example.com",
      remoteCorpusPath: "/srv/org2",
      token: "",
      clearToken: false
    ))

    let restored = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertEqual(restored.openClawAgentID, "research-agent")
    XCTAssertEqual(restored.agentHandoffAssignee, "OpenClaw")
    XCTAssertEqual(restored.personalAssigneeNamesText, "Avi, avi@example.com")
  }

  @MainActor
  func testPersonalAssigneeNamesClassifyAgendaOwnership() throws {
    let suiteName = "org2-workspace-personal-assignee-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertTrue(store.isPersonalAssignee(nil))
    XCTAssertTrue(store.isPersonalAssignee(""))
    XCTAssertFalse(store.isPersonalAssignee("Avi"))
    XCTAssertTrue(store.saveOpenClawConfiguration(
      endpoint: store.openClawEndpointText,
      agent: store.openClawAgentID,
      handoffAssignee: store.agentHandoffAssignee,
      personalAssigneeNames: "Avi; avi@example.com\nAvi Press",
      remoteCorpusPath: store.openClawRemoteCorpusPath,
      token: "",
      clearToken: false
    ))

    XCTAssertTrue(store.isPersonalAssignee("Avi"))
    XCTAssertTrue(store.isPersonalAssignee(" avi@example.com "))
    XCTAssertTrue(store.isPersonalAssignee("avi   press"))
    XCTAssertFalse(store.isPersonalAssignee("OpenClaw"))
  }

  @MainActor
  func testAgentAssigneeClassificationUsesConfiguredHandoffAssigneeOnly() throws {
    let suiteName = "org2-workspace-agent-assignee-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertFalse(store.isAgentAssignee(nil))
    XCTAssertFalse(store.isAgentAssignee(""))
    XCTAssertTrue(store.isAgentAssignee("OpenClaw"))
    XCTAssertFalse(store.isAgentAssignee("Avi"))
    XCTAssertTrue(store.saveOpenClawConfiguration(
      endpoint: store.openClawEndpointText,
      agent: store.openClawAgentID,
      handoffAssignee: "OpenClaw Worker",
      personalAssigneeNames: "Avi",
      remoteCorpusPath: store.openClawRemoteCorpusPath,
      token: "",
      clearToken: false
    ))

    XCTAssertTrue(store.isAgentAssignee("openclaw worker"))
    XCTAssertTrue(store.isAgentAssignee("OpenClaw"))
    XCTAssertFalse(store.isAgentAssignee("Avi"))
  }

  @MainActor
  func testOpenClawConfigurationMigratesFromLegacyDefaultsDomain() throws {
    let currentSuiteName = "org2-workspace-stable-defaults-\(UUID().uuidString)"
    let legacySuiteName = "org2-workspace-legacy-defaults-\(UUID().uuidString)"
    let currentDefaults = UserDefaults(suiteName: currentSuiteName)!
    let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
    defer {
      currentDefaults.removePersistentDomain(forName: currentSuiteName)
      legacyDefaults.removePersistentDomain(forName: legacySuiteName)
    }

    legacyDefaults.set("https://example.invalid/v1/chat/completions", forKey: "Org2Workspace.openClawEndpoint")
    legacyDefaults.set("openclaw/org2", forKey: "Org2Workspace.openClawAgent")
    legacyDefaults.set("OpenClaw", forKey: "Org2Workspace.agentHandoffAssignee")
    legacyDefaults.set("Avi", forKey: "Org2Workspace.personalAssigneeNames")
    legacyDefaults.set("~/avi.org2", forKey: "Org2Workspace.openClawRemoteCorpusPath")

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: currentDefaults,
      legacyDefaultsDomains: [legacySuiteName]
    )

    XCTAssertEqual(store.openClawEndpointText, "https://example.invalid/v1/chat/completions")
    XCTAssertEqual(store.openClawAgentID, "openclaw/org2")
    XCTAssertEqual(store.agentHandoffAssignee, "OpenClaw")
    XCTAssertEqual(store.personalAssigneeNamesText, "Avi")
    XCTAssertEqual(store.openClawRemoteCorpusPath, "~/avi.org2")
    XCTAssertTrue(currentDefaults.bool(forKey: "Org2Workspace.legacyDefaultsMigrated.v1"))
  }

  func testLegacyDefaultsMigrationRunsOnlyForProductionBundleByDefault() {
    XCTAssertTrue(WorkspaceStore.shouldMigrateLegacyDefaults(bundleIdentifier: nil))
    XCTAssertTrue(WorkspaceStore.shouldMigrateLegacyDefaults(bundleIdentifier: "org.org2.workspace"))
    XCTAssertFalse(WorkspaceStore.shouldMigrateLegacyDefaults(bundleIdentifier: "org.org2.workspace.codex"))
  }

  @MainActor
  func testLegacyDefaultsMigrationDoesNotOverwriteCurrentOpenClawConfiguration() throws {
    let currentSuiteName = "org2-workspace-current-defaults-\(UUID().uuidString)"
    let legacySuiteName = "org2-workspace-old-defaults-\(UUID().uuidString)"
    let currentDefaults = UserDefaults(suiteName: currentSuiteName)!
    let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
    defer {
      currentDefaults.removePersistentDomain(forName: currentSuiteName)
      legacyDefaults.removePersistentDomain(forName: legacySuiteName)
    }

    currentDefaults.set("https://current.example.invalid/v1/chat/completions", forKey: "Org2Workspace.openClawEndpoint")
    currentDefaults.set("current-agent", forKey: "Org2Workspace.openClawAgent")
    currentDefaults.set("/current/org2", forKey: "Org2Workspace.openClawRemoteCorpusPath")
    legacyDefaults.set("https://legacy.example.invalid/v1/chat/completions", forKey: "Org2Workspace.openClawEndpoint")
    legacyDefaults.set("legacy-agent", forKey: "Org2Workspace.openClawAgent")
    legacyDefaults.set("/legacy/org2", forKey: "Org2Workspace.openClawRemoteCorpusPath")

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: currentDefaults,
      legacyDefaultsDomains: [legacySuiteName]
    )

    XCTAssertEqual(store.openClawEndpointText, "https://current.example.invalid/v1/chat/completions")
    XCTAssertEqual(store.openClawAgentID, "current-agent")
    XCTAssertEqual(store.openClawRemoteCorpusPath, "/current/org2")
  }

  @MainActor
  func testOrgCryptConfigurationPersistsRecipientFilesAsDefaults() throws {
    let suiteName = "org2-workspace-crypt-config-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    XCTAssertTrue(store.saveOrgCryptConfiguration(
      encryptOnSave: true,
      recipientsText: "person@example.com",
      recipientFilesText: "/tmp/team.asc\nkeys/project.asc",
      useDefaultGpgKey: true,
      gpgProgram: "gpg",
      passphrase: "",
      clearPassphrase: false
    ))

    let restored = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertEqual(restored.orgCryptRecipientsText, "person@example.com")
    XCTAssertEqual(restored.orgCryptRecipientFilesText, "/tmp/team.asc\nkeys/project.asc")
    XCTAssertTrue(restored.orgCryptUseDefaultGpgKey)
  }

  @MainActor
  func testOrgCryptImportsAgentPublicKeysIntoCorpusPublicKeys() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-public-keys-\(UUID().uuidString)", isDirectory: true)
    let sourceDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-public-key-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let source = sourceDirectory.appendingPathComponent("clavi.asc")
    try "PUBLIC KEY".write(to: source, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)

    let imported = try store.importOrgCryptAgentPublicKey(from: source)

    XCTAssertEqual(imported.relativePath, "public-keys/clavi.asc")
    XCTAssertEqual(imported.name, "clavi.asc")
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: imported.path), encoding: .utf8), "PUBLIC KEY")
    XCTAssertEqual(store.orgCryptManagedRecipientFiles, [imported])
    XCTAssertTrue(store.orgCryptStatusText.contains("Added clavi.asc"))
  }

  @MainActor
  func testOrgCryptManagedRecipientFilesSplitAndPersistWithManualFiles() throws {
    let suiteName = "org2-workspace-crypt-managed-config-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-managed-public-keys-\(UUID().uuidString)", isDirectory: true)
    let publicKeys = root.appendingPathComponent("public-keys", isDirectory: true)
    try FileManager.default.createDirectory(at: publicKeys, withIntermediateDirectories: true)
    let clavi = publicKeys.appendingPathComponent("clavi.asc")
    let helper = publicKeys.appendingPathComponent("helper.asc")
    try "CLAVI".write(to: clavi, atomically: true, encoding: .utf8)
    try "HELPER".write(to: helper, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.setCorpusRoot(root)

    XCTAssertEqual(store.orgCryptManagedRecipientFiles.map(\.relativePath), [
      "public-keys/clavi.asc",
      "public-keys/helper.asc"
    ])

    let savedRecipientFiles = "\(clavi.path)\n/tmp/team.asc\npublic-keys/helper.asc"
    XCTAssertEqual(store.selectedManagedOrgCryptRecipientFilePaths(in: savedRecipientFiles), Set([clavi.path, helper.path]))
    XCTAssertEqual(store.manualOrgCryptRecipientFilesText(from: savedRecipientFiles), "/tmp/team.asc")

    let combined = store.combinedOrgCryptRecipientFilesText(
      manualText: "/tmp/team.asc",
      selectedManagedPaths: Set([helper.path])
    )
    XCTAssertEqual(combined, "/tmp/team.asc\n\(helper.path)")
    XCTAssertTrue(store.saveOrgCryptConfiguration(
      encryptOnSave: true,
      recipientsText: "",
      recipientFilesText: combined,
      useDefaultGpgKey: true,
      gpgProgram: "gpg",
      passphrase: "",
      clearPassphrase: false
    ))

    let restored = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    XCTAssertEqual(restored.orgCryptRecipientFilesText, "/tmp/team.asc\n\(helper.path)")
  }

  @MainActor
  func testOrgCryptConfigurationDefaultsToIncludingDefaultGPGKey() throws {
    let suiteName = "org2-workspace-crypt-config-default-key-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertTrue(store.orgCryptUseDefaultGpgKey)
  }

  @MainActor
  func testOrgCryptConfigurationMigratesOldDefaultGPGKeySettingOn() throws {
    let suiteName = "org2-workspace-crypt-config-migrate-key-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "Org2Workspace.orgCrypt.useDefaultGpgKey")

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertTrue(store.orgCryptUseDefaultGpgKey)
    XCTAssertTrue(defaults.bool(forKey: "Org2Workspace.orgCrypt.useDefaultGpgKey"))
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

  func testMeetingArtifactWriterCreatesNoteAndTranscript() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-meeting-artifacts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recordedAt = ISO8601DateFormatter().date(from: "2026-06-11T21:00:00Z")!
    let paths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Scarf reporting sync",
      recordedAt: recordedAt
    )
    try Data("fake audio".utf8).write(to: paths.audioURL)
    try Data("fake system audio".utf8).write(to: paths.systemAudioURL)

    let bundle = try MeetingArtifactWriter.writeArtifacts(
      paths: paths,
      corpusRoot: root,
      duration: 12.5,
      transcript: MeetingTranscriptResult(
        text: "We decided to publish the reporting update.",
        status: .complete,
        engine: "whisper.cpp"
      ),
      systemAudioURL: paths.systemAudioURL
    )

    let note = try String(contentsOf: bundle.noteURL, encoding: .utf8)
    let transcript = try String(contentsOf: bundle.transcriptURL, encoding: .utf8)

    XCTAssertTrue(note.contains("* Meeting: Scarf reporting sync"))
    XCTAssertTrue(note.contains(":kind: meeting"))
    XCTAssertTrue(note.contains(":audio_artifact: meetings/"))
    XCTAssertTrue(note.contains(":system_audio_artifact: meetings/"))
    XCTAssertTrue(note.contains(":transcript_artifact: meetings/"))
    XCTAssertTrue(note.contains(":capture_sources: microphone, system_audio"))
    XCTAssertTrue(note.contains(":transcription_engine: whisper.cpp"))
    XCTAssertTrue(note.contains("** Decisions"))
    XCTAssertTrue(transcript.contains("* Transcript: Scarf reporting sync"))
    XCTAssertTrue(transcript.contains(":kind: meeting_transcript"))
    XCTAssertTrue(transcript.contains(":system_audio_artifact: meetings/"))
    XCTAssertTrue(transcript.contains("We decided to publish the reporting update."))
  }

  func testMeetingRecorderMeterNormalizesAudioPower() {
    XCTAssertEqual(MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: -80), 0)
    XCTAssertEqual(MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: 0), 1)
    XCTAssertEqual(MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: 20), 1)
    XCTAssertEqual(
      MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: -30),
      0.5,
      accuracy: 0.001
    )
  }

  func testMeetingMeterPublishingSkipsSmallLevelChanges() {
    XCTAssertFalse(WorkspaceStore.shouldPublishMeetingMeterLevelChange(current: 0.50, next: 0.51))
    XCTAssertTrue(WorkspaceStore.shouldPublishMeetingMeterLevelChange(current: 0.50, next: 0.54))
    XCTAssertTrue(WorkspaceStore.shouldPublishMeetingMeterLevelChange(current: 0, next: 0.01))
    XCTAssertTrue(WorkspaceStore.shouldPublishMeetingMeterLevelChange(current: 0.94, next: 0.96))
  }

  func testMeetingCaptureSourceDisclosesSystemAudioPermission() {
    let source = WorkspaceStore.meetingCaptureSourceSummary.lowercased()
    XCTAssertTrue(source.contains("microphone"))
    XCTAssertTrue(source.contains("system"))
    XCTAssertTrue(source.contains("screencapturekit"))
    XCTAssertTrue(source.contains("audio only"))
  }

  func testLocalWhisperInstallationStatusDetectsFastPath() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-whisper-status-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let model = root.appendingPathComponent("ggml-base.en.bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try "#!/bin/sh\nexit 0\n".write(to: bin.appendingPathComponent("whisper-cli"), atomically: true, encoding: .utf8)
    try Data("fake model".utf8).write(to: model)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("whisper-cli").path)

    let status = LocalWhisperTranscriber.installationStatus(configuration: LocalWhisperConfiguration(environment: [
      "PATH": bin.path,
      "ORG2_WORKSPACE_WHISPER_MODEL": model.path
    ]))

    XCTAssertTrue(status.isWhisperCppReady)
    XCTAssertEqual(status.backendDescription, "whisper.cpp")
    XCTAssertTrue(status.whisperCppExecutablePath?.hasSuffix("whisper-cli") == true)
    XCTAssertEqual(status.whisperCppModelPath, model.path)
    XCTAssertEqual(status.statusLabel, "Fast local transcription ready")
  }

  func testWhisperCppConvertsM4AAudioToWAVBeforeTranscribing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-whisper-m4a-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let model = root.appendingPathComponent("ggml-base.en.bin")
    let capturedInput = root.appendingPathComponent("captured-input.txt")
    let sourceAudio = root.appendingPathComponent("system-audio.m4a")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("fake model".utf8).write(to: model)
    try writeSilentM4A(to: sourceAudio)

    let whisperCLI = bin.appendingPathComponent("whisper-cli")
    try """
    #!/bin/sh
    input=""
    output=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -f)
          shift
          input="$1"
          ;;
        -of)
          shift
          output="$1"
          ;;
      esac
      shift
    done
    printf "%s" "$input" > '\(capturedInput.path.replacingOccurrences(of: "'", with: "'\\''"))'
    printf "system transcript" > "${output}.txt"
    exit 0
    """.write(to: whisperCLI, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whisperCLI.path)

    let transcriber = LocalWhisperTranscriber(configuration: LocalWhisperConfiguration(environment: [
      "PATH": bin.path,
      "ORG2_WORKSPACE_WHISPER_MODEL": model.path
    ]))
    let result = try await transcriber.transcribe(audioURL: sourceAudio)

    XCTAssertEqual(result.text, "system transcript")
    XCTAssertEqual(result.engine, "whisper.cpp")
    let inputPath = try String(contentsOf: capturedInput, encoding: .utf8)
    XCTAssertTrue(inputPath.hasSuffix(".wav"))
    XCTAssertNotEqual(inputPath, sourceAudio.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: inputPath))
  }

  func testWorkspaceRuntimeIdentityLabelsUnbundledExecutables() {
    let identity = WorkspaceRuntimeIdentity(
      executablePath: "/tmp/Org2Workspace",
      bundlePath: "/tmp/Org2Workspace",
      bundleIdentifier: nil,
      isAppBundle: false
    )

    XCTAssertEqual(identity.audioPermissionStatusLabel, "Debug executable")
    XCTAssertTrue(identity.audioPermissionDetailText.contains("SwiftPM debug executable"))
  }

  func testMeetingTranscriptCombinesMicrophoneAndSystemAudioSections() {
    let transcript = MeetingTranscriptResult.combined(
      microphone: MeetingTranscriptResult(
        text: "I can ship that today.",
        status: .complete,
        engine: "whisper.cpp"
      ),
      systemAudio: MeetingTranscriptResult(
        text: "The customer asked for Friday.",
        status: .complete,
        engine: "whisper.cpp"
      )
    )

    XCTAssertEqual(transcript.status, .complete)
    XCTAssertTrue(transcript.text.contains("** Microphone"))
    XCTAssertTrue(transcript.text.contains("I can ship that today."))
    XCTAssertTrue(transcript.text.contains("** System Audio"))
    XCTAssertTrue(transcript.text.contains("The customer asked for Friday."))
  }

  @MainActor
  func testDeleteMeetingRemovesNoteAndArtifacts() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-meeting-delete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recordedAt = ISO8601DateFormatter().date(from: "2026-06-11T21:00:00Z")!
    let paths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Delete sync",
      recordedAt: recordedAt
    )
    try Data("fake audio".utf8).write(to: paths.audioURL)
    try Data("fake system audio".utf8).write(to: paths.systemAudioURL)
    let bundle = try MeetingArtifactWriter.writeArtifacts(
      paths: paths,
      corpusRoot: root,
      duration: nil,
      transcript: MeetingTranscriptResult(text: "Delete me.", status: .complete, engine: "whisper.cpp"),
      systemAudioURL: paths.systemAudioURL
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshMeetings()
    let meeting = try XCTUnwrap(store.meetings.first)
    store.selectMeeting(meeting)

    await store.deleteMeeting(meeting)

    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.noteURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.audioURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.systemAudioURL?.path ?? ""))
    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.transcriptURL.path))
    XCTAssertTrue(store.meetings.isEmpty)
    XCTAssertNil(store.selectedLocation)
  }

  @MainActor
  func testWorkspaceScansMeetingArtifacts() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-meeting-scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recordedAt = ISO8601DateFormatter().date(from: "2026-06-11T21:00:00Z")!
    let paths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Planning sync",
      recordedAt: recordedAt
    )
    try Data("fake audio".utf8).write(to: paths.audioURL)
    _ = try MeetingArtifactWriter.writeArtifacts(
      paths: paths,
      corpusRoot: root,
      duration: nil,
      transcript: MeetingTranscriptResult(
        text: "Action item: ship the meeting recorder.",
        status: .complete,
        engine: "whisper.cpp"
      )
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshMeetings()

    XCTAssertEqual(store.meetings.count, 1)
    XCTAssertEqual(store.meetings[0].title, "Planning sync")
    XCTAssertEqual(store.meetings[0].transcriptionStatus, "complete")
    XCTAssertTrue(store.meetings[0].audioArtifact?.hasPrefix("meetings/") == true)
    XCTAssertNil(store.meetings[0].systemAudioArtifact)
    XCTAssertTrue(store.meetings[0].transcriptArtifact?.hasSuffix(".transcript.org2") == true)
  }

  func testScansRecoverableMeetingAudioWithoutCompletedNote() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-meeting-recovery-\(UUID().uuidString)", isDirectory: true)
    let meetings = root.appendingPathComponent("meetings", isDirectory: true)
    try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)

    let interruptedAudio = meetings.appendingPathComponent("2026-06-15-093644-alexandria.wav")
    let interruptedSystemAudio = meetings.appendingPathComponent("2026-06-15-093644-alexandria.system.m4a")
    let completedAudio = meetings.appendingPathComponent("2026-06-15-100000-finished.wav")
    let completedNote = meetings.appendingPathComponent("2026-06-15-100000-finished.org2")
    try Data("fake microphone audio".utf8).write(to: interruptedAudio)
    try Data("fake system audio".utf8).write(to: interruptedSystemAudio)
    try Data("fake completed audio".utf8).write(to: completedAudio)
    try "* Meeting: Finished\n".write(to: completedNote, atomically: true, encoding: .utf8)

    let recoverable = try WorkspaceStore.scanRecoverableMeetingRecordings(corpusRoot: root)

    XCTAssertEqual(recoverable.count, 1)
    XCTAssertEqual(recoverable[0].paths.title, "Alexandria")
    XCTAssertEqual(recoverable[0].paths.baseName, "2026-06-15-093644-alexandria")
    XCTAssertEqual(recoverable[0].paths.audioURL.standardizedFileURL, interruptedAudio.standardizedFileURL)
    XCTAssertEqual(recoverable[0].systemAudioURL?.standardizedFileURL, interruptedSystemAudio.standardizedFileURL)
    XCTAssertEqual(recoverable[0].captureSources, "recovered_audio, system_audio")
  }

  @MainActor
  func testRefreshMeetingsClearsStaleTranscribingStateForCompletedArtifact() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-meeting-stale-processing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recordedAt = ISO8601DateFormatter().date(from: "2026-06-11T21:00:00Z")!
    let paths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Company Meeting",
      recordedAt: recordedAt
    )
    try Data("fake audio".utf8).write(to: paths.audioURL)
    _ = try MeetingArtifactWriter.writeArtifacts(
      paths: paths,
      corpusRoot: root,
      duration: nil,
      transcript: MeetingTranscriptResult(
        text: "Transcript is complete.",
        status: .complete,
        engine: "whisper.cpp"
      )
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedSurface = .meetings
    store.isProcessingMeeting = true
    store.meetingStatusText = "Transcribing Company Meeting locally..."

    await store.refreshMeetings()

    XCTAssertFalse(store.isProcessingMeeting)
    XCTAssertFalse(store.meetingStatusText.hasPrefix("Transcribing "))
    XCTAssertEqual(store.meetings.first?.transcriptionStatus, "complete")
  }

  func testOpenClawComposerSizingGrowsAndCaps() {
    let emptyHeight = OpenClawComposerSizing.height(for: "", compact: false)
    let shortHeight = OpenClawComposerSizing.height(for: "hello", compact: false)
    let multilineHeight = OpenClawComposerSizing.height(for: "one\ntwo\nthree\nfour", compact: false)
    let longHeight = OpenClawComposerSizing.height(
      for: String(repeating: "long message line\n", count: 80),
      compact: false
    )
    let compactLongHeight = OpenClawComposerSizing.height(
      for: String(repeating: "long message line\n", count: 80),
      compact: true
    )

    XCTAssertEqual(emptyHeight, shortHeight)
    XCTAssertGreaterThan(multilineHeight, shortHeight)
    XCTAssertEqual(longHeight, 190)
    XCTAssertEqual(compactLongHeight, 150)
  }

  func testOpenClawComposerReturnSendsAndCommandReturnAddsNewline() {
    XCTAssertTrue(OpenClawComposerKeyCommand.isSendCommand(keyCode: 36, modifiers: []))
    XCTAssertTrue(OpenClawComposerKeyCommand.isSendCommand(keyCode: 76, modifiers: []))
    XCTAssertFalse(OpenClawComposerKeyCommand.isSendCommand(keyCode: 36, modifiers: [.command]))
    XCTAssertFalse(OpenClawComposerKeyCommand.isSendCommand(keyCode: 36, modifiers: [.command, .shift]))
    XCTAssertFalse(OpenClawComposerKeyCommand.isSendCommand(keyCode: 49, modifiers: [.command]))

    XCTAssertTrue(OpenClawComposerKeyCommand.isNewlineCommand(keyCode: 36, modifiers: [.command]))
    XCTAssertTrue(OpenClawComposerKeyCommand.isNewlineCommand(keyCode: 76, modifiers: [.command]))
    XCTAssertFalse(OpenClawComposerKeyCommand.isNewlineCommand(keyCode: 36, modifiers: []))
    XCTAssertFalse(OpenClawComposerKeyCommand.isNewlineCommand(keyCode: 36, modifiers: [.command, .shift]))
  }

  func testOpenClawComposerDraftSyncMergesExternalDraftChangesWithoutDroppingLocalTyping() {
    XCTAssertEqual(
      OpenClawComposerDraftSync.localDraftAfterStoreChange(
        localDraft: "old",
        previousStoreDraft: "old",
        nextStoreDraft: "external"
      ),
      "external"
    )
    XCTAssertEqual(
      OpenClawComposerDraftSync.localDraftAfterStoreChange(
        localDraft: "local edit",
        previousStoreDraft: "",
        nextStoreDraft: "Use selected entry as context.\n\n"
      ),
      "Use selected entry as context.\n\nlocal edit"
    )
    XCTAssertEqual(
      OpenClawComposerDraftSync.localDraftAfterStoreChange(
        localDraft: "draft plus local edit",
        previousStoreDraft: "draft",
        nextStoreDraft: "Use selected entry as context.\n\ndraft"
      ),
      "Use selected entry as context.\n\ndraft plus local edit"
    )
    XCTAssertEqual(
      OpenClawComposerDraftSync.localDraftAfterStoreChange(
        localDraft: "local edit",
        previousStoreDraft: "",
        nextStoreDraft: ""
      ),
      ""
    )
  }

  @MainActor
  func testOpenClawComposerDraftCacheDoesNotPublishStoreChangesWhileTyping() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.createOpenClawChatThread()

    var publishedChangeCount = 0
    let cancellable = store.objectWillChange.sink {
      publishedChangeCount += 1
    }

    store.cacheOpenClawComposerDraft("typing into a large chat")
    store.cacheOpenClawComposerDraft("typing into a large chat thread")

    XCTAssertEqual(store.openClawDraft, "")
    XCTAssertEqual(publishedChangeCount, 0)
    cancellable.cancel()
  }

  @MainActor
  func testOpenClawComposerDraftCacheRestoresDraftsAcrossThreadSwitches() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.createOpenClawChatThread()
    let firstThreadID = try XCTUnwrap(store.selectedOpenClawChatThreadID)
    store.cacheOpenClawComposerDraft("first local draft")

    store.createOpenClawChatThread()
    let secondThreadID = try XCTUnwrap(store.selectedOpenClawChatThreadID)
    XCTAssertEqual(store.openClawDraft, "")
    store.cacheOpenClawComposerDraft("second local draft")

    store.selectOpenClawChatThread(firstThreadID)
    XCTAssertEqual(store.openClawDraft, "first local draft")

    store.selectOpenClawChatThread(secondThreadID)
    XCTAssertEqual(store.openClawDraft, "second local draft")
  }

  func testOpenClawVoiceDictationAppendsToDraftBeforeSend() {
    XCTAssertEqual(
      WorkspaceStore.openClawDraftByAppendingDictation(existing: "Existing instruction", dictatedText: "Dictated note"),
      "Existing instruction\n\nDictated note"
    )
    XCTAssertEqual(
      WorkspaceStore.openClawDraftByAppendingDictation(existing: "  ", dictatedText: " Dictated note\n"),
      "Dictated note"
    )
  }

  func testOpenClawVoiceTranscriptionProgressIsEstimatedAndCapped() {
    XCTAssertEqual(WorkspaceStore.estimatedOpenClawVoiceTranscriptionDuration(for: 1), 8)
    XCTAssertEqual(WorkspaceStore.estimatedOpenClawVoiceTranscriptionDuration(for: 20), 80)
    XCTAssertEqual(WorkspaceStore.estimatedOpenClawVoiceTranscriptionDuration(for: 100), 180)

    XCTAssertEqual(
      WorkspaceStore.openClawVoiceTranscriptionProgress(elapsed: 0, estimatedDuration: 10),
      0.02,
      accuracy: 0.001
    )
    XCTAssertEqual(
      WorkspaceStore.openClawVoiceTranscriptionProgress(elapsed: 5, estimatedDuration: 10),
      0.5,
      accuracy: 0.001
    )
    XCTAssertEqual(
      WorkspaceStore.openClawVoiceTranscriptionProgress(elapsed: 20, estimatedDuration: 10),
      0.95,
      accuracy: 0.001
    )
  }

  func testMeetingTranscriptionProgressIsEstimatedAndCapped() {
    XCTAssertEqual(WorkspaceStore.estimatedMeetingTranscriptionDuration(for: nil), 120)
    XCTAssertEqual(WorkspaceStore.estimatedMeetingTranscriptionDuration(for: 10), 30)
    XCTAssertEqual(WorkspaceStore.estimatedMeetingTranscriptionDuration(for: 600), 1_200)
    XCTAssertEqual(WorkspaceStore.estimatedMeetingTranscriptionDuration(for: 4_000), 3_600)

    XCTAssertEqual(
      WorkspaceStore.meetingTranscriptionProgress(elapsed: 0, estimatedDuration: 100),
      0.02,
      accuracy: 0.001
    )
    XCTAssertEqual(
      WorkspaceStore.meetingTranscriptionProgress(elapsed: 50, estimatedDuration: 100),
      0.5,
      accuracy: 0.001
    )
    XCTAssertEqual(
      WorkspaceStore.meetingTranscriptionProgress(elapsed: 500, estimatedDuration: 100),
      0.95,
      accuracy: 0.001
    )
  }

  func testOpenClawVoiceTranscriptionElapsedTextFormatsDuration() {
    XCTAssertEqual(WorkspaceStore.openClawVoiceTranscriptionElapsedText(elapsed: 0.8), "0s")
    XCTAssertEqual(WorkspaceStore.openClawVoiceTranscriptionElapsedText(elapsed: 12.4), "12s")
    XCTAssertEqual(WorkspaceStore.openClawVoiceTranscriptionElapsedText(elapsed: 75.9), "1m 15s")
  }

  func testRenderedSearchHighlightQueryNormalizesSearchText() {
    XCTAssertEqual(WorkspaceStore.normalizedRenderedSearchHighlightQuery("  Alpha  "), "Alpha")
    XCTAssertEqual(WorkspaceStore.normalizedRenderedSearchHighlightQuery("\"exact phrase\""), "exact phrase")
    XCTAssertEqual(WorkspaceStore.normalizedRenderedSearchHighlightQuery("id:abc-123"), "abc-123")
    XCTAssertNil(WorkspaceStore.normalizedRenderedSearchHighlightQuery("   "))

    XCTAssertEqual(WorkspaceStore.countSearchOccurrences(in: "Needle needle NEED", query: "needle"), 2)
    XCTAssertEqual(WorkspaceStore.countSearchOccurrences(in: "aaa", query: "aa"), 1)
    XCTAssertEqual(WorkspaceStore.countSearchOccurrences(in: "anything", query: "  "), 0)
  }

  @MainActor
  func testSelectingSearchResultActivatesAndClearsRenderedHighlight() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let result = try JSONDecoder().decode(SearchResult.self, from: Data("""
    {
      "file": "/tmp/search.org",
      "line": 3,
      "tags": [],
      "snippet": "Body with Needle",
      "heading": "Search hit"
    }
    """.utf8))

    store.searchQuery = "needle"
    store.select(.search(result))

    XCTAssertEqual(store.renderedSearchHighlightQuery, "needle")
    XCTAssertTrue(store.hasRenderedSearchHighlight)

    XCTAssertTrue(store.focusPageSearch())
    XCTAssertTrue(store.isPageSearchPresented)
    XCTAssertEqual(store.pageSearchQuery, "needle")
    store.pageSearchQuery = "other"
    XCTAssertEqual(store.renderedSearchHighlightQuery, "other")
    XCTAssertEqual(store.pageSearchOccurrenceCount, 0)
    XCTAssertNil(store.pageSearchSelectedOccurrenceIndex)

    store.clearRenderedSearchHighlight()
    XCTAssertNil(store.renderedSearchHighlightQuery)
    XCTAssertFalse(store.isPageSearchPresented)
    XCTAssertEqual(store.pageSearchOccurrenceCount, 0)
    XCTAssertNil(store.pageSearchSelectedOccurrenceIndex)

    store.renderedSearchHighlightQuery = "needle"
    store.isPageSearchPresented = true
    store.pageSearchQuery = "needle"
    store.select(.openClaw(OpenClawThread(
      title: "Other",
      file: "/tmp/other.org",
      line: 1,
      zone: "corpus",
      modifiedAt: nil,
      idValue: nil
    )))
    XCTAssertNil(store.renderedSearchHighlightQuery)
    XCTAssertFalse(store.isPageSearchPresented)
    XCTAssertTrue(store.pageSearchQuery.isEmpty)
  }

  @MainActor
  func testPageSearchCountsFullFileAndNavigatesRenderedOccurrences() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("page-search.org2")
    try """
    #+TITLE: Page Search

    * First
    Alpha needle here

    * Second
    Beta Needle again
    Third needle
    """.write(to: note, atomically: true, encoding: .utf8)

    let result = SearchResult(
      file: note.path,
      line: 4,
      lineEnd: nil,
      heading: "First",
      headingLine: 3,
      headingLevel: 1,
      headingAncestry: nil,
      idValue: nil,
      todo: nil,
      tags: [],
      snippet: "Alpha needle here",
      sourceRange: nil,
      matchedLines: nil,
      date: nil
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedSurface = .search
    store.searchQuery = "needle"
    store.select(.search(result))
    store.selectedEntrySourceMode = .page
    await store.reloadSelectedEntrySource()
    try await waitForEntryRender(store)
    try await waitForCondition {
      !store.selectedRenderedBlocks.isEmpty
    }

    XCTAssertTrue(store.focusPageSearch())
    XCTAssertEqual(store.pageSearchQuery, "needle")
    XCTAssertEqual(store.pageSearchOccurrenceCount, 3)
    XCTAssertEqual(store.pageSearchSelectedOccurrenceIndex, 0)
    XCTAssertEqual(store.pageSearchOccurrenceSummary, "1 of 3")
    let firstSelectedBlockID = try XCTUnwrap(store.selectedBlockID)
    let firstScrollRequest = try XCTUnwrap(store.detailScrollRequest)
    XCTAssertEqual(firstScrollRequest.target, .block(firstSelectedBlockID))
    var previousScrollRequestID = firstScrollRequest.id

    store.selectNextPageSearchOccurrence()
    XCTAssertEqual(store.pageSearchSelectedOccurrenceIndex, 1)
    XCTAssertEqual(store.pageSearchOccurrenceSummary, "2 of 3")
    let secondSelectedBlockID = try XCTUnwrap(store.selectedBlockID)
    XCTAssertNotEqual(secondSelectedBlockID, firstSelectedBlockID)
    var scrollRequest = try XCTUnwrap(store.detailScrollRequest)
    XCTAssertGreaterThan(scrollRequest.id, previousScrollRequestID)
    XCTAssertEqual(scrollRequest.target, .block(secondSelectedBlockID))
    previousScrollRequestID = scrollRequest.id

    store.selectNextPageSearchOccurrence()
    XCTAssertEqual(store.pageSearchSelectedOccurrenceIndex, 2)
    XCTAssertEqual(store.pageSearchOccurrenceSummary, "3 of 3")
    XCTAssertEqual(store.selectedBlockID, secondSelectedBlockID)
    scrollRequest = try XCTUnwrap(store.detailScrollRequest)
    XCTAssertGreaterThan(scrollRequest.id, previousScrollRequestID)
    XCTAssertEqual(scrollRequest.target, .block(secondSelectedBlockID))
    previousScrollRequestID = scrollRequest.id

    store.selectNextPageSearchOccurrence()
    XCTAssertEqual(store.pageSearchSelectedOccurrenceIndex, 0)
    XCTAssertEqual(store.selectedBlockID, firstSelectedBlockID)
    scrollRequest = try XCTUnwrap(store.detailScrollRequest)
    XCTAssertGreaterThan(scrollRequest.id, previousScrollRequestID)
    XCTAssertEqual(scrollRequest.target, .block(firstSelectedBlockID))
    previousScrollRequestID = scrollRequest.id

    store.selectPreviousPageSearchOccurrence()
    XCTAssertEqual(store.pageSearchSelectedOccurrenceIndex, 2)
    XCTAssertEqual(store.selectedBlockID, secondSelectedBlockID)
    scrollRequest = try XCTUnwrap(store.detailScrollRequest)
    XCTAssertGreaterThan(scrollRequest.id, previousScrollRequestID)
    XCTAssertEqual(scrollRequest.target, .block(secondSelectedBlockID))

    store.pageSearchQuery = "missing"
    XCTAssertEqual(store.pageSearchOccurrenceCount, 0)
    XCTAssertEqual(store.pageSearchOccurrenceSummary, "0 matches")
    XCTAssertNil(store.pageSearchSelectedOccurrenceIndex)
  }

  @MainActor
  func testOpenClawSendQueueSerializesConsecutiveMessages() async throws {
    let recorder = OpenClawQueuedSendRecorder()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-queue-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      openClawTranscriptURL: transcriptURL,
      openClawSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )

    store.openClawDraft = "first"
    let firstSend = Task { await store.sendOpenClawMessage() }
    try await waitForCondition {
      store.isSendingOpenClawMessage
    }
    store.openClawDraft = "second"
    let secondSend = Task { await store.sendOpenClawMessage() }

    await firstSend.value
    await secondSend.value

    XCTAssertEqual(store.openClawMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:first",
      "assistant:reply 1",
      "user:second",
      "assistant:reply 2"
    ])
    let calls = await recorder.recordedCalls()
    XCTAssertEqual(calls, [
      ["user:first"],
      ["user:first", "assistant:reply 1", "user:second"]
    ])
    XCTAssertFalse(store.isSendingOpenClawMessage)
    XCTAssertEqual(store.openClawQueuedMessageCount, 0)
    XCTAssertEqual(store.openClawStatusText, "OpenClaw replied")
  }

  @MainActor
  func testOpenClawQueuedRepliesNotifyWhenInsertedBeforeLaterUserMessages() async throws {
    let recorder = OpenClawQueuedSendRecorder()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-queue-unread-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      openClawTranscriptURL: transcriptURL,
      openClawSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    var soundCount = 0
    store.openClawIncomingMessageSoundPlayer = {
      soundCount += 1
    }
    store.selectedSurface = .agenda

    store.openClawDraft = "first"
    let firstSend = Task { await store.sendOpenClawMessage() }
    try await waitForCondition {
      store.isSendingOpenClawMessage
    }
    let threadID = try XCTUnwrap(store.selectedOpenClawChatThreadID)

    store.openClawDraft = "second"
    let secondSend = Task { await store.sendOpenClawMessage() }

    await firstSend.value
    await secondSend.value

    XCTAssertEqual(store.openClawMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:first",
      "assistant:reply 1",
      "user:second",
      "assistant:reply 2"
    ])
    XCTAssertEqual(store.openClawChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 2)
    XCTAssertEqual(store.openClawUnreadMessageCount, 2)
    XCTAssertEqual(soundCount, 2)
  }

  @MainActor
  func testOpenClawCanSendInAnotherThreadWhileCurrentThreadIsProcessing() async throws {
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-parallel-threads-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      openClawTranscriptURL: transcriptURL,
      openClawSendHandler: { messages, _, _, _ in
        try await Task.sleep(nanoseconds: 200_000_000)
        return "reply to \(messages.last?.content ?? "")"
      }
    )

    store.openClawDraft = "first"
    let firstSend = Task { await store.sendOpenClawMessage() }
    try await waitForCondition {
      store.isSendingOpenClawMessage
    }
    let firstThreadID = try XCTUnwrap(store.selectedOpenClawChatThreadID)
    XCTAssertEqual(store.openClawSendingThreadIDs, [firstThreadID])

    store.createOpenClawChatThread()

    let secondThreadID = try XCTUnwrap(store.selectedOpenClawChatThreadID)
    XCTAssertNotEqual(firstThreadID, secondThreadID)
    XCTAssertFalse(store.isSendingOpenClawMessage)
    XCTAssertEqual(store.openClawSendingThreadIDs, [firstThreadID])

    store.openClawDraft = "second"
    let secondSend = Task { await store.sendOpenClawMessage() }
    try await waitForCondition {
      store.isSendingOpenClawMessage
    }
    XCTAssertTrue(store.openClawSendingThreadIDs.contains(secondThreadID))

    await firstSend.value
    await secondSend.value

    store.selectOpenClawChatThread(firstThreadID)
    XCTAssertEqual(store.openClawMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:first",
      "assistant:reply to first"
    ])

    store.selectOpenClawChatThread(secondThreadID)
    XCTAssertEqual(store.openClawMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:second",
      "assistant:reply to second"
    ])
    XCTAssertFalse(store.isSendingOpenClawMessage)
    XCTAssertEqual(store.openClawQueuedMessageCount, 0)
    XCTAssertTrue(store.openClawSendingThreadIDs.isEmpty)
  }

  @MainActor
  func testOpenClawChatScrollPositionPersistsAndResets() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))

    XCTAssertNil(store.openClawChatScrollPosition)

    store.recordOpenClawChatScrollPosition(0.42)
    XCTAssertEqual(try XCTUnwrap(store.openClawChatScrollPosition), 0.42, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(store.openClawChatScrollPosition(isAssistantPanel: false)), 0.42, accuracy: 0.001)

    store.recordOpenClawChatScrollPosition(2)
    XCTAssertEqual(try XCTUnwrap(store.openClawChatScrollPosition), 1, accuracy: 0.001)

    store.recordOpenClawChatScrollPosition(0.25, isAssistantPanel: true)
    XCTAssertEqual(try XCTUnwrap(store.openClawAssistantChatScrollPosition), 0.25, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(store.openClawChatScrollPosition(isAssistantPanel: true)), 0.25, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(store.openClawChatScrollPosition), 1, accuracy: 0.001)

    store.resetOpenClawChat()
    XCTAssertNil(store.openClawChatScrollPosition)
    XCTAssertNil(store.openClawAssistantChatScrollPosition)
  }

  @MainActor
  func testAskOpenClawAboutCurrentEntryInjectsMappedReference() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-ai-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("daily.org2")
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.selectedEntrySource = EntrySource(
      file: file.path,
      startLine: 7,
      endLineExclusive: 11,
      text: "* Test\nbody",
      isSubtree: true
    )
    store.openClawDraft = "What should I do next?"

    store.askOpenClawAboutCurrentSelection()

    XCTAssertEqual(store.selectedSurface, .openClaw)
    XCTAssertFalse(store.isOpenClawAssistantPresented)
    XCTAssertEqual(
      store.openClawDraft,
      "Use selected entry at /remote/org2/daily.org2:7 as context.\n\nWhat should I do next?"
    )
    XCTAssertEqual(store.openClawStatusText, "Added daily.org2:7 to OpenClaw")

    store.askOpenClawAboutCurrentSelection()
    XCTAssertEqual(
      store.openClawDraft,
      "Use selected entry at /remote/org2/daily.org2:7 as context.\n\nWhat should I do next?"
    )

    store.performUndoCommand()
    XCTAssertEqual(store.openClawDraft, "What should I do next?")
    XCTAssertEqual(store.openClawStatusText, "Undid OpenClaw draft change")

    store.performRedoCommand()
    XCTAssertEqual(
      store.openClawDraft,
      "Use selected entry at /remote/org2/daily.org2:7 as context.\n\nWhat should I do next?"
    )
    XCTAssertEqual(store.openClawStatusText, "Redid OpenClaw draft change")
  }

  @MainActor
  func testAskOpenClawAboutCurrentSelectionPrefersSelectedRenderedBlock() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-ai-block-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("project.org2")
    let source = EntrySource(
      file: file.path,
      startLine: 12,
      endLineExclusive: 16,
      text: """
      * Project
      First paragraph
      Second paragraph
      """,
      isSubtree: true
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.selectedEntrySource = source
    store.selectedRenderedBlocks = OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine)
    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first { block in
      if case .paragraph = block.rendered {
        return block.rawText.contains("First paragraph")
      }
      return false
    })
    store.selectBlock(paragraph)

    store.askOpenClawAboutCurrentSelection()

    XCTAssertEqual(store.selectedSurface, .openClaw)
    XCTAssertEqual(store.selectedBlockID, paragraph.id)
    XCTAssertEqual(
      store.openClawDraft,
      "Use selected block at /remote/org2/project.org2:13-14 as context.\n\n"
    )
    XCTAssertEqual(store.openClawStatusText, "Added project.org2:13-14 to OpenClaw")
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

  func testOrgInlineParserResolvesRoamIDAndWikiLinks() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-roam-links-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let alpha = root.appendingPathComponent("alpha.org2")
    let beta = root.appendingPathComponent("beta.org2")
    try """
    #+TITLE: Alpha Node
    #+ROAM_ALIASES: "A Node"
    :PROPERTIES:
    :ID: alpha-123
    :END:

    * Beta Heading
    :PROPERTIES:
    :ID: beta-456
    :END:
    """.write(to: alpha, atomically: true, encoding: .utf8)
    try """
    #+TITLE: Duplicate
    :PROPERTIES:
    :ID: duplicate-1
    :END:
    """.write(to: beta, atomically: true, encoding: .utf8)

    let resolver = WorkspaceStore.buildOrgRoamLinkResolver(files: [
      CorpusFile(path: alpha.path, relativePath: "alpha.org2", modifiedAt: nil, byteCount: nil),
      CorpusFile(path: beta.path, relativePath: "beta.org2", modifiedAt: nil, byteCount: nil)
    ])

    XCTAssertEqual(
      OrgInlineParser.parse("See [[id:beta-456][Beta]] and [[A Node]].", linkResolver: resolver),
      [
        .text("See "),
        .link(
          label: "Beta",
          target: "id:beta-456",
          fileReference: OpenClawFileReference(path: alpha.path, line: 7)
        ),
        .text(" and "),
        .link(
          label: "A Node",
          target: "A Node",
          fileReference: OpenClawFileReference(path: alpha.path, line: 1)
        ),
        .text(".")
      ]
    )

    XCTAssertEqual(
      OrgInlineParser.parse("See [[id:alpha-123]].", linkResolver: resolver),
      [
        .text("See "),
        .link(
          label: "Alpha Node",
          target: "id:alpha-123",
          fileReference: OpenClawFileReference(path: alpha.path, line: 1)
        ),
        .text(".")
      ]
    )
  }

  func testOrgInlineParserResolvesWikiLinksToFileStemNodes() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-roam-file-stem-links-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sarah = root.appendingPathComponent("Sarah.org")
    try "Notes about Sarah\n".write(to: sarah, atomically: true, encoding: .utf8)

    let resolver = WorkspaceStore.buildOrgRoamLinkResolver(files: [
      CorpusFile(path: sarah.path, relativePath: "Sarah.org", modifiedAt: nil, byteCount: nil)
    ])

    XCTAssertEqual(
      OrgInlineParser.parse("Talk to [[Sarah]].", linkResolver: resolver),
      [
        .text("Talk to "),
        .link(
          label: "Sarah",
          target: "Sarah",
          fileReference: OpenClawFileReference(path: sarah.path, line: 1)
        ),
        .text(".")
      ]
    )
  }

  func testOrgInlineRenderedTextLinkMapUsesRenderedLabelsForHitRanges() throws {
    let node = OrgRoamNodeReference(
      idValue: "alpha-123",
      title: "Alpha Node",
      file: "/tmp/alpha.org2",
      line: 7
    )
    let resolver = OrgRoamLinkResolver(nodes: [node])
    let map = OrgInlineRenderedTextLinkMap.make(
      raw: "See [[id:alpha-123]] and https://example.com/docs.",
      linkResolver: resolver
    )

    XCTAssertEqual(map.displayText, "See Alpha Node and https://example.com/docs.")
    XCTAssertEqual(map.links.map(\.label), ["Alpha Node", "https://example.com/docs"])
    XCTAssertEqual(map.links.map(\.displayRange), [
      NSRange(location: 4, length: 10),
      NSRange(location: 19, length: 24)
    ])

    let firstURL = try XCTUnwrap(map.link(atDisplayUTF16Location: 4)?.url)
    let firstReference = try XCTUnwrap(OpenClawFileReference.fromDeepLinkURL(firstURL))
    XCTAssertEqual(firstReference, OpenClawFileReference(path: "/tmp/alpha.org2", line: 7))
    XCTAssertEqual(map.link(atDisplayUTF16Location: 13)?.url, firstURL)
    XCTAssertNil(map.link(atDisplayUTF16Location: 3))
    XCTAssertNil(map.link(atDisplayUTF16Location: 43))
    XCTAssertEqual(map.link(atDisplayUTF16Location: 19)?.url, URL(string: "https://example.com/docs"))
  }

  func testOrgRoamLinkResolverDoesNotGuessAmbiguousWikiLinks() {
    let resolver = OrgRoamLinkResolver(nodes: [
      OrgRoamNodeReference(idValue: "one", title: "Shared", file: "/tmp/one.org2", line: 1),
      OrgRoamNodeReference(idValue: "two", title: "Shared", file: "/tmp/two.org2", line: 1)
    ])

    XCTAssertNil(resolver.resolve(target: "Shared"))
    XCTAssertEqual(
      resolver.resolve(target: "id:one"),
      OrgRoamResolvedLink(
        title: "Shared",
        fileReference: OpenClawFileReference(path: "/tmp/one.org2", line: 1)
      )
    )
  }

  func testOrgRoamLinkResolverAllowsPunctuationInWikiTitles() {
    let resolver = OrgRoamLinkResolver(nodes: [
      OrgRoamNodeReference(idValue: "punctuation", title: "Project: Alpha/Beta", file: "/tmp/project.org2", line: 12)
    ])

    XCTAssertEqual(
      resolver.resolve(target: "Project: Alpha/Beta"),
      OrgRoamResolvedLink(
        title: "Project: Alpha/Beta",
        fileReference: OpenClawFileReference(path: "/tmp/project.org2", line: 12)
      )
    )
  }

  func testOrgRoamLinkResolverRanksPagesBeforeEntryNodes() {
    let page = OrgRoamNodeReference(
      idValue: nil,
      title: "Sarah",
      file: "/tmp/Sarah.org",
      line: 1,
      isPageNode: true
    )
    let olderEntry = OrgRoamNodeReference(
      idValue: "older-sarah",
      title: "Sarah",
      file: "/tmp/2023-08-31.org",
      line: 12
    )
    let personalEntry = OrgRoamNodeReference(
      idValue: "personal-sarah",
      title: "Sarah",
      file: "/tmp/personal.org",
      line: 44
    )

    let resolver = OrgRoamLinkResolver(nodes: [olderEntry, personalEntry, page])

    XCTAssertEqual(resolver.searchCandidates(matching: "sarah", limit: 3).first, page)
    XCTAssertEqual(resolver.exactCandidates(for: "Sarah").first, page)
  }

  func testParagraphWikiLinkCompletionReplacesPartialLinkWithStableNodeLink() {
    let text = "Talk to [[Sar"
    let match = ParagraphWikiLinkCompletion.match(
      in: text,
      selectedRange: NSRange(location: (text as NSString).length, length: 0)
    )
    let node = OrgRoamNodeReference(
      idValue: "sarah-123",
      title: "Sarah",
      file: "/tmp/Sarah.org",
      line: 1
    )

    let edit = match.flatMap {
      ParagraphWikiLinkCompletion.replacement(in: text, match: $0, node: node)
    }

    XCTAssertEqual(edit?.text, "Talk to [[id:sarah-123][Sarah]]")
    XCTAssertEqual(edit?.selectedRange.location, ("Talk to [[id:sarah-123][Sarah]]" as NSString).length)
    XCTAssertEqual(edit?.selectedRange.length, 0)
  }

  func testParagraphWikiLinkCompletionPreservesTrailingHeadingText() {
    let text = "Wallet rec from [[sarah : Secrid"
    let match = ParagraphWikiLinkCompletion.match(
      in: text,
      selectedRange: NSRange(location: (text as NSString).length, length: 0)
    )
    let node = OrgRoamNodeReference(
      idValue: "sarah-123",
      title: "Sarah",
      file: "/tmp/Sarah.org",
      line: 1
    )

    let edit = match.flatMap {
      ParagraphWikiLinkCompletion.replacement(in: text, match: $0, node: node)
    }

    XCTAssertEqual(match?.query, "sarah")
    XCTAssertEqual(edit?.text, "Wallet rec from [[id:sarah-123][Sarah]] : Secrid")
    XCTAssertEqual(edit?.selectedRange.location, ("Wallet rec from [[id:sarah-123][Sarah]]" as NSString).length)
    XCTAssertEqual(edit?.selectedRange.length, 0)
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

  func testOrgInlineAttributedStringHighlightsSearchMatches() throws {
    let raw = "First Alpha, second alpha."
    let highlighted = OrgInlineAttributedString.highlightingSearchMatches(
      in: OrgInlineAttributedString.plain(raw, baseFont: .body),
      query: "alpha"
    )
    let display = String(highlighted.characters)
    let firstRange = try XCTUnwrap(display.range(of: "Alpha"))
    let secondRange = try XCTUnwrap(display.range(of: "alpha", options: [], range: firstRange.upperBound..<display.endIndex))
    let firstLower = try XCTUnwrap(AttributedString.Index(firstRange.lowerBound, within: highlighted))
    let firstUpper = try XCTUnwrap(AttributedString.Index(display.index(after: firstRange.lowerBound), within: highlighted))
    let secondLower = try XCTUnwrap(AttributedString.Index(secondRange.lowerBound, within: highlighted))
    let secondUpper = try XCTUnwrap(AttributedString.Index(display.index(after: secondRange.lowerBound), within: highlighted))

    XCTAssertNotNil(highlighted[firstLower..<firstUpper].backgroundColor)
    XCTAssertNotNil(highlighted[secondLower..<secondUpper].backgroundColor)
  }

  func testOrgInlineAttributedStringHighlightsRenderedLinkLabels() throws {
    let raw = "See [Important Node](https://example.com)."
    let attributed = OrgInlineAttributedString.make(OrgInlineParser.parse(raw), baseFont: .body)
    let highlighted = OrgInlineAttributedString.highlightingSearchMatches(in: attributed, query: "important")
    let display = String(highlighted.characters)
    let range = try XCTUnwrap(display.range(of: "Important"))
    let lower = try XCTUnwrap(AttributedString.Index(range.lowerBound, within: highlighted))
    let upper = try XCTUnwrap(AttributedString.Index(display.index(after: range.lowerBound), within: highlighted))

    XCTAssertNotNil(highlighted[lower..<upper].backgroundColor)
    XCTAssertEqual(highlighted[lower..<upper].link, URL(string: "https://example.com"))
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
    assertToken(.headingTitle, "Review [[id:11111111-1111-4111-8111-111111111111][Alice]]", in: raw, tokens: tokens)
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
    let bracketFont = try XCTUnwrap(storage.attribute(.font, at: bracketIndex, effectiveRange: nil) as? NSFont)
    let tickFont = try XCTUnwrap(storage.attribute(.font, at: tickIndex, effectiveRange: nil) as? NSFont)
    XCTAssertLessThan(bracketFont.pointSize, 1)
    XCTAssertLessThan(tickFont.pointSize, 1)

    let labelColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: linkLabelIndex, effectiveRange: nil) as? NSColor)
    XCTAssertEqual(labelColor, NSColor.controlAccentColor)
    let labelUnderline = storage.attribute(.underlineStyle, at: linkLabelIndex, effectiveRange: nil) as? Int
    XCTAssertEqual(labelUnderline, NSUnderlineStyle.single.rawValue)

    let orgTargetColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: orgTargetIndex, effectiveRange: nil) as? NSColor)
    let markdownTargetColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: markdownTargetIndex, effectiveRange: nil) as? NSColor)
    XCTAssertLessThan(orgTargetColor.alphaComponent, 0.24)
    XCTAssertLessThan(markdownTargetColor.alphaComponent, 0.24)
    let orgTargetFont = try XCTUnwrap(storage.attribute(.font, at: orgTargetIndex, effectiveRange: nil) as? NSFont)
    let markdownTargetFont = try XCTUnwrap(storage.attribute(.font, at: markdownTargetIndex, effectiveRange: nil) as? NSFont)
    XCTAssertLessThan(orgTargetFont.pointSize, 1)
    XCTAssertLessThan(markdownTargetFont.pointSize, 1)
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
  func testSyntaxEditorOnlyOffersBoundaryDeleteAtDocumentRowStart() {
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldOfferDeleteBackwardCommand(
      selectedRange: NSRange(location: 0, length: 0)
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldOfferDeleteBackwardCommand(
      selectedRange: NSRange(location: 1, length: 0)
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldOfferDeleteBackwardCommand(
      selectedRange: NSRange(location: 0, length: 1)
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

    try await waitForCondition {
      boundText == "new" && !coordinator.hasPendingTextPublishing(for: "new")
    }
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

    try await waitForCondition {
      boundText == "second" && !coordinator.hasPendingTextPublishing(for: "second")
    }
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
    XCTAssertEqual(
      InlineEditorSizing.stickyCappedLineCount(
        in: "one",
        reservedLineCount: 8,
        minimum: 1,
        maximum: 15
      ),
      8
    )
    XCTAssertEqual(
      InlineEditorSizing.stickyCappedLineCount(
        in: "one\ntwo\nthree",
        reservedLineCount: 1,
        minimum: 1,
        maximum: 15
      ),
      3
    )
    XCTAssertEqual(
      InlineEditorSizing.stickyCappedLineCount(
        in: (1...1_000).map { "line \($0)" }.joined(separator: "\n"),
        reservedLineCount: 3,
        minimum: 1,
        maximum: 15
      ),
      15
    )
    XCTAssertEqual(
      InlineEditorSizing.expandedReservedLineCount(
        in: "one",
        reservedLineCount: 8,
        minimum: 1,
        maximum: 15
      ),
      8
    )
    XCTAssertEqual(
      InlineEditorSizing.expandedReservedLineCount(
        in: "one\ntwo\nthree",
        reservedLineCount: 1,
        minimum: 1,
        maximum: 15
      ),
      3
    )
    XCTAssertEqual(
      InlineEditorSizing.expandedReservedLineCount(
        in: (1...1_000).map { "line \($0)" }.joined(separator: "\n"),
        reservedLineCount: 3,
        minimum: 1,
        maximum: 15
      ),
      15
    )

    let longLine = "extension importer; CRM sync progress; backlink plan model upgrade evaluation"
    let narrowHeight = InlineEditorSizing.wrappedTextEditorHeight(
      in: longLine,
      width: 160,
      minimumLineCount: 1
    )
    let wideHeight = InlineEditorSizing.wrappedTextEditorHeight(
      in: longLine,
      width: 900,
      minimumLineCount: 1
    )
    XCTAssertGreaterThan(narrowHeight, wideHeight)
    XCTAssertGreaterThanOrEqual(
      InlineEditorSizing.wrappedTextEditorHeight(in: "", width: 160, minimumLineCount: 2),
      47
    )
  }

  func testInlineEditorChromeKeepsStableHiddenControls() {
    XCTAssertTrue(InlineEditorChrome.rendersControls(true))
    XCTAssertTrue(InlineEditorChrome.rendersControls(false))
    XCTAssertTrue(InlineEditorChrome.rendersSavingIndicator(true))
    XCTAssertTrue(InlineEditorChrome.rendersSavingIndicator(false))
    XCTAssertEqual(InlineEditorChrome.controlsOpacity(true), 1)
    XCTAssertEqual(InlineEditorChrome.controlsOpacity(false), 0)
    XCTAssertTrue(InlineEditorChrome.allowsHitTesting(true))
    XCTAssertFalse(InlineEditorChrome.allowsHitTesting(false))
    XCTAssertEqual(InlineEditorChrome.accessoryOpacity(true), 1)
    XCTAssertEqual(InlineEditorChrome.accessoryOpacity(false), 0)
    XCTAssertEqual(InlineEditorChrome.savingIndicatorSize, 14)
    XCTAssertEqual(InlineEditorChrome.savingIndicatorOpacity(true), 1)
    XCTAssertEqual(InlineEditorChrome.savingIndicatorOpacity(false), 0)
    XCTAssertEqual(InlineEditorChrome.controlsReserveWidth, RenderedRowChrome.controlsReserveWidth)
    XCTAssertEqual(InlineEditorChrome.controlsTrailingPadding(), RenderedRowChrome.controlsReserveWidth)
    XCTAssertEqual(
      InlineEditorChrome.controlsTrailingPadding(isPersistent: false),
      InlineEditorChrome.compactControlsReserveWidth
    )
  }

  func testParagraphFocusedInlineEditorSkipsPlainText() {
    XCTAssertFalse(ParagraphFocusedInlineEditor.shouldRender(
      text: "Plain paragraph without editable inline syntax",
      selectedRange: NSRange(location: 6, length: 0),
      showsInlineDetails: false
    ))
    XCTAssertFalse(ParagraphFocusedInlineEditor.shouldRender(
      text: "Review [[id:abc][Alice]]",
      selectedRange: NSRange(location: 15, length: 0),
      showsInlineDetails: true
    ))
    XCTAssertTrue(ParagraphFocusedInlineEditor.shouldRender(
      text: "Review [[id:abc][Alice]]",
      selectedRange: NSRange(location: 15, length: 0),
      showsInlineDetails: false
    ))
    XCTAssertTrue(ParagraphFocusedInlineEditor.shouldRender(
      text: "Meet on <2026-06-13 Sat>",
      selectedRange: NSRange(location: 12, length: 0),
      showsInlineDetails: false
    ))

    let linkedPrefix = "See [[id:abc][Alice]]. " + String(repeating: "plain text ", count: 160)
    let farPlainRange = NSRange(location: (linkedPrefix as NSString).length, length: 0)
    XCTAssertFalse(ParagraphFocusedInlineEditor.shouldRender(
      text: linkedPrefix,
      selectedRange: farPlainRange,
      showsInlineDetails: false
    ))

    let longRichParagraph = "See [[id:abc][Alice]]. " + String(
      repeating: "Long paragraph body ",
      count: 900
    )
    XCTAssertGreaterThan((longRichParagraph as NSString).length, OrgEditableInlineToken.focusedScanUTF16Limit)
    XCTAssertFalse(ParagraphFocusedInlineEditor.shouldRender(
      text: longRichParagraph,
      selectedRange: NSRange(location: 6, length: 0),
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

  func testParagraphInlineDetailsAvailabilityMatchesEditableInlineSyntax() {
    XCTAssertFalse(ParagraphInlineDetailsAvailability.hasDetails(in: "Plain paragraph without inline fields."))
    XCTAssertTrue(ParagraphInlineDetailsAvailability.hasDetails(in: "Review [[id:abc][Alice]]."))
    XCTAssertTrue(ParagraphInlineDetailsAvailability.hasDetails(in: "Use `code` here."))
    XCTAssertTrue(ParagraphInlineDetailsAvailability.hasDetails(in: "Meet on <2026-06-13 Sat>."))
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
    XCTAssertEqual(ParagraphFocusedInlinePanelLayout.verticalOffset(editorHeight: 1), 36)
    XCTAssertEqual(ParagraphFocusedInlinePanelLayout.verticalOffset(editorHeight: 80), 106)
  }

  func testParagraphEditorTextPublishingPolicyDefersRichTextDraftPublishing() {
    XCTAssertFalse(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("Plain paragraph text"))
    XCTAssertTrue(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("/todo"))
    XCTAssertFalse(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("See [[id:abc][Alice]]"))
    XCTAssertFalse(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("Meet <2026-06-12 Fri>"))
    XCTAssertFalse(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("Use `code`"))

    let longRichParagraph = "See [[id:abc][Alice]]. " + String(repeating: "Long paragraph body ", count: 180)
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
  func testQuickOpenSelectionMovesThroughFilteredFiles() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusFiles = [
      CorpusFile(path: "/tmp/alpha.org2", relativePath: "alpha.org2", modifiedAt: nil, byteCount: nil),
      CorpusFile(path: "/tmp/beta.org2", relativePath: "beta.org2", modifiedAt: nil, byteCount: nil),
      CorpusFile(path: "/tmp/notes/gamma.org2", relativePath: "notes/gamma.org2", modifiedAt: nil, byteCount: nil)
    ]

    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "alpha.org2")
    XCTAssertNil(store.selectedQuickOpenFileID)

    store.moveQuickOpenSelection(.down)
    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "alpha.org2")

    store.moveQuickOpenSelection(.down)
    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "beta.org2")

    store.moveQuickOpenSelection(.up)
    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "alpha.org2")

    store.resetQuickOpenSelection()
    store.moveQuickOpenSelection(.up)
    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "notes/gamma.org2")

    store.quickOpenQuery = "bet"
    store.resetQuickOpenSelection()
    try await waitForCondition {
      store.quickOpenFiles.map(\.relativePath) == ["beta.org2"]
    }
    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "beta.org2")
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
  func testDetailNavigationBackRestoresPreviousLocation() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-detail-back-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("first.org2")
    let second = root.appendingPathComponent("second.org2")
    try "#+TITLE: First\n".write(to: first, atomically: true, encoding: .utf8)
    try "#+TITLE: Second\n".write(to: second, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    let firstThread = OpenClawThread(title: "First", file: first.path, line: 1, zone: "test", modifiedAt: nil)
    store.select(.openClaw(firstThread))
    XCTAssertFalse(store.canNavigateBackInDetail)

    store.openChatFileReference(OpenClawFileReference(path: second.path, line: 1))

    XCTAssertTrue(store.canNavigateBackInDetail)
    XCTAssertEqual(store.selectedLocation?.file, second.path)

    store.navigateBackInDetail()

    XCTAssertFalse(store.canNavigateBackInDetail)
    XCTAssertEqual(store.selectedLocation?.file, first.path)
  }

  @MainActor
  func testBacklinksResolveSelectedFileLineIdThroughCLI() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-cli-backlinks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("target.org2")
    let source = root.appendingPathComponent("source.org2")
    try """
    #+TITLE: Target

    * Target Heading
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :END:
    Body
    """.write(to: target, atomically: true, encoding: .utf8)
    try """
    #+TITLE: Source
    :PROPERTIES:
    :ID: 22222222-2222-4222-8222-222222222222
    :END:

    Link to [[id:11111111-1111-4111-8111-111111111111][Target Heading]].
    """.write(to: source, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.openChatFileReference(OpenClawFileReference(path: target.path, line: 3))

    try await waitForCondition {
      store.backlinks?.backlinks.count == 1
        && store.selectedLocation?.idValue == "11111111-1111-4111-8111-111111111111"
    }

    XCTAssertEqual(store.backlinks?.backlinks.first?.file, source.path)
  }

  @MainActor
  func testNodeContextGroupsBacklinksAndSendsBriefRequest() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("target.org2")
    let firstSource = root.appendingPathComponent("first.org2")
    let secondSource = root.appendingPathComponent("second.org2")
    let targetID = "11111111-1111-4111-8111-111111111111"
    try """
    #+TITLE: Target Node
    :PROPERTIES:
    :ID: \(targetID)
    :END:

    Canonical target body.
    """.write(to: target, atomically: true, encoding: .utf8)
    try """
    #+TITLE: First Source
    :PROPERTIES:
    :ID: 22222222-2222-4222-8222-222222222222
    :END:

    * First mention
    Link to [[id:\(targetID)][Target Node]].
    * Second mention
    Another [[id:\(targetID)][Target Node]] reference.
    """.write(to: firstSource, atomically: true, encoding: .utf8)
    try """
    #+TITLE: Second Source
    :PROPERTIES:
    :ID: 33333333-3333-4333-8333-333333333333
    :END:

    See [[id:\(targetID)][Target Node]].
    """.write(to: secondSource, atomically: true, encoding: .utf8)

    let artifactRelativePath = WorkspaceStore.nodeBriefArtifactRelativePath(
      title: "Target Node",
      id: targetID,
      file: "target.org2",
      line: 1
    )

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      openClawSendHandler: { messages, _, _, context in
        let prompt = try XCTUnwrap(messages.last?.content)
        XCTAssertTrue(prompt.contains("Generate a concise, source-cited briefing for the selected org2 node \"Target Node\""))
        XCTAssertTrue(prompt.contains("Target artifact relative path: \(artifactRelativePath)"))
        XCTAssertTrue(prompt.contains(":ORG2_ARTIFACT_ROLE: view"))
        XCTAssertTrue(prompt.contains(":ORG2_REVIEW_STATUS: review-required"))
        XCTAssertTrue(prompt.contains(":ORG2_PROMPT_TEMPLATE: node-brief@v2"))
        XCTAssertTrue(prompt.contains("* Most important facts"))
        XCTAssertTrue(prompt.contains("* Active related tasks"))
        XCTAssertTrue(prompt.contains("* Recent related decisions"))
        XCTAssertTrue(prompt.contains("* Open questions"))
        XCTAssertTrue(prompt.contains("* Node health issues"))
        XCTAssertTrue(prompt.contains("* Sources"))
        XCTAssertTrue(prompt.contains("Before writing, do a current-state sweep."))
        XCTAssertTrue(prompt.contains("Do not discard completed DONE/CANCELED workflow items"))
        XCTAssertTrue(prompt.contains("waiting on reply/response"))
        XCTAssertTrue(prompt.contains("Most important facts: 3-6 bullets, including recent material state changes"))
        XCTAssertTrue(prompt.contains("Open questions: unresolved questions/unknowns/risks, including waiting-on-response states"))
        XCTAssertTrue(prompt.contains("Do not present stable IDs, artifact metadata, file paths, provenance fields, review status, schema fields, or the mere existence of a title/ID as facts or highlights."))
        XCTAssertTrue(prompt.contains("Mention metadata only in \"Node health issues\""))
        XCTAssertTrue(prompt.contains("do not run org2 brief"))
        XCTAssertFalse(prompt.contains("* Review checklist"))
        XCTAssertFalse(prompt.contains("* Reference clusters"))
        XCTAssertFalse(prompt.contains("Deterministic org2 context pack"))
        XCTAssertEqual(context?.backlinks?.backlinks.count, 3)
        XCTAssertEqual(context?.backlinks?.id, targetID)
        return "No artifact written"
      }
    )
    store.setCorpusRoot(root)
    store.select(.openClaw(OpenClawThread(
      title: "Target Node",
      file: target.path,
      line: 1,
      zone: "node",
      modifiedAt: nil,
      idValue: targetID
    )))

    try await waitForCondition {
      store.backlinks?.backlinks.count == 3
    }

    XCTAssertEqual(store.backlinkReferenceCount, 3)
    XCTAssertEqual(store.backlinkFileCount, 2)
    XCTAssertEqual(store.backlinkFileGroups.first?.file, firstSource.path)
    XCTAssertEqual(store.backlinkFileGroups.first?.count, 2)

    let firstGroup = try XCTUnwrap(store.backlinkFileGroups.first)
    store.toggleBacklinkFileGroup(firstGroup)
    XCTAssertTrue(store.expandedBacklinkFileIDs.contains(firstGroup.id))
    store.toggleBacklinkFileGroup(firstGroup)
    XCTAssertFalse(store.expandedBacklinkFileIDs.contains(firstGroup.id))

    await store.briefCurrentNodeInOpenClaw()

    XCTAssertEqual(store.openClawDraft, "")
    XCTAssertEqual(store.openClawMessages.count, 2)
    XCTAssertEqual(store.openClawMessages.last?.content, "No artifact written")
    XCTAssertEqual(store.statusText, "Node brief artifact was not written")
  }

  func testRelatedBacklinkNodesFilterGenericStructuralHeadingsAndKeepEvidence() {
    let backlinks = [
      BacklinkItem(
        srcId: "summary-id",
        srcTitle: "Summary",
        file: "/corpus/meetings/a.org2",
        line: 2,
        context: "Summary mentions [[id:scarf][Scarf]]."
      ),
      BacklinkItem(
        srcId: "raw-id",
        srcTitle: "Raw transcript",
        file: "/corpus/meetings/a.org2",
        line: 8,
        context: "Raw transcript mentions Scarf."
      ),
      BacklinkItem(
        srcId: "pilot-id",
        srcTitle: "Pilot relaunch details",
        file: "/corpus/projects/pilot.org2",
        line: 10,
        context: "Scarf pilot relaunch should include weekly usage notes."
      ),
      BacklinkItem(
        srcId: "pilot-id",
        srcTitle: "Pilot relaunch details",
        file: "/corpus/meetings/b.org2",
        line: 4,
        context: "Discussed Scarf data infrastructure during relaunch planning."
      ),
      BacklinkItem(
        srcId: "todo-id",
        srcTitle: "TODO Make org2 answer relationship questions like Scarf advisors",
        file: "/corpus/tasks.org2",
        line: 20,
        context: "Use Scarf advisors as a target workflow."
      )
    ]

    let related = WorkspaceStore.relatedBacklinkNodes(from: backlinks) { file in
      file.replacingOccurrences(of: "/corpus/", with: "")
    }

    XCTAssertEqual(related.map(\.title), [
      "Pilot relaunch details",
      "TODO Make org2 answer relationship questions like Scarf advisors"
    ])
    XCTAssertEqual(related.first?.referenceCount, 2)
    XCTAssertEqual(related.first?.fileCount, 2)
    XCTAssertEqual(related.first?.primaryPath, "meetings/b.org2:5")
    XCTAssertEqual(related.first?.examples.count, 2)
    XCTAssertTrue(WorkspaceStore.isGenericRelatedBacklinkTitle("Details"))
    XCTAssertFalse(WorkspaceStore.isGenericRelatedBacklinkTitle("Pilot relaunch details"))
  }

  func testNodeBriefArtifactBodyDropsOrgMetadata() {
    let raw = """
    #+TITLE: Node brief: Frances
    :PROPERTIES:
    :ID: node-brief-frances
    :ORG2_ARTIFACT_ROLE: view
    :END:

    * Highlights
    - Frances is our dog.
    * Sources
    - frances.org:1
    """

    XCTAssertEqual(WorkspaceStore.nodeBriefArtifactTitle(raw), "Node brief: Frances")
    XCTAssertEqual(
      WorkspaceStore.nodeBriefArtifactBody(raw),
      """
      * Highlights
      - Frances is our dog.
      * Sources
      - frances.org:1
      """
    )
  }

  @MainActor
  func testBriefCurrentNodeOpensCachedArtifact() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-brief-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let targetID = "44444444-4444-4444-8444-444444444444"
    let target = root.appendingPathComponent("target.org2")
    try """
    #+TITLE: Target Node
    :PROPERTIES:
    :ID: \(targetID)
    :END:

    Cached brief target.
    """.write(to: target, atomically: true, encoding: .utf8)

    let artifactRelativePath = WorkspaceStore.nodeBriefArtifactRelativePath(
      title: "Target Node",
      id: targetID,
      file: "target.org2",
      line: 1
    )
    let artifactURL = root.appendingPathComponent(artifactRelativePath)
    try FileManager.default.createDirectory(
      at: artifactURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try """
    #+TITLE: Node brief: Target Node
    :PROPERTIES:
    :ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata/v1
    :ORG2_ARTIFACT_ROLE: view
    :ORG2_REVIEW_STATUS: review-required
    :END:

    * Highlights
    Cached result.
    """.write(to: artifactURL, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.openClaw(OpenClawThread(
      title: "Target Node",
      file: target.path,
      line: 1,
      zone: "node",
      modifiedAt: nil,
      idValue: targetID
    )))

    await store.briefCurrentNodeInOpenClaw()

    XCTAssertEqual(store.openClawDraft, "")
    XCTAssertEqual(store.selectedSurface, .files)
    guard case .openClaw(let selected)? = store.selectedLocation else {
      XCTFail("Expected cached brief artifact to be selected")
      return
    }
    XCTAssertEqual(selected.file, artifactURL.path)
    XCTAssertEqual(selected.zone, "views/openclaw")
    XCTAssertEqual(store.statusText, "Opened \(artifactRelativePath)")
  }

  func testNodeBriefArtifactLoadsCachedBody() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-brief-inline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let targetID = "66666666-6666-4666-8666-666666666666"
    let artifactRelativePath = WorkspaceStore.nodeBriefArtifactRelativePath(
      title: "Target Node",
      id: targetID,
      file: "target.org2",
      line: 1
    )
    let artifactURL = root.appendingPathComponent(artifactRelativePath)
    try FileManager.default.createDirectory(
      at: artifactURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try """
    #+TITLE: Node brief: Target Node
    :PROPERTIES:
    :ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata/v1
    :ORG2_ARTIFACT_ROLE: view
    :ORG2_REVIEW_STATUS: review-required
    :END:

    * Highlights
    Cached inline result.
    """.write(to: artifactURL, atomically: true, encoding: .utf8)

    let artifact = try XCTUnwrap(WorkspaceStore.nodeBriefArtifact(
      at: artifactURL,
      relativePath: artifactRelativePath
    ))
    XCTAssertEqual(artifact.relativePath, artifactRelativePath)
    XCTAssertEqual(artifact.file, artifactURL.path)
    XCTAssertEqual(artifact.title, "Node brief: Target Node")
    XCTAssertEqual(artifact.body, "* Highlights\nCached inline result.")
  }

  @MainActor
  func testBriefCurrentNodeAutoOpensArtifactAfterOpenClawWritesIt() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-brief-autoload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let targetID = "55555555-5555-4555-8555-555555555555"
    let target = root.appendingPathComponent("target.org2")
    try """
    #+TITLE: Target Node
    :PROPERTIES:
    :ID: \(targetID)
    :END:

    Auto-open brief target.
    """.write(to: target, atomically: true, encoding: .utf8)

    let artifactRelativePath = WorkspaceStore.nodeBriefArtifactRelativePath(
      title: "Target Node",
      id: targetID,
      file: "target.org2",
      line: 1
    )
    let artifactURL = root.appendingPathComponent(artifactRelativePath)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      openClawSendHandler: { messages, _, _, _ in
        XCTAssertTrue(messages.last?.content.contains("Target artifact relative path: \(artifactRelativePath)") == true)
        try FileManager.default.createDirectory(
          at: artifactURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try """
        #+TITLE: Node brief: Target Node
        :PROPERTIES:
        :ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata/v1
        :ORG2_ARTIFACT_ROLE: view
        :ORG2_REVIEW_STATUS: review-required
        :END:

        * Highlights
        Generated result.
        """.write(to: artifactURL, atomically: true, encoding: .utf8)
        return "Wrote \(artifactRelativePath)"
      }
    )
    store.setCorpusRoot(root)
    store.select(.openClaw(OpenClawThread(
      title: "Target Node",
      file: target.path,
      line: 1,
      zone: "node",
      modifiedAt: nil,
      idValue: targetID
    )))

    await store.briefCurrentNodeInOpenClaw()

    guard case .openClaw(let selected)? = store.selectedLocation else {
      XCTFail("Expected generated brief artifact to be selected")
      return
    }
    XCTAssertEqual(selected.file, artifactURL.path)
    XCTAssertEqual(selected.title, "Brief: Target Node")
    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertTrue(store.openClawMessages.last?.changeSummary?.files.contains(where: { $0.relativePath == artifactRelativePath }) == true)
  }

  @MainActor
  func testBriefCurrentNodeAutoOpensArtifactWrittenAfterOpenClawReply() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-brief-delayed-autoload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let targetID = "77777777-7777-4777-8777-777777777777"
    let target = root.appendingPathComponent("target.org2")
    try """
    #+TITLE: Target Node
    :PROPERTIES:
    :ID: \(targetID)
    :END:

    Delayed auto-open brief target.
    """.write(to: target, atomically: true, encoding: .utf8)

    let artifactRelativePath = WorkspaceStore.nodeBriefArtifactRelativePath(
      title: "Target Node",
      id: targetID,
      file: "target.org2",
      line: 1
    )
    let artifactURL = root.appendingPathComponent(artifactRelativePath)
    let artifactPath = artifactURL.path
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      openClawSendHandler: { _, _, _, _ in
        Task.detached {
          try? await Task.sleep(nanoseconds: 250_000_000)
          try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: artifactPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try? """
          #+TITLE: Node brief: Target Node
          :PROPERTIES:
          :ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata/v1
          :ORG2_ARTIFACT_ROLE: view
          :ORG2_REVIEW_STATUS: review-required
          :END:

          * Highlights
          Delayed generated result.
          """.write(toFile: artifactPath, atomically: true, encoding: .utf8)
        }
        return "Queued artifact write"
      }
    )
    store.setCorpusRoot(root)
    store.select(.openClaw(OpenClawThread(
      title: "Target Node",
      file: target.path,
      line: 1,
      zone: "node",
      modifiedAt: nil,
      idValue: targetID
    )))

    await store.briefCurrentNodeInOpenClaw()

    guard case .openClaw(let selected)? = store.selectedLocation else {
      XCTFail("Expected delayed generated brief artifact to be selected")
      return
    }
    XCTAssertEqual(selected.file, artifactURL.path)
    XCTAssertEqual(selected.title, "Brief: Target Node")
    XCTAssertEqual(store.statusText, "Opened \(artifactRelativePath)")
  }

  @MainActor
  func testWorkspaceSearchScansCorpusRecursively() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-recursive-search-\(UUID().uuidString)", isDirectory: true)
    let nested = root.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let note = nested.appendingPathComponent("launch.org2")
    try """
    #+TITLE: Launch

    * TODO Launch checklist
    The recursive workspace search should find this nested full text phrase.
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.searchQuery = "nested full text"

    await store.runSearch()

    XCTAssertEqual(store.searchResults.count, 1)
    XCTAssertEqual(store.searchResults.first?.file, note.path)
    XCTAssertEqual(store.searchResults.first?.heading, "Launch checklist")
    XCTAssertEqual(store.selectedSurface, .search)
  }

  func testWorkspaceSearchPrioritizesActiveTodosForDisplay() {
    let done = searchResult(file: "/tmp/archive.org2", line: 2, heading: "Done item", todo: "DONE")
    let plain = searchResult(file: "/tmp/note.org2", line: 3, heading: "Plain note", todo: nil)
    let active = searchResult(file: "/tmp/action.org2", line: 4, heading: "Active item", todo: "TODO")

    let displayResults = WorkspaceStore.prioritizedSearchResultsForDisplay([done, plain, active])

    XCTAssertEqual(displayResults.map(\.heading), ["Active item", "Plain note", "Done item"])
  }

  func testWorkspaceSearchGroupsRepeatedFileResultsForDisplay() {
    let done = searchResult(file: "/tmp/accounts.org2", line: 12, heading: "Done account note", todo: "DONE")
    let active = searchResult(file: "/tmp/accounts.org2", line: 4, heading: "Active account todo", todo: "WAIT")
    let other = searchResult(file: "/tmp/meeting.org2", line: 2, heading: "Meeting note", todo: nil)
    let displayResults = WorkspaceStore.prioritizedSearchResultsForDisplay([done, other, active])

    let groups = WorkspaceStore.groupedSearchResultsForDisplay(displayResults)

    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups.first?.file, "/tmp/accounts.org2")
    XCTAssertEqual(groups.first?.representative.heading, "Active account todo")
    XCTAssertEqual(groups.first?.additionalCount, 1)
    XCTAssertEqual(groups.last?.file, "/tmp/meeting.org2")
  }

  @MainActor
  func testWorkspaceSearchIncludesOpenClawChatThreads() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.openClawMessages = [
      OpenClawChatMessage(role: .user, content: "How should we structure chat thread navigation?"),
      OpenClawChatMessage(role: .assistant, content: "Nest threads under OpenClaw in the sidebar.")
    ]
    let threadID = try XCTUnwrap(store.selectedOpenClawChatThreadID)
    store.searchQuery = "sidebar"

    await store.runSearch()

    XCTAssertTrue(store.searchResults.isEmpty)
    XCTAssertEqual(store.openClawChatSearchResults.count, 1)
    XCTAssertEqual(store.openClawChatSearchResults.first?.threadID, threadID)
    XCTAssertEqual(store.selectedSurface, .search)

    let result = try XCTUnwrap(store.openClawChatSearchResults.first)
    store.selectOpenClawChatSearchResult(result)

    XCTAssertEqual(store.selectedSurface, .openClaw)
    XCTAssertEqual(store.selectedOpenClawChatThreadID, threadID)
  }

  @MainActor
  func testWorkspaceNodeSearchFiltersIndexedNodesAndOpensSelection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("alpha.org2")
    try """
    #+TITLE: Alpha Project
    #+ROAM_ALIASES: "Apollo"
    :PROPERTIES:
    :ID: alpha-id
    :END:

    * Beta Heading
    :PROPERTIES:
    :ID: beta-id
    :END:
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshCorpusFiles()

    try await waitForCondition {
      store.orgRoamLinkResolver.nodes.count == 2
    }

    store.searchMode = .nodes
    store.searchQuery = "apollo"
    XCTAssertEqual(store.searchNodes.first?.title, "Alpha Project")

    store.searchQuery = "beta"
    XCTAssertTrue(store.searchNodes.isEmpty)

    store.searchQuery = "alpha"
    let alpha = try XCTUnwrap(store.searchNodes.first)
    store.selectSearchNode(alpha)

    XCTAssertEqual(store.selectedSurface, .search)
    XCTAssertEqual(store.selectedLocation?.title, "Alpha Project")
    XCTAssertEqual(store.selectedLocation?.file, note.path)
    XCTAssertEqual(store.selectedLocation?.lineForEditor, 1)
    XCTAssertNil(store.renderedSearchHighlightQuery)
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
    try await waitForCondition {
      store.quickOpenFiles.first?.relativePath == "notes/alice.org2"
    }
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

  @MainActor
  func testGlobalKeyboardShortcutsNavigateWorkspaceSurfaces() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "1", keyCode: 18, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .home)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "2", keyCode: 19, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .agenda)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "3", keyCode: 20, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .files)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "4", keyCode: 21, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertEqual(store.searchFocusToken, 0)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "F", keyCode: 3, modifiers: [.command, .shift])))
    XCTAssertEqual(store.selectedSurface, .search)
    XCTAssertEqual(store.searchFocusToken, 1)

    store.select(.openClaw(OpenClawThread(
      title: "Current page",
      file: "/tmp/current.org",
      line: 1,
      zone: "corpus",
      modifiedAt: nil,
      idValue: nil
    )))
    let surfaceBeforePageFind = store.selectedSurface
    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "f", keyCode: 3, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, surfaceBeforePageFind)
    XCTAssertTrue(store.isPageSearchPresented)
    XCTAssertEqual(store.pageSearchFocusToken, 1)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "5", keyCode: 23, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .meetings)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "6", keyCode: 22, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .openClaw)

    XCTAssertFalse(store.handleGlobalKeyDown(keyDown(characters: "f", keyCode: 3, modifiers: [.command, .option])))
    XCTAssertFalse(store.handleGlobalKeyDown(keyDown(characters: "w", keyCode: 13, modifiers: [.command, .option])))
    XCTAssertFalse(store.handleGlobalKeyDown(keyDown(characters: "p", keyCode: 35, modifiers: [.command, .option])))

    XCTAssertFalse(store.handleGlobalKeyDown(keyDown(characters: "7", keyCode: 26, modifiers: [.command, .shift])))

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "0", keyCode: 29, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .openClaw)
    XCTAssertFalse(store.isOpenClawAssistantPresented)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "/", keyCode: 44, modifiers: [.command])))
    XCTAssertTrue(store.isKeyboardShortcutsPresented)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "z", keyCode: 6, modifiers: [.command])))
    XCTAssertEqual(store.statusText, "Nothing to undo")

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "Z", keyCode: 6, modifiers: [.command, .shift])))
    XCTAssertEqual(store.statusText, "Nothing to redo")
  }

  @MainActor
  func testGlobalKeyboardShortcutsIncludeRefreshAndSave() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-global-menu-keys-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))

    XCTAssertFalse(store.handleGlobalKeyDown(keyDown(characters: "r", keyCode: 15, modifiers: [.command])))
    XCTAssertFalse(store.handleGlobalKeyDown(keyDown(characters: "s", keyCode: 1, modifiers: [.command])))

    store.setCorpusRoot(root)
    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "r", keyCode: 15, modifiers: [.command])))
  }

  func testWorkspaceKeyboardEventRoutingLetsCommandShortcutsThroughTextInputs() {
    XCTAssertEqual(
      WorkspaceKeyboardEventRouting.scope(
        for: keyDown(characters: "1", keyCode: 18, modifiers: [.command]),
        textInputActive: true
      ),
      .globalOnly
    )
    XCTAssertEqual(
      WorkspaceKeyboardEventRouting.scope(
        for: keyDown(characters: "Z", keyCode: 6, modifiers: [.command, .shift]),
        textInputActive: true
      ),
      .globalOnly
    )
    XCTAssertEqual(
      WorkspaceKeyboardEventRouting.scope(
        for: keyDown(characters: "f", keyCode: 3, modifiers: [.command, .option]),
        textInputActive: true
      ),
      .globalOnly
    )
    XCTAssertNil(WorkspaceKeyboardEventRouting.scope(
      for: keyDown(characters: "j", keyCode: 38),
      textInputActive: true
    ))
    XCTAssertNil(WorkspaceKeyboardEventRouting.scope(
      for: keyDown(characters: "f", keyCode: 3, modifiers: [.command, .control]),
      textInputActive: true
    ))
    XCTAssertEqual(
      WorkspaceKeyboardEventRouting.scope(
        for: keyDown(characters: "j", keyCode: 38),
        textInputActive: false
      ),
      .all
    )
  }

  @MainActor
  func testGlobalQuickOpenShortcutRequiresCorpus() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-global-keys-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "p", keyCode: 35, modifiers: [.command])))
    XCTAssertFalse(store.isQuickOpenPresented)

    store.setCorpusRoot(root)
    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "k", keyCode: 40, modifiers: [.command])))
    XCTAssertTrue(store.isQuickOpenPresented)
  }

  func testWorkspaceSurfaceShortcutTitlesMatchCommandNavigation() {
    XCTAssertEqual(WorkspaceSurface.home.commandShortcutTitle, "⌘1")
    XCTAssertEqual(WorkspaceSurface.agenda.commandShortcutTitle, "⌘2")
    XCTAssertEqual(WorkspaceSurface.approvals.commandShortcutTitle, "⌘4")
    XCTAssertEqual(WorkspaceSurface.files.commandShortcutTitle, "⌘3")
    XCTAssertEqual(WorkspaceSurface.search.commandShortcutTitle, "⌘⇧F")
    XCTAssertEqual(WorkspaceSurface.meetings.commandShortcutTitle, "⌘5")
    XCTAssertEqual(WorkspaceSurface.openClaw.commandShortcutTitle, "⌘6")
    XCTAssertEqual(WorkspaceSurface.sidebarCases, [.home, .agenda, .files, .approvals, .search, .meetings, .openClaw])
  }

  @MainActor
  func testDetailPaneLayoutActionsCloseExpandAndReopenOnSelection() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let thread = OpenClawThread(
      title: "Current page",
      file: "/tmp/current.org2",
      line: 1,
      zone: "test",
      modifiedAt: nil
    )
    store.select(.openClaw(thread))
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)

    store.closeDetailPane()
    XCTAssertTrue(store.isWorkspaceDetailPaneClosed)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)

    store.toggleDetailPaneExpansion()
    XCTAssertFalse(store.isWorkspaceDetailPaneExpanded)
    XCTAssertTrue(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)

    store.toggleDetailPaneExpansion()
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneExpanded)

    store.makeDetailPanePrimary()
    XCTAssertTrue(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneExpanded)

    store.closeDetailPane()
    store.select(.openClaw(thread))
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
  }

  @MainActor
  func testOpenClawAssistantRequestsUseWorkspaceSurface() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    XCTAssertFalse(store.isNodeContextPanePresented)
    let thread = OpenClawThread(
      title: "Current page",
      file: "/tmp/current.org2",
      line: 1,
      zone: "test",
      modifiedAt: nil
    )

    store.select(.openClaw(thread))
    XCTAssertFalse(store.isNodeContextPanePresented)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)

    store.toggleNodeContextPane()
    XCTAssertTrue(store.isNodeContextPanePresented)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)

    store.selectedSurface = .agenda
    store.isWorkspaceSurfacePaneClosed = false
    store.isNodeContextPanePresented = false
    store.setOpenClawAssistantPanelPresented(true)
    XCTAssertEqual(store.selectedSurface, .openClaw)
    XCTAssertFalse(store.isOpenClawAssistantPresented)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
  }

  func testWorkspaceHealthChecksReportRepoBuildAndCorpusReadiness() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-health-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try "{}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "".write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)
    try "".write(to: dist.appendingPathComponent("parse.js"), atomically: true, encoding: .utf8)

    let corpus = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    let checks = WorkspaceStore.workspaceHealthChecks(cli: Org2CLI(repoRoot: root), corpusRoot: corpus)

    XCTAssertEqual(checks.first { $0.id == "repo-root" }?.status, .ready)
    XCTAssertEqual(checks.first { $0.id == "node-build" }?.status, .ready)
    XCTAssertEqual(checks.first { $0.id == "corpus-root" }?.status, .ready)
    XCTAssertEqual(checks.first { $0.id == "corpus-config" }?.status, .warning)
    XCTAssertNotNil(checks.first { $0.id == "node-modules" }?.remediationTitle)
  }

  @MainActor
  func testGlobalDailyNoteShortcutsCreateAndOpenDailyFiles() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-shortcuts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "7", keyCode: 26, modifiers: [.command])))

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let todayFileName = "\(formatter.string(from: Date())).org2"
    let today = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent(todayFileName)
      .standardizedFileURL

    XCTAssertTrue(FileManager.default.fileExists(atPath: today.path))
    XCTAssertEqual(store.selectedCorpusFileID, today.path)
    XCTAssertEqual(store.selectedSurface, .files)
  }

  func testDailyNoteTargetsPutTodayFirstAndExposeCommandShortcuts() {
    XCTAssertEqual(DailyNoteTarget.allCases, [.today, .yesterday, .tomorrow])
    XCTAssertEqual(DailyNoteTarget.today.commandShortcutTitle, "⌘7")
    XCTAssertEqual(DailyNoteTarget.yesterday.commandShortcutTitle, "⌘8")
    XCTAssertEqual(DailyNoteTarget.tomorrow.commandShortcutTitle, "⌘9")
  }

  func testAgendaSurfaceIsNamedAgenda() {
    XCTAssertEqual(WorkspaceSurface.agenda.title, "Agenda")
  }

  @MainActor
  func testAgendaFilterFocusLetsTypingBypassAgendaShortcuts() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.selectedSurface = .agenda
    store.isAgendaFilterFocused = true

    XCTAssertFalse(store.handleAgendaKeyDown(keyDown(characters: "o", keyCode: 31)))
    XCTAssertFalse(store.handleAgendaKeyDown(keyDown(characters: "r", keyCode: 15)))
    XCTAssertFalse(store.handleAgendaKeyDown(keyDown(characters: "a", keyCode: 0, modifiers: [.command])))
    XCTAssertTrue(store.isAgendaFilterFocused)

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "\u{1b}", keyCode: 53)))
    XCTAssertFalse(store.isAgendaFilterFocused)
  }

  @MainActor
  func testAgendaItemSelectionClearsFilterFocusForShortcuts() throws {
    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Filtered task",
      "kind": "SCHEDULED",
      "file": "/tmp/filtered.org2",
      "line": 1,
      "body": "",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.selectedSurface = .agenda
    store.agendaFilter = "filtered"
    store.isAgendaFilterFocused = true

    store.handleAgendaItemClick(item)

    XCTAssertFalse(store.isAgendaFilterFocused)
    XCTAssertEqual(store.selectedAgendaItemID, item.id)
    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "p", keyCode: 35)))
    XCTAssertTrue(store.priorityModeActive)
  }

  @MainActor
  func testAgendaDisplayModeChangeDoesNotOpenEntry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-mode-no-open-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-mode.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO Today task
    SCHEDULED: <\(today)>

    * DONE Closed task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()
    store.selectedLocation = nil
    store.selectedAgendaItemID = nil

    store.agendaMode = .today
    store.syncAgendaSelectionAfterDisplayOptionsChange()

    XCTAssertNotNil(store.selectedAgendaItemID)
    XCTAssertNil(store.selectedLocation)
    XCTAssertTrue(store.consumeAgendaSelectionActivationSuppression())
    XCTAssertFalse(store.consumeAgendaSelectionActivationSuppression())
  }

  @MainActor
  func testAgendaUppercaseJKScrollDetailPaneWithoutMovingSelection() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.selectedSurface = .agenda
    store.selectedAgendaItemID = "selected-agenda-item"

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "J", keyCode: 38, modifiers: [.shift])))
    XCTAssertEqual(store.detailScrollRequest, DetailScrollRequest(id: 1, direction: .down))
    XCTAssertEqual(store.selectedAgendaItemID, "selected-agenda-item")

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "K", keyCode: 40, modifiers: [.shift])))
    XCTAssertEqual(store.detailScrollRequest, DetailScrollRequest(id: 2, direction: .up))
    XCTAssertEqual(store.selectedAgendaItemID, "selected-agenda-item")
  }

  @MainActor
  func testCompletingAgendaItemSelectsNextActionableAgendaRowWithoutActivatingEntry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-done-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(second)

    await store.applyTodoShortcut(.done)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE Second task"))
    let third = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Third task" })
    XCTAssertEqual(store.selectedAgendaItemID, third.id)
    XCTAssertTrue(store.consumeAgendaSelectionActivationSuppression())
    guard case .agenda(let selected)? = store.selectedLocation else {
      return XCTFail("Expected agenda selection")
    }
    XCTAssertEqual(selected.headline, "Second task")
  }

  @MainActor
  func testRepeatedAgendaDoneKeysAdvanceRowsInsteadOfEditingSelectedHeading() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-repeated-done-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-repeated-done.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let first = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "First task" })
    store.selectAgendaItem(first)
    try await waitForCondition {
      store.selectedEntrySource?.file == note.path
        && !store.isLoadingEntrySource
        && !store.isRenderingEntrySource
        && !store.selectedRenderedBlocks.isEmpty
    }

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered {
        return heading.title == "First task"
      }
      return false
    })
    store.selectBlock(heading)

    XCTAssertTrue(store.handleWorkspaceKeyDown(keyDown(characters: "d", keyCode: 2)))
    XCTAssertTrue(store.handleWorkspaceKeyDown(keyDown(characters: "d", keyCode: 2)))
    XCTAssertTrue(store.handleWorkspaceKeyDown(keyDown(characters: "d", keyCode: 2)))
    XCTAssertNil(store.editingBlockID)

    try await waitForCondition(timeout: 10) {
      ((try? String(contentsOf: note, encoding: .utf8)) ?? "")
        .components(separatedBy: "* DONE ")
        .count == 4
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE First task"))
    XCTAssertTrue(updated.contains("* DONE Second task"))
    XCTAssertTrue(updated.contains("* DONE Third task"))
    XCTAssertFalse(updated.contains("ddd"))
  }

  @MainActor
  func testCancelingAgendaItemSelectsNextActionableAgendaRowWithoutActivatingEntry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-canceled-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(second)

    await store.applyTodoShortcut(.canceled)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* CANCELED Second task"))
    let third = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Third task" })
    XCTAssertEqual(store.selectedAgendaItemID, third.id)
    XCTAssertTrue(store.consumeAgendaSelectionActivationSuppression())
    guard case .agenda(let selected)? = store.selectedLocation else {
      return XCTFail("Expected agenda selection")
    }
    XCTAssertEqual(selected.headline, "Second task")
  }

  @MainActor
  func testAgendaLocationStatusChangeSelectsNextRowWithoutActivatingEntry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-location-status-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(second)

    await store.applyTodoShortcut(.canceled, to: .agenda(second))

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* CANCELED Second task"))
    let third = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Third task" })
    XCTAssertEqual(store.selectedAgendaItemID, third.id)
    XCTAssertTrue(store.consumeAgendaSelectionActivationSuppression())
    guard case .agenda(let selected)? = store.selectedLocation else {
      return XCTFail("Expected agenda selection")
    }
    XCTAssertEqual(selected.headline, "Second task")
  }

  @MainActor
  func testNonTerminalAgendaStatusChangeStaysOnCurrentRow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-active-status-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(second)

    await store.applyTodoShortcut(.inProgress)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* IN_PROGRESS Second task"))
    let updatedSecond = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    XCTAssertEqual(store.selectedAgendaItemID, updatedSecond.id)
    XCTAssertFalse(store.consumeAgendaSelectionActivationSuppression())
    guard case .agenda(let selected)? = store.selectedLocation else {
      return XCTFail("Expected agenda selection")
    }
    XCTAssertEqual(selected.headline, "Second task")
  }

  @MainActor
  func testBulkAgendaDoneMarksCheckedItems() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-bulk-done-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-bulk.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()
    store.selectedSurface = .agenda

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "a", keyCode: 0, modifiers: [.command])))
    XCTAssertEqual(store.bulkAgendaSelectionCount, 3)
    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "a", keyCode: 0, modifiers: [.command, .shift])))
    XCTAssertEqual(store.bulkAgendaSelectionCount, 0)

    let first = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "First task" })
    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.toggleAgendaItemBulkSelection(first)
    store.toggleAgendaItemBulkSelection(second)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 2)

    await store.applyTodoShortcut(.done)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE First task"))
    XCTAssertTrue(updated.contains("* DONE Second task"))
    XCTAssertTrue(updated.contains("* TODO Third task"))
    XCTAssertEqual(store.bulkAgendaSelectionCount, 0)
  }

  @MainActor
  func testAgendaShiftArrowsExtendBulkSelection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-shift-bulk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-shift-bulk.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let first = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "First task" })
    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    let third = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Third task" })
    store.selectAgendaItem(second)

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(keyCode: 125, modifiers: [.shift])))
    XCTAssertTrue(store.isAgendaItemBulkSelected(second))
    XCTAssertTrue(store.isAgendaItemBulkSelected(third))
    XCTAssertFalse(store.isAgendaItemBulkSelected(first))
    XCTAssertEqual(store.selectedAgendaItemID, third.id)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 2)

    store.clearAgendaBulkSelection()
    store.selectAgendaItem(second)

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(keyCode: 126, modifiers: [.shift])))
    XCTAssertTrue(store.isAgendaItemBulkSelected(first))
    XCTAssertTrue(store.isAgendaItemBulkSelected(second))
    XCTAssertFalse(store.isAgendaItemBulkSelected(third))
    XCTAssertEqual(store.selectedAgendaItemID, first.id)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 2)
    try await waitForCondition {
      store.selectedEntrySource?.file == note.path && !store.isLoadingEntrySource && !store.isLoadingBacklinks
    }
  }

  @MainActor
  func testAgendaCommandClickTogglesBulkSelectionForRow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-command-click-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-command-click.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.handleAgendaItemClick(second, modifiers: [.command])

    XCTAssertTrue(store.isAgendaItemBulkSelected(second))
    XCTAssertEqual(store.selectedAgendaItemID, second.id)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 1)

    store.handleAgendaItemClick(second, modifiers: [.command])
    XCTAssertFalse(store.isAgendaItemBulkSelected(second))
    XCTAssertEqual(store.selectedAgendaItemID, second.id)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 0)
    try await waitForCondition {
      store.selectedEntrySource?.file == note.path && !store.isLoadingEntrySource && !store.isLoadingBacklinks
    }
  }

  @MainActor
  func testReselectingSameAgendaItemReusesRenderedDetail() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-reselect-detail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-reselect.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let item = try XCTUnwrap(store.visibleAgendaItems.first)
    store.selectAgendaItem(item)
    try await waitForCondition {
      store.selectedEntrySource?.file == note.path
        && !store.isLoadingEntrySource
        && !store.isRenderingEntrySource
        && !store.selectedRenderedBlocks.isEmpty
    }

    let renderedBlockIDs = store.selectedRenderedBlocks.map(\.id)
    store.selectAgendaItem(item)

    XCTAssertEqual(store.selectedRenderedBlocks.map(\.id), renderedBlockIDs)
    XCTAssertFalse(store.isLoadingEntrySource)
    XCTAssertFalse(store.isRenderingEntrySource)
  }

  @MainActor
  func testReselectingSameAgendaItemRetriesStuckSourceLoad() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-reselect-loading-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-reselect-loading.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let item = try XCTUnwrap(store.visibleAgendaItems.first)
    store.selectedLocation = .agenda(item)
    store.selectedEntrySourceMode = .entry
    store.selectedEntrySource = nil
    store.selectedRenderedBlocks = []
    store.isLoadingEntrySource = true
    store.isRenderingEntrySource = false

    store.selectAgendaItem(item)

    try await waitForCondition {
      store.selectedEntrySource?.file == note.path
        && !store.isLoadingEntrySource
        && !store.isRenderingEntrySource
        && !store.selectedRenderedBlocks.isEmpty
    }
  }

  @MainActor
  func testBulkAgentHandoffAssignsCheckedItemsWithoutChangingTodoState() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-bulk-agent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-bulk-agent.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First agent task
    SCHEDULED: <\(today)>
    Body

    * TODO Second agent task
    SCHEDULED: <\(today)>
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let first = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "First agent task" })
    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second agent task" })
    store.toggleAgendaItemBulkSelection(first)
    store.toggleAgendaItemBulkSelection(second)

    await store.applyAgentHandoffShortcut()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO First agent task"))
    XCTAssertTrue(updated.contains("* TODO Second agent task"))
    XCTAssertFalse(updated.contains("* DONE First agent task"))
    XCTAssertFalse(updated.contains("* DONE Second agent task"))
    XCTAssertEqual(updated.components(separatedBy: ":ASSIGNEE: OpenClaw").count - 1, 2)
    XCTAssertEqual(updated.components(separatedBy: ":STATUS: ready").count - 1, 2)
    XCTAssertEqual(updated.components(separatedBy: ":ASSIGNED_AT: <").count - 1, 2)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 0)
  }

  @MainActor
  func testOpenDailyNoteCreatesAndSelectsConfiguredDailyFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-open-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.openDailyNote(.today)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let fileName = "\(formatter.string(from: Date())).org2"
    let daily = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent(fileName)
      .standardizedFileURL

    XCTAssertTrue(FileManager.default.fileExists(atPath: daily.path))
    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertEqual(store.selectedCorpusFileID, daily.path)
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    XCTAssertEqual(store.selectedLocation?.file, daily.path)
    XCTAssertEqual(store.corpusFiles.map(\.relativePath), ["dailies/\(fileName)"])
  }

  @MainActor
  func testOpenHomeCreatesTodayDailyNoteAsOpenClawDetail() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.openHome()

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let fileName = "\(formatter.string(from: Date())).org2"
    let daily = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent(fileName)
      .standardizedFileURL

    XCTAssertTrue(FileManager.default.fileExists(atPath: daily.path))
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertEqual(store.selectedCorpusFileID, daily.path)
    XCTAssertEqual(store.selectedOpenClawThreadID, daily.path)
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    XCTAssertEqual(store.selectedLocation?.file, daily.path)
    XCTAssertEqual(store.selectedLocation?.lineForEditor, 1)
    XCTAssertEqual(store.corpusFiles.map(\.relativePath), ["dailies/\(fileName)"])
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
      searchResults: [],
      agentThreadDirectories: ["\(localRoot)/agents", "\(localRoot)/notes/openclaw"]
    )

    let prompt = context.systemPrompt()

    XCTAssertTrue(prompt.contains("Remote org2 root for OpenClaw: \(remoteRoot)"))
    XCTAssertTrue(prompt.contains("Agent-thread directories: \(remoteRoot)/agents, \(remoteRoot)/notes/openclaw"))
    XCTAssertTrue(prompt.contains("Do not write generated Backlinks sections"))
    XCTAssertTrue(prompt.contains("OpenClaw handoff rules"))
    XCTAssertTrue(prompt.contains(":KIND: agent-thread"))
    XCTAssertTrue(prompt.contains("Context attachments"))
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
    #+begin_example
    Example text should render as prose
    #+end_example
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
    XCTAssertTrue(blocks.contains(.quote(["Example text should render as prose"])))
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

  func testEditableInlineTokenChecksFocusedSyntaxNearSelection() {
    let raw = "See [[id:abc][Alice]]. " + String(repeating: "plain text ", count: 160)
    let nsRaw = raw as NSString
    let aliceRange = nsRaw.range(of: "Alice")
    let farPlainRange = NSRange(location: nsRaw.length, length: 0)

    XCTAssertTrue(OrgInlineParser.hasInlineSyntaxCandidate(raw))
    XCTAssertTrue(OrgEditableInlineToken.hasFocusedInlineSyntaxCandidate(
      in: raw,
      selection: NSRange(location: aliceRange.location, length: 0)
    ))
    XCTAssertFalse(OrgEditableInlineToken.hasFocusedInlineSyntaxCandidate(
      in: raw,
      selection: farPlainRange
    ))
    XCTAssertNil(OrgEditableInlineToken.focused(in: raw, selection: farPlainRange))
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

  func testRenderedBlockEditingPolicyStartsInlineEditingForRichBlocksOnSingleClick() {
    let editableBlocks = [
      OrgEditableBlock(
        id: "heading",
        startLine: 1,
        endLineExclusive: 2,
        rawText: "* TODO Heading",
        rendered: .heading(OrgHeadingBlock(level: 1, todo: "TODO", priority: nil, title: "Heading", tags: []))
      ),
      OrgEditableBlock(
        id: "quote",
        startLine: 5,
        endLineExclusive: 8,
        rawText: "#+begin_quote\nquoted\n#+end_quote",
        rendered: .quote(["quoted"])
      ),
      OrgEditableBlock(
        id: "source",
        startLine: 8,
        endLineExclusive: 11,
        rawText: "#+begin_src sh\necho hi\n#+end_src",
        rendered: .source(language: "sh", lines: ["echo hi"])
      ),
      OrgEditableBlock(
        id: "table",
        startLine: 11,
        endLineExclusive: 13,
        rawText: "| A | B |\n| 1 | 2 |",
        rendered: .table(OrgTableBlock(rows: [
          .cells(["A", "B"]),
          .cells(["1", "2"])
        ]))
      )
    ]

    for block in editableBlocks {
      XCTAssertTrue(
        RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: block, isSourceEditable: true),
        block.id
      )
      XCTAssertFalse(
        RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: block, isSourceEditable: false),
        block.id
      )
    }
  }

  func testRenderedBlockEditingPolicyStartsInlineEditingForStructuralBlocksOnSingleClick() {
    let divider = OrgEditableBlock(
      id: "divider",
      startLine: 1,
      endLineExclusive: 2,
      rawText: "-----",
      rendered: .horizontalRule
    )
    let blank = OrgEditableBlock(
      id: "blank",
      startLine: 2,
      endLineExclusive: 3,
      rawText: "",
      rendered: .blank
    )
    XCTAssertTrue(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: divider, isSourceEditable: true))
    XCTAssertFalse(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: blank, isSourceEditable: true))
    let properties = OrgEditableBlock(
      id: "properties",
      startLine: 3,
      endLineExclusive: 6,
      rawText: ":PROPERTIES:\n:Owner: Avi\n:END:",
      rendered: .properties([OrgPropertyRow(key: "Owner", value: "Avi")])
    )
    XCTAssertTrue(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: properties, isSourceEditable: true))
  }

  func testRenderedBlockEditingPolicyDoesNotStartInlineEditingForMediaParagraphsOnSingleClick() throws {
    let embedded = try XCTUnwrap(OrgEntryRenderer.parseEditable(
      "inline images [[file:images/image.png][Image]]"
    ).first)
    let standalone = try XCTUnwrap(OrgEntryRenderer.parseEditable(
      "[[file:images/image.png][Image]]"
    ).first)

    XCTAssertFalse(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: embedded, isSourceEditable: true))
    XCTAssertFalse(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: standalone, isSourceEditable: true))
  }

  func testLiveRenderedTextEditingPolicyUsesDirectEditorsForDocumentTextBlocks() throws {
    let paragraph = try XCTUnwrap(OrgEntryRenderer.parseEditable("Body with [[id:abc][Alice]].").first)
    let listItem = try XCTUnwrap(OrgEntryRenderer.parseEditable("- [ ] Task").first)
    let heading = try XCTUnwrap(OrgEntryRenderer.parseEditable("* Heading").first)
    let media = try XCTUnwrap(OrgEntryRenderer.parseEditable("[[file:images/image.png][Image]]").first)

    XCTAssertTrue(LiveRenderedTextEditingPolicy.usesDirectEditor(block: paragraph, isSourceEditable: true))
    XCTAssertTrue(LiveRenderedTextEditingPolicy.usesDirectEditor(block: listItem, isSourceEditable: true))
    XCTAssertTrue(LiveRenderedTextEditingPolicy.usesDirectEditor(block: heading, isSourceEditable: true))
    XCTAssertFalse(LiveRenderedTextEditingPolicy.usesDirectEditor(block: media, isSourceEditable: true))
    XCTAssertFalse(LiveRenderedTextEditingPolicy.usesDirectEditor(block: paragraph, isSourceEditable: false))
  }

  func testRenderedBlockDisplayPolicyCollapsesBlankButKeepsProperties() {
    let blank = OrgEditableBlock(
      id: "blank",
      startLine: 1,
      endLineExclusive: 2,
      rawText: "",
      rendered: .blank
    )
    let properties = OrgEditableBlock(
      id: "properties",
      startLine: 2,
      endLineExclusive: 5,
      rawText: ":PROPERTIES:\n:ID: 316c31f8\n:END:",
      rendered: .properties([OrgPropertyRow(key: "ID", value: "316c31f8")])
    )
    let heading = OrgEditableBlock(
      id: "heading",
      startLine: 5,
      endLineExclusive: 6,
      rawText: "* Heading",
      rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Heading", tags: []))
    )

    XCTAssertFalse(OrgRenderedBlockDisplayPolicy.isVisible(blank))
    XCTAssertTrue(OrgRenderedBlockDisplayPolicy.isVisible(properties))
    XCTAssertTrue(OrgRenderedBlockDisplayPolicy.isVisible(heading))
    XCTAssertFalse(OrgRenderedBlockDisplayPolicy.showsRowChrome(for: blank))
    XCTAssertTrue(OrgRenderedBlockDisplayPolicy.showsRowChrome(for: properties))
    XCTAssertTrue(OrgRenderedBlockDisplayPolicy.showsRowChrome(for: heading))
  }

  func testRenderedFoldTreeHidesHeadingAndListDescendants() {
    let blocks = [
      OrgEditableBlock(
        id: "h1",
        startLine: 1,
        endLineExclusive: 2,
        rawText: "* Parent",
        rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Parent", tags: []))
      ),
      OrgEditableBlock(id: "p1", startLine: 2, endLineExclusive: 3, rawText: "Body", rendered: .paragraph("Body")),
      OrgEditableBlock(
        id: "h2",
        startLine: 3,
        endLineExclusive: 4,
        rawText: "** Child",
        rendered: .heading(OrgHeadingBlock(level: 2, todo: nil, priority: nil, title: "Child", tags: []))
      ),
      OrgEditableBlock(id: "p2", startLine: 4, endLineExclusive: 5, rawText: "Child body", rendered: .paragraph("Child body")),
      OrgEditableBlock(
        id: "next",
        startLine: 5,
        endLineExclusive: 6,
        rawText: "* Next",
        rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Next", tags: []))
      ),
      OrgEditableBlock(id: "list", startLine: 6, endLineExclusive: 7, rawText: "- Parent", rendered: .listItem(indent: 0, marker: "-", checkbox: nil, text: "Parent")),
      OrgEditableBlock(id: "child", startLine: 7, endLineExclusive: 8, rawText: "  - Child", rendered: .listItem(indent: 2, marker: "-", checkbox: nil, text: "Child")),
      OrgEditableBlock(id: "grand", startLine: 8, endLineExclusive: 9, rawText: "    - Grand", rendered: .listItem(indent: 4, marker: "-", checkbox: nil, text: "Grand")),
      OrgEditableBlock(id: "sibling", startLine: 9, endLineExclusive: 10, rawText: "- Sibling", rendered: .listItem(indent: 0, marker: "-", checkbox: nil, text: "Sibling"))
    ]

    XCTAssertTrue(OrgRenderedFoldTree.isFoldable(blocks[0], in: blocks))
    XCTAssertTrue(OrgRenderedFoldTree.isFoldable(blocks[5], in: blocks))
    XCTAssertFalse(OrgRenderedFoldTree.isFoldable(blocks[8], in: blocks))

    XCTAssertEqual(
      OrgRenderedFoldTree.visibleBlocks(blocks, foldedBlockIDs: ["h1"]).map(\.id),
      ["h1", "next", "list", "child", "grand", "sibling"]
    )
    XCTAssertEqual(
      OrgRenderedFoldTree.visibleBlocks(blocks, foldedBlockIDs: ["list"]).map(\.id),
      ["h1", "p1", "h2", "p2", "next", "list", "sibling"]
    )
    XCTAssertEqual(
      OrgRenderedFoldTree.foldedAncestorID(hiding: "grand", foldedBlockIDs: ["list", "child"], blocks: blocks),
      "list"
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
    let emptyRunSignature = WorkspaceStore.sourceBlockRunsRenderSignature(for: [:])
    let runStates = [
      "/tmp/render-context.org2:source": SourceBlockRunState(
        status: .succeeded,
        language: "sh",
        commandLabel: "sh",
        stdout: "hi\n"
      )
    ]
    let runSignature = WorkspaceStore.sourceBlockRunsRenderSignature(for: runStates)
    XCTAssertNotEqual(emptyRunSignature, runSignature)
    XCTAssertNotEqual(
      runSignature,
      WorkspaceStore.sourceBlockRunsRenderSignature(for: [
        "/tmp/render-context.org2:source": SourceBlockRunState(
          status: .succeeded,
          language: "sh",
          commandLabel: "sh",
          stdout: "hi again\n"
        )
      ])
    )
    let base = OrgRenderedEntryView(
      blocks: blocks,
      blocksRenderSignature: signature,
      source: sourceContext,
      corpusRoot: nil,
      selectedBlockID: nil,
      selectedBlockIndex: nil,
      editingBlockID: nil,
      sourceBlockRunsRenderSignature: emptyRunSignature,
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
        sourceBlockRunsRenderSignature: emptyRunSignature,
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
        sourceBlockRunsRenderSignature: emptyRunSignature,
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
        sourceBlockRunsRenderSignature: emptyRunSignature,
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
        sourceBlockRunsRenderSignature: emptyRunSignature,
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
        sourceBlockRunsRenderSignature: runSignature,
        sourceBlockRuns: runStates
      )
    )
  }

  @MainActor
  func testRenderedBlockViewEqualityUsesSourceRunSignature() {
    let block = OrgEditableBlock(
      id: "source",
      startLine: 1,
      endLineExclusive: 4,
      rawText: "#+begin_src sh\necho hi\n#+end_src",
      rendered: .source(language: "sh", lines: ["echo hi"])
    )
    let baseActions = RenderedBlockInlineActions(
      isSourceEditable: true,
      decryptSubtree: nil,
      toggleHeadingTodo: nil,
      setHeadingPriority: nil,
      setHeadingTags: nil,
      setPlanningBlock: nil,
      setPropertyValue: nil,
      toggleListItemCheckbox: nil,
      sourceBlockRunRenderSignature: "same-output",
      sourceBlockRunState: SourceBlockRunState(
        status: .succeeded,
        language: "sh",
        commandLabel: "sh",
        stdout: "hi\n"
      ),
      runSourceBlock: nil
    )
    let changedStateSameSignature = RenderedBlockInlineActions(
      isSourceEditable: true,
      decryptSubtree: nil,
      toggleHeadingTodo: nil,
      setHeadingPriority: nil,
      setHeadingTags: nil,
      setPlanningBlock: nil,
      setPropertyValue: nil,
      toggleListItemCheckbox: nil,
      sourceBlockRunRenderSignature: "same-output",
      sourceBlockRunState: SourceBlockRunState(
        status: .succeeded,
        language: "sh",
        commandLabel: "sh",
        stdout: String(repeating: "large output\n", count: 1_000)
      ),
      runSourceBlock: nil
    )
    let changedSignature = RenderedBlockInlineActions(
      isSourceEditable: true,
      decryptSubtree: nil,
      toggleHeadingTodo: nil,
      setHeadingPriority: nil,
      setHeadingTags: nil,
      setPlanningBlock: nil,
      setPropertyValue: nil,
      toggleListItemCheckbox: nil,
      sourceBlockRunRenderSignature: "changed-output",
      sourceBlockRunState: SourceBlockRunState(
        status: .succeeded,
        language: "sh",
        commandLabel: "sh",
        stdout: "hi again\n"
      ),
      runSourceBlock: nil
    )

    let base = RenderedBlockView(
      block: block.rendered,
      rawText: block.rawText,
      editableBlock: block,
      inlineActions: baseActions
    )
    XCTAssertEqual(
      base,
      RenderedBlockView(
        block: block.rendered,
        rawText: block.rawText,
        editableBlock: block,
        inlineActions: changedStateSameSignature
      )
    )
    XCTAssertNotEqual(
      base,
      RenderedBlockView(
        block: block.rendered,
        rawText: block.rawText,
        editableBlock: block,
        inlineActions: changedSignature
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
    XCTAssertTrue(OrgRenderedEntryView.shouldAutoExpandNextFooter(visibleWindow: topWindow))

    let expandedNext = topWindow.expanding(
      .next,
      by: OrgRenderedEntryView.renderedBlockPageSize(for: blocks.count),
      totalCount: blocks.count
    )
    XCTAssertEqual(expandedNext, 0..<96)
    XCTAssertTrue(OrgRenderedEntryView.shouldAutoExpandNextFooter(
      visibleWindow: OrgRenderedBlockWindow(range: expandedNext, totalCount: blocks.count)
    ))

    let anchoredWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: nil,
      blocks: blocks,
      selectedBlockIndex: 1_200
    )
    XCTAssertGreaterThan(anchoredWindow.range.lowerBound, 0)
    XCTAssertFalse(OrgRenderedEntryView.shouldAutoExpandNextFooter(visibleWindow: anchoredWindow))
  }

  func testProgressiveRenderFooterAutoLoadTokensGateRepeatedLoads() {
    let firstToken = ProgressiveRenderFooterAutoLoad.token(
      visibleRange: "1-48",
      totalCount: 1_500,
      direction: .next
    )
    let expandedToken = ProgressiveRenderFooterAutoLoad.token(
      visibleRange: "1-96",
      totalCount: 1_500,
      direction: .next
    )
    let previousToken = ProgressiveRenderFooterAutoLoad.token(
      visibleRange: "48-96",
      totalCount: 1_500,
      direction: .previous
    )

    XCTAssertTrue(ProgressiveRenderFooterAutoLoad.shouldTrigger(
      autoLoadsOnAppear: true,
      lastTriggeredToken: nil,
      currentToken: firstToken
    ))
    XCTAssertFalse(ProgressiveRenderFooterAutoLoad.shouldTrigger(
      autoLoadsOnAppear: false,
      lastTriggeredToken: nil,
      currentToken: firstToken
    ))
    XCTAssertFalse(ProgressiveRenderFooterAutoLoad.shouldTrigger(
      autoLoadsOnAppear: true,
      lastTriggeredToken: firstToken,
      currentToken: firstToken
    ))
    XCTAssertTrue(ProgressiveRenderFooterAutoLoad.shouldTrigger(
      autoLoadsOnAppear: true,
      lastTriggeredToken: firstToken,
      currentToken: expandedToken
    ))
    XCTAssertNotEqual(firstToken, previousToken)
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
    let assignedRenderSignature = store.selectedRenderedBlocksRenderSignature

    let updatedFirstBlock = OrgEditableBlock(
      id: "first",
      startLine: 1,
      endLineExclusive: 2,
      rawText: "First updated",
      rendered: .paragraph("First updated")
    )
    store.selectedRenderedBlocks = [updatedFirstBlock]
    XCTAssertEqual(store.selectedRenderedBlocksSignature, assignedSignature)
    XCTAssertNotEqual(store.selectedRenderedBlocksRenderSignature, assignedRenderSignature)
    XCTAssertEqual(store.selectedRenderedBlockIndexes["first"], 0)

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

  func testRenderedBlockExpansionStatePersistsVisibleLimitsByBlockKey() {
    let block = OrgEditableBlock(
      id: "source-block",
      startLine: 10,
      endLineExclusive: 13,
      rawText: "#+begin_src swift\nprint(1)\n#+end_src",
      rendered: .source(language: "swift", lines: ["print(1)"])
    )
    let key = RenderedBlockExpansionState.key(
      sourceFile: "/tmp/example.org2",
      editableBlock: block,
      renderedKind: "source",
      rawText: block.rawText
    )
    let shiftedBlock = OrgEditableBlock(
      id: "source-block",
      startLine: 11,
      endLineExclusive: 14,
      rawText: block.rawText,
      rendered: block.rendered
    )
    let shiftedKey = RenderedBlockExpansionState.key(
      sourceFile: "/tmp/example.org2",
      editableBlock: shiftedBlock,
      renderedKind: "source",
      rawText: shiftedBlock.rawText
    )

    XCTAssertEqual(RenderedBlockExpansionState.visibleLimit(for: key, default: 80), 80)
    RenderedBlockExpansionState.setVisibleLimit(240, for: key)
    XCTAssertEqual(RenderedBlockExpansionState.visibleLimit(for: key, default: 80), 240)
    XCTAssertEqual(RenderedBlockExpansionState.visibleLimit(for: shiftedKey, default: 80), 80)
  }

  func testRenderedBlockExpansionStateComputesToggleLimits() {
    XCTAssertEqual(
      RenderedBlockExpansionState.toggledLimit(
        currentLimit: 80,
        totalCount: 300,
        hiddenCount: 220,
        defaultLimit: 80,
        pageSize: 160
      ),
      240
    )
    XCTAssertEqual(
      RenderedBlockExpansionState.toggledLimit(
        currentLimit: 240,
        totalCount: 300,
        hiddenCount: 60,
        defaultLimit: 80,
        pageSize: 160
      ),
      300
    )
    XCTAssertEqual(
      RenderedBlockExpansionState.toggledLimit(
        currentLimit: 300,
        totalCount: 300,
        hiddenCount: 0,
        defaultLimit: 80,
        pageSize: 160
      ),
      80
    )
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

  func testRenderedEntryOnlyMarksExecutableSourceBlocksRunnable() {
    let shell = OrgEditableBlock(
      startLine: 1,
      endLineExclusive: 4,
      rawText: "#+begin_src sh\necho hi\n#+end_src",
      rendered: .source(language: "sh", lines: ["echo hi"])
    )
    let unlabeled = OrgEditableBlock(
      startLine: 1,
      endLineExclusive: 4,
      rawText: "#+begin_src\nplain text\n#+end_src",
      rendered: .source(language: nil, lines: ["plain text"])
    )
    let unsupported = OrgEditableBlock(
      startLine: 1,
      endLineExclusive: 4,
      rawText: "#+begin_src mermaid\ngraph TD\n#+end_src",
      rendered: .source(language: "mermaid", lines: ["graph TD"])
    )
    let quote = OrgEditableBlock(
      startLine: 1,
      endLineExclusive: 4,
      rawText: "#+begin_quote\nplain text\n#+end_quote",
      rendered: .quote(["plain text"])
    )

    XCTAssertTrue(OrgRenderedEntryView.isRunnableSourceBlock(shell))
    XCTAssertFalse(OrgRenderedEntryView.isRunnableSourceBlock(unlabeled))
    XCTAssertFalse(OrgRenderedEntryView.isRunnableSourceBlock(unsupported))
    XCTAssertFalse(OrgRenderedEntryView.isRunnableSourceBlock(quote))
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
    store.selectedSurface = .agenda
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
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("https://example.com/image.png"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("[[file:../assets/diagram.png][System Diagram]]"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("[[https://example.com/image.png][Remote Image]]"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("https://youtu.be/dQw4w9WgXcQ"))
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

    let embedded = try XCTUnwrap(OrgMediaAttachment.embedded(
      in: "inline images [[file:../assets/diagram.png][Image]]",
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(embedded.displayText, "inline images")
    XCTAssertEqual(embedded.attachments.count, 1)
    XCTAssertEqual(embedded.attachments[0].kind, .image)
    XCTAssertEqual(embedded.attachments[0].displayName, "Image")
    XCTAssertEqual(embedded.attachments[0].resolvedPath, image.standardizedFileURL.path)

    XCTAssertNil(OrgMediaAttachment.embedded(
      in: "Not media [[id:11111111-1111-4111-8111-111111111111][Node]]",
      sourceFile: note.path,
      corpusRoot: root
    ))

    let remoteImage = try XCTUnwrap(OrgMediaAttachment.standalone(raw: "https://example.com/image.png"))
    XCTAssertEqual(remoteImage.kind, .image)
    XCTAssertEqual(remoteImage.target, "https://example.com/image.png")
    XCTAssertEqual(remoteImage.resolvedPath, nil)
    XCTAssertEqual(remoteImage.resolvedURL?.absoluteString, "https://example.com/image.png")

    let remoteVideoPage = try XCTUnwrap(OrgMediaAttachment.standalone(raw: "https://youtu.be/dQw4w9WgXcQ"))
    XCTAssertEqual(remoteVideoPage.kind, .video)
    XCTAssertEqual(remoteVideoPage.resolvedURL?.absoluteString, "https://youtu.be/dQw4w9WgXcQ")
  }

  func testRenderedInlineMediaPresentationUsesRawParagraphAndListText() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-inline-media-render-\(UUID().uuidString)", isDirectory: true)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let image = assets.appendingPathComponent("diagram.png")
    let note = root.appendingPathComponent("note.org2")
    try Data().write(to: image)
    try Data().write(to: note)

    let paragraphBlock = try XCTUnwrap(OrgEntryRenderer.parseEditable(
      "inline images [[file:assets/diagram.png][Image]]"
    ).first)
    let paragraphEmbedded = try XCTUnwrap(RenderedInlineMediaPresentation.embedded(
      raw: paragraphBlock.rawText,
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(paragraphEmbedded.displayText, "inline images")
    XCTAssertEqual(paragraphEmbedded.attachments.first?.resolvedPath, image.standardizedFileURL.path)

    let headingBlock = try XCTUnwrap(OrgEntryRenderer.parseEditable(
      "** inline images [[file:assets/diagram.png][Image]]"
    ).first)
    guard case .heading(let heading) = headingBlock.rendered else {
      return XCTFail("Expected heading")
    }
    let rawHeadingTitle = OrgRenderedLineDisplayCache.headingTitle(
      rawText: headingBlock.rawText,
      fallback: heading.title
    )
    let headingEmbedded = try XCTUnwrap(RenderedInlineMediaPresentation.headingTitle(
      rawTitle: rawHeadingTitle,
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(headingEmbedded.displayText, "inline images")
    XCTAssertEqual(headingEmbedded.attachments.first?.displayName, "Image")
    XCTAssertEqual(headingEmbedded.attachments.first?.resolvedPath, image.standardizedFileURL.path)

    let remoteHeadingEmbedded = try XCTUnwrap(RenderedInlineMediaPresentation.headingTitle(
      rawTitle: "inline images [[https://raw.githubusercontent.com/aviaviavi/org2/refs/heads/main/site/assets/favicon.png][Image]]",
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(remoteHeadingEmbedded.displayText, "inline images")
    XCTAssertEqual(remoteHeadingEmbedded.attachments.first?.kind, .image)
    XCTAssertEqual(remoteHeadingEmbedded.attachments.first?.displayName, "Image")
    XCTAssertEqual(
      remoteHeadingEmbedded.attachments.first?.resolvedURL?.absoluteString,
      "https://raw.githubusercontent.com/aviaviavi/org2/refs/heads/main/site/assets/favicon.png"
    )

    let listBlock = try XCTUnwrap(OrgEntryRenderer.parseEditable(
      "- inline images [[file:assets/diagram.png][Image]]"
    ).first)
    guard case .listItem(_, _, _, let renderedText) = listBlock.rendered else {
      return XCTFail("Expected list item")
    }
    let rawListText = OrgRenderedLineDisplayCache.listText(rawText: listBlock.rawText, fallback: renderedText)
    let listEmbedded = try XCTUnwrap(RenderedInlineMediaPresentation.embedded(
      raw: rawListText,
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(listEmbedded.displayText, "inline images")
    XCTAssertEqual(listEmbedded.attachments.first?.resolvedPath, image.standardizedFileURL.path)
  }

  func testParagraphEditorInlineMediaPreviewUsesLiveDraftText() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-inline-media-editor-\(UUID().uuidString)", isDirectory: true)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let image = assets.appendingPathComponent("diagram.png")
    let note = root.appendingPathComponent("note.org2")
    try Data().write(to: image)
    try Data().write(to: note)

    let preview = try XCTUnwrap(ParagraphEditorInlineMediaPreview.embedded(
      raw: "inline images [[file:assets/diagram.png][Image]]",
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(preview.displayText, "inline images")
    XCTAssertEqual(preview.attachments.first?.resolvedPath, image.standardizedFileURL.path)
    XCTAssertNil(ParagraphEditorInlineMediaPreview.embedded(
      raw: "inline images Image",
      sourceFile: note.path,
      corpusRoot: root
    ))
  }

  func testOrgCryptFindsPlaintextCryptSubtreesAndProperties() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let key = root.appendingPathComponent("keys/agent.asc")
    try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)

    let text = """
    * Public
    Body
    * Secret :crypt:
    :PROPERTIES:
    :CRYPT_RECIPIENTS: user@example.com, agent@example.com
    :CRYPT_RECIPIENT_FILE: keys/agent.asc
    :END:
    plaintext
    ** Child
    more
    * Already encrypted :crypt:
    -----BEGIN PGP MESSAGE-----
    abc
    -----END PGP MESSAGE-----
    """

    let targets = OrgCrypt.findPlaintextCryptSubtrees(in: text, file: note.path)

    XCTAssertEqual(targets.count, 1)
    XCTAssertEqual(targets[0].headingLine, 3)
    XCTAssertEqual(targets[0].bodyStartLine, 7)
    XCTAssertEqual(targets[0].endLine, 10)
    XCTAssertEqual(targets[0].recipients, ["user@example.com", "agent@example.com"])
    XCTAssertEqual(targets[0].recipientFiles, [key.standardizedFileURL.path])
  }

  func testOrgCryptArmorSummaryDetectsPGPBlocks() {
    let raw = """
    -----BEGIN PGP MESSAGE-----
    abc
    def
    -----END PGP MESSAGE-----
    """

    let summary = OrgCrypt.armorSummary(raw)

    XCTAssertEqual(summary?.lineCount, 4)
    XCTAssertEqual(summary?.payloadLineCount, 2)
    XCTAssertEqual(summary?.byteCount, Data(raw.utf8).count)
    XCTAssertNil(OrgCrypt.armorSummary("not encrypted"))
  }

  func testEncryptedRenderedBlockTargetsOwningHeadingAndDoesNotSingleClickEdit() {
    let heading = OrgEditableBlock(
      id: "heading",
      startLine: 10,
      endLineExclusive: 11,
      rawText: "* Secret :crypt:",
      rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Secret", tags: ["crypt"]))
    )
    let armorRaw = """
    -----BEGIN PGP MESSAGE-----
    abc
    -----END PGP MESSAGE-----
    """
    let armor = OrgEditableBlock(
      id: "armor",
      startLine: 11,
      endLineExclusive: 14,
      rawText: armorRaw,
      rendered: .paragraph(armorRaw)
    )

    XCTAssertEqual(OrgRenderedCryptTarget.headingLine(for: armor, in: [heading, armor]), 10)
    XCTAssertFalse(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: armor, isSourceEditable: true))
    XCTAssertFalse(RenderedBlockInteractionPolicy.usesRowTapGestures(block: armor, isSourceEditable: true))
    XCTAssertFalse(RenderedBlockInteractionPolicy.showsRowChrome(for: armor))
  }

  func testOrgCryptEncryptionTimesOutNonInteractiveGPG() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-timeout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    sleep 5
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)

    let text = """
    * Secret :crypt:
    plaintext
    """
    let settings = OrgCryptSettings(
      recipients: ["person@example.com"],
      gpgProgram: fakeGPG.path,
      gpgTimeout: 0.2
    )

    XCTAssertThrowsError(try OrgCrypt.encryptPlaintextCryptSubtrees(in: text, file: note.path, settings: settings)) { error in
      guard case OrgCryptError.gpgTimedOut = error else {
        return XCTFail("Expected gpg timeout, got \(error)")
      }
    }
  }

  func testOrgCryptUsesDefaultGPGKeyRecipientWhenConfigured() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-default-key-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let argsLog = root.appendingPathComponent("gpg-args.txt")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    let fakeGPGConf = root.appendingPathComponent("gpgconf")
    try """
    #!/bin/sh
    printf '%s\\n' "$@" > "\(argsLog.path)"
    cat >/dev/null
    printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'fake encrypted payload' '-----END PGP MESSAGE-----'
    exit 0
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try """
    #!/bin/sh
    printf '%s\\n' 'default-key:0:0:use NAME as default secret key:1:1:NAME:::"self-key'
    exit 0
    """.write(to: fakeGPGConf, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPGConf.path)

    let text = """
    * Secret :crypt:
    plaintext
    """
    let settings = OrgCryptSettings(
      gpgProgram: fakeGPG.path,
      gpgTimeout: 2,
      useDefaultGpgKey: true
    )

    let result = try OrgCrypt.encryptPlaintextCryptSubtrees(in: text, file: note.path, settings: settings)

    XCTAssertEqual(result.encryptedCount, 1)
    XCTAssertTrue(result.text.contains("fake encrypted payload"))
    let args = try String(contentsOf: argsLog, encoding: .utf8)
    XCTAssertTrue(args.contains("--encrypt\n"))
    XCTAssertTrue(args.contains("--recipient\nself-key\n"))
    XCTAssertFalse(args.contains("--default-recipient-self\n"))
  }

  func testOrgCryptUsesExplicitRecipientWhenDefaultGPGKeyIsUnavailable() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-explicit-recipient-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let argsLog = root.appendingPathComponent("gpg-args.txt")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    printf '%s\\n' "$@" > "\(argsLog.path)"
    cat >/dev/null
    printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'fake encrypted payload' '-----END PGP MESSAGE-----'
    exit 0
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)

    let text = """
    * Secret :crypt:
    plaintext
    """
    let settings = OrgCryptSettings(
      recipients: ["person@example.com"],
      gpgProgram: fakeGPG.path,
      gpgTimeout: 2,
      useDefaultGpgKey: true
    )

    let result = try OrgCrypt.encryptPlaintextCryptSubtrees(in: text, file: note.path, settings: settings)

    XCTAssertEqual(result.encryptedCount, 1)
    XCTAssertTrue(result.text.contains("fake encrypted payload"))
    let args = try String(contentsOf: argsLog, encoding: .utf8)
    XCTAssertTrue(args.contains("--encrypt\n"))
    XCTAssertTrue(args.contains("--recipient\nperson@example.com\n"))
    XCTAssertFalse(args.contains("--recipient\nself-key\n"))
  }

  func testCanonicalEditableRenderCoalescesSplitPGPArmorBlocks() throws {
    let raw = """
    * Secret :crypt:
    -----BEGIN PGP MESSAGE-----
    abc
    -----END PGP MESSAGE-----
    """
    let json = """
    {
      "type": "Document",
      "version": "test",
      "children": [
        {
          "type": "Headline",
          "level": 1,
          "todo": null,
          "tags": ["crypt"],
          "title": [{ "type": "Text", "value": "Secret" }],
          "sourceRange": { "startLine": 1, "endLine": 1 },
          "children": [
            {
              "type": "Paragraph",
              "children": [{ "type": "Text", "value": "-----BEGIN PGP MESSAGE-----" }],
              "sourceRange": { "startLine": 2, "endLine": 2 }
            },
            {
              "type": "Paragraph",
              "children": [{ "type": "Text", "value": "abc" }],
              "sourceRange": { "startLine": 3, "endLine": 3 }
            },
            {
              "type": "Paragraph",
              "children": [{ "type": "Text", "value": "-----END PGP MESSAGE-----" }],
              "sourceRange": { "startLine": 4, "endLine": 4 }
            }
          ]
        }
      ]
    }
    """
    let document = try JSONDecoder().decode(Org2CanonicalDocument.self, from: Data(json.utf8))

    let blocks = OrgEntryRenderer.parseEditable(raw, canonicalDocument: document)

    let encrypted = blocks.filter { OrgCrypt.armorSummary($0.rawText) != nil }
    XCTAssertEqual(encrypted.count, 1)
    XCTAssertEqual(encrypted.first?.startLine, 2)
    XCTAssertEqual(encrypted.first?.endLineExclusive, 5)
  }

  @MainActor
  func testRunOrgCryptDecryptRewritesSelectedFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-decrypt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    if printf '%s\\n' "$@" | grep -q -- '--decrypt'; then
      cat >/dev/null
      printf '%s\\n' 'plaintext'
      exit 0
    fi
    printf '%s\\n' 'unexpected gpg action' >&2
    exit 2
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    try """
    * Secret :crypt:
    -----BEGIN PGP MESSAGE-----
    fake encrypted payload
    -----END PGP MESSAGE-----
    * Public
    body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptGpgProgram = fakeGPG.path
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))

    let result = await store.runOrgCrypt(.decrypt, line: 1)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(result.succeeded)
    XCTAssertTrue(result.changed)
    XCTAssertEqual(result.headingLine, 1)
    XCTAssertTrue(updated.contains("* Secret :crypt:\nplaintext"))
    XCTAssertFalse(updated.contains("-----BEGIN PGP MESSAGE-----"))
    XCTAssertTrue(updated.contains("* Public\nbody"))
  }

  @MainActor
  func testRunOrgCryptDecryptReturnsGPGFailureMessage() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-decrypt-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    cat >/dev/null
    printf '%s\\n' 'gpg: decryption failed: No secret key' >&2
    exit 2
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    let original = """
    * Secret :crypt:
    -----BEGIN PGP MESSAGE-----
    fake encrypted payload
    -----END PGP MESSAGE-----
    """
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptGpgProgram = fakeGPG.path
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))

    let result = await store.runOrgCrypt(.decrypt, line: 1)

    XCTAssertFalse(result.succeeded)
    XCTAssertFalse(result.changed)
    XCTAssertTrue(result.message.contains("No secret key"))
    XCTAssertEqual(store.statusText, result.message)
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), original)
  }

  @MainActor
  func testSaveCurrentFileEncryptsPlaintextCryptSubtreesWithoutActiveEdit() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-save-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    cat >/dev/null
    printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'fake encrypted payload' '-----END PGP MESSAGE-----'
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    try """
    * Secret :crypt:
    plaintext
    * Public
    body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptRecipientsText = "person@example.com"
    store.orgCryptGpgProgram = fakeGPG.path
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected file")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    XCTAssertFalse(store.hasActiveEdit)
    XCTAssertTrue(store.canSaveCurrentFile)

    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* Secret :crypt:\n-----BEGIN PGP MESSAGE-----"))
    XCTAssertTrue(updated.contains("fake encrypted payload"))
    XCTAssertFalse(updated.contains("* Secret :crypt:\nplaintext"))
    XCTAssertTrue(updated.contains("* Public\nbody"))
    XCTAssertEqual(store.statusText, "Encrypted 1 subtree")
  }

  @MainActor
  func testSaveCurrentFileEncryptsMultipleCryptSubtreesIncludingFinalBlock() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-save-multiple-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    input=$(cat)
    if printf '%s' "$input" | grep -q 'first secret'; then
      printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'encrypted alpha payload' '-----END PGP MESSAGE-----'
    else
      printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'encrypted beta payload' '-----END PGP MESSAGE-----'
    fi
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    let original = """
    * First :crypt:
    first secret
    * Public
    body
    * Second :crypt:
    second secret
    """ + "\n"
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptRecipientsText = "person@example.com"
    store.orgCryptGpgProgram = fakeGPG.path
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected file")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* First :crypt:\n-----BEGIN PGP MESSAGE-----\nencrypted alpha payload\n-----END PGP MESSAGE-----"))
    XCTAssertTrue(updated.contains("* Public\nbody"))
    XCTAssertTrue(updated.contains("* Second :crypt:\n-----BEGIN PGP MESSAGE-----\nencrypted beta payload\n-----END PGP MESSAGE-----\n"))
    XCTAssertFalse(updated.contains("first secret"))
    XCTAssertFalse(updated.contains("second secret"))
    XCTAssertTrue(updated.hasSuffix("\n"))
    XCTAssertEqual(store.statusText, "Encrypted 2 subtrees")
  }

  @MainActor
  func testAddingCryptTagToHeadingEncryptsSubtreeOnSave() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-heading-tag-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    cat >/dev/null
    printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'fake encrypted payload' '-----END PGP MESSAGE-----'
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    try """
    * Secret
    plaintext
    * Public
    body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptRecipientsText = "person@example.com"
    store.orgCryptGpgProgram = fakeGPG.path
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected file")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered {
        return heading.title == "Secret"
      }
      return false
    })
    await store.setHeadingTags(heading, tags: ["crypt"])

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* Secret :crypt:\n-----BEGIN PGP MESSAGE-----"))
    XCTAssertTrue(updated.contains("fake encrypted payload"))
    XCTAssertFalse(updated.contains("* Secret :crypt:\nplaintext"))
    XCTAssertTrue(updated.contains("* Public\nbody"))
    XCTAssertEqual(store.statusText, "Saved and encrypted 1 subtree")
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
    XCTAssertTrue(OrgMediaAttachmentRenderCache.shouldAttemptStandaloneLookup(
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

    let remote = try XCTUnwrap(OrgEditableMediaLink(rawText: "[[https://example.com/diagram.png][Diagram]]"))
    XCTAssertEqual(remote.kind, .image)
    XCTAssertEqual(remote.target, "https://example.com/diagram.png")
    XCTAssertEqual(remote.formattedRawText, "[[https://example.com/diagram.png][Diagram]]")

    XCTAssertEqual(
      OrgEditableMediaLink(kind: .image, target: "file:https://example.com/diagram.png", label: "Diagram").formattedRawText,
      "[[https://example.com/diagram.png][Diagram]]"
    )
  }

  func testMediaAttachmentInfersKindFromTargets() {
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "images/diagram.webp"), .image)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "https://example.com/diagram.webp?raw=1"), .image)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "file:clips/demo.webm"), .video)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "https://example.com/demo.mp4"), .video)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), .video)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "/tmp/movie.MP4#clip"), .video)
    XCTAssertNil(OrgMediaAttachment.kind(forTarget: "notes/project.org2"))
  }

  func testRenderedMediaDoesNotAutoloadVideoPlayers() {
    XCTAssertFalse(RenderedMediaPreviewPolicy.autoloadsVideoPlayerOnAppear)
  }

  @MainActor
  func testAgentHandoffShortcutAssignsTempNoteWithoutChangingTodoState() async throws {
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
    XCTAssertTrue(updated.contains("* TODO Send to agent"))
    XCTAssertFalse(updated.contains("* DONE Send to agent"))
    XCTAssertTrue(updated.contains(":ASSIGNEE: OpenClaw"))
    XCTAssertTrue(updated.contains(":STATUS: ready"))
    XCTAssertTrue(updated.contains(":ASSIGNED_AT: <"))
  }

  @MainActor
  func testApproveAndAgentHandoffCompletesApprovalAndCreatesSendTodo() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-approve-handoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("approve-handoff.org2")
    try """
    * TODO Approve reply to Maya / Oracle supplier onboarding details
    SCHEDULED: <2026-06-16 Tue>
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: draft-needs-review
    :END:

    Draft body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Approve reply to Maya / Oracle supplier onboarding details",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Draft body",
      "level": 1,
      "tags": [],
      "properties": {
        "ASSIGNEE": "Avi",
        "STATUS": "draft-needs-review"
      }
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))

    await store.applyApproveAndAgentHandoffShortcut()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertNil(store.errorText, store.statusText)
    XCTAssertTrue(updated.contains("* DONE Approve reply to Maya / Oracle supplier onboarding details"))
    XCTAssertTrue(updated.contains(":STATUS: approved"))
    XCTAssertTrue(updated.contains(":APPROVED_AT: <"))
    XCTAssertTrue(updated.contains(":PAIRED_SEND_TODO: Send approved reply to Maya / Oracle supplier onboarding details"))
    XCTAssertTrue(updated.contains("* TODO Send approved reply to Maya / Oracle supplier onboarding details"))
    XCTAssertTrue(updated.contains(":ASSIGNEE: OpenClaw"))
    XCTAssertTrue(updated.contains(":STATUS: approved-to-send"))
    XCTAssertTrue(updated.contains(":APPROVAL_TODO: Approve reply to Maya / Oracle supplier onboarding details"))
  }

  @MainActor
  func testApproveAndAgentHandoffActivatesExistingPairedSendTodo() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-approve-existing-handoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("approve-existing-handoff.org2")
    try """
    * TODO Approve reply to Maya / Oracle supplier onboarding details
    SCHEDULED: <2026-06-16 Tue>
    :PROPERTIES:
    :ASSIGNEE: Avi
    :PAIRED_SEND_TODO: Send approved reply to Maya / Oracle supplier onboarding details
    :STATUS: draft-needs-review
    :END:

    Draft body

    * TODO Send approved reply to Maya / Oracle supplier onboarding details
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: blocked
    :END:
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Approve reply to Maya / Oracle supplier onboarding details",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Draft body",
      "level": 1,
      "tags": [],
      "properties": {
        "ASSIGNEE": "Avi",
        "PAIRED_SEND_TODO": "Send approved reply to Maya / Oracle supplier onboarding details",
        "STATUS": "draft-needs-review"
      }
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))

    await store.applyApproveAndAgentHandoffShortcut()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertNil(store.errorText, store.statusText)
    XCTAssertTrue(updated.contains("* DONE Approve reply to Maya / Oracle supplier onboarding details"))
    XCTAssertEqual(
      updated.components(separatedBy: "* TODO Send approved reply to Maya / Oracle supplier onboarding details").count - 1,
      1
    )
    XCTAssertTrue(updated.contains(":ASSIGNEE: OpenClaw"))
    XCTAssertTrue(updated.contains(":STATUS: approved-to-send"))
    XCTAssertTrue(updated.contains(":APPROVAL_TODO: Approve reply to Maya / Oracle supplier onboarding details"))
  }

  @MainActor
  func testRejectApprovalRecordsEndStatusAndReason() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-reject-approval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("reject-approval.org2")
    try """
    * TODO Approve reply to Maya / Oracle supplier onboarding details
    SCHEDULED: <2026-06-16 Tue>
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: draft-needs-review
    :END:

    Draft body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Approve reply to Maya / Oracle supplier onboarding details",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Draft body",
      "level": 1,
      "tags": [],
      "properties": {
        "ASSIGNEE": "Avi",
        "STATUS": "draft-needs-review"
      }
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))

    await store.applyRejectApprovalShortcut(endStatus: .canceled, reason: "Not the right reply\nneeds a rewrite")

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertNil(store.errorText, store.statusText)
    XCTAssertTrue(updated.contains("* CANCELED Approve reply to Maya / Oracle supplier onboarding details"))
    XCTAssertTrue(updated.contains(":STATUS: rejected"))
    XCTAssertTrue(updated.contains(":REJECTED_AT: <"))
    XCTAssertTrue(updated.contains(":REJECTION_END_STATUS: CANCELED"))
    XCTAssertTrue(updated.contains(":REJECTION_REASON: Not the right reply needs a rewrite"))
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
  func testDetailEntryOrganizeControlsMutateSelectedTodoOutsideAgenda() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-detail-organize-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("detail.org2")
    try """
    #+TITLE: Detail

    * TODO Review from search
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let result = SearchResult(
      file: note.path,
      line: 3,
      lineEnd: nil,
      heading: "Review from search",
      headingLine: 3,
      headingLevel: 1,
      headingAncestry: nil,
      idValue: nil,
      todo: "TODO",
      tags: [],
      snippet: "Review from search",
      sourceRange: nil,
      matchedLines: nil,
      date: nil
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedSurface = .search
    store.select(.search(result))
    await store.loadEntrySource(for: .search(result))
    try await waitForEntryRender(store)

    XCTAssertTrue(store.canOrganizeCurrentHeadline)

    await store.applyPriorityShortcut("A")
    await store.applyPlanningShortcut(kind: .deadline, target: .today)
    await store.applyTodoShortcut(.inProgress)
    await store.applyPropertyShortcut(key: "OWNER", value: "agent")

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())
    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* IN_PROGRESS [#A] Review from search"))
    XCTAssertTrue(updated.contains("DEADLINE: <\(today)"))
    XCTAssertTrue(updated.contains(":OWNER: agent"))
  }

  @MainActor
  func testSimilarTodoAssignmentBulkAssignsBacklogAndPromptsOpenClaw() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-similar-todos-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("contacts.org2")
    try """
    * TODO find valid contact for Acme
    Body

    * TODO find valid contact for Beta Inc
    Body

    * TODO Schedule Beta review
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let result = SearchResult(
      file: note.path,
      line: 1,
      lineEnd: nil,
      heading: "find valid contact for Acme",
      headingLine: 1,
      headingLevel: 1,
      headingAncestry: nil,
      idValue: nil,
      todo: "TODO",
      tags: [],
      snippet: "find valid contact for Acme",
      sourceRange: nil,
      matchedLines: nil,
      date: nil
    )
    let recorder = OpenClawQueuedSendRecorder()
    let defaultsSuiteName = "org2-workspace-similar-todos-defaults-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsSuiteName)!
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.setCorpusRoot(root)
    store.selectedSurface = .search
    store.select(.search(result))
    await store.loadEntrySource(for: .search(result))
    try await waitForEntryRender(store)

    store.presentSimilarTodoAssignment()

    XCTAssertTrue(store.isSimilarTodoAssignmentPresented)
    XCTAssertEqual(store.similarTodoCandidates.map(\.headline), [
      "find valid contact for Acme",
      "find valid contact for Beta Inc"
    ])
    XCTAssertTrue(store.similarTodoPattern.contains("find valid contact for"))
    XCTAssertEqual(store.similarTodoAssignee, "OpenClaw")

    store.similarTodoAssignee = "contact-finder"
    store.similarTodoStatus = "ready"
    await store.assignSimilarTodos(askOpenClaw: true)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertEqual(updated.components(separatedBy: ":ASSIGNEE: contact-finder").count - 1, 2)
    XCTAssertEqual(updated.components(separatedBy: ":STATUS: ready").count - 1, 2)
    XCTAssertEqual(updated.components(separatedBy: ":ASSIGNED_AT: <").count - 1, 2)
    XCTAssertEqual(store.assignedWorkItems.map(\.headline), [
      "find valid contact for Acme",
      "find valid contact for Beta Inc"
    ])
    XCTAssertEqual(store.assignedWorkSections.map(\.label), ["contact-finder / TODO"])

    let calls = await recorder.recordedCalls()
    let prompt = try XCTUnwrap(calls.last?.last)
    XCTAssertTrue(prompt.contains("Assignee: contact-finder"))
    XCTAssertTrue(prompt.contains("\(note.path):1"))
    XCTAssertTrue(prompt.contains("\(note.path):4"))
    XCTAssertTrue(prompt.contains("Do not create a separate runner"))
  }

  @MainActor
  func testAssignedWorkSectionsGroupByAssigneeAndTodoKeyword() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-assigned-sections-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("assigned.org2")
    try """
    * TODO Draft first reply
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: draft-needs-review
    :END:

    * TODO Draft second reply
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: needs-avi
    :END:

    * DONE Send finished reply
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: done
    :END:
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshCorpusFiles()
    await store.refreshAssignedWork()

    XCTAssertEqual(store.assignedWorkSections.map(\.label), [
      "Avi / DONE",
      "Avi / TODO"
    ])
    XCTAssertEqual(store.assignedWorkSections.first { $0.label == "Avi / TODO" }?.items.count, 2)

    store.agendaFilter = "second"

    XCTAssertEqual(store.assignedWorkSections.map(\.label), ["Avi / TODO"])
    XCTAssertEqual(store.assignedWorkSections[0].items.map(\.headline), ["Draft second reply"])
  }

  @MainActor
  func testPageRenderOrganizeControlsUseSelectedRenderedHeading() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-organize-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("page.org2")
    try """
    * TODO First
    Body

    * TODO Second
    More
    """.write(to: note, atomically: true, encoding: .utf8)

    let result = SearchResult(
      file: note.path,
      line: 1,
      lineEnd: nil,
      heading: "First",
      headingLine: 1,
      headingLevel: 1,
      headingAncestry: nil,
      idValue: nil,
      todo: "TODO",
      tags: [],
      snippet: "First",
      sourceRange: nil,
      matchedLines: nil,
      date: nil
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedSurface = .search
    store.select(.search(result))
    store.selectedEntrySourceMode = .page
    await store.reloadSelectedEntrySource()
    try await waitForEntryRender(store)

    let second = try XCTUnwrap(store.selectedRenderedBlocks.first { block in
      if case .heading(let heading) = block.rendered {
        return heading.title == "Second"
      }
      return false
    })
    store.selectBlock(second)
    XCTAssertTrue(store.canOrganizeCurrentHeadline)

    await store.applyPriorityShortcut("B")
    await store.applyTodoShortcut(.done)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO First"))
    XCTAssertTrue(updated.contains("* DONE [#B] Second"))
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
  func testGlobalCaptureDraftWritesMetadataAndAttachments() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-global-capture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let source = root.appendingPathComponent("clip.txt")
    try "source text".write(to: source, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    let calendar = Calendar(identifier: .gregorian)
    let scheduled = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    let deadline = calendar.date(from: DateComponents(year: 2026, month: 6, day: 20))!

    await store.submitCaptureDraft(WorkspaceCaptureDraft(
      kind: .task,
      title: "Ship capture modal",
      body: "Handle pasted media.",
      todoStatus: .inProgress,
      includeScheduled: true,
      scheduledDate: scheduled,
      includeDeadline: true,
      deadlineDate: deadline,
      priority: "a",
      tagsText: "mac capture",
      assignToAgent: true,
      attachments: [
        WorkspaceCaptureAttachmentDraft(
          kind: .file,
          name: "clip.txt",
          sourceURL: source,
          suggestedExtension: "txt"
        )
      ]
    ))

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    let daily = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent("\(formatter.string(from: Date())).org2")
    let updated = try String(contentsOf: daily, encoding: .utf8)
    XCTAssertTrue(updated.contains("* IN_PROGRESS [#A] Ship capture modal :capture:mac:"))
    XCTAssertTrue(updated.contains("SCHEDULED: <2026-06-15"))
    XCTAssertTrue(updated.contains("DEADLINE: <2026-06-20"))
    XCTAssertTrue(updated.contains(":CAPTURED_AT: <"))
    XCTAssertTrue(updated.contains(":ASSIGNEE: OpenClaw"))
    XCTAssertTrue(updated.contains(":STATUS: ready"))
    XCTAssertTrue(updated.contains(":ASSIGNED_AT: <"))
    XCTAssertTrue(updated.contains("Handle pasted media."))
    XCTAssertTrue(updated.contains("[[file:attachments/"))
    XCTAssertTrue(updated.contains("][clip.txt]]"))

    let attachments = root.appendingPathComponent("attachments", isDirectory: true)
    let copied = try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil)
    XCTAssertEqual(copied.count, 1)
    XCTAssertEqual(try String(contentsOf: copied[0], encoding: .utf8), "source text")
  }

  @MainActor
  func testCreateKnowledgeNodeUsesConfiguredIndexDir() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-knowledge-node-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"indexDir":"knowledge"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.createKnowledgeNode(title: "Project Notes")

    let node = root
      .appendingPathComponent("knowledge", isDirectory: true)
      .appendingPathComponent("project-notes.org2")
    let text = try String(contentsOf: node, encoding: .utf8)
    XCTAssertTrue(text.contains("#+TITLE: Project Notes"))
    XCTAssertTrue(text.contains(":ID: "))
  }

  func testInlineSelectionBacklinkReplacementWrapsSelectedText() {
    let text = "Ask Docker about usage"
    let range = (text as NSString).range(of: "Docker")
    let edit = WorkspaceStore.backlinkReplacementForSelectedText(in: text, range: range)

    XCTAssertEqual(edit?.text, "Ask [[Docker]] about usage")
    XCTAssertEqual(edit?.selectedRange.location, range.location)
    XCTAssertEqual(edit?.selectedRange.length, ("[[Docker]]" as NSString).length)
  }

  @MainActor
  func testCreateKnowledgeNodeFromSelectionCreatesNodeAndIdLink() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-selection-node-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"indexDir":"knowledge"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)
    let source = root.appendingPathComponent("source.org2")
    try """
    #+TITLE: Source

    * Source
    Ask Docker about usage.
    """.write(to: source, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.openClaw(OpenClawThread(
      title: "Source",
      file: source.path,
      line: 3,
      zone: "test",
      modifiedAt: nil
    )))

    let text = "Ask Docker about usage."
    let range = (text as NSString).range(of: "Docker")
    let edit = await store.createKnowledgeNodeFromSelection(text: text, range: range)

    let node = root
      .appendingPathComponent("knowledge", isDirectory: true)
      .appendingPathComponent("docker.org2")
    let nodeText = try String(contentsOf: node, encoding: .utf8)
    let idMatch = try XCTUnwrap(nodeText.range(of: #":ID:\s+([A-Fa-f0-9-]+)"#, options: .regularExpression))
    let idLine = String(nodeText[idMatch])
    let id = try XCTUnwrap(idLine.split(separator: " ").last.map(String.init))

    XCTAssertEqual(edit?.text, "Ask [[id:\(id)][Docker]] about usage.")
    XCTAssertTrue(nodeText.contains("#+TITLE: Docker"))
    XCTAssertTrue(nodeText.contains("Origin: [[file:source.org2][Source]]"))
  }

  @MainActor
  func testLinkifyCurrentFileRunsRoamLinkifyOnSelectedFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-linkify-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let node = root.appendingPathComponent("docker.org2")
    let note = root.appendingPathComponent("note.org2")
    try """
    #+TITLE: Docker
    :PROPERTIES:
    :ID: docker-id
    :END:
    """.write(to: node, atomically: true, encoding: .utf8)
    try """
    #+TITLE: Note

    * Note
    Docker usage should become linked.
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.openClaw(OpenClawThread(
      title: "Note",
      file: note.path,
      line: 3,
      zone: "test",
      modifiedAt: nil
    )))

    await store.linkifyCurrentFile()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("[[id:docker-id][Docker]] usage should become linked."))
    XCTAssertTrue(store.statusText.contains("Linkified note.org2"))
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
  func testStaleEntrySourceLoadWithSameFileAndLineDoesNotReplaceSelectedAgendaItem() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-stale-entry-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda.org2")
    try """
    * TODO First stale item
    SCHEDULED: <2026-06-15 Mon>

    * TODO Selected fresh item
    SCHEDULED: <2026-06-15 Mon>
    """.write(to: note, atomically: true, encoding: .utf8)

    let stale = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": "TODO",
      "headline": "First stale item",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 0,
      "body": null,
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """.utf8))
    let selected = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": "TODO",
      "headline": "Selected fresh item",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 0,
      "body": null,
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """.utf8))

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedLocation = .agenda(selected)

    await store.loadEntrySource(for: .agenda(stale))

    XCTAssertNil(store.selectedEntrySource)
    guard case .agenda(let item)? = store.selectedLocation else {
      return XCTFail("Expected selected agenda location")
    }
    XCTAssertEqual(item.headline, "Selected fresh item")
  }

  @MainActor
  func testPageScopeEditSavesNewHeadingInDailyNote() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("2026-06-13.org2")
    try """
    #+TITLE: 2026-06-13

    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected daily note")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    store.beginEditingCurrentScope()
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertNil(store.editingBlockID)

    store.editableEntryText += "\n* Quick note\nSome body\n"
    await store.saveActiveEdit()
    try await waitForEntryRender(store)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* Quick note\nSome body"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertTrue(store.selectedRenderedBlocks.contains {
      if case .heading(let heading) = $0.rendered {
        return heading.title == "Quick note"
      }
      return false
    })
  }

  @MainActor
  func testFileTabSelectionUsesLiveFileEditorBufferWithoutLegacyEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-live-file-editor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("live.org2")
    try """
    #+TITLE: Live Editor

    * First
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected note")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    XCTAssertTrue(store.isLiveFileEditorSelected)
    XCTAssertTrue(store.isLiveFileEditorAvailable)
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertFalse(store.hasActiveEdit)
    XCTAssertEqual(store.editableEntryText, store.selectedEntrySource?.text)
    XCTAssertTrue(store.canSaveCurrentFile)
  }

  @MainActor
  func testLiveFileEditorSaveKeepsLiveEditorAvailable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-live-file-save-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("live-save.org2")
    try """
    #+TITLE: Live Save

    * First
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected note")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    store.editableEntryText = store.editableEntryText.replacingOccurrences(of: "Body", with: "Edited body")
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Edited body"))
    XCTAssertTrue(store.isLiveFileEditorAvailable)
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertFalse(store.hasActiveEdit)
    XCTAssertEqual(store.selectedEntrySource?.text, store.editableEntryText)
    XCTAssertEqual(store.liveFileEditorStatusText, "Saved")
  }

  @MainActor
  func testPageScopeEditRefusesStaleDailyNoteWhenSyncedContentTouchesLoadedRange() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-stale-save-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("2026-06-13.org2")
    try """
    #+TITLE: 2026-06-13

    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected daily note")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    store.beginEditingCurrentScope()
    XCTAssertTrue(store.isEditingEntry)

    try """
    #+TITLE: 2026-06-13 synced

    * Phone note
    Synced from mobile.
    """.write(to: note, atomically: true, encoding: .utf8)

    store.editableEntryText += "\n* Mac note\nShould not overwrite phone note.\n"
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("#+TITLE: 2026-06-13 synced"))
    XCTAssertTrue(updated.contains("* Phone note\nSynced from mobile."))
    XCTAssertFalse(updated.contains("* Mac note"))
    XCTAssertEqual(store.statusText, "Save failed")
    XCTAssertTrue(store.errorText?.contains("File changed on disk") == true)
  }

  @MainActor
  func testBlankPageClickStartsParagraphDraftAtEndOfDailyNote() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-blank-click-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("2026-06-16.org2")
    try """
    #+TITLE: 2026-06-16

    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    await store.beginAppendingSectionAtEnd()

    XCTAssertFalse(store.isEditingEntry)
    XCTAssertNotNil(store.editingBlockID)
    XCTAssertEqual(store.editableBlockText, "")
    store.editableBlockText = "Meeting notes"
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Meeting notes"))
    XCTAssertFalse(store.hasActiveEdit)
  }

  @MainActor
  func testBlankPageParagraphDraftCommitsWhenReturnStartsNextDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-blank-return-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("2026-06-16.org2")
    try """
    #+TITLE: 2026-06-16

    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    await store.beginAppendingSectionAtEnd()
    let draft = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "Meeting notes"

    await store.splitEditingBlock(draft, atUTF16Offset: ("Meeting notes" as NSString).length)
    try await waitForCondition {
      (try? String(contentsOf: note, encoding: .utf8).contains("Meeting notes")) == true
        && store.hasActiveEdit
    }

    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Meeting notes"))
    XCTAssertFalse(store.hasActiveEdit)
  }

  @MainActor
  func testPageScopeSaveCompletesWhenOrgCryptEncryptionFails() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-crypt-save-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    try """
    #+TITLE: Secrets

    * Secret :crypt:
    plaintext
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptRecipientsText = "person@example.com"
    store.orgCryptGpgProgram = "/bin/false"
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected file")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    store.beginEditingCurrentScope()
    store.editableEntryText = store.editableEntryText.replacingOccurrences(of: "plaintext", with: "changed plaintext")
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("changed plaintext"))
    XCTAssertFalse(updated.contains("-----BEGIN PGP MESSAGE-----"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.statusText, "Saved, but encryption failed")
    XCTAssertTrue(store.errorText?.contains("Encryption failed") == true)
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
  func testUndoRestoresLiveFileEditorAutosaveAndRedoReappliesIt() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-live-undo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("live-undo.org2")
    let original = """
    #+TITLE: Live Undo

    * Meetings
    Original body
    """
    let updated = """
    #+TITLE: Live Undo

    * Meetings
    Updated body
    """
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)
    XCTAssertTrue(store.isLiveFileEditorSelected)

    store.noteLiveFileEditorTextChanged(updated)
    await store.saveLiveFileEditor(explicit: false)
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), updated)

    store.performUndoCommand()
    try await waitForCondition {
      (try? String(contentsOf: note, encoding: .utf8)) == original
        && store.selectedEntrySource?.text == original
    }
    XCTAssertEqual(store.statusText, "Undid edit in live-undo.org2")

    store.performRedoCommand()
    try await waitForCondition {
      (try? String(contentsOf: note, encoding: .utf8)) == updated
        && store.selectedEntrySource?.text == updated
    }
    XCTAssertEqual(store.statusText, "Redid edit in live-undo.org2")
  }

  @MainActor
  func testUndoRestoresSavedRenderedBlockChange() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-undo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-undo.org2")
    let original = """
    #+TITLE: Block Undo

    * Parent
    Original body
    * Sibling
    Sibling body
    """
    try original.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": null,
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Original body",
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
    store.updateEditingBlockDraft(paragraph, draft: "Updated body")
    await store.saveActiveEdit()
    XCTAssertTrue((try String(contentsOf: note, encoding: .utf8)).contains("Updated body"))

    store.performUndoCommand()
    try await waitForCondition {
      (try? String(contentsOf: note, encoding: .utf8)) == original
        && store.selectedRenderedBlocks.contains { block in
          if case .paragraph(let text) = block.rendered {
            return text == "Original body"
          }
          return false
        }
    }
    XCTAssertEqual(store.statusText, "Undid edit in block-undo.org2")
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
    try await waitForCondition(timeout: 5) {
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
  func testReturnAfterTypingHeadingInEmptyDraftStartsEmptyDraftWithoutReusingEditorState() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-return-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-return.org2")
    try "".write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    await store.beginAppendingSectionAtEnd()
    let originalDraft = try XCTUnwrap(store.selectedBlock)
    XCTAssertEqual(originalDraft.rawText, "")

    let typedHeading = "* testing this 123"
    store.updateEditingBlockDraft(originalDraft, draft: typedHeading)
    await store.splitEditingBlock(
      originalDraft,
      atUTF16Offset: (typedHeading as NSString).length,
      draftText: typedHeading
    )

    try await waitForCondition {
      store.selectedBlock?.rawText == ""
        && store.selectedBlock?.id != originalDraft.id
        && store.selectedRenderedBlocks.filter { $0.rawText == typedHeading }.count == 1
    }
    let nextDraft = try XCTUnwrap(store.selectedBlock)
    XCTAssertEqual(nextDraft.rawText, "")
    XCTAssertNotEqual(nextDraft.id, originalDraft.id)
    XCTAssertEqual(
      store.selectedRenderedBlocks.filter { $0.rawText == typedHeading }.count,
      1
    )

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertEqual(updated.components(separatedBy: typedHeading).count - 1, 1)
    XCTAssertTrue(updated.contains(typedHeading))
  }

  @MainActor
  func testSavesInsertedParagraphDraftPublishedFromEditor() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-paragraph-insert-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("paragraph-insert-draft.org2")
    try """
    #+TITLE: Paragraph Insert Draft Test

    * TODO Parent
    https://x.com/sdhilip/status/2069140867466797200?s=46&t=8JLnk5l_ZQz2KJfqZ5W_jQ
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
      "body": "https://x.com/sdhilip/status/2069140867466797200?s=46&t=8JLnk5l_ZQz2KJfqZ5W_jQ",
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
    await store.insertBlock(after: paragraph, kind: .paragraph)
    try await waitForCondition {
      store.selectedBlock?.rawText == "" && store.editingBlockID == store.selectedBlock?.id
    }

    let draft = try XCTUnwrap(store.selectedBlock)
    store.updateEditingBlockDraft(draft, draft: "https://altic.dev/fluid")
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "https://altic.dev/fluid"
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("""
    https://x.com/sdhilip/status/2069140867466797200?s=46&t=8JLnk5l_ZQz2KJfqZ5W_jQ

    https://altic.dev/fluid
    * Sibling
    """))
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
  func testDeleteBackwardAtStartMergesParagraphWithPreviousParagraph() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-paragraph-merge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("paragraph-merge.org2")
    try """
    #+TITLE: Paragraph Merge Test

    * TODO Parent
    Alpha

    beta
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
      "body": "Alpha\\n\\nbeta",
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

    let beta = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph(let text) = $0.rendered { return text == "beta" }
      return false
    })
    store.beginEditingBlock(beta)
    store.updateEditingBlockDraft(beta, draft: "beta edited")

    await store.deleteBackwardFromStartOfEditingBlock(beta, draftText: "beta edited")
    try await waitForCondition {
      store.selectedBlock?.rawText == "Alpha beta edited" && store.editingBlockID == store.selectedBlock?.id
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Alpha beta edited\n* Sibling"))
    XCTAssertFalse(updated.contains("Alpha\n\nbeta"))
  }

  @MainActor
  func testDeleteBackwardAtStartMergesListItemWithPreviousListItem() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-list-merge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("list-merge.org2")
    try """
    #+TITLE: List Merge Test

    * TODO Parent
    - [X] Done task
    - [ ] Follow up
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
      "body": "- [X] Done task\\n- [ ] Follow up",
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

    let followUp = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, .unchecked, let text) = $0.rendered { return text == "Follow up" }
      return false
    })
    store.beginEditingBlock(followUp)
    store.updateEditingBlockDraft(followUp, draft: "- [ ] Follow up edited")

    await store.deleteBackwardFromStartOfEditingBlock(followUp, draftText: "- [ ] Follow up edited")
    try await waitForCondition {
      store.selectedBlock?.rawText == "- [X] Done task Follow up edited"
        && store.editingBlockID == store.selectedBlock?.id
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- [X] Done task Follow up edited\n* Sibling"))
    XCTAssertFalse(updated.contains("- [ ] Follow up"))
  }

  @MainActor
  func testDeleteBackwardAtStartMergesHeadingTitleIntoPreviousTextBlock() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-merge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-merge.org2")
    try """
    #+TITLE: Heading Merge Test

    * TODO Parent
    Intro paragraph
    ** Child heading
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
      "line": 3,
      "body": "Intro paragraph\\n** Child heading\\nChild body",
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

    let childHeading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered { return heading.title == "Child heading" }
      return false
    })
    store.beginEditingBlock(childHeading)

    await store.deleteBackwardFromStartOfEditingBlock(childHeading, draftText: "** Child heading")
    try await waitForCondition {
      store.selectedBlock?.rawText == "Intro paragraph Child heading\nChild body"
        && store.editingBlockID == store.selectedBlock?.id
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Intro paragraph Child heading\nChild body\n* Sibling"))
    XCTAssertFalse(updated.contains("** Child heading"))
  }

  @MainActor
  func testDeleteBackwardAtStartMergesParagraphIntoPreviousHeading() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-absorb-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-absorb.org2")
    try """
    #+TITLE: Heading Absorb Test

    * TODO Parent :work:
    First body
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
      "body": "First body",
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

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph(let text) = $0.rendered { return text == "First body" }
      return false
    })
    store.beginEditingBlock(paragraph)

    await store.deleteBackwardFromStartOfEditingBlock(paragraph, draftText: "First body")
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO Parent First body :work:"
        && store.editingBlockID == store.selectedBlock?.id
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent First body :work:\n* Sibling"))
    XCTAssertFalse(updated.contains("* TODO Parent :work:\nFirst body"))
  }

  @MainActor
  func testDeleteBackwardAtStartDiscardsEmptyTransientParagraphDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-empty-draft-delete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("empty-draft-delete.org2")
    try """
    #+TITLE: Empty Draft Delete Test

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
      "line": 3,
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
    await store.splitEditingBlock(paragraph, atUTF16Offset: (paragraph.rawText as NSString).length)
    try await waitForCondition {
      store.selectedBlock?.rawText == "" && store.editingBlockID == store.selectedBlock?.id
    }

    let draft = try XCTUnwrap(store.selectedBlock)
    await store.deleteBackwardFromStartOfEditingBlock(draft, draftText: "")
    try await waitForCondition {
      store.selectedBlock?.rawText == "Alpha beta" && store.editingBlockID == nil
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Alpha beta\n* Sibling"))
    XCTAssertFalse(updated.contains("Alpha beta\n\n* Sibling"))
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

    store.selectBlock(heading)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 123)))
    XCTAssertTrue(store.foldedRenderedBlockIDs.contains(heading.id))
    XCTAssertFalse(store.canSelectAdjacentBlock(.down))
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 124)))
    XCTAssertFalse(store.foldedRenderedBlockIDs.contains(heading.id))
    XCTAssertTrue(store.canSelectAdjacentBlock(.down))

    store.selectBlock(paragraph)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 123, modifiers: [.command])))
    XCTAssertEqual(store.selectedBlock?.id, heading.id)
    XCTAssertTrue(store.foldedRenderedBlockIDs.contains(heading.id))
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 124, modifiers: [.command])))
    XCTAssertTrue(store.foldedRenderedBlockIDs.isEmpty)

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
    store.selectedSurface = .agenda
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
  func testDeletingRenderedHeadingFromPageDeletesSubtree() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-heading-delete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("page-heading-delete.org2")
    try """
    #+TITLE: Page Heading Delete Test

    * TODO Parent
    Parent body
    ** TODO Child
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
      "line": 3,
      "body": "Parent body",
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

    let parent = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered { return heading.title == "Parent" }
      return false
    })
    await store.deleteBlock(parent)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("* TODO Parent"))
    XCTAssertFalse(updated.contains("Parent body"))
    XCTAssertFalse(updated.contains("** TODO Child"))
    XCTAssertFalse(updated.contains("Child body"))
    XCTAssertTrue(updated.contains("* Sibling\nSibling body"))
    XCTAssertEqual(store.selectedBlock?.rawText, "* Sibling")
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
  private func waitForCondition(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(condition())
  }

  private func writeSilentM4A(to url: URL) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
    buffer.frameLength = 1_600
    try file.write(from: buffer)
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
