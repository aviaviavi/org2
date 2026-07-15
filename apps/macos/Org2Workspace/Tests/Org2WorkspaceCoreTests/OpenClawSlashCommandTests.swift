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
  func testUnknownCommandStaysLocal() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-slash-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      openClawSendHandler: { _, _, _, _ in XCTFail("Unknown command reached the agent"); return "" }
    )

    store.submitOpenClawComposerInput(text: "/wat")

    XCTAssertEqual(store.openClawMessages.map(\.role), [.user, .system])
    XCTAssertEqual(store.openClawMessages.first?.content, "/wat")
    XCTAssertTrue(store.openClawMessages.last?.content.contains("Unknown command") == true)
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
