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
