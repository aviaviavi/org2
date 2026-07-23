import Foundation
import XCTest
@testable import Org2WorkspaceCore

private final class ObservedPathSet: @unchecked Sendable {
  private let lock = NSLock()
  private var paths = Set<String>()

  func insertAndContains(_ newPaths: [String], target: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    paths.formUnion(newPaths)
    return paths.contains(target)
  }
}

final class CorpusFileWatcherTests: XCTestCase {
  func testReportsNestedFileWritesWithoutScanningTheCorpus() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-watcher-\(UUID().uuidString)", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let changed = expectation(description: "nested file event")
    let target = notes.appendingPathComponent("changed.org2").standardizedFileURL.path
    let observedPaths = ObservedPathSet()
    let watcher = CorpusFileWatcher(rootURL: root) { paths, requiresFullScan in
      guard !requiresFullScan else { return }
      let foundTarget = observedPaths.insertAndContains(
        paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
        target: target
      )
      if foundTarget { changed.fulfill() }
    }
    withExtendedLifetime(watcher) {
      try? "* TODO Changed underneath the app\n".write(
        to: URL(fileURLWithPath: target),
        atomically: false,
        encoding: .utf8
      )
      wait(for: [changed], timeout: 5)
    }
  }
}
