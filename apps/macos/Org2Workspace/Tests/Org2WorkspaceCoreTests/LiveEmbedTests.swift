import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class LiveEmbedTests: XCTestCase {
  func testPortableRelativeNoteTargets() {
    XCTAssertEqual(
      LiveEmbedPresentation.fileTarget(file: "/corpus/notes/source.org", sourceFile: "/corpus/daily/today.org"),
      "file:../notes/source.org"
    )
    XCTAssertEqual(
      LiveEmbedPresentation.fileTarget(file: "/corpus/notes/source.org2", sourceFile: "/corpus/notes/host.org"),
      "file:source.org2"
    )
  }

  @MainActor
  func testSourceEventsRefreshRenderedEmbedsAndInsertionOnlyChangesDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("org2-live-embed-swift-\(UUID().uuidString)")
    let suite = "org2-live-embed-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    let host = root.appendingPathComponent("host.org")
    let source = root.appendingPathComponent("source.org")
    let hostText = "#+TITLE: Host\n#+EMBED: file:source.org\n"
    try hostText.write(to: host, atomically: true, encoding: .utf8)
    try "Original source".write(to: source, atomically: true, encoding: .utf8)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults, legacyDefaultsDomains: [])
    store.setCorpusRoot(root)
    // A deterministic renderer isolates the native invalidation and draft path;
    // TypeScript regressions cover actual source resolution and frame rendering.
    store.entryHTMLRendererForTesting = { _, _, _, _ in
      let text = try String(contentsOf: source, encoding: .utf8)
      return "<aside data-org2-live-embed=\"true\">\(text)</aside>"
    }
    store.selectCorpusFile(CorpusFile(path: host.path, relativePath: "host.org", modifiedAt: nil, byteCount: nil))
    try await waitUntil { store.selectedEntryHTML?.contains("Original source") == true }
    try "Updated source".write(to: source, atomically: true, encoding: .utf8)
    store.handleCorpusFileEvents([source.path], corpusRoot: root, requiresFullScan: false)
    try await waitUntil { store.selectedEntryHTML?.contains("Updated source") == true }
    XCTAssertEqual(try String(contentsOf: host, encoding: .utf8), hostText)

    store.insertLiveEmbedDirective("#+EMBED: file:source.org")
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertEqual(store.sourceEditorPresentation, .split)
    XCTAssertTrue(store.sourceEditorInteraction.text.hasSuffix("\n#+EMBED: file:source.org\n"))
    XCTAssertEqual(try String(contentsOf: host, encoding: .utf8), hostText)
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Updated source")
    store.cancelEditingSelectedEntry()
  }

  @MainActor
  private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(8)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertTrue(predicate())
  }
}
