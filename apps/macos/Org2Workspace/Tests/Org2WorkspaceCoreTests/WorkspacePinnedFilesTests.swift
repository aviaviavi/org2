import XCTest
@testable import Org2WorkspaceCore

private final class PinnedProjectionThreadObserver: @unchecked Sendable {
  private let lock = NSLock()
  private var mainThreadBuilds = 0

  func record(wasBuiltOnMainThread: Bool) {
    guard wasBuiltOnMainThread else { return }
    lock.lock()
    mainThreadBuilds += 1
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return mainThreadBuilds
  }
}

private actor ControlledPinnedProjectionPreparation {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var hasStarted = false
  private(set) var hasFinished = false

  func wait() async {
    hasStarted = true
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
    hasFinished = true
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
final class WorkspacePinnedFilesTests: XCTestCase {
  func testPinnedFilesPersistInOrderAndRemainScopedToTheirCorpus() async throws {
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
    await store.waitForCorpusFilePublicationForTesting()

    XCTAssertEqual(store.pinnedFileRelativePaths, ["notes/first.org2", "notes/second.org2"])
    XCTAssertEqual(store.pinnedCorpusFiles.map(\.name), ["first.org2", "second.org2"])
    XCTAssertEqual(store.pinnedCorpusFileProjectionMainThreadBuildCountForTesting, 0)

    store.setCorpusRoot(secondRoot, persistsDefault: false)
    await store.waitForCorpusFilePublicationForTesting()
    XCTAssertTrue(store.pinnedFileRelativePaths.isEmpty)
    XCTAssertTrue(store.pinnedCorpusFiles.isEmpty)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    restored.setCorpusRoot(firstRoot, persistsDefault: false)
    await restored.waitForCorpusFilePublicationForTesting()
    XCTAssertEqual(restored.pinnedFileRelativePaths, ["notes/first.org2", "notes/second.org2"])
    XCTAssertEqual(restored.pinnedCorpusFiles.map(\.name), ["first.org2", "second.org2"])

    restored.togglePinnedFile(path: firstURL.path)
    await restored.waitForCorpusFilePublicationForTesting()
    XCTAssertEqual(restored.pinnedFileRelativePaths, ["notes/second.org2"])
    XCTAssertEqual(restored.pinnedCorpusFiles.map(\.name), ["second.org2"])
  }

  func testPinnedProjectionSkipsUnrelatedCatalogUpdatesAndTracksReplacement() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-pinned-projection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaultsSuite = "org2-pinned-projection-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }

    let pinnedURL = root.appendingPathComponent("notes/pinned.org2")
    let unrelatedURL = root.appendingPathComponent("notes/unrelated.org2")
    try FileManager.default.createDirectory(
      at: pinnedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "#+TITLE: Pinned\n".write(to: pinnedURL, atomically: true, encoding: .utf8)
    try "#+TITLE: Unrelated\n".write(to: unrelatedURL, atomically: true, encoding: .utf8)

    let pinned = CorpusFile(
      path: pinnedURL.path,
      relativePath: "notes/pinned.org2",
      modifiedAt: Date(timeIntervalSince1970: 1),
      byteCount: 10
    )
    let unrelated = CorpusFile(
      path: unrelatedURL.path,
      relativePath: "notes/unrelated.org2",
      modifiedAt: Date(timeIntervalSince1970: 1),
      byteCount: 20
    )
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      legacyDefaultsDomains: []
    )
    let threadObserver = PinnedProjectionThreadObserver()
    store.pinnedCorpusFileProjectionDidBuildForTesting = { wasMainThread in
      threadObserver.record(wasBuiltOnMainThread: wasMainThread)
    }
    store.setCorpusRoot(root, persistsDefault: false)
    store.corpusFiles = [pinned, unrelated]
    await store.waitForCorpusFilePublicationForTesting()
    store.togglePinnedFile(pinned)
    await store.waitForCorpusFilePublicationForTesting()

    XCTAssertEqual(store.pinnedCorpusFiles, [pinned])
    let buildCount = store.pinnedCorpusFileProjectionBuildCountForTesting
    let publicationCount = store.pinnedCorpusFileProjectionPublicationCountForTesting

    let changedUnrelated = CorpusFile(
      path: unrelatedURL.path,
      relativePath: "notes/unrelated.org2",
      modifiedAt: Date(timeIntervalSince1970: 2),
      byteCount: 21
    )
    store.corpusFiles = [pinned, changedUnrelated]
    await store.waitForCorpusFilePublicationForTesting()
    XCTAssertEqual(
      store.pinnedCorpusFileProjectionBuildCountForTesting,
      buildCount,
      "An unrelated catalog replacement must not recompute the pinned projection"
    )
    XCTAssertEqual(
      store.pinnedCorpusFileProjectionPublicationCountForTesting,
      publicationCount,
      "An unchanged pinned row must not invalidate the mounted sidebar"
    )

    let replacement = CorpusFile(
      path: pinnedURL.path,
      relativePath: "notes/pinned.org2",
      modifiedAt: Date(timeIntervalSince1970: 3),
      byteCount: 30
    )
    store.corpusFiles = [replacement, changedUnrelated]
    await store.waitForCorpusFilePublicationForTesting()
    XCTAssertEqual(store.pinnedCorpusFiles, [replacement])
    XCTAssertGreaterThan(store.pinnedCorpusFileProjectionBuildCountForTesting, buildCount)
    XCTAssertGreaterThan(store.pinnedCorpusFileProjectionPublicationCountForTesting, publicationCount)
    XCTAssertEqual(store.pinnedCorpusFileProjectionMainThreadBuildCountForTesting, 0)
    XCTAssertEqual(threadObserver.count, 0)

    store.togglePinnedFile(replacement)
    await store.waitForCorpusFilePublicationForTesting()
    XCTAssertTrue(store.pinnedFileRelativePaths.isEmpty)
    XCTAssertTrue(store.pinnedCorpusFiles.isEmpty)
  }

  func testDelayedPinnedProjectionCannotPublishAcrossCorpusSwitch() async throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-pinned-switch-\(UUID().uuidString)", isDirectory: true)
    let firstRoot = base.appendingPathComponent("first", isDirectory: true)
    let secondRoot = base.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let defaultsSuite = "org2-pinned-switch-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }

    let firstURL = firstRoot.appendingPathComponent("notes/shared.org2")
    let secondURL = secondRoot.appendingPathComponent("notes/shared.org2")
    try FileManager.default.createDirectory(
      at: firstURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: secondURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "#+TITLE: First\n".write(to: firstURL, atomically: true, encoding: .utf8)
    try "#+TITLE: Second\n".write(to: secondURL, atomically: true, encoding: .utf8)
    let first = CorpusFile(
      path: firstURL.path,
      relativePath: "notes/shared.org2",
      modifiedAt: Date(timeIntervalSince1970: 1),
      byteCount: 10
    )
    let firstReplacement = CorpusFile(
      path: firstURL.path,
      relativePath: "notes/shared.org2",
      modifiedAt: Date(timeIntervalSince1970: 2),
      byteCount: 11
    )
    let second = CorpusFile(
      path: secondURL.path,
      relativePath: "notes/shared.org2",
      modifiedAt: Date(timeIntervalSince1970: 3),
      byteCount: 20
    )
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(firstRoot, persistsDefault: false)
    store.corpusFiles = [first]
    await store.waitForCorpusFilePublicationForTesting()
    store.togglePinnedFile(first)
    await store.waitForCorpusFilePublicationForTesting()

    let preparation = ControlledPinnedProjectionPreparation()
    store.pinnedCorpusFileProjectionPreparationForTesting = { root, _ in
      guard root.path == firstRoot.path else { return }
      await preparation.wait()
    }
    store.corpusFiles = [firstReplacement]
    try await waitUntil { await preparation.hasStarted }

    store.setCorpusRoot(secondRoot, persistsDefault: false)
    store.corpusFiles = [second]
    await store.waitForCorpusFilePublicationForTesting()
    store.togglePinnedFile(second)
    await store.waitForCorpusFilePublicationForTesting()
    await preparation.release()
    try await waitUntil { await preparation.hasFinished }
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(store.pinnedFileRelativePaths, ["notes/shared.org2"])
    XCTAssertEqual(store.pinnedCorpusFiles, [second])
    XCTAssertFalse(store.pinnedCorpusFiles.contains(firstReplacement))
    XCTAssertEqual(store.pinnedCorpusFileProjectionMainThreadBuildCountForTesting, 0)
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for pinned projection test state")
  }
}
