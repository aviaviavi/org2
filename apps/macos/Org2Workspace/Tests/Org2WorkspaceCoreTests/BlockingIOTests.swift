import Foundation
import XCTest

@testable import Org2WorkspaceCore

final class BlockingIOTests: XCTestCase {
  /// Long-running agent turns wait on pipes and child processes. Those waits
  /// must not occupy the cooperative pool, or unrelated async work (chat
  /// rendering, the thread outputs chip) stalls until the turns finish.
  func testParkedPipeReadsDoNotStarveDetachedTasks() async throws {
    let parkedCount = ProcessInfo.processInfo.activeProcessorCount * 3
    let pipes = (0..<parkedCount).map { _ in Pipe() }
    let readers = pipes.map { pipe in
      Task.detached {
        try await BlockingIO.read(pipe.fileHandleForReading, upToCount: 16)
      }
    }
    // Give every reader time to park in read(2).
    try await Task.sleep(for: .milliseconds(200))

    let started = Date()
    let value = try await withThrowingTaskGroup(of: Int?.self) { group in
      group.addTask { await Task.detached(priority: .utility) { 42 }.value }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        return nil
      }
      let first = try await group.next() ?? nil
      group.cancelAll()
      return first
    }
    XCTAssertEqual(value, 42, "a detached task starved behind parked pipe reads")
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)

    for pipe in pipes {
      try pipe.fileHandleForWriting.write(contentsOf: Data("x".utf8))
    }
    for reader in readers {
      let chunk = try await reader.value
      XCTAssertEqual(chunk, Data("x".utf8))
    }
  }

  func testTerminationStatusReportsExitCode() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "exit 3"]
    try process.run()
    let status = await BlockingIO.terminationStatus(of: process)
    XCTAssertEqual(status, 3)
  }

  func testReadToEndCollectsOutputUntilEOF() async throws {
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
    try pipe.fileHandleForWriting.close()
    let data = try await BlockingIO.readToEnd(pipe.fileHandleForReading)
    XCTAssertEqual(data, Data("hello".utf8))
  }

  /// Every `org2` CLI call waits for its child process. Slow commands must not
  /// hold cooperative threads, or chat rendering and the outputs chip stall.
  func testSlowCLICommandsDoNotStarveDetachedTasks() async throws {
    let root = try makeSlowCLIFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = Org2CLI(repoRoot: root)
    let slowCount = ProcessInfo.processInfo.activeProcessorCount * 2
    let commands = (0..<slowCount).map { _ in
      Task.detached { try await cli.run(["slow"]) }
    }
    try await Task.sleep(for: .milliseconds(300))

    let started = Date()
    let value = try await withThrowingTaskGroup(of: Int?.self) { group in
      group.addTask { await Task.detached(priority: .utility) { 7 }.value }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        return nil
      }
      let first = try await group.next() ?? nil
      group.cancelAll()
      return first
    }
    XCTAssertEqual(value, 7, "a detached task starved behind running CLI commands")
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    for command in commands { command.cancel() }
    for command in commands { _ = try? await command.value }
  }

  func testCancellingCLICommandStopsTheChildPromptly() async throws {
    let root = try makeSlowCLIFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = Org2CLI(repoRoot: root)
    let command = Task.detached { try await cli.run(["slow"]) }
    try await Task.sleep(for: .milliseconds(300))
    let started = Date()
    command.cancel()
    do {
      _ = try await command.value
      XCTFail("a cancelled CLI command completed")
    } catch is CancellationError {
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
  }

  private func makeSlowCLIFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-cli-slow-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try "setTimeout(() => process.stdout.write('done'), 20000);"
      .write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)
    return root
  }
}
