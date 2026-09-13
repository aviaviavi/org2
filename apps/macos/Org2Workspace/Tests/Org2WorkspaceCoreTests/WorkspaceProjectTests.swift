import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceProjectTests: XCTestCase {
  private func project(threadID: UUID, brief: String = "* TODO Ship the thing") -> WorkspaceProjectNote {
    WorkspaceProjectNote(id: UUID().uuidString, title: "Launch", color: "blue", file: "/local/launch.org", relativePath: "launch.org", revision: "sha256:fixture", threadIDs: [threadID.uuidString.lowercased()], brief: brief, briefTruncated: false)
  }

  func testOnlyExplicitThreadMembershipSuppliesContext() {
    let linked = UUID(), unrelated = UUID()
    let note = project(threadID: linked)
    XCTAssertEqual(WorkspaceProjectContext.presentation(projects: [note], threadID: unrelated), "")
    let context = WorkspaceProjectContext.presentation(projects: [note], threadID: linked, mappedPath: { $0.replacingOccurrences(of: "/local", with: "/remote") })
    XCTAssertTrue(context.contains("/remote/launch.org:1"))
    XCTAssertTrue(context.contains("sha256:fixture"))
    XCTAssertTrue(context.contains("* TODO Ship the thing"))
    XCTAssertTrue(context.contains("does not grant access"))
  }

  func testContextBoundsBriefAcrossMultipleNotes() {
    let thread = UUID()
    let notes = (0..<10).map { _ in project(threadID: thread, brief: String(repeating: "x", count: 15000)) }
    let context = WorkspaceProjectContext.presentation(projects: notes, threadID: thread)
    XCTAssertLessThan(context.count, 16000)
    XCTAssertTrue(context.contains("truncated"))
    XCTAssertTrue(context.contains("Additional project notes omitted"))
  }

  func testProjectBriefSurvivesLocalAndGatewayPromptConstruction() {
    let context = OpenClawWorkspaceContext(localCorpusRoot: "/local", remoteCorpusRoot: "/remote",
      selectedSurface: "AI Chat", selectedLocation: nil, selectedEntrySource: nil,
      backlinks: nil, agenda: nil, searchQuery: "", searchResults: [], projectContext: "Project brief fixture")
    XCTAssertTrue(context.systemPrompt().contains("Project brief fixture"))
    XCTAssertTrue(context.codexSystemPrompt().contains("Project brief fixture"))
    XCTAssertTrue(context.localAgentSystemPrompt(runtime: "claude", runtimeTitle: "Claude Code").contains("Project brief fixture"))
  }

  func testCustomProjectColorsRoundTripThroughNativePicker() {
    for hex in ["#123456", "#000000", "#FFFFFF", "#aB12eF"] {
      XCTAssertEqual(WorkspaceProjectPalette.hex(WorkspaceProjectPalette.tint(hex)), hex.uppercased())
    }
  }

  func testEmptyProjectListHasNoPromptOverhead() {
    XCTAssertEqual(WorkspaceProjectContext.presentation(projects: [], threadID: UUID()), "")
  }

  @MainActor
  func testForkedThreadRetainsProjectMembership() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-project-fork-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "WorkspaceProjectTests.Fork.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let sourceID = store.createOpenClawChatThread(runtime: .openClaw)
    let projectID = UUID().uuidString.lowercased()
    let projectURL = root.appendingPathComponent("launch.org")
    let projectText = """
    #+ORG2_KIND: project
    #+TITLE: Launch
    #+PROJECT_THREADS: \(sourceID.uuidString.lowercased())
    :PROPERTIES:
    :ID: \(projectID)
    :END:

    Keep the launch coordinated.
    """
    try projectText.write(to: projectURL, atomically: true, encoding: .utf8)
    await store.refreshProjects()
    XCTAssertTrue(try XCTUnwrap(store.projectNotes.first).contains(sourceID))

    let loadedForkID = await store.forkAIChatThread(sourceID)
    let forkID = try XCTUnwrap(loadedForkID)

    let project = try XCTUnwrap(store.projectNotes.first(where: { $0.id == projectID }))
    XCTAssertTrue(project.contains(sourceID))
    XCTAssertTrue(project.contains(forkID))
    let persisted = try String(contentsOf: projectURL, encoding: .utf8)
    XCTAssertTrue(persisted.contains(forkID.uuidString.lowercased()))
  }
}
