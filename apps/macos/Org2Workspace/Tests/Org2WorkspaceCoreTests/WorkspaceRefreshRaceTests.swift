import Foundation
import XCTest
@testable import Org2WorkspaceCore

extension WorkspaceRefreshTests {
  func testBatchResultCannotPublishAfterCorpusSwitch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-switch-\(UUID().uuidString)")
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    _ = try await cli.run(["goal", "create", "old-goal", "--title", "Old corpus goal", "--dir", root.path, "--apply", "--json"])
    let snapshot: WorkspaceAgentStateSnapshot = try await cli.runJSON(["workspace", "agent-state", "--dir", root.path, "--json"])
    let store = WorkspaceStore(cli: cli)
    store.setWorkspaceRealtimeRefreshActive(false)
    store.setCorpusRoot(root, persistsDefault: false)
    let entered = expectation(description: "batch read in flight")
    let (gate, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    store.workspaceAgentStateLoaderForTesting = {
      entered.fulfill()
      for await _ in gate {}
      return snapshot
    }
    let refresh = Task { await store.refreshWorkspace() }
    await fulfillment(of: [entered], timeout: 20)
    let operation = try XCTUnwrap(store.workspaceRefreshTaskForTesting)
    store.setCorpusRoot(other, persistsDefault: false)
    continuation.finish()
    await refresh.value
    await operation.value
    XCTAssertTrue(store.agentGoals.isEmpty)
    XCTAssertEqual(store.corpusRoot?.standardizedFileURL, other.standardizedFileURL)
    XCTAssertFalse(store.isRefreshingWorkspace)
  }

  func testBatchInvalidationFetchesFreshSectionInsteadOfMarkingOldDataClean() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-invalidate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let stale: WorkspaceAgentStateSnapshot = try await cli.runJSON(["workspace", "agent-state", "--dir", root.path, "--json"])
    let store = WorkspaceStore(cli: cli)
    store.setWorkspaceRealtimeRefreshActive(false)
    store.setCorpusRoot(root, persistsDefault: false)
    store.workspaceAgentStateLoaderForTesting = {
      _ = try await cli.run(["goal", "create", "new-goal", "--title", "New goal", "--dir", root.path, "--apply", "--json"])
      store.handleCorpusFileEvents([root.appendingPathComponent("goals/new-goal.org2").path], corpusRoot: root, requiresFullScan: false)
      return stale
    }
    await store.refreshWorkspace()
    XCTAssertEqual(store.agentGoals.map(\.id), ["new-goal"])
    XCTAssertNil(store.errorText)
  }
}

extension WorkspaceRefreshTests {
  func testLateCLIStagesRespectCancellationAndCorpusSwitch() async throws {
    for command in ["agenda", "source"] {
      for cancel in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-late-\(UUID().uuidString)")
        let dist = root.appendingPathComponent("dist")
        let corpus = root.appendingPathComponent("corpus")
        let other = root.appendingPathComponent("other")
        for directory in [dist, corpus, other] {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        // A real subprocess that can finish after navigation. The gate makes
        // the race deterministic instead of assuming a particular CLI speed.
        let script = #"""
        const fs = require('node:fs');
        const command = process.argv[2];
        async function main() {
          if (command === 'agenda' || (command === 'source' && process.argv[3] === 'list')) {
            fs.writeFileSync('entered', 'yes');
            const deadline = Date.now() + 20000;
            while (!fs.existsSync('release') && Date.now() < deadline) {
              await new Promise(resolve => setTimeout(resolve, 10));
            }
          }
          if (command === 'agenda') {
            process.stdout.write(JSON.stringify({range:{start:'2026-09-01',end:'2026-09-01',days:1},overdue:[],days:[]}));
          } else if (command === 'source' && process.argv[3] === 'list') {
            process.stdout.write(JSON.stringify([{id:'old-corpus',type:'slack',enabled:true,scopes:[],rawZone:'raw',reviewZone:'views',ingestionLimit:10,syncArgs:[],media:'metadata-only',binary:'fixture',binaryAvailable:true,configAvailable:true,ready:true}]));
          } else {
            process.stdout.write(JSON.stringify({sources:[]}));
          }
        }
        main();
        """#
        try script.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)
        let store = WorkspaceStore(cli: Org2CLI(repoRoot: root))
        store.setWorkspaceRealtimeRefreshActive(false)
        store.setCorpusRoot(corpus, persistsDefault: false)
        let request = Task {
          if command == "agenda" { await store.refreshAgenda() }
          else { await store.refreshSourceConnections() }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("entered").path), ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("entered").path))
        if cancel { request.cancel() }
        else { store.setCorpusRoot(other, persistsDefault: false) }
        try "go".write(to: root.appendingPathComponent("release"), atomically: true, encoding: .utf8)
        await request.value
        XCTAssertNil(store.agenda, "Late \(command) results must not replace current state")
        XCTAssertTrue(store.sourceProfiles.isEmpty)
        XCTAssertNil(store.errorText, "Cancellation/old-corpus failures must not become current errors")
      }
    }
  }
}
