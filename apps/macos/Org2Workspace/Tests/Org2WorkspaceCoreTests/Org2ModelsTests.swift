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

    let bundle = try MeetingArtifactWriter.writeArtifacts(
      paths: paths,
      corpusRoot: root,
      duration: 12.5,
      transcript: MeetingTranscriptResult(
        text: "We decided to publish the reporting update.",
        status: .complete,
        engine: "whisper.cpp"
      )
    )

    let note = try String(contentsOf: bundle.noteURL, encoding: .utf8)
    let transcript = try String(contentsOf: bundle.transcriptURL, encoding: .utf8)

    XCTAssertTrue(note.contains("* Meeting: Scarf reporting sync"))
    XCTAssertTrue(note.contains(":kind: meeting"))
    XCTAssertTrue(note.contains(":audio_artifact: meetings/"))
    XCTAssertTrue(note.contains(":transcript_artifact: meetings/"))
    XCTAssertTrue(note.contains(":transcription_engine: whisper.cpp"))
    XCTAssertTrue(note.contains("** Decisions"))
    XCTAssertTrue(transcript.contains("* Transcript: Scarf reporting sync"))
    XCTAssertTrue(transcript.contains(":kind: meeting_transcript"))
    XCTAssertTrue(transcript.contains("We decided to publish the reporting update."))
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
    XCTAssertTrue(store.meetings[0].transcriptArtifact?.hasSuffix(".transcript.org2") == true)
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

    store.beginEditingSelectedEntry()
    store.editableEntryText = store.editableEntryText.replacingOccurrences(of: "Body", with: "Updated body")
    await store.saveEditedEntry()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Updated body"))
    XCTAssertTrue(updated.contains("* Sibling\nSibling body"))
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
}
