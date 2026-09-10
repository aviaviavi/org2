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
  func testThousandsOfChangedPathsRoundTripWithoutFoundationArgumentException() async throws {
    let root = try makeArgumentFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let arguments = ["index", "--files"] + (0..<5000).map {
      "/notes/\($0) spaced 'quoted' \"unicode 🦉\"\n.org"
    } + ["--incremental", "--format", "json"]
    let recorder = Org2CLIMetricRecorder()
    let cli = Org2CLI(repoRoot: root, telemetryHandler: recorder.append)
    let output = try await cli.run(arguments)
    let payload = try JSONDecoder().decode(ArgumentFixtureOutput.self, from: output)
    XCTAssertEqual(payload.arguments, arguments)
    XCTAssertEqual(payload.script, root.appendingPathComponent("dist/cli.js").path)
    let preload = try XCTUnwrap(payload.preload)
    XCTAssertFalse(FileManager.default.fileExists(atPath: preload))
    XCTAssertEqual(recorder.metrics.last?.outcome, .succeeded)
    XCTAssertEqual(recorder.metrics.last?.command, "cli.index")
  }

  func testLargeArgumentBytesAndESMEntryPointRoundTrip() async throws {
    let root = try makeArgumentFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try #"{"type":"module"}"#.write(
      to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8
    )
    let arguments = ["search", String(repeating: "🦉\n'\\\"", count: 40000)]
    let output = try await Org2CLI(repoRoot: root).run(arguments)
    let payload = try JSONDecoder().decode(ArgumentFixtureOutput.self, from: output)
    XCTAssertEqual(payload.arguments, arguments)
    XCTAssertNotNil(payload.preload)
  }

  func testOversizedArgumentsPreserveStdinAndCleanUpAfterFailure() async throws {
    let root = try makeArgumentFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("dist/parse.js")
    try """
    const fs = require('node:fs');
    fs.writeFileSync('preload-path', process.execArgv[1]);
    const input = fs.readFileSync(0, 'utf8');
    process.stderr.write(input === 'stdin payload' ? 'expected failure' : 'lost stdin');
    process.exitCode = 7;
    """.write(to: script, atomically: true, encoding: .utf8)
    do {
      let _: [String: String] = try await Org2CLI(repoRoot: root).parseTextJSON(
        "stdin payload", sourcePath: String(repeating: "long-path", count: 40000)
      )
      XCTFail("Expected failure")
    } catch let error as Org2CLIError {
      XCTAssertEqual(error, .commandFailed(status: 7, message: "expected failure"))
    }
    let preload = try String(contentsOf: root.appendingPathComponent("preload-path"), encoding: .utf8)
    XCTAssertFalse(FileManager.default.fileExists(atPath: preload))
  }

  func testArgumentTransportUsesPrivateDirectoryAndLeavesSmallRequestsUnchanged() throws {
    let small = try Org2CLIArgumentTransport(arguments: ["version"])
    XCTAssertEqual(small.directArguments, ["version"])
    XCTAssertTrue(small.nodeOptions.isEmpty)
    XCTAssertNil(small.temporaryDirectory)
    let large = try Org2CLIArgumentTransport(arguments: Array(repeating: "file", count: 5000))
    defer { large.removeTemporaryFiles() }
    let directory = try XCTUnwrap(large.temporaryDirectory)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    XCTAssertTrue(large.directArguments.isEmpty)
    XCTAssertEqual(large.nodeOptions.count, 2)
  }

  private struct ArgumentFixtureOutput: Decodable {
    let arguments: [String]
    let script: String
    let preload: String?
  }

  private func makeArgumentFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-cli-arguments-test-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try """
    process.stdout.write(JSON.stringify({
      arguments: process.argv.slice(2), script: process.argv[1], preload: process.execArgv[1]
    }));
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)
    return root
  }

  func testStaleConfiguredNodeFallsBackWithoutCrashing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-cli-stale-node-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    let node = root.appendingPathComponent("temporary-node")
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try #"process.stdout.write("fallback");"#
      .write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexec /usr/bin/env node \"$@\"\n"
      .write(to: node, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)

    let cli = Org2CLI(repoRoot: root, nodePath: node.path)
    try FileManager.default.removeItem(at: node)

    let output = try await cli.run(["--version"])
    XCTAssertEqual(String(decoding: output, as: UTF8.self), "fallback")
  }

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
        arguments: ["plugin", "update", "private-plugin-id", "--dir", "/private/corpus"]
      ),
      "cli.plugin.update"
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
