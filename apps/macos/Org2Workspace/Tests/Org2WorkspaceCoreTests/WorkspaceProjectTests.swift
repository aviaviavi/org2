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
}
