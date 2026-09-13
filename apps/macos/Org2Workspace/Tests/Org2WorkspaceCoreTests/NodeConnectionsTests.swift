import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class NodeConnectionsTests: XCTestCase {
  @MainActor func testNativeMentionActionEditsOnlySelectedOccurrenceAndRejectsStaleSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("org2-connections-swift-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("alpha.org")
    let source = root.appendingPathComponent("mentions.org")
    try "#+TITLE: Alpha Topic\n#+ID: alpha-stable\n".write(to: target, atomically: true, encoding: .utf8)
    try "#+TITLE: Meeting\nAlpha Topic and Alpha Topic.\n".write(to: source, atomically: true, encoding: .utf8)
    let defaultsName = "org2-connections-swift-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults, openClawTranscriptURL: root.appendingPathComponent("chat.json"))
    store.setWorkspaceRealtimeRefreshActive(false)
    store.setCorpusRoot(root, persistsDefault: false)
    let payload: NodeConnectionsPayload = try await store.cli.runJSON([
      "roam", "connections", "--dir", root.path, "--id", "alpha-stable", "--format", "json"
    ])
    XCTAssertEqual(payload.mentions.count, 2)
    let mention = try XCTUnwrap(payload.mentions.first)
    try await store.linkConnectionMention(mention, target: "alpha-stable", root: root.path)
    let changed = try String(contentsOf: source, encoding: .utf8)
    XCTAssertEqual(changed, "#+TITLE: Meeting\n[[id:alpha-stable][Alpha Topic]] and Alpha Topic.\n")
    do {
      try await store.linkConnectionMention(try XCTUnwrap(payload.mentions.last), target: "alpha-stable", root: root.path)
      XCTFail("A second action from the stale scan must fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("changed"), error.localizedDescription)
    }
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), changed)
  }

  func testDecodesSharedGraphAndPreservesSourceNavigation() throws {
    let data = Data(Self.fixture.utf8)
    let payload = try JSONDecoder().decode(NodeConnectionsPayload.self, from: data)
    let graph = try XCTUnwrap(payload.neighborhood)
    XCTAssertEqual(graph.focus.id, "alpha-stable")
    XCTAssertEqual(graph.focus.location.file, "/corpus/alpha.org")
    XCTAssertEqual(graph.focus.location.lineForEditor, 17)
    XCTAssertEqual(graph.focus.location.idValue, "alpha-stable")
    XCTAssertEqual(graph.edges.first?.source, "beta-stable")
    XCTAssertEqual(graph.edges.first?.target, "alpha-stable")
    XCTAssertEqual(graph.edges.first?.count, 2)
    XCTAssertTrue(graph.truncated)
    XCTAssertEqual(payload.mentions.first?.location.file, "/corpus/mentions.org")
    XCTAssertEqual(payload.mentions.first?.location.lineForEditor, 3)
    XCTAssertNil(payload.mentions.first?.location.idValue)
  }

  func testAmbiguousMentionsRetainEveryExplicitDestinationAndRevision() throws {
    let payload = try JSONDecoder().decode(NodeConnectionsPayload.self, from: Data(Self.fixture.utf8))
    let mention = try XCTUnwrap(payload.mentions.first)
    XCTAssertTrue(mention.ambiguous)
    XCTAssertEqual(mention.candidates.map(\.id), ["alpha-stable", "gamma-stable"])
    XCTAssertEqual(mention.revision, "sha256:unchanged-source")
    XCTAssertEqual(mention.start, 3)
    XCTAssertEqual(mention.end, 15)
    XCTAssertTrue(payload.mentionsTruncated)
  }

  func testNoStableIDIsAnEmptyDiscoveryState() throws {
    let data = Data(#"{"root":"/corpus","scannedFiles":2,"neighborhood":null,"mentions":[],"mentionsTruncated":false}"#.utf8)
    let payload = try JSONDecoder().decode(NodeConnectionsPayload.self, from: data)
    XCTAssertNil(payload.neighborhood)
    XCTAssertTrue(payload.mentions.isEmpty)
    XCTAssertEqual(NodeContextTab.connections.title, "Graph")
    XCTAssertTrue(NodeContextTab.allCases.contains(.connections))
  }

  private static let fixture = #"""
  {
    "$schema":"org2:connections:v1","root":"/corpus","scannedFiles":4,
    "neighborhood": {
      "focus":{"id":"alpha-stable","label":"Alpha Topic","file":"/corpus/alpha.org","line":17,"degreeIn":2,"degreeOut":1},
      "depth":2,"truncated":true,
      "nodes":[{"id":"alpha-stable","label":"Alpha Topic","file":"/corpus/alpha.org","line":17,"degreeIn":2,"degreeOut":1}],
      "edges":[{"source":"beta-stable","target":"alpha-stable","count":2}]
    },
    "mentions":[{
      "id":"mention-key","file":"/corpus/mentions.org","line":3,"start":3,"end":15,
      "text":"Shared Alias","context":"😀 Shared Alias is discussed here.","revision":"sha256:unchanged-source","ambiguous":true,
      "candidates":[{"id":"alpha-stable","label":"Alpha Topic","file":"/corpus/alpha.org"},{"id":"gamma-stable","label":"Gamma Topic","file":"/corpus/gamma.org"}]
    }],"mentionsTruncated":true
  }
  """#
}
