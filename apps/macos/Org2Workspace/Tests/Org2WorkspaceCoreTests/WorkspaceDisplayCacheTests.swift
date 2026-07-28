import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceDisplayCacheTests: XCTestCase {
  @MainActor
  func testCorpusFileDisplayCacheInvalidatesForFileAndQueryChanges() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let alpha = CorpusFile(
      path: "/tmp/alpha.org2",
      relativePath: "notes/alpha.org2",
      modifiedAt: nil,
      byteCount: nil
    )
    let beta = CorpusFile(
      path: "/tmp/beta.org2",
      relativePath: "projects/beta.org2",
      modifiedAt: nil,
      byteCount: nil
    )

    store.corpusFiles = [alpha, beta]
    store.corpusFileFilter = "alpha"
    XCTAssertEqual(store.filteredCorpusFiles, [alpha])

    store.corpusFiles = [beta]
    XCTAssertTrue(store.filteredCorpusFiles.isEmpty)

    store.corpusFileFilter = "beta"
    XCTAssertEqual(store.filteredCorpusFiles, [beta])
  }

  @MainActor
  func testAgendaDisplayCacheInvalidatesForAgendaAndQueryChanges() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.agenda = try agenda(headline: "Alpha launch", file: "/tmp/alpha.org2")
    store.agendaFilter = "alpha"
    XCTAssertEqual(store.visibleAgendaItems.map(\.headline), ["Alpha launch"])

    store.agenda = try agenda(headline: "Beta launch", file: "/tmp/beta.org2")
    XCTAssertTrue(store.visibleAgendaItems.isEmpty)

    store.agendaFilter = "beta launch"
    XCTAssertEqual(store.visibleAgendaItems.map(\.headline), ["Beta launch"])
  }

  @MainActor
  func testSwitchingBackToCorpusRestoresCachedAgendaFilesAndRuns() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-corpus-workspace-cache-\(UUID().uuidString)", isDirectory: true)
    let alphaRoot = container.appendingPathComponent("alpha", isDirectory: true)
    let betaRoot = container.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alphaRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: betaRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }

    let run = try agentRun()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(alphaRoot, persistsDefault: false)
    store.agenda = try agenda(
      headline: "Alpha launch",
      file: alphaRoot.appendingPathComponent("notes/alpha.org2").path
    )
    let alphaFile = CorpusFile(
      path: alphaRoot.appendingPathComponent("notes/alpha.org2").path,
      relativePath: "notes/alpha.org2",
      modifiedAt: nil,
      byteCount: nil
    )
    store.corpusFiles = [alphaFile]
    store.replaceAgentRunsForTesting([run])
    XCTAssertEqual(store.agentRuns.map(\.id), ["run-alpha"])

    store.setCorpusRoot(betaRoot, persistsDefault: false)
    XCTAssertNil(store.agenda)
    XCTAssertTrue(store.corpusFiles.isEmpty)
    XCTAssertTrue(store.agentRuns.isEmpty)

    store.workspaceRefreshOperationForTesting = {
      XCTFail("A warm corpus switch should not run a full workspace refresh")
    }
    let alphaMount = try XCTUnwrap(store.mountedCorpora.first { $0.path == alphaRoot.path })
    store.switchCorpus(to: alphaMount)
    while store.isSwitchingCorpus {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(store.agenda?.days.flatMap(\.items).map(\.headline), ["Alpha launch"])
    XCTAssertEqual(store.corpusFiles, [alphaFile])
    XCTAssertEqual(store.agentRuns.map(\.id), ["run-alpha"])
  }

  @MainActor
  func testInactiveCorpusChangeMarksRestoredCacheDirtyWithoutDiscardingIt() throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-inactive-corpus-cache-\(UUID().uuidString)", isDirectory: true)
    let alphaRoot = container.appendingPathComponent("alpha", isDirectory: true)
    let betaRoot = container.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alphaRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: betaRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(alphaRoot, persistsDefault: false)
    store.agenda = try agenda(
      headline: "Cached alpha item",
      file: alphaRoot.appendingPathComponent("notes/alpha.org2").path
    )
    store.setCorpusRoot(betaRoot, persistsDefault: false)

    let changedFile = alphaRoot.appendingPathComponent("notes/alpha.org2")
    store.handleCorpusFileEvents(
      [changedFile.path],
      corpusRoot: alphaRoot,
      requiresFullScan: false
    )
    store.setCorpusRoot(alphaRoot, persistsDefault: false)

    XCTAssertEqual(store.agenda?.days.flatMap(\.items).map(\.headline), ["Cached alpha item"])
    XCTAssertTrue(store.isWorkspaceSurfaceDirty(.agenda))
    XCTAssertTrue(store.isWorkspaceSurfaceDirty(.files))
  }

  private func agentRun() throws -> AgentRunItem {
    let data = try JSONSerialization.data(withJSONObject: [
      "schema": "org2:agent-run:v1",
      "id": "run-alpha",
      "goal": "Keep alpha warm",
      "acceptanceCriteria": [],
      "status": "running",
      "riskClass": "local-draft",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [],
      "validations": [],
      "comments": [],
      "events": [],
      "createdAt": "2026-07-28T00:00:00.000Z",
      "updatedAt": "2026-07-28T00:01:00.000Z"
    ])
    return try JSONDecoder().decode(AgentRunItem.self, from: data)
  }

  private func agenda(headline: String, file: String) throws -> AgendaPayload {
    let data = try JSONSerialization.data(withJSONObject: [
      "$schema": "org2:agenda:v1",
      "range": ["start": "2026-07-21", "end": "2026-07-28", "days": 8],
      "overdue": [],
      "days": [[
        "date": "2026-07-21",
        "weekday": "Tuesday",
        "items": [[
          "todo": "TODO",
          "headline": headline,
          "kind": "SCHEDULED",
          "file": file,
          "line": 0,
          "body": "",
          "tags": [],
          "properties": [:]
        ]]
      ]]
    ])
    return try JSONDecoder().decode(AgendaPayload.self, from: data)
  }
}
