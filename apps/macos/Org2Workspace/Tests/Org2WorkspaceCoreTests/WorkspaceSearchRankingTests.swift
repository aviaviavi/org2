import XCTest
@testable import Org2WorkspaceCore

private enum DelayedWorkspaceSearchError: LocalizedError {
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .failed(let message): message
    }
  }
}

private actor DelayedWorkspaceSearchLoader {
  private var continuations: [Int: CheckedContinuation<SearchPayload, Error>] = [:]
  private var requestCount = 0

  func load(query: String, arguments: [String]) async throws -> SearchPayload {
    let requestIndex = requestCount
    requestCount += 1
    return try await withCheckedThrowingContinuation { continuation in
      continuations[requestIndex] = continuation
    }
  }

  func waitForRequestCount(_ expectedCount: Int) async {
    while requestCount < expectedCount {
      await Task.yield()
    }
  }

  func succeed(_ requestIndex: Int, payload: SearchPayload) {
    continuations.removeValue(forKey: requestIndex)?.resume(returning: payload)
  }

  func fail(_ requestIndex: Int, message: String) {
    continuations.removeValue(forKey: requestIndex)?.resume(
      throwing: DelayedWorkspaceSearchError.failed(message)
    )
  }
}

final class WorkspaceSearchRankingTests: XCTestCase {
  @MainActor
  func testSearchCompletionAfterNavigationDoesNotStealSurface() async throws {
    let root = try makeSearchRoot(label: "navigation")
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = DelayedWorkspaceSearchLoader()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.workspaceSearchLoaderForTesting = { query, arguments in
      try await loader.load(query: query, arguments: arguments)
    }
    store.selectedSurface = .search
    store.searchQuery = "alpha"

    let searchTask = Task { await store.runSearch() }
    await loader.waitForRequestCount(1)
    store.selectedSurface = .files
    await loader.succeed(0, payload: searchPayload(
      query: "alpha",
      result: searchResult(
        file: root.appendingPathComponent("alpha.org").path,
        line: 1,
        heading: "Alpha",
        headingLine: 1,
        todo: nil,
        snippet: "alpha"
      )
    ))
    await searchTask.value

    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertEqual(store.searchResults.first?.heading, "Alpha")
  }

  @MainActor
  func testOlderSearchCannotOverwriteNewerQuery() async throws {
    let root = try makeSearchRoot(label: "latest-query")
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = DelayedWorkspaceSearchLoader()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.workspaceSearchLoaderForTesting = { query, arguments in
      try await loader.load(query: query, arguments: arguments)
    }

    store.searchQuery = "older"
    let olderTask = Task { await store.runSearch() }
    await loader.waitForRequestCount(1)
    store.searchQuery = "newer"
    let newerTask = Task { await store.runSearch() }
    await loader.waitForRequestCount(2)

    await loader.succeed(1, payload: searchPayload(
      query: "newer",
      result: searchResult(
        file: root.appendingPathComponent("newer.org").path,
        line: 2,
        heading: "Newer",
        headingLine: 2,
        todo: nil,
        snippet: "newer"
      )
    ))
    await newerTask.value
    await loader.succeed(0, payload: searchPayload(
      query: "older",
      result: searchResult(
        file: root.appendingPathComponent("older.org").path,
        line: 1,
        heading: "Older",
        headingLine: 1,
        todo: nil,
        snippet: "older"
      )
    ))
    await olderTask.value

    XCTAssertEqual(store.searchResults.compactMap(\.heading), ["Newer"])
    XCTAssertFalse(store.isSearching)
  }

  @MainActor
  func testCorpusSwitchRejectsStaleSearchErrorAndLoadingCleanup() async throws {
    let container = try makeSearchRoot(label: "corpus-switch")
    let alpha = container.appendingPathComponent("alpha", isDirectory: true)
    let beta = container.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let loader = DelayedWorkspaceSearchLoader()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.workspaceSearchLoaderForTesting = { query, arguments in
      try await loader.load(query: query, arguments: arguments)
    }
    store.setCorpusRoot(alpha, persistsDefault: false)
    store.searchQuery = "shared"
    let alphaTask = Task { await store.runSearch() }
    await loader.waitForRequestCount(1)

    store.setCorpusRoot(beta, persistsDefault: false)
    store.selectedSurface = .files
    let betaTask = Task { await store.runSearch() }
    await loader.waitForRequestCount(2)
    await loader.fail(0, message: "stale alpha failure")
    await alphaTask.value

    XCTAssertTrue(store.isSearching)
    XCTAssertNotEqual(store.errorText, "stale alpha failure")
    XCTAssertTrue(store.searchResults.isEmpty)
    XCTAssertEqual(store.selectedSurface, .files)

    await loader.succeed(1, payload: searchPayload(
      query: "shared",
      result: searchResult(
        file: beta.appendingPathComponent("beta.org").path,
        line: 1,
        heading: "Beta",
        headingLine: 1,
        todo: nil,
        snippet: "shared beta"
      )
    ))
    await betaTask.value

    XCTAssertEqual(store.searchResults.compactMap(\.heading), ["Beta"])
    XCTAssertFalse(store.isSearching)
    XCTAssertEqual(store.selectedSurface, .files)
  }

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

  private func searchPayload(query: String, result: SearchResult) -> SearchPayload {
    SearchPayload(
      schema: "org2:search:v1",
      query: query,
      mode: "text",
      sort: "relevance",
      results: [result],
      corpora: nil,
      issues: nil
    )
  }

  private func makeSearchRoot(label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-search-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
