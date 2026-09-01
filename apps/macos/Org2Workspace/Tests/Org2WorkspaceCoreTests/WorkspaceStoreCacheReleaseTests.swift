import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor WorkspaceStoreTestGate {
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    started = true
    startWaiters.forEach { $0.resume() }
    startWaiters = []
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private struct WorkspaceStylesheetBuildRecord: Sendable {
  let rootPath: String?
  let wasBuiltOnMainThread: Bool
}

private final class WorkspaceStylesheetBuildRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [WorkspaceStylesheetBuildRecord] = []

  var values: [WorkspaceStylesheetBuildRecord] {
    lock.withLock { storage }
  }

  func append(root: URL?, wasBuiltOnMainThread: Bool) {
    lock.withLock {
      storage.append(WorkspaceStylesheetBuildRecord(
        rootPath: root?.standardizedFileURL.path,
        wasBuiltOnMainThread: wasBuiltOnMainThread
      ))
    }
  }
}

@MainActor
final class WorkspaceStoreCacheReleaseTests: XCTestCase {
  func testDocumentCacheEvictionReplacementAndInvalidationReleaseOffMain() async throws {
    let suiteName = "WorkspaceStoreCacheReleaseTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    let payloadBody = String(repeating: "cache-payload-0123456789\n", count: 10_000)

    for index in 0..<30 {
      store.installWorkspaceDocumentCachePayloadForTesting(
        file: "/tmp/workspace-cache-release-\(index).org2",
        payload: "\(index)\n\(payloadBody)"
      )
    }

    XCTAssertEqual(store.workspaceDocumentCacheCountsForTesting.entrySources, 24)
    XCTAssertEqual(store.workspaceDocumentCacheCountsForTesting.blocks, 12)
    XCTAssertEqual(store.workspaceDocumentCacheCountsForTesting.html, 24)
    let evictionReleaseCount = store.workspaceCacheReleaseScheduledCountForTesting
    XCTAssertGreaterThan(evictionReleaseCount, 0)
    try await waitUntil {
      store.workspaceCacheReleaseCompletedCountForTesting >= evictionReleaseCount
    }
    XCTAssertEqual(store.workspaceCacheMainThreadReleaseCountForTesting, 0)

    let retainedFile = "/tmp/workspace-cache-release-29.org2"
    store.installWorkspaceDocumentCachePayloadForTesting(
      file: retainedFile,
      payload: "replacement\n\(payloadBody)"
    )
    store.invalidateWorkspaceDocumentCachesForTesting(file: retainedFile)
    let replacementAndInvalidationReleaseCount =
      store.workspaceCacheReleaseScheduledCountForTesting
    XCTAssertGreaterThan(replacementAndInvalidationReleaseCount, evictionReleaseCount)
    try await waitUntil {
      store.workspaceCacheReleaseCompletedCountForTesting
        >= replacementAndInvalidationReleaseCount
    }
    XCTAssertEqual(store.workspaceCacheMainThreadReleaseCountForTesting, 0)
    XCTAssertEqual(store.workspaceDocumentCacheCountsForTesting.entrySources, 23)
    XCTAssertEqual(store.workspaceDocumentCacheCountsForTesting.blocks, 11)
    XCTAssertEqual(store.workspaceDocumentCacheCountsForTesting.html, 23)
  }

  func testStylesheetIdentityBuildsOffMainAndRejectsStaleCorpusPublication() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-stylesheet-snapshot-\(UUID().uuidString)", isDirectory: true)
    let firstRoot = container.appendingPathComponent("first.org2", isDirectory: true)
    let secondRoot = container.appendingPathComponent("second.org2", isDirectory: true)
    let firstStylesheet = firstRoot.appendingPathComponent(".org2/app.css")
    let secondStylesheet = secondRoot.appendingPathComponent(".org2/app.css")
    try FileManager.default.createDirectory(
      at: firstStylesheet.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: secondStylesheet.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try ":root { --source: first; }\n".write(
      to: firstStylesheet,
      atomically: true,
      encoding: .utf8
    )
    try ":root { --source: second; }\n".write(
      to: secondStylesheet,
      atomically: true,
      encoding: .utf8
    )
    defer { try? FileManager.default.removeItem(at: container) }

    let suiteName = "WorkspaceStoreCacheReleaseTests.stylesheet.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    store.corpusFileScanForTesting = { _ in [] }
    let staleBuildGate = WorkspaceStoreTestGate()
    let recorder = WorkspaceStylesheetBuildRecorder()
    store.appHTMLStylesheetSnapshotPreparationForTesting = { root in
      if root.standardizedFileURL.path == firstRoot.standardizedFileURL.path {
        await staleBuildGate.wait()
      }
    }
    store.appHTMLStylesheetSnapshotDidBuildForTesting = { root, wasBuiltOnMainThread in
      recorder.append(root: root, wasBuiltOnMainThread: wasBuiltOnMainThread)
    }

    store.setCorpusRoot(firstRoot, persistsDefault: false)
    await staleBuildGate.waitUntilStarted()
    store.setCorpusRoot(secondRoot, persistsDefault: false)
    try await waitUntil {
      recorder.values.contains { $0.rootPath == secondRoot.standardizedFileURL.path }
        && store.appHTMLStylesheetSnapshotCorpusRootPathForTesting
          == secondRoot.standardizedFileURL.path
        && store.hasAppHTMLStylesheet
    }
    let secondIdentity = store.appHTMLStylesheetSnapshotIdentityForTesting

    await staleBuildGate.release()
    try await waitUntil { recorder.values.count >= 2 }
    await Task.yield()
    XCTAssertEqual(
      store.appHTMLStylesheetSnapshotCorpusRootPathForTesting,
      secondRoot.standardizedFileURL.path
    )
    XCTAssertEqual(store.appHTMLStylesheetSnapshotIdentityForTesting, secondIdentity)
    XCTAssertTrue(recorder.values.allSatisfy { !$0.wasBuiltOnMainThread })
    XCTAssertEqual(store.appHTMLStylesheetSnapshotMainThreadBuildCountForTesting, 0)

    try ":root { --source: updated-second; }\n".write(
      to: secondStylesheet,
      atomically: true,
      encoding: .utf8
    )
    let buildCountBeforeEvent = recorder.values.count
    store.handleCorpusFileEvents(
      [secondStylesheet.path],
      corpusRoot: secondRoot,
      requiresFullScan: false
    )
    try await waitUntil {
      recorder.values.count > buildCountBeforeEvent
        && store.appHTMLStylesheetSnapshotIdentityForTesting != secondIdentity
    }
    XCTAssertTrue(store.hasAppHTMLStylesheet)
    XCTAssertTrue(recorder.values.allSatisfy { !$0.wasBuiltOnMainThread })
    XCTAssertEqual(store.appHTMLStylesheetSnapshotMainThreadBuildCountForTesting, 0)
  }

  private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(condition())
  }
}
