import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AgendaNavigationPerformanceTests: XCTestCase {
  private actor CallLog {
    private(set) var renderedFiles: [String] = []
    private(set) var backlinkFiles: [String] = []

    func recordRender(file: String) {
      renderedFiles.append(file)
    }

    func recordBacklinks(file: String) {
      backlinkFiles.append(file)
    }

    func snapshot() -> (renderedFiles: [String], backlinkFiles: [String]) {
      (renderedFiles, backlinkFiles)
    }
  }

  @MainActor
  func testRapidAgendaNavigationOnlyStartsSettledPreviewAndBacklinks() async throws {
    let fixture = try makeFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.root)
      fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite)
    }

    let calls = CallLog()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: fixture.defaults,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(fixture.root)
    store.agendaEntryRenderIdleDelayNanoseconds = 100_000_000
    store.backlinksSelectionIdleDelayNanoseconds = 100_000_000
    store.entrySourceLoaderForTesting = { file, _, _ in
      EntrySource(
        file: file,
        startLine: 1,
        endLineExclusive: 3,
        text: "* TODO \(URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent)\nBody",
        isSubtree: true
      )
    }
    store.entryHTMLRendererForTesting = { _, file, _, _ in
      await calls.recordRender(file: file)
      return "<html>\(file)</html>"
    }
    store.backlinksLoaderForTesting = { location in
      await calls.recordBacklinks(file: location.file)
      return try JSONDecoder().decode(
        BacklinksPayload.self,
        from: Data(#"{"$schema":"org2/backlinks/v1","id":"target","backlinks":[]}"#.utf8)
      )
    }

    store.toggleNodeContextPane()
    store.selectAgendaItem(fixture.first)
    try await Task.sleep(nanoseconds: 20_000_000)
    store.selectAgendaItem(fixture.second)

    let settled = await waitUntil {
      store.selectedEntryHTML?.contains(fixture.second.file) == true
        && store.backlinks != nil
        && !store.isRenderingEntrySource
        && !store.isLoadingBacklinks
    }
    XCTAssertTrue(settled)
    let snapshot = await calls.snapshot()
    XCTAssertEqual(snapshot.renderedFiles, [fixture.second.file])
    XCTAssertEqual(snapshot.backlinkFiles, [fixture.second.file])
  }

  @MainActor
  func testAgendaNavigationDoesNotLoadBacklinksWhileContextPaneIsHidden() async throws {
    let fixture = try makeFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.root)
      fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite)
    }

    let calls = CallLog()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: fixture.defaults,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(fixture.root)
    store.agendaEntryRenderIdleDelayNanoseconds = 0
    store.backlinksSelectionIdleDelayNanoseconds = 30_000_000
    store.entrySourceLoaderForTesting = { file, _, _ in
      EntrySource(
        file: file,
        startLine: 1,
        endLineExclusive: 3,
        text: "* TODO First\nBody",
        isSubtree: true
      )
    }
    store.entryHTMLRendererForTesting = { _, file, _, _ in "<html>\(file)</html>" }
    store.backlinksLoaderForTesting = { location in
      await calls.recordBacklinks(file: location.file)
      return try JSONDecoder().decode(
        BacklinksPayload.self,
        from: Data(#"{"$schema":"org2/backlinks/v1","id":"target","backlinks":[]}"#.utf8)
      )
    }

    store.selectAgendaItem(fixture.first)
    try await Task.sleep(nanoseconds: 100_000_000)
    let hiddenSnapshot = await calls.snapshot()
    XCTAssertEqual(hiddenSnapshot.backlinkFiles, [])

    store.toggleNodeContextPane()
    let loaded = await waitUntil { store.backlinks != nil && !store.isLoadingBacklinks }
    XCTAssertTrue(loaded)
    let visibleSnapshot = await calls.snapshot()
    XCTAssertEqual(visibleSnapshot.backlinkFiles, [fixture.first.file])
  }

  @MainActor
  private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    condition: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
    while ContinuousClock.now < deadline {
      if condition() {
        return true
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
  }

  private struct Fixture {
    let root: URL
    let defaults: UserDefaults
    let defaultsSuite: String
    let first: AgendaItem
    let second: AgendaItem
  }

  private func makeFixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-agenda-navigation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let firstURL = root.appendingPathComponent("first.org2")
    let secondURL = root.appendingPathComponent("second.org2")
    try "* TODO First\nBody\n".write(to: firstURL, atomically: true, encoding: .utf8)
    try "* TODO Second\nBody\n".write(to: secondURL, atomically: true, encoding: .utf8)

    let suite = "org2-agenda-navigation-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return Fixture(
      root: root,
      defaults: defaults,
      defaultsSuite: suite,
      first: agendaItem(title: "First", file: firstURL.path),
      second: agendaItem(title: "Second", file: secondURL.path)
    )
  }

  private func agendaItem(title: String, file: String) -> AgendaItem {
    AgendaItem(
      todo: "TODO",
      headline: title,
      kind: "SCHEDULED",
      file: file,
      line: 1,
      body: "Body",
      level: 1,
      tags: [],
      properties: [:],
      priority: nil,
      time: nil,
      effort: nil,
      idValue: UUID().uuidString,
      habit: nil
    )
  }
}
