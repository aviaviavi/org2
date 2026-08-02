import XCTest
@testable import Org2WorkspaceCore

private actor SlashCommandRequestRecorder {
  private(set) var messages: [OpenClawChatMessage] = []

  func record(_ messages: [OpenClawChatMessage]) -> String {
    self.messages = messages
    return "Done"
  }
}

final class OpenClawSlashCommandTests: XCTestCase {
  func testParsesKnownCommandAndArguments() {
    guard case .command(let command, let arguments) = OpenClawSlashCommands.parse("/search project atlas") else {
      return XCTFail("Expected a command")
    }
    XCTAssertEqual(command.name, "search")
    XCTAssertEqual(arguments, "project atlas")
  }

  func testEscapedSlashBecomesOrdinaryMessage() {
    XCTAssertEqual(OpenClawSlashCommands.parse("//help"), .message("/help"))
  }

  func testUnknownCommandIsNotOrdinaryMessage() {
    XCTAssertEqual(OpenClawSlashCommands.parse("/does-not-exist"), .unknown("does-not-exist"))
  }

  func testSuggestionsNarrowByPrefix() {
    XCTAssertEqual(OpenClawSlashCommands.suggestions(for: "/sp").map(\.name), ["spellcheck"])
    XCTAssertTrue(OpenClawSlashCommands.suggestions(for: "/search notes").isEmpty)
  }

  func testCatalogKeepsAgentContextInternal() {
    XCTAssertFalse(OpenClawSlashCommands.all.map(\.name).contains("context"))
    XCTAssertTrue(OpenClawSlashCommands.all.first(where: { $0.name == "brief" })?.isAgentAssisted == true)
    XCTAssertTrue(OpenClawSlashCommands.all.first(where: { $0.name == "lint" })?.isAgentAssisted == false)
  }

  @MainActor
  func testUnknownCommandPassesThroughToOpenClaw() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-slash-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = SlashCommandRequestRecorder()
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      openClawSendHandler: { messages, _, _, _ in await recorder.record(messages) }
    )

    store.submitOpenClawComposerInput(text: "/wat")
    let deadline = Date().addingTimeInterval(3)
    while store.openClawMessages.count < 2, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertEqual(store.openClawMessages.map(\.role), [.user, .assistant])
    XCTAssertEqual(store.openClawMessages.first?.content, "/wat")
    XCTAssertEqual(store.openClawMessages.last?.content, "Done")
    let requestMessages = await recorder.messages
    XCTAssertEqual(requestMessages.first?.content, "/wat")
  }

  func testGatewayCatalogDecodesCommandsAliasesAndArguments() throws {
    let data = Data(#"""
    {
      "commands": [
        {
          "name": "triage",
          "textAliases": ["/triage", "/tr"],
          "description": "Triage the current queue",
          "category": "tools",
          "source": "plugin",
          "scope": "text",
          "acceptsArgs": true,
          "args": [
            {"name": "scope", "description": "What to triage", "type": "string", "required": true},
            {"name": "limit", "description": "Maximum count", "type": "number"}
          ]
        }
      ]
    }
    """#.utf8)

    let commands = try OpenClawGatewayCommandCatalog.decode(data)
    XCTAssertEqual(commands.count, 1)
    XCTAssertEqual(commands[0].name, "triage")
    XCTAssertEqual(commands[0].aliases, ["tr"])
    XCTAssertEqual(commands[0].arguments, "<scope> [limit]")
    XCTAssertEqual(commands[0].origin, .openClaw)
    XCTAssertEqual(
      OpenClawSlashCommands.suggestions(for: "/tr", gatewayCommands: commands).map(\.name),
      ["triage"]
    )
    guard case .command(let command, let arguments) = OpenClawSlashCommands.parse(
      "/tr all",
      gatewayCommands: commands
    ) else {
      return XCTFail("Expected the Gateway alias to parse")
    }
    XCTAssertEqual(command.name, "triage")
    XCTAssertEqual(arguments, "all")
  }

  func testUnknownSlashCommandRequiresTheGatewayButEscapedSlashDoesNot() {
    XCTAssertTrue(OpenClawSlashCommands.isGatewayCommand("/new-plugin-command", gatewayCommands: []))
    XCTAssertFalse(OpenClawSlashCommands.isGatewayCommand("//new-plugin-command", gatewayCommands: []))
    XCTAssertFalse(OpenClawSlashCommands.isGatewayCommand("/agenda", gatewayCommands: []))
  }

  func testGatewaySlashCommandSkipsWorkspaceContextEnvelope() {
    let context = OpenClawWorkspaceContext(
      localCorpusRoot: "/tmp/org2",
      remoteCorpusRoot: "/workspace/org2",
      selectedSurface: "OpenClaw Chat",
      selectedLocation: nil,
      selectedEntrySource: nil,
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: []
    )

    XCTAssertEqual(
      WorkspaceStore.openClawGatewayMessage(
        userMessage: "/triage all",
        workspaceContext: context,
        isGatewayCommand: true
      ),
      "/triage all"
    )
    let wrappedMessage = WorkspaceStore.openClawGatewayMessage(
      userMessage: "Summarize this",
      workspaceContext: context,
      isGatewayCommand: false
    )
    XCTAssertTrue(wrappedMessage.hasPrefix("<org2-workspace-context>"))
    XCTAssertTrue(wrappedMessage.contains("Org2 response formatting contract"))
    XCTAssertTrue(wrappedMessage.contains("are application instructions and must be followed"))
    XCTAssertTrue(wrappedMessage.contains("|-------+--------------|"))
  }

  @MainActor
  func testAgentCommandKeepsInvocationInTranscriptAndExpandsRequest() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-agent-slash-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = SlashCommandRequestRecorder()
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      openClawSendHandler: { messages, _, _, _ in await recorder.record(messages) }
    )

    store.submitOpenClawComposerInput(text: "/brief")
    let deadline = Date().addingTimeInterval(3)
    while store.openClawMessages.count < 2, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertEqual(store.openClawMessages.first?.content, "/brief")
    let request = await recorder.messages
    XCTAssertEqual(request.first?.content.hasPrefix("/brief\n\nCreate a concise, cited brief"), true)
  }

  @MainActor
  func testPDFExporterProducesPDFData() async throws {
    let data = try await Org2PDFExporter().data(
      for: "<html><body><h1>Org2 export</h1><p>Plain text stays canonical.</p></body></html>",
      baseURL: nil
    )
    XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
  }
}
