import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class SourceConnectionsTests: XCTestCase {
  func testAutomaticSourceScheduleChecksOncePerMinute() {
    XCTAssertEqual(WorkspaceStore.sourceAutoSyncCheckIntervalNanoseconds, 60_000_000_000)
  }

  func testDecodesCompilerSourceProfilesAndCrawlerStatus() throws {
    let profilesJSON = Data(#"""
    [{"id":"slack","type":"slack","enabled":true,"scopes":[],"workspaceId":"T01","rawZone":"raw/connectors/slack","reviewZone":"views/connectors/slack","ingestionSince":"14d","ingestionLimit":5000,"syncArgs":["--source","desktop"],"media":"metadata-only","schedule":{"enabled":true,"kind":"interval","everyMinutes":120,"timezone":"local"},"bindingPath":"/tmp/bindings.json","binary":"slacrawl","binaryAvailable":true,"configPath":"/tmp/slacrawl.toml","configAvailable":true,"ready":true}]
    """#.utf8)
    let profiles = try JSONDecoder().decode([WorkspaceSourceProfileStatus].self, from: profilesJSON)
    XCTAssertEqual(profiles.first?.workspaceId, "T01")
    XCTAssertEqual(profiles.first?.ingestionSince, "14d")
    XCTAssertEqual(profiles.first?.reviewZone, "views/connectors/slack")
    XCTAssertEqual(profiles.first?.schedule?.summary, "Every 2 hours")

    let statusJSON = Data(#"""
    {"schema":"org2:source-status:v1","root":"/tmp/corpus","sources":[{"id":"slack","type":"slack","ok":true,"crawlerStatus":{"app_id":"slacrawl","state":"current","summary":"42 messages across 3 channels","database_path":"/tmp/slacrawl.db","database_bytes":1024,"last_sync_at":"2026-07-20T18:20:19Z","counts":[{"id":"messages","label":"Messages","value":42}]}}]}
    """#.utf8)
    let status = try JSONDecoder().decode(WorkspaceSourceStatusEnvelope.self, from: statusJSON)
    XCTAssertEqual(status.sources.first?.crawlerStatus?.summary, "42 messages across 3 channels")
    XCTAssertEqual(status.sources.first?.crawlerStatus?.counts.first?.value, 42)
  }

  func testDecodesSourceImportPreview() throws {
    let data = Data(#"""
    {"schema":"org2:source-import-run:v1","root":"/tmp/corpus","applied":false,"results":[{"id":"notion","ok":true,"imported":{"apply":false,"inputCount":100,"acceptedCount":90,"skippedCount":10,"groupCount":2,"changedFileCount":2}}]}
    """#.utf8)
    let envelope = try JSONDecoder().decode(WorkspaceSourceOperationEnvelope.self, from: data)
    XCTAssertEqual(envelope.results.first?.imported?.acceptedCount, 90)
    XCTAssertEqual(envelope.results.first?.imported?.groupCount, 2)
  }

  func testDecodesBenignConcurrentSyncResult() throws {
    let data = Data(#"""
    {"schema":"org2:source-sync:v1","root":"/tmp/corpus","results":[{"id":"slack","ok":true,"skipped":true,"reason":"sync-in-progress","message":"Sync already in progress on this machine."}]}
    """#.utf8)
    let envelope = try JSONDecoder().decode(WorkspaceSourceOperationEnvelope.self, from: data)

    XCTAssertTrue(envelope.results[0].isSyncInProgress)
    XCTAssertEqual(envelope.results[0].message, "Sync already in progress on this machine.")
  }

  func testSourcePresentationCollapsesDuplicateErrorsAndUsesHonestStatus() {
    let error = "Slack sync failed."
    let notice = WorkspaceSourcePresentation.notice(
      scheduleError: error,
      operationMessage: error,
      operationFailed: true
    )

    XCTAssertEqual(notice, WorkspaceSourceNotice(text: error, isError: true))
    XCTAssertEqual(
      WorkspaceSourcePresentation.state(
        isRunning: false,
        needsToken: false,
        isReady: true,
        runtimeOK: true,
        notice: notice
      ),
      .needsAttention
    )
    XCTAssertEqual(
      WorkspaceSourcePresentation.state(
        isRunning: false,
        needsToken: false,
        isReady: true,
        runtimeOK: true,
        notice: WorkspaceSourceNotice(text: "Sync already in progress on this machine.", isError: false)
      ),
      .configured
    )
  }

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

  func testSchedulePlannerHandlesIntervalsDailyTimesAndDueChecks() throws {
    let formatter = ISO8601DateFormatter()
    let start = try XCTUnwrap(formatter.date(from: "2026-07-21T01:00:00Z"))
    let interval = WorkspaceSourceSchedule(
      enabled: true,
      kind: .interval,
      everyMinutes: 120,
      time: nil,
      timezone: "local"
    )
    XCTAssertEqual(
      WorkspaceSourceSchedulePlanner.nextRun(after: start, schedule: interval),
      start.addingTimeInterval(2 * 60 * 60)
    )

    let daily = WorkspaceSourceSchedule(
      enabled: true,
      kind: .daily,
      everyMinutes: nil,
      time: "02:00",
      timezone: "UTC"
    )
    let sameDay = try XCTUnwrap(formatter.date(from: "2026-07-21T02:00:00Z"))
    XCTAssertEqual(WorkspaceSourceSchedulePlanner.nextRun(after: start, schedule: daily), sameDay)
    let afterDaily = try XCTUnwrap(formatter.date(from: "2026-07-21T03:00:00Z"))
    let nextDay = try XCTUnwrap(formatter.date(from: "2026-07-22T02:00:00Z"))
    XCTAssertEqual(WorkspaceSourceSchedulePlanner.nextRun(after: afterDaily, schedule: daily), nextDay)

    let state = WorkspaceSourceScheduleState(
      scheduleFingerprint: daily.fingerprint,
      initializedAt: start,
      nextRunAt: sameDay
    )
    XCTAssertFalse(WorkspaceSourceSchedulePlanner.isDue(state, at: start))
    XCTAssertTrue(WorkspaceSourceSchedulePlanner.isDue(state, at: sameDay))
  }

  func testScheduleDraftRoundTripsIntervalAndDailyControls() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z"))

    var intervalDraft = WorkspaceSourceScheduleDraft(
      schedule: WorkspaceSourceSchedule(
        enabled: true,
        kind: .interval,
        everyMinutes: 120,
        time: nil,
        timezone: "local"
      ),
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(intervalDraft.intervalValue, 2)
    XCTAssertEqual(intervalDraft.intervalUnit, .hours)
    intervalDraft.intervalValue = 45
    intervalDraft.intervalUnit = .minutes
    XCTAssertEqual(
      try intervalDraft.schedule(enabled: false, calendar: calendar),
      WorkspaceSourceSchedule(
        enabled: false,
        kind: .interval,
        everyMinutes: 45,
        time: nil,
        timezone: "local"
      )
    )

    var dailyDraft = WorkspaceSourceScheduleDraft(schedule: nil, now: now, calendar: calendar)
    dailyDraft.kind = .daily
    dailyDraft.dailyTime = try XCTUnwrap(
      calendar.date(bySettingHour: 8, minute: 45, second: 0, of: now)
    )
    dailyDraft.timezone = "America/Los_Angeles"
    XCTAssertEqual(
      try dailyDraft.schedule(enabled: true, calendar: calendar),
      WorkspaceSourceSchedule(
        enabled: true,
        kind: .daily,
        everyMinutes: nil,
        time: "08:45",
        timezone: "America/Los_Angeles"
      )
    )
  }

  func testScheduleDraftRejectsZeroFrequencyAndInvalidTimezone() {
    var draft = WorkspaceSourceScheduleDraft(schedule: nil)
    draft.intervalValue = 0
    XCTAssertThrowsError(try draft.schedule(enabled: true)) { error in
      XCTAssertEqual(error.localizedDescription, "Sync frequency must be greater than zero.")
    }
    draft.intervalValue = 1
    draft.timezone = "Not/A-Time-Zone"
    XCTAssertThrowsError(try draft.schedule(enabled: true)) { error in
      XCTAssertEqual(error.localizedDescription, "Choose Local time or a valid time zone.")
    }
  }

  func testDecodesSourceScheduleMutationResult() throws {
    let data = Data(#"""
    {"schema":"org2:source-schedule:v1","root":"/tmp/corpus","configFile":"/tmp/corpus/org2.json","profile":"slack","previous":{"enabled":true,"kind":"interval","everyMinutes":120,"timezone":"local"},"schedule":{"enabled":false,"kind":"interval","everyMinutes":120,"timezone":"local"},"changed":true,"applied":true}
    """#.utf8)
    let envelope = try JSONDecoder().decode(WorkspaceSourceScheduleUpdateEnvelope.self, from: data)
    XCTAssertEqual(envelope.profile, "slack")
    XCTAssertEqual(envelope.previous?.summary, "Every 2 hours")
    XCTAssertEqual(envelope.schedule.summary, "Off")
    XCTAssertTrue(envelope.changed)
    XCTAssertTrue(envelope.applied)
  }

  func testScheduleStateStorePersistsPerCorpusAndProfile() throws {
    let (defaults, key) = isolatedDefaults()
    let store = WorkspaceSourceScheduleStateStore(defaults: defaults, persistenceKey: key)
    let now = Date(timeIntervalSince1970: 1_752_840_000)
    let state = WorkspaceSourceScheduleState(
      scheduleFingerprint: "interval|120",
      initializedAt: now,
      lastAttemptAt: now,
      lastSuccessAt: now,
      nextRunAt: now.addingTimeInterval(7_200)
    )

    store.setState(state, corpusPath: "/tmp/corpus-a", profileID: "slack")

    let restored = WorkspaceSourceScheduleStateStore(defaults: defaults, persistenceKey: key)
    XCTAssertEqual(restored.state(corpusPath: "/tmp/corpus-a", profileID: "slack"), state)
    XCTAssertNil(restored.state(corpusPath: "/tmp/corpus-b", profileID: "slack"))
    XCTAssertNil(restored.state(corpusPath: "/tmp/corpus-a", profileID: "notion"))
  }

  private func isolatedDefaults() -> (UserDefaults, String) {
    let suite = "SourceConnectionsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, "registry")
  }
}
