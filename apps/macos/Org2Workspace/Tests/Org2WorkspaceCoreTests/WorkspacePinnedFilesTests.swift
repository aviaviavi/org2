import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspacePinnedFilesTests: XCTestCase {
  func testPinnedFilesPersistInOrderAndRemainScopedToTheirCorpus() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-pinned-files-\(UUID().uuidString)", isDirectory: true)
    let firstRoot = base.appendingPathComponent("first", isDirectory: true)
    let secondRoot = base.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let firstURL = firstRoot.appendingPathComponent("notes/first.org2")
    let secondURL = firstRoot.appendingPathComponent("notes/second.org2")
    try FileManager.default.createDirectory(
      at: firstURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "#+TITLE: First\n".write(to: firstURL, atomically: true, encoding: .utf8)
    try "#+TITLE: Second\n".write(to: secondURL, atomically: true, encoding: .utf8)

    let suiteName = "org2-pinned-files-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    store.setCorpusRoot(firstRoot, persistsDefault: false)
    store.togglePinnedFile(CorpusFile(
      path: firstURL.path,
      relativePath: "notes/first.org2",
      modifiedAt: nil,
      byteCount: nil
    ))
    store.togglePinnedFile(CorpusFile(
      path: secondURL.path,
      relativePath: "notes/second.org2",
      modifiedAt: nil,
      byteCount: nil
    ))

    XCTAssertEqual(store.pinnedFileRelativePaths, ["notes/first.org2", "notes/second.org2"])
    XCTAssertEqual(store.pinnedCorpusFiles.map(\.name), ["first.org2", "second.org2"])

    store.setCorpusRoot(secondRoot, persistsDefault: false)
    XCTAssertTrue(store.pinnedFileRelativePaths.isEmpty)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    restored.setCorpusRoot(firstRoot, persistsDefault: false)
    XCTAssertEqual(restored.pinnedFileRelativePaths, ["notes/first.org2", "notes/second.org2"])

    restored.togglePinnedFile(path: firstURL.path)
    XCTAssertEqual(restored.pinnedFileRelativePaths, ["notes/second.org2"])
  }
}
