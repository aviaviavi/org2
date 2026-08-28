import Foundation
import XCTest
@testable import Org2WorkspaceCore

private final class Org2CLIMetricRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Org2CLIInvocationMetric] = []

  func append(_ metric: Org2CLIInvocationMetric) {
    lock.lock()
    storage.append(metric)
    lock.unlock()
  }

  var metrics: [Org2CLIInvocationMetric] {
    lock.lock()
    let metrics = storage
    lock.unlock()
    return metrics
  }
}

final class Org2CLITelemetryTests: XCTestCase {
  func testRecordsSanitizedSuccessfulCommandMetric() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-cli-telemetry-success-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try #"process.stdout.write("done");"#
      .write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)
    let recorder = Org2CLIMetricRecorder()
    let cli = Org2CLI(repoRoot: root, telemetryHandler: recorder.append)

    let output = try await cli.run([
      "source", "sync", "private-customer-profile",
      "--dir", "/private/customer/corpus",
      "--token", "secret-value"
    ])

    XCTAssertEqual(String(decoding: output, as: UTF8.self), "done")
    let metric = try XCTUnwrap(recorder.metrics.last)
    XCTAssertEqual(metric.command, "cli.source.sync")
    XCTAssertEqual(metric.outcome, .succeeded)
    XCTAssertEqual(metric.standardInputBytes, 0)
    XCTAssertEqual(metric.standardOutputBytes, 4)
    XCTAssertEqual(metric.standardErrorBytes, 0)
    XCTAssertEqual(metric.exitStatus, 0)
    XCTAssertGreaterThanOrEqual(metric.elapsedMilliseconds, 0)
    XCTAssertFalse(metric.command.contains("private-customer-profile"))
    XCTAssertFalse(metric.command.contains("secret-value"))
    XCTAssertFalse(metric.command.contains("/private/customer/corpus"))
  }

  func testRecordsFailureOutcomeAndPayloadSizes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-cli-telemetry-failure-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    process.stdout.write("partial");
    process.stderr.write("failure");
    process.exitCode = 7;
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)
    let recorder = Org2CLIMetricRecorder()
    let cli = Org2CLI(repoRoot: root, telemetryHandler: recorder.append)

    do {
      _ = try await cli.run(["search", "private search query"])
      XCTFail("Expected command failure")
    } catch let error as Org2CLIError {
      XCTAssertEqual(error, .commandFailed(status: 7, message: "failure"))
    }

    let metric = try XCTUnwrap(recorder.metrics.last)
    XCTAssertEqual(metric.command, "cli.search")
    XCTAssertEqual(metric.outcome, .failed)
    XCTAssertEqual(metric.standardOutputBytes, 7)
    XCTAssertEqual(metric.standardErrorBytes, 7)
    XCTAssertEqual(metric.exitStatus, 7)
    XCTAssertFalse(metric.command.contains("private search query"))
  }

  func testSanitizedIdentityNeverIncludesDataArguments() {
    let cli = URL(fileURLWithPath: "/tmp/dist/cli.js")

    XCTAssertEqual(
      Org2CLI.telemetryCommandIdentity(
        scriptPath: cli,
        arguments: ["run", "show", "private-run-id", "--dir", "/private/corpus"]
      ),
      "cli.run.show"
    )
    XCTAssertEqual(
      Org2CLI.telemetryCommandIdentity(
        scriptPath: cli,
        arguments: ["search", "private query"]
      ),
      "cli.search"
    )
    XCTAssertEqual(
      Org2CLI.telemetryCommandIdentity(
        scriptPath: URL(fileURLWithPath: "/tmp/dist/render-html.js"),
        arguments: ["--source-path", "/private/note.org2"]
      ),
      "render-html"
    )
    XCTAssertEqual(
      Org2CLI.telemetryCommandIdentity(
        scriptPath: cli,
        arguments: ["source", "private-profile", "secret-value"]
      ),
      "cli.source"
    )
    XCTAssertEqual(
      Org2CLI.telemetryCommandIdentity(
        scriptPath: cli,
        arguments: ["private-command", "secret-value"]
      ),
      "cli.unknown"
    )
  }
}
