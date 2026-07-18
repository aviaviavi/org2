import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class SourceConnectionsTests: XCTestCase {
  func testDefaultsToEmptyRegistryAndInternalStorage() {
    let (defaults, key) = isolatedDefaults()
    let registry = WorkspaceSourceConnectionRegistry(defaults: defaults, persistenceKey: key)

    XCTAssertEqual(registry.connections, [])
    XCTAssertEqual(registry.storageRoot, .internalDefault)
  }

  func testPersistsCompleteConnectionAndExternalStorageMetadata() throws {
    let (defaults, key) = isolatedDefaults()
    let registry = WorkspaceSourceConnectionRegistry(defaults: defaults, persistenceKey: key)
    let now = Date(timeIntervalSince1970: 1_752_840_000)
    let connection = WorkspaceSourceConnection(
      id: UUID(uuidString: "12D1AC77-213B-4829-B9E7-EB39E5EA82B0")!,
      kind: .slack,
      displayName: "Scarf Slack",
      state: .paused,
      scopes: ["C012345", "threads:replies"],
      credentialReference: WorkspaceCredentialReference(
        service: "Org2Workspace.Sources",
        account: "slack-scarf"
      ),
      syncStatus: WorkspaceSourceSyncStatus(
        lastCursor: "cursor-42",
        lastSuccessAt: now,
        nextRunAt: now.addingTimeInterval(900),
        bytesFetched: 1_024,
        bytesStored: 768,
        actionableError: WorkspaceSourceActionableError(
          code: "rate_limited",
          message: "Slack paused the sync.",
          recoverySuggestion: "Retry after the indicated time.",
          occurredAt: now
        )
      )
    )
    let external = WorkspaceExternalStorageRoot(
      bookmarkData: Data([0x01, 0x02, 0x03]),
      lastKnownPath: "/Volumes/Org2 Data",
      volumeIdentifier: "org2-data-volume",
      availability: .missingVolume
    )

    try registry.upsert(connection)
    try registry.setStorageRoot(.external(external))

    let restored = WorkspaceSourceConnectionRegistry(defaults: defaults, persistenceKey: key)
    XCTAssertEqual(restored.connections, [connection])
    XCTAssertEqual(restored.storageRoot, .external(external))
  }

  func testUpsertReplacesByIdentifierAndRemovePersists() throws {
    let (defaults, key) = isolatedDefaults()
    let registry = WorkspaceSourceConnectionRegistry(defaults: defaults, persistenceKey: key)
    var connection = WorkspaceSourceConnection(kind: .notion, displayName: "Company Wiki")

    try registry.upsert(connection)
    connection.state = .paused
    connection.syncStatus.bytesStored = 99
    try registry.upsert(connection)

    XCTAssertEqual(registry.connections, [connection])
    try registry.remove(id: connection.id)
    XCTAssertTrue(registry.connections.isEmpty)
    XCTAssertTrue(
      WorkspaceSourceConnectionRegistry(defaults: defaults, persistenceKey: key).connections.isEmpty
    )
  }

  func testUnknownSourceKindRoundTripsForForwardCompatibility() throws {
    let kind = WorkspaceSourceKind(rawValue: "future-source")
    let data = try JSONEncoder().encode(kind)
    XCTAssertEqual(try JSONDecoder().decode(WorkspaceSourceKind.self, from: data), kind)
  }

  func testCorruptPersistenceFallsBackWithoutOverwritingIt() {
    let (defaults, key) = isolatedDefaults()
    let corrupt = Data("not json".utf8)
    defaults.set(corrupt, forKey: key)

    let registry = WorkspaceSourceConnectionRegistry(defaults: defaults, persistenceKey: key)

    XCTAssertEqual(registry.connections, [])
    XCTAssertEqual(registry.storageRoot, .internalDefault)
    XCTAssertEqual(defaults.data(forKey: key), corrupt)
  }

  private func isolatedDefaults() -> (UserDefaults, String) {
    let suite = "SourceConnectionsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, "registry")
  }
}
