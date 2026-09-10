import Foundation
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceRefreshTests: XCTestCase {
  func testSchedulerBoundsConcurrencyAndDrainsAllStages() async {
    let stages: [WorkspaceRefreshStage] = [.agenda, .files, .agentState]
    let gates = stages.map { _ in AsyncStream<Void>.makeStream() }
    let entered = expectation(description: "two independent stages entered")
    var active = 0, maximum = 0
    var started: [WorkspaceRefreshStage] = []
    let task = Task {
      await WorkspaceRefreshScheduler.run(stages: stages) { stage in
        active += 1
        maximum = max(maximum, active)
        started.append(stage)
        if started.count == 2 { entered.fulfill() }
        for await _ in gates[stages.firstIndex(of: stage)!].stream {}
        active -= 1
      }
    }
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertEqual(started.count, 2)
    XCTAssertEqual(maximum, 2)
    for gate in gates { gate.continuation.finish() }
    await task.value
    XCTAssertEqual(Set(started), Set(stages))
    XCTAssertEqual(active, 0)
    XCTAssertEqual(maximum, 2)
  }

  func testSchedulerCancellationDoesNotStartQueuedStages() async {
    let stages: [WorkspaceRefreshStage] = [.agenda, .files, .agentState, .meetings]
    let gates = stages.map { _ in AsyncStream<Void>.makeStream() }
    let entered = expectation(description: "initial stages entered")
    var started = 0
    let task = Task {
      await WorkspaceRefreshScheduler.run(stages: stages) { stage in
        started += 1
        if started == 2 { entered.fulfill() }
        for await _ in gates[stages.firstIndex(of: stage)!].stream {}
      }
    }
    await fulfillment(of: [entered], timeout: 2)
    task.cancel()
    for gate in gates { gate.continuation.finish() }
    await task.value
    XCTAssertEqual(started, 2)
  }

  func testTodoCacheReusesParsesAndDetectsEditsDeletesAndReplacements() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("one.org")
    let second = root.appendingPathComponent("two.org2")
    try "* TODO First\n".write(to: first, atomically: true, encoding: .utf8)
    try "* TODO Other\n".write(to: second, atomically: true, encoding: .utf8)
    let files = [first, second].map { CorpusFile(path: $0.path, relativePath: $0.lastPathComponent, modifiedAt: nil, byteCount: nil) }
    let cache = WorkspaceTodoScanCache()
    let cold = try await cache.scan(files: files)
    var parsed = await cache.lastParsedFileCount
    XCTAssertEqual(parsed, 2)
    let warm = try await cache.scan(files: files)
    parsed = await cache.lastParsedFileCount
    XCTAssertEqual(cold, warm)
    XCTAssertEqual(parsed, 0)

    let mtime = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate]!
    // Same bytes, restored timestamp: ctime must still invalidate the fragment.
    try "* TODO Edit!\n".write(to: first, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: first.path)
    let edited = try await cache.scan(files: files)
    parsed = await cache.lastParsedFileCount
    XCTAssertEqual(edited.first?.headline, "Edit!")
    XCTAssertEqual(parsed, 1)

    try "* TODO Swap!\n".write(to: first, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: first.path)
    try FileManager.default.removeItem(at: second)
    let replaced = try await cache.scan(files: files)
    XCTAssertEqual(replaced.map(\.headline), ["Swap!"])
    let empty = try await cache.scan(files: [])
    XCTAssertTrue(empty.isEmpty)
    _ = try await cache.scan(files: [files[0]])
    parsed = await cache.lastParsedFileCount
    XCTAssertEqual(parsed, 1, "Removed catalog entries must not survive in the cache")
  }

  func testAgentStateFailureKeepsExistingSectionAndDoesNotBlockOtherSections() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()))
    store.setWorkspaceRealtimeRefreshActive(false)
    store.setCorpusRoot(root, persistsDefault: false)
    let good = try JSONDecoder().decode(WorkspaceAgentStateSection<AgentGoalListPayload>.self, from: Data(#"{"value":{"schema":"org2:goal-list:v1","goals":[{"schema":"org2:goal:v1","id":"existing","title":"Existing","description":"","status":"active","measures":[],"file":"existing.org","createdAt":"2026-09-01","updatedAt":"2026-09-01"}]},"elapsedMilliseconds":1}"#.utf8))
    await store.refreshAgentGoals(prefetched: good)
    XCTAssertEqual(store.agentGoals.map(\.id), ["existing"])
    let failed = try JSONDecoder().decode(WorkspaceAgentStateSection<AgentGoalListPayload>.self, from: Data(#"{"error":"Unreadable goal","elapsedMilliseconds":1}"#.utf8))
    await store.refreshAgentGoals(prefetched: failed)
    let profiles = try JSONDecoder().decode(WorkspaceAgentStateSection<AgentProfileListPayload>.self, from: Data(#"{"value":{"schema":"org2:agent-profile-list:v1","profiles":[]},"elapsedMilliseconds":1}"#.utf8))
    await store.refreshAgentProfiles(prefetched: profiles)
    XCTAssertEqual(store.agentGoals.map(\.id), ["existing"])
    XCTAssertEqual(store.errorText, "Unreadable goal")
    XCTAssertTrue(store.isRunReviewPageLoadedForTesting(.agents))
  }
}

private final class RefreshMetricCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Org2CLIInvocationMetric] = []
  func append(_ value: Org2CLIInvocationMetric) { lock.lock(); defer { lock.unlock() }; values.append(value) }
  func take() -> [Org2CLIInvocationMetric] { lock.lock(); defer { lock.unlock() }; let result = values; values = []; return result }
}

extension WorkspacePerformanceRegressionTests {
  func testFullRefreshStagesBatchQueriesAndReuseNativeParses() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-perf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Keep this deterministic and credential-free; the user's corpus is never touched.
    for index in 0..<300 {
      let text = "* TODO Task \(index)\n:PROPERTIES:\n:ASSIGNEE: Fixture\n:END:\n" + String(repeating: "Representative document prose.\n", count: 30)
      try text.write(to: root.appendingPathComponent("note-\(index).org"), atomically: true, encoding: .utf8)
    }
    let recorder = RefreshMetricCollector()
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot(), telemetryHandler: recorder.append))
    store.setWorkspaceRealtimeRefreshActive(false)
    store.setCorpusRoot(root, persistsDefault: false)
    let productionConcurrency = store.workspaceRefreshConcurrencyForTesting
    let productionBatching = store.workspaceRefreshUsesBatchForTesting
    store.workspaceRefreshConcurrencyForTesting = 1
    store.workspaceRefreshUsesBatchForTesting = false
    // Warm the existing CLI caches for both paths, then model the previous
    // native behavior by clearing its new cache before the serial baseline.
    await store.refreshWorkspace()
    await store.workspaceTodoScanCache.clear()
    _ = recorder.take()
    await store.refreshWorkspace()
    let baseline = try XCTUnwrap(store.workspaceRefreshMetrics.first { $0.stage == "total" }).elapsedMilliseconds
    let expected = store.assignedWorkItems
    XCTAssertEqual(expected.count, 300)
    _ = recorder.take()
    store.workspaceRefreshConcurrencyForTesting = productionConcurrency
    store.workspaceRefreshUsesBatchForTesting = productionBatching
    await store.refreshWorkspace()
    let metrics = recorder.take()
    let optimized = try XCTUnwrap(store.workspaceRefreshMetrics.first { $0.stage == "total" }).elapsedMilliseconds
    XCTAssertEqual(store.assignedWorkItems, expected)
    XCTAssertNil(store.errorText)
    XCTAssertEqual(metrics.filter { $0.command == "cli.workspace.agent-state" }.count, 1)
    for command in ["cli.run.list", "cli.workflow.list", "cli.goal.list", "cli.agent-profile.list"] {
      XCTAssertFalse(metrics.contains { $0.command == command }, "Full refresh must batch \(command)")
    }
    XCTAssertEqual(Set(store.workspaceRefreshMetrics.map(\.stage)), Set(WorkspaceRefreshStage.allCases.map(\.rawValue) + ["total"]))
    let parsed = await store.workspaceTodoScanCache.lastParsedFileCount
    XCTAssertEqual(parsed, 0, "Unchanged files must not be reread and reparsed")
    // An absolute budget catches serious regression without timing-ratio flakes.
    XCTAssertLessThan(optimized, 30_000)
    print("Full refresh (300 documents): serial/unbatched (CLI warm, native uncached) \(baseline)ms; concurrent/batched warm \(optimized)ms")
    for metric in store.workspaceRefreshMetrics { print("Refresh stage \(metric.stage): \(metric.elapsedMilliseconds)ms") }
  }
}
