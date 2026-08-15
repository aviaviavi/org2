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
