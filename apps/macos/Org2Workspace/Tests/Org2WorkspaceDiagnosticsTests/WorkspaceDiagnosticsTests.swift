import Foundation
import XCTest
@testable import Org2WorkspaceDiagnosticsCore

final class WorkspaceDiagnosticsTests: XCTestCase {
  func testHeartbeatResponderAcknowledgesAProcessTargetedPing() {
    let center = DistributedNotificationCenter.default()
    let responder = WorkspaceDiagnosticsHeartbeatResponder(center: center)
    let probe = HeartbeatAcknowledgementProbe()
    center.addObserver(
      probe,
      selector: #selector(HeartbeatAcknowledgementProbe.receive(_:)),
      name: WorkspaceDiagnosticsHeartbeat.acknowledgement,
      object: nil
    )
    defer {
      responder.stop()
      center.removeObserver(probe)
    }
    responder.start()

    let nonce = UUID().uuidString
    center.postNotificationName(
      WorkspaceDiagnosticsHeartbeat.ping,
      object: nil,
      userInfo: [
        WorkspaceDiagnosticsHeartbeat.targetPIDKey: NSNumber(value: ProcessInfo.processInfo.processIdentifier),
        WorkspaceDiagnosticsHeartbeat.nonceKey: nonce,
      ],
      deliverImmediately: true
    )
    let deadline = Date().addingTimeInterval(2)
    while probe.nonce == nil, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    XCTAssertEqual(probe.nonce, nonce)
    XCTAssertEqual(probe.pid, ProcessInfo.processInfo.processIdentifier)
  }

  func testHeartbeatPulseAcknowledgesWhileMainRunLoopTracksEvents() {
    let acknowledgement = LockedHeartbeatAcknowledgement()
    let pulse = WorkspaceDiagnosticsHeartbeatPulse(
      intervalSeconds: 0.05,
      leaseDurationSeconds: 2
    ) { _, _ in
      acknowledgement.record(onMainThread: Thread.isMainThread)
    }
    defer { pulse.stop() }
    pulse.activate(targetPID: ProcessInfo.processInfo.processIdentifier, nonce: UUID().uuidString)

    let deadline = Date().addingTimeInterval(2)
    let eventTrackingMode = RunLoop.Mode("NSEventTrackingRunLoopMode")
    while !acknowledgement.wasRecorded, Date() < deadline {
      RunLoop.current.run(mode: eventTrackingMode, before: Date().addingTimeInterval(0.01))
    }

    XCTAssertTrue(acknowledgement.wasRecorded)
    XCTAssertTrue(acknowledgement.wasRecordedOnMainThread)
  }

  func testHeartbeatPulseCanRepeatTheLastAcknowledgedNonce() {
    XCTAssertTrue(WorkspaceDiagnosticsMonitor.acceptsHeartbeatAcknowledgement(
      "pending",
      pendingNonces: ["pending"],
      lastAcknowledgedNonce: nil
    ))
    XCTAssertTrue(WorkspaceDiagnosticsMonitor.acceptsHeartbeatAcknowledgement(
      "active-pulse",
      pendingNonces: [],
      lastAcknowledgedNonce: "active-pulse"
    ))
    XCTAssertFalse(WorkspaceDiagnosticsMonitor.acceptsHeartbeatAcknowledgement(
      "stale",
      pendingNonces: [],
      lastAcknowledgedNonce: "active-pulse"
    ))
  }

  func testParsesConservativeRuntimeOptions() throws {
    let options = try WorkspaceDiagnosticsOptions.parse([
      "--corpus", "/tmp/corpus",
      "--bundle-id", "org.org2.workspace.codex",
      "--poll-seconds", "2",
      "--hang-seconds", "7",
      "--cpu-percent", "120",
      "--cpu-seconds", "20",
      "--memory-mb", "2048",
      "--sample-seconds", "3",
      "--cooldown-seconds", "900",
    ])

    XCTAssertEqual(options.corpusPath, "/tmp/corpus")
    XCTAssertEqual(options.bundleIdentifier, "org.org2.workspace.codex")
    XCTAssertEqual(options.pollIntervalSeconds, 2)
    XCTAssertEqual(options.hangThresholdSeconds, 7)
    XCTAssertEqual(options.cpuThresholdPercent, 120)
    XCTAssertEqual(options.cpuThresholdDurationSeconds, 20)
    XCTAssertEqual(options.memoryThresholdMegabytes, 2048)
    XCTAssertEqual(options.sampleDurationSeconds, 3)
    XCTAssertEqual(options.cooldownSeconds, 900)
  }

  func testHangTriggerWinsAndCooldownSuppressesRepeatedCapture() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var evaluator = WorkspaceDiagnosticsTriggerEvaluator(
      hangThresholdSeconds: 5,
      cpuThresholdPercent: 95,
      cpuThresholdDurationSeconds: 15,
      memoryThresholdBytes: 1_500 * 1_048_576,
      cooldownSeconds: 600
    )
    let sample = WorkspaceDiagnosticsResourceSample(
      capturedAt: start,
      cpuPercent: 99,
      residentBytes: 1_600 * 1_048_576,
      heartbeatGapSeconds: 6
    )

    XCTAssertEqual(evaluator.evaluate(sample)?.kind, .unresponsive)
    evaluator.recordIncident(at: start)
    XCTAssertNil(evaluator.evaluate(WorkspaceDiagnosticsResourceSample(
      capturedAt: start.addingTimeInterval(30),
      cpuPercent: 99,
      residentBytes: 1_600 * 1_048_576,
      heartbeatGapSeconds: 36
    )))
  }

  func testPollingInterruptionDoesNotBecomeAnUnresponsiveIncident() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var continuity = WorkspaceDiagnosticsPollContinuity(expectedIntervalSeconds: 1)
    var evaluator = WorkspaceDiagnosticsTriggerEvaluator(
      hangThresholdSeconds: 5,
      cpuThresholdPercent: 0,
      cpuThresholdDurationSeconds: 15,
      memoryThresholdBytes: 0,
      cooldownSeconds: 0
    )

    _ = continuity.observe(
      at: start,
      lastAcknowledgementAt: start,
      hasReceivedHeartbeat: true
    )
    let continuousPoll = continuity.observe(
      at: start.addingTimeInterval(1),
      lastAcknowledgementAt: start,
      hasReceivedHeartbeat: true
    )
    XCTAssertFalse(continuousPoll.resumedAfterInterruption)
    XCTAssertEqual(continuousPoll.heartbeatGapSeconds, 1)

    let afterSleep = start.addingTimeInterval(1_038.5)
    let resumedPoll = continuity.observe(
      at: afterSleep,
      lastAcknowledgementAt: start,
      hasReceivedHeartbeat: true
    )
    XCTAssertTrue(resumedPoll.resumedAfterInterruption)
    XCTAssertEqual(resumedPoll.heartbeatGapSeconds, 0)
    XCTAssertNil(evaluator.evaluate(sample(
      at: afterSleep,
      cpu: 0,
      heartbeatGap: resumedPoll.heartbeatGapSeconds
    )))

    let nextPoll = continuity.observe(
      at: afterSleep.addingTimeInterval(1),
      lastAcknowledgementAt: afterSleep,
      hasReceivedHeartbeat: true
    )
    XCTAssertFalse(nextPoll.resumedAfterInterruption)
    XCTAssertEqual(nextPoll.heartbeatGapSeconds, 1)
  }

  func testSustainedCPURequiresFullDuration() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var evaluator = WorkspaceDiagnosticsTriggerEvaluator(
      hangThresholdSeconds: 0,
      cpuThresholdPercent: 90,
      cpuThresholdDurationSeconds: 10,
      memoryThresholdBytes: 0,
      cooldownSeconds: 0
    )

    XCTAssertNil(evaluator.evaluate(sample(at: start, cpu: 95)))
    XCTAssertNil(evaluator.evaluate(sample(at: start.addingTimeInterval(9), cpu: 96)))
    XCTAssertEqual(
      evaluator.evaluate(sample(at: start.addingTimeInterval(10), cpu: 97))?.kind,
      .sustainedCPU
    )
  }

  func testWritesRawIncidentWithoutCorpusContentFileExtensions() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-diagnostics-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = """
    {
      "corpus": {
        "schema": "org2:corpus:v1",
        "id": "diagnostics-fixture",
        "name": "Diagnostics Fixture",
        "kind": "project"
      }
    }
    """
    try Data(config.utf8).write(to: root.appendingPathComponent("org2.json"))
    let corpus = try WorkspaceDiagnosticsCorpus.load(at: root)
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let output = try WorkspaceDiagnosticsIncidentWriter(
      corpus: corpus,
      stackSampler: FixtureStackSampler()
    ).capture(
      trigger: WorkspaceDiagnosticsTrigger(kind: .unresponsive, detail: "Fixture hang"),
      target: WorkspaceDiagnosticsTargetMetadata(
        pid: 42,
        bundleIdentifier: "org.org2.workspace",
        applicationName: "Org2Workspace",
        applicationVersion: "0.4.0",
        applicationBuild: "1",
        executableName: "Org2Workspace"
      ),
      samples: [sample(at: capturedAt, cpu: 100, heartbeatGap: 8)],
      pollIntervalSeconds: 1,
      sampleDurationSeconds: 1,
      at: capturedAt
    )

    XCTAssertTrue(output.path.contains("/raw/diagnostics/org2-workspace/"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("incident.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("stacks.sample.txt").path))
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)), [
      "incident.json",
      "stacks.sample.txt",
    ])

    let data = try Data(contentsOf: output.appendingPathComponent("incident.json"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let incident = try decoder.decode(WorkspaceDiagnosticsIncident.self, from: data)
    XCTAssertEqual(incident.schema, WorkspaceDiagnosticsIncident.schema)
    XCTAssertEqual(incident.corpusID, "diagnostics-fixture")
    XCTAssertEqual(incident.trigger.kind, .unresponsive)
    XCTAssertEqual(incident.target.pid, 42)
    XCTAssertNotNil(incident.hotPathFingerprint)
    XCTAssertEqual(incident.hotPathFrames.count, 2)
  }

  private func sample(
    at date: Date,
    cpu: Double?,
    residentBytes: UInt64 = 512 * 1_048_576,
    heartbeatGap: Double? = nil
  ) -> WorkspaceDiagnosticsResourceSample {
    WorkspaceDiagnosticsResourceSample(
      capturedAt: date,
      cpuPercent: cpu,
      residentBytes: residentBytes,
      heartbeatGapSeconds: heartbeatGap
    )
  }
}

private final class HeartbeatAcknowledgementProbe: NSObject {
  private(set) var nonce: String?
  private(set) var pid: pid_t?

  @objc func receive(_ notification: Notification) {
    nonce = notification.userInfo?[WorkspaceDiagnosticsHeartbeat.nonceKey] as? String
    pid = (notification.userInfo?[WorkspaceDiagnosticsHeartbeat.responderPIDKey] as? NSNumber)?.int32Value
  }
}

private final class LockedHeartbeatAcknowledgement: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded = false
  private var recordedOnMainThread = false

  var wasRecorded: Bool {
    lock.withLock { recorded }
  }

  var wasRecordedOnMainThread: Bool {
    lock.withLock { recordedOnMainThread }
  }

  func record(onMainThread: Bool) {
    lock.withLock {
      recorded = true
      recordedOnMainThread = recordedOnMainThread || onMainThread
    }
  }
}

private struct FixtureStackSampler: WorkspaceDiagnosticsStackSampling {
  func capture(pid: pid_t, durationSeconds: Int, outputURL: URL) -> WorkspaceDiagnosticsStackSample {
    let sample = """
    + 100 specialized GraphHost.flushTransactions() (in SwiftUICore)
    + 95 static OrgRoamLinkResolver.__derived_struct_equals(_:_:) (in Org2Workspace) + 556 [0x123]
    + 90 protocol witness for static Equatable.== (in Org2Workspace) + 84 [0x456]
    """
    do {
      try Data(sample.utf8).write(to: outputURL)
      return WorkspaceDiagnosticsStackSample(exitStatus: 0, error: nil)
    } catch {
      return WorkspaceDiagnosticsStackSample(exitStatus: -1, error: error.localizedDescription)
    }
  }
}
