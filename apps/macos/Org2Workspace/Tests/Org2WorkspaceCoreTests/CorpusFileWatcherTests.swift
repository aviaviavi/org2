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

private final class ObservedCLICommands: @unchecked Sendable {
  private let lock = NSLock()
  private var commands: [String] = []

  func append(_ metric: Org2CLIInvocationMetric) {
    lock.lock()
    commands.append(metric.command)
    lock.unlock()
  }

  func count(_ command: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return commands.filter { $0 == command }.count
  }
}

private enum ControlledCorpusFileScanError: Error, Sendable {
  case injected
}

private actor ControlledCorpusFileScan {
  private var continuations: [String: CheckedContinuation<[CorpusFile], Error>] = [:]

  func scan(_ root: URL) async throws -> [CorpusFile] {
    try await withCheckedThrowingContinuation { continuation in
      continuations[root.standardizedFileURL.path] = continuation
    }
  }

  func hasRequest(for root: URL) -> Bool {
    continuations[root.standardizedFileURL.path] != nil
  }

  func succeed(_ root: URL, files: [CorpusFile]) {
    continuations.removeValue(forKey: root.standardizedFileURL.path)?.resume(returning: files)
  }

  func fail(_ root: URL) {
    continuations.removeValue(forKey: root.standardizedFileURL.path)?.resume(
      throwing: ControlledCorpusFileScanError.injected
    )
  }
}

private actor ControlledIncrementalCorpusPreparation {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var hasStarted = false

  func wait() async {
    hasStarted = true
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

final class CorpusFileWatcherTests: XCTestCase {
  func testClassifiesRuntimeRunChangesSeparatelyFromVisibleCorpusContent() {
    let root = URL(fileURLWithPath: "/tmp/org2-corpus").standardizedFileURL
    let note = root.appendingPathComponent("notes/visible.org2").path
    let markdown = root.appendingPathComponent("views/report.md").path
    let csv = root.appendingPathComponent("views/sample.csv").path
    let run = root.appendingPathComponent(".org2/runs/run-1.org2").path
    let syncHistory = root.appendingPathComponent(".stversions/notes/visible~old.org2").path
    let temporary = root.appendingPathComponent("notes/.visible.org2.tmp").path

    let classification = WorkspaceStore.classifyCorpusFileEvents(
      [note, run, syncHistory, temporary, markdown, csv, note, "/tmp/outside.org2"],
      corpusRoot: root
    )

    XCTAssertEqual(classification.contentPaths, [note, markdown, csv])
    XCTAssertTrue(classification.hasAgentRunStateChanges)
    XCTAssertFalse(classification.hasConfigurationChanges)
  }

  func testRuntimeOnlyFileEventsDoNotEnterTheGeneralCorpusRefreshPath() {
    let root = URL(fileURLWithPath: "/tmp/org2-corpus").standardizedFileURL
    let classification = WorkspaceStore.classifyCorpusFileEvents(
      [
        root.appendingPathComponent(".org2/runs/run-1.org2").path,
        root.appendingPathComponent(".org2/search-index.json").path,
      ],
      corpusRoot: root
    )

    XCTAssertTrue(classification.contentPaths.isEmpty)
    XCTAssertTrue(classification.hasAgentRunStateChanges)
    XCTAssertFalse(classification.hasConfigurationChanges)
  }

  func testRawDiagnosticEvidenceDoesNotEnterTheCorpusRefreshPath() {
    let root = URL(fileURLWithPath: "/tmp/org2-corpus").standardizedFileURL
    let diagnosticRoot = root.appendingPathComponent("raw/diagnostics/org2-workspace/incident-1")
    let classification = WorkspaceStore.classifyCorpusFileEvents(
      [
        diagnosticRoot.appendingPathComponent("incident.json").path,
        diagnosticRoot.appendingPathComponent("stacks.sample.txt").path,
      ],
      corpusRoot: root
    )

    XCTAssertTrue(classification.contentPaths.isEmpty)
    XCTAssertFalse(classification.hasAgentRunStateChanges)
    XCTAssertFalse(classification.hasConfigurationChanges)
  }

  func testClassifiesWorkspaceConfigurationChangesForFullReconciliation() {
    let root = URL(fileURLWithPath: "/tmp/org2-corpus").standardizedFileURL
    let classification = WorkspaceStore.classifyCorpusFileEvents(
      [
        root.appendingPathComponent("org2.json").path,
        root.appendingPathComponent(".org2/app.css").path,
      ],
      corpusRoot: root
    )

    XCTAssertTrue(classification.contentPaths.isEmpty)
    XCTAssertFalse(classification.hasAgentRunStateChanges)
    XCTAssertTrue(classification.hasConfigurationChanges)
  }

  func testMeetingFilesInvalidateMeetingAndAggregateSurfaces() {
    let root = URL(fileURLWithPath: "/tmp/org2-corpus").standardizedFileURL
    let note = root.appendingPathComponent("notes/plan.org2").path
    let meeting = root.appendingPathComponent("meetings/weekly.org2").path

    XCTAssertEqual(
      WorkspaceStore.invalidatedWorkspaceSurfaces(for: [note], corpusRoot: root),
      [.agenda, .approvals, .search]
    )
    XCTAssertEqual(
      WorkspaceStore.invalidatedWorkspaceSurfaces(for: [meeting], corpusRoot: root),
      [.agenda, .approvals, .search, .meetings, .openClaw]
    )
  }

  func testAgendaClockInvalidatesAtTheNextLocalMidnight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let now = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026,
      month: 7,
      day: 24,
      hour: 16,
      minute: 45
    )))
    let expected = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026,
      month: 7,
      day: 25
    )))

    XCTAssertEqual(
      WorkspaceStore.nextAgendaClockInvalidationDate(after: now, calendar: calendar),
      expected
    )
  }

  @MainActor
  func testCompletedCorpusScanCannotPublishIntoReplacementCorpus() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-stale-corpus-scan-\(UUID().uuidString)", isDirectory: true)
    let alpha = workspace.appendingPathComponent("alpha", isDirectory: true)
    let beta = workspace.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let alphaFile = CorpusFile(
      path: alpha.appendingPathComponent("alpha.org2").path,
      relativePath: "alpha.org2",
      modifiedAt: nil,
      byteCount: 10
    )
    let betaFile = CorpusFile(
      path: beta.appendingPathComponent("beta.org2").path,
      relativePath: "beta.org2",
      modifiedAt: nil,
      byteCount: 20
    )
    let scanner = ControlledCorpusFileScan()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(alpha, persistsDefault: false)
    store.corpusFileScanForTesting = { root in
      try await scanner.scan(root)
    }

    let staleRefresh = Task { @MainActor in
      await store.refreshCorpusFiles()
    }
    let alphaScanStarted = await waitForScanRequest(scanner, root: alpha)
    XCTAssertTrue(alphaScanStarted)

    store.setCorpusRoot(beta, persistsDefault: false)
    store.corpusFiles = [betaFile]
    await store.waitForCorpusFilePublicationForTesting()
    store.statusText = "Beta corpus ready"
    store.errorText = nil

    await scanner.succeed(alpha, files: [alphaFile])
    await staleRefresh.value

    XCTAssertEqual(store.corpusRoot?.standardizedFileURL.path, beta.standardizedFileURL.path)
    XCTAssertEqual(store.corpusFiles, [betaFile])
    XCTAssertEqual(store.statusText, "Beta corpus ready")
    XCTAssertNil(store.errorText)
    XCTAssertFalse(store.isScanningCorpusFiles)
  }

  @MainActor
  func testFailedCorpusScanCannotReportErrorInReplacementCorpus() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-stale-corpus-scan-error-\(UUID().uuidString)", isDirectory: true)
    let alpha = workspace.appendingPathComponent("alpha", isDirectory: true)
    let beta = workspace.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let scanner = ControlledCorpusFileScan()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(alpha, persistsDefault: false)
    store.corpusFileScanForTesting = { root in
      try await scanner.scan(root)
    }

    let staleRefresh = Task { @MainActor in
      await store.refreshCorpusFiles()
    }
    let alphaScanStarted = await waitForScanRequest(scanner, root: alpha)
    XCTAssertTrue(alphaScanStarted)

    store.setCorpusRoot(beta, persistsDefault: false)
    store.statusText = "Beta corpus ready"
    store.errorText = nil

    await scanner.fail(alpha)
    await staleRefresh.value

    XCTAssertEqual(store.corpusRoot?.standardizedFileURL.path, beta.standardizedFileURL.path)
    XCTAssertEqual(store.statusText, "Beta corpus ready")
    XCTAssertNil(store.errorText)
    XCTAssertFalse(store.isScanningCorpusFiles)
  }

  @MainActor
  func testIncrementalCorpusUpdateCannotPublishIntoReplacementCorpus() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-stale-incremental-update-\(UUID().uuidString)", isDirectory: true)
    let alpha = workspace.appendingPathComponent("alpha", isDirectory: true)
    let beta = workspace.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let changedAlphaURL = alpha.appendingPathComponent("changed.org2")
    try "* Changed in alpha\n".write(to: changedAlphaURL, atomically: true, encoding: .utf8)
    let betaFile = CorpusFile(
      path: beta.appendingPathComponent("beta.org2").path,
      relativePath: "beta.org2",
      modifiedAt: nil,
      byteCount: 20
    )
    let preparation = ControlledIncrementalCorpusPreparation()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(alpha, persistsDefault: false)
    store.incrementalCorpusChangePreparationForTesting = { _, _ in
      await preparation.wait()
    }

    let staleUpdate = Task { @MainActor in
      await store.applyIncrementalCorpusChangesForTesting([changedAlphaURL.path])
    }
    let incrementalPreparationStarted = await waitForIncrementalPreparation(preparation)
    XCTAssertTrue(incrementalPreparationStarted)

    store.setCorpusRoot(beta, persistsDefault: false)
    store.corpusFiles = [betaFile]
    await store.waitForCorpusFilePublicationForTesting()
    store.statusText = "Beta corpus ready"
    store.errorText = nil

    await preparation.release()
    await staleUpdate.value

    XCTAssertEqual(store.corpusRoot?.standardizedFileURL.path, beta.standardizedFileURL.path)
    XCTAssertEqual(store.corpusFiles, [betaFile])
    XCTAssertEqual(store.statusText, "Beta corpus ready")
    XCTAssertNil(store.errorText)
  }

  @MainActor
  func testCancelledSurfaceRefreshCannotClearReplacementTaskHandle() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-stale-surface-task-\(UUID().uuidString)", isDirectory: true)
    let alpha = workspace.appendingPathComponent("alpha", isDirectory: true)
    let beta = workspace.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let scanner = ControlledCorpusFileScan()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(alpha, persistsDefault: false)
    store.corpusFileScanForTesting = { root in
      try await scanner.scan(root)
    }
    store.setWorkspaceRealtimeRefreshActive(true)
    defer { store.setWorkspaceRealtimeRefreshActive(false) }
    store.selectedSurface = .files

    let alphaScanStarted = await waitForScanRequest(scanner, root: alpha)
    XCTAssertTrue(alphaScanStarted)
    XCTAssertTrue(store.hasWorkspaceSurfaceRefreshTaskForTesting(.files))
    XCTAssertTrue(store.isScanningCorpusFiles)

    store.setCorpusRoot(beta, persistsDefault: false)
    store.selectedSurface = .home
    store.selectedSurface = .files

    let betaScanStarted = await waitForScanRequest(scanner, root: beta)
    XCTAssertTrue(betaScanStarted)
    XCTAssertTrue(store.hasWorkspaceSurfaceRefreshTaskForTesting(.files))
    XCTAssertTrue(store.isScanningCorpusFiles)

    await scanner.succeed(alpha, files: [])
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertTrue(
      store.hasWorkspaceSurfaceRefreshTaskForTesting(.files),
      "The cancelled alpha task must not clear the replacement beta task handle"
    )
    XCTAssertTrue(
      store.isScanningCorpusFiles,
      "The cancelled alpha scan must not clear the replacement beta scan's loading state"
    )

    await scanner.succeed(beta, files: [])
    let deadline = Date().addingTimeInterval(2)
    while (store.hasWorkspaceSurfaceRefreshTaskForTesting(.files) || store.isScanningCorpusFiles),
          Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertFalse(store.hasWorkspaceSurfaceRefreshTaskForTesting(.files))
    XCTAssertFalse(store.isScanningCorpusFiles)
  }

  @MainActor
  func testInactiveCorpusEventRefreshesDirtySurfaceWhenWorkspaceBecomesActive() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-realtime-refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let firstPaths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "First live meeting",
      recordedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
    try Data("audio".utf8).write(to: firstPaths.audioURL)
    _ = try MeetingArtifactWriter.writeArtifacts(
      paths: firstPaths,
      corpusRoot: root,
      duration: nil,
      transcript: MeetingTranscriptResult(text: "First.", status: .complete, engine: "test")
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.setWorkspaceRealtimeRefreshActive(false)
    await store.refreshMeetings()
    XCTAssertEqual(store.meetings.count, 1)
    XCTAssertFalse(store.isWorkspaceSurfaceDirty(.meetings))

    let secondPaths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Second live meeting",
      recordedAt: Date(timeIntervalSince1970: 1_790_003_600)
    )
    try Data("audio".utf8).write(to: secondPaths.audioURL)
    let secondBundle = try MeetingArtifactWriter.writeArtifacts(
      paths: secondPaths,
      corpusRoot: root,
      duration: nil,
      transcript: MeetingTranscriptResult(text: "Second.", status: .complete, engine: "test")
    )
    store.handleCorpusFileEvents(
      [secondBundle.noteURL.path],
      corpusRoot: root,
      requiresFullScan: false
    )

    XCTAssertTrue(store.isWorkspaceSurfaceDirty(.meetings))
    XCTAssertEqual(store.meetings.count, 1)

    store.selectedSurface = .meetings
    store.setWorkspaceRealtimeRefreshActive(true)
    defer { store.setWorkspaceRealtimeRefreshActive(false) }

    XCTAssertEqual(
      store.meetings.count,
      1,
      "App activation must not synchronously refresh a visible surface before the window is foregrounded"
    )
    XCTAssertTrue(store.isWorkspaceSurfaceDirty(.meetings))

    let deadline = Date().addingTimeInterval(10)
    while (store.meetings.count != 2 || store.isWorkspaceSurfaceDirty(.meetings)),
          Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(store.meetings.count, 2)
    XCTAssertFalse(store.isWorkspaceSurfaceDirty(.meetings))
  }

  @MainActor
  func testPendingWatcherEventBuildsRoamSearchProjectionOffMainAfterActivation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-activation-roam-projection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("large-roam-file.org2")
    let headings = (0..<2_000).map { index in
      "* Heading \(index)\n:PROPERTIES:\n:ID: activation-heading-\(index)\n:END:\n"
    }.joined()
    try ("#+TITLE: Activation projection\n" + headings).write(
      to: note,
      atomically: true,
      encoding: .utf8
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.setWorkspaceRealtimeRefreshActive(false)
    await store.refreshCorpusFiles()

    var deadline = Date().addingTimeInterval(10)
    while (store.orgRoamLinkResolver.nodes.count != 2_001
            || store.orgRoamSearchProjectionBuildCountForTesting == 0),
          Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(store.orgRoamLinkResolver.nodes.count, 2_001)
    XCTAssertGreaterThan(store.orgRoamSearchProjectionBuildCountForTesting, 0)
    XCTAssertEqual(store.orgRoamSearchProjectionMainThreadBuildCountForTesting, 0)

    deadline = Date().addingTimeInterval(10)
    while store.orgRoamSearchProjectionReleaseCompletedCountForTesting
            < store.orgRoamSearchProjectionReleaseScheduledCountForTesting,
          Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(
      store.orgRoamSearchProjectionReleaseCompletedCountForTesting,
      store.orgRoamSearchProjectionReleaseScheduledCountForTesting
    )
    XCTAssertEqual(store.orgRoamSearchProjectionMainThreadReleaseCountForTesting, 0)

    let buildCountBeforeActivation = store.orgRoamSearchProjectionBuildCountForTesting
    let mainThreadBuildCountBeforeActivation =
      store.orgRoamSearchProjectionMainThreadBuildCountForTesting
    let releaseScheduleCountBeforeActivation =
      store.orgRoamSearchProjectionReleaseScheduledCountForTesting
    let mainThreadReleaseCountBeforeActivation =
      store.orgRoamSearchProjectionMainThreadReleaseCountForTesting
    store.handleCorpusFileEvents(
      [note.path],
      corpusRoot: root,
      requiresFullScan: false
    )

    // The watcher event must remain queued while inactive. If it were applied
    // here, this test would not cover the delayed Cmd-Tab activation path.
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(
      store.orgRoamSearchProjectionBuildCountForTesting,
      buildCountBeforeActivation
    )

    store.setWorkspaceRealtimeRefreshActive(true)
    defer { store.setWorkspaceRealtimeRefreshActive(false) }
    store.workspaceDidBecomeActive()
    deadline = Date().addingTimeInterval(15)
    while store.orgRoamSearchProjectionBuildCountForTesting == buildCountBeforeActivation,
          Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    while store.orgRoamSearchProjectionReleaseCompletedCountForTesting
            < store.orgRoamSearchProjectionReleaseScheduledCountForTesting,
          Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    XCTAssertGreaterThan(
      store.orgRoamSearchProjectionBuildCountForTesting,
      buildCountBeforeActivation,
      "Activation must drain the corpus event that the watcher queued while inactive"
    )
    XCTAssertEqual(store.orgRoamLinkResolver.nodes.count, 2_001)
    XCTAssertEqual(
      store.orgRoamSearchProjectionMainThreadBuildCountForTesting,
      mainThreadBuildCountBeforeActivation,
      "Resolver construction, signature generation, and search projection building must stay off the main thread"
    )
    XCTAssertGreaterThan(
      store.orgRoamSearchProjectionReleaseScheduledCountForTesting,
      releaseScheduleCountBeforeActivation,
      "An equal watcher projection must transfer its unpublished ownership to the detached release sink"
    )
    XCTAssertEqual(
      store.orgRoamSearchProjectionReleaseCompletedCountForTesting,
      store.orgRoamSearchProjectionReleaseScheduledCountForTesting
    )
    XCTAssertEqual(
      store.orgRoamSearchProjectionMainThreadReleaseCountForTesting,
      mainThreadReleaseCountBeforeActivation,
      "Rejected projection graphs must never perform their final ARC teardown on MainActor"
    )

    let replacementReleaseScheduleCount =
      store.orgRoamSearchProjectionReleaseScheduledCountForTesting
    let replacementMainThreadReleaseCount =
      store.orgRoamSearchProjectionMainThreadReleaseCountForTesting
    let replacementHeading = "* Replacement heading\n:PROPERTIES:\n:ID: activation-heading-replacement\n:END:\n"
    try ("#+TITLE: Activation projection\n" + headings + replacementHeading).write(
      to: note,
      atomically: true,
      encoding: .utf8
    )
    await store.applyIncrementalCorpusChangesForTesting([note.path])
    deadline = Date().addingTimeInterval(15)
    while (store.orgRoamLinkResolver.nodes.count != 2_002
            || store.orgRoamSearchProjectionReleaseCompletedCountForTesting
              < store.orgRoamSearchProjectionReleaseScheduledCountForTesting),
          Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(store.orgRoamLinkResolver.nodes.count, 2_002)
    XCTAssertGreaterThanOrEqual(
      store.orgRoamSearchProjectionReleaseScheduledCountForTesting
        - replacementReleaseScheduleCount,
      2,
      "Replacement must release both the old published box and the incoming ownership box off-main"
    )
    XCTAssertEqual(
      store.orgRoamSearchProjectionReleaseCompletedCountForTesting,
      store.orgRoamSearchProjectionReleaseScheduledCountForTesting
    )
    XCTAssertEqual(
      store.orgRoamSearchProjectionMainThreadReleaseCountForTesting,
      replacementMainThreadReleaseCount,
      "Replaced projection graphs must never perform their final ARC teardown on MainActor"
    )
  }

  @MainActor
  func testCleanWorkspaceActivationDoesNotInvalidateVisibleSurface() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-clean-activation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.selectedSurface = .meetings
    await store.refreshMeetings()
    XCTAssertFalse(store.isWorkspaceSurfaceDirty(.meetings))

    store.setWorkspaceRealtimeRefreshActive(true)
    defer { store.setWorkspaceRealtimeRefreshActive(false) }
    store.workspaceDidBecomeActive()

    XCTAssertFalse(
      store.isWorkspaceSurfaceDirty(.meetings),
      "Foregrounding an unchanged workspace must not trigger a corpus-wide meeting refresh"
    )
  }

  @MainActor
  func testCleanSelectedFileActivationUsesMetadataFreshnessFastPath() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-clean-file-activation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("large.org2")
    let text = "* Alpha\n" + String(repeating: "Generated body line.\n", count: 60_000)
    try text.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.entryHTMLRendererForTesting = { _, _, _, _ in "<html><body></body></html>" }
    store.setCorpusRoot(root, persistsDefault: false)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: try note.resourceValues(
        forKeys: [.contentModificationDateKey]
      ).contentModificationDate,
      byteCount: Int64(text.utf8.count)
    ))

    var deadline = Date().addingTimeInterval(10)
    while store.selectedEntrySource?.text.utf8.count != text.utf8.count,
          Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(store.selectedEntrySource?.text.utf8.count, text.utf8.count)
    XCTAssertEqual(store.selectedDetailFreshnessMetadataFastPathCountForTesting, 0)

    store.setWorkspaceRealtimeRefreshActive(true)
    defer { store.setWorkspaceRealtimeRefreshActive(false) }
    store.workspaceDidBecomeActive()
    deadline = Date().addingTimeInterval(3)
    while store.selectedDetailFreshnessMetadataFastPathCountForTesting == 0,
          Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertGreaterThan(
      store.selectedDetailFreshnessMetadataFastPathCountForTesting,
      0,
      "An unchanged selected file must not be read and hashed after activation"
    )
    XCTAssertEqual(store.selectedEntrySource?.text.utf8.count, text.utf8.count)
  }

  @MainActor
  func testSelectedFileReloadsWhenSyncPreservesModificationDateAndSize() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-realtime-selected-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("synced.org2")
    let original = "#+TITLE: Synced\n\n* Alpha\n"
    let updated = "#+TITLE: Synced\n\n* Bravo\n"
    XCTAssertEqual(original.utf8.count, updated.utf8.count)
    try original.write(to: note, atomically: true, encoding: .utf8)
    let originalModifiedAt = try XCTUnwrap(
      note.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.setWorkspaceRealtimeRefreshActive(true)
    defer { store.setWorkspaceRealtimeRefreshActive(false) }
    store.openChatFileReference(OpenClawFileReference(path: note.path, line: 1))

    var deadline = Date().addingTimeInterval(8)
    while store.selectedEntrySource?.text.contains("* Alpha") != true,
          Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(store.selectedEntrySource?.text.contains("* Alpha") == true)

    try updated.write(to: note, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: originalModifiedAt],
      ofItemAtPath: note.path
    )
    store.handleCorpusFileEvents(
      [note.path],
      corpusRoot: root,
      requiresFullScan: false
    )

    deadline = Date().addingTimeInterval(10)
    while store.selectedEntrySource?.text.contains("* Bravo") != true,
          Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(store.selectedEntrySource?.text.contains("* Bravo") == true)
  }

  @MainActor
  func testSourceSyncDefersFileEventsIntoOnePostSyncIndexUpdate() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-source-sync-event-batch-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    try """
    const args = process.argv.slice(2);
    if (args[0] === "source" && args[1] === "sync") {
      setTimeout(() => process.stdout.write(JSON.stringify({
        schema: "org2:source-sync:v1",
        root: ".",
        applied: true,
        results: [{ id: "notion", ok: true, imported: {
          apply: true,
          inputCount: 2,
          acceptedCount: 2,
          skippedCount: 0,
          groupCount: 2,
          changedFileCount: 2
        }}]
      })), 500);
    } else if (args[0] === "index") {
      process.stdout.write(JSON.stringify({ fileCount: 2, lineCount: 2, skippedFiles: 0 }));
    } else if (args[0] === "source" && args[1] === "list") {
      process.stdout.write("[]");
    } else {
      process.stderr.write(`Unexpected command: ${args.join(" ")}`);
      process.exitCode = 2;
    }
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let commands = ObservedCLICommands()
    let cli = Org2CLI(repoRoot: repoRoot, telemetryHandler: commands.append)
    let store = WorkspaceStore(cli: cli)
    store.setCorpusRoot(corpus, persistsDefault: false)
    store.setWorkspaceRealtimeRefreshActive(true)
    defer { store.setWorkspaceRealtimeRefreshActive(false) }
    let profile = WorkspaceSourceProfileStatus(
      id: "notion",
      type: "knowledge-base",
      enabled: true,
      scopes: [],
      workspaceId: nil,
      rawZone: "raw/connectors/notion",
      reviewZone: "views/connectors/notion",
      ingestionSince: nil,
      ingestionLimit: 100,
      syncArgs: [],
      media: "metadata-only",
      schedule: nil,
      binary: "notcrawl",
      binaryAvailable: true,
      configPath: nil,
      configAvailable: true,
      ready: true
    )

    let sync = Task { await store.syncAndStageSource(profile) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let first = corpus.appendingPathComponent("raw/connectors/notion/first.org2")
    try FileManager.default.createDirectory(
      at: first.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "* First\n".write(to: first, atomically: true, encoding: .utf8)
    store.handleCorpusFileEvents([first.path], corpusRoot: corpus, requiresFullScan: false)
    try await Task.sleep(nanoseconds: 180_000_000)

    let second = corpus.appendingPathComponent("views/connectors/notion/second.org2")
    try FileManager.default.createDirectory(
      at: second.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "* Second\n".write(to: second, atomically: true, encoding: .utf8)
    store.handleCorpusFileEvents([second.path], corpusRoot: corpus, requiresFullScan: false)
    try await Task.sleep(nanoseconds: 180_000_000)

    XCTAssertEqual(
      commands.count("cli.index"),
      0,
      "File events must not start index work while the connector is still writing"
    )

    await sync.value

    XCTAssertEqual(commands.count("cli.index"), 1)
    XCTAssertEqual(Set(store.corpusFiles.map(\.path)), Set([first.path, second.path]))
  }

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

  @MainActor
  private func waitForScanRequest(
    _ scanner: ControlledCorpusFileScan,
    root: URL,
    timeout: TimeInterval = 2
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await scanner.hasRequest(for: root) {
        return true
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await scanner.hasRequest(for: root)
  }

  @MainActor
  private func waitForIncrementalPreparation(
    _ preparation: ControlledIncrementalCorpusPreparation,
    timeout: TimeInterval = 2
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await preparation.hasStarted {
        return true
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await preparation.hasStarted
  }
}
