import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceSearchRankingTests: XCTestCase {
  func testSearchRankingFindsAndDeduplicatesActiveTodoBeyondOldCandidateWindow() {
    let historical = (1...60).map { index in
      searchResult(
        file: "/tmp/archive.org2",
        line: index,
        heading: nil,
        headingLine: nil,
        todo: nil,
        snippet: "Mercor historical mention \(index)"
      )
    }
    let activeHeading = searchResult(
      file: "/tmp/current.org2",
      line: 80,
      heading: "Follow up with Mercor after review",
      headingLine: 80,
      todo: "TODO",
      snippet: "* TODO Follow up with Mercor after review"
    )
    let activeBody = searchResult(
      file: "/tmp/current.org2",
      line: 82,
      heading: "Follow up with Mercor after review",
      headingLine: 80,
      todo: "TODO",
      snippet: "Mercor is ready for a response."
    )

    let results = WorkspaceStore.prioritizedSearchResultsForDisplay(
      historical + [activeBody, activeHeading],
      query: "Mercor",
      limit: 50
    )

    XCTAssertEqual(results.count, 50)
    XCTAssertEqual(results.first?.heading, "Follow up with Mercor after review")
    XCTAssertEqual(results.first?.line, 80)
    XCTAssertEqual(results.filter(\.isActiveTodo).count, 1)
  }

  @MainActor
  func testWorkspaceSearchReturnsRelevantTodoBeforeLargeRawMatchSet() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-search-ranking-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let historical = (1...60)
      .map { "Mercor historical mention \($0)" }
      .joined(separator: "\n")
    try (historical + "\n")
      .write(to: root.appendingPathComponent("archive.org2"), atomically: true, encoding: .utf8)
    try """
    * TODO Follow up with Mercor after review
    Mercor is ready for a response.
    """
      .write(to: root.appendingPathComponent("current.org2"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.searchQuery = "Mercor"

    await store.runSearch()

    XCTAssertEqual(store.searchResults.count, 50)
    XCTAssertEqual(store.searchResults.first?.heading, "Follow up with Mercor after review")
    XCTAssertEqual(store.searchResults.first?.todo, "TODO")
    XCTAssertEqual(store.searchResults.filter(\.isActiveTodo).count, 1)
  }

  private func searchResult(
    file: String,
    line: Int,
    heading: String?,
    headingLine: Int?,
    todo: String?,
    snippet: String
  ) -> SearchResult {
    SearchResult(
      file: file,
      line: line,
      lineEnd: nil,
      heading: heading,
      headingLine: headingLine,
      headingLevel: heading == nil ? nil : 1,
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
}
