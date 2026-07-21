import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class OpenClawRemoteRootMigrationTests: XCTestCase {
  @MainActor
  func testLegacyRemoteRootMigratesWhenOnlyCorpusMountWasPersisted() throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-root-migration-\(UUID().uuidString)", isDirectory: true)
    let originalCorpus = container.appendingPathComponent("original", isDirectory: true)
    let laterCorpus = container.appendingPathComponent("later", isDirectory: true)
    try FileManager.default.createDirectory(at: originalCorpus, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: laterCorpus, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }

    let suiteName = "org2-openclaw-root-migration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set("/remote/org2", forKey: "Org2Workspace.openClawRemoteCorpusPath")
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.setCorpusRoot(originalCorpus, persistsDefault: false)

    XCTAssertEqual(store.openClawRemoteCorpusPath, "/remote/org2")
    XCTAssertEqual(
      defaults.dictionary(forKey: "Org2Workspace.openClawRemoteCorpusPathsByCorpus.v1") as? [String: String],
      [originalCorpus.standardizedFileURL.path: "/remote/org2"]
    )

    store.setCorpusRoot(laterCorpus, persistsDefault: false)
    XCTAssertEqual(store.openClawRemoteCorpusPath, "")

    store.setCorpusRoot(originalCorpus, persistsDefault: false)
    XCTAssertEqual(store.openClawRemoteCorpusPath, "/remote/org2")
  }
}
