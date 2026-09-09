import Foundation
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class BundledAgentTests: XCTestCase {
  func testExistingDestinationDecodesWithToolsDisabled() throws {
    let old = AIChatDestinationConfiguration(name: "Local", mention: "local", adapter: .ollama)
    var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    value.removeValue(forKey: "workspaceToolsEnabled")
    var decoded = try JSONDecoder().decode(AIChatDestinationConfiguration.self, from: JSONSerialization.data(withJSONObject: value))
    XCTAssertFalse(decoded.usesBundledAgent(experimentalFeaturesEnabled: true))
    decoded.workspaceToolsEnabled = true
    XCTAssertFalse(decoded.usesBundledAgent(experimentalFeaturesEnabled: false))
    XCTAssertTrue(decoded.usesBundledAgent(experimentalFeaturesEnabled: true))
    decoded.adapter = .codexLocal
    XCTAssertFalse(decoded.usesBundledAgent(experimentalFeaturesEnabled: true))
  }

  func testExperimentalFeaturesDefaultOffAndPersistAcrossWorkspaces() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "BundledAgentTests.ExperimentalFeatures.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    func makeStore(_ transcript: String) -> WorkspaceStore {
      WorkspaceStore(defaults: defaults, openClawTranscriptURL: root.appendingPathComponent(transcript), legacyDefaultsDomains: [])
    }
    var destination = AIChatDestinationConfiguration(name: "Local", mention: "local", adapter: .ollama)
    destination.workspaceToolsEnabled = true
    let store = makeStore("first.json")
    XCTAssertFalse(store.experimentalFeaturesEnabled)
    XCTAssertFalse(destination.usesBundledAgent(experimentalFeaturesEnabled: store.experimentalFeaturesEnabled))
    store.experimentalFeaturesEnabled = true
    let reopened = makeStore("second.json")
    XCTAssertTrue(reopened.experimentalFeaturesEnabled)
    XCTAssertTrue(destination.usesBundledAgent(experimentalFeaturesEnabled: reopened.experimentalFeaturesEnabled))
    reopened.experimentalFeaturesEnabled = false
    let disabled = makeStore("third.json")
    XCTAssertFalse(disabled.experimentalFeaturesEnabled)
    XCTAssertFalse(destination.usesBundledAgent(experimentalFeaturesEnabled: disabled.experimentalFeaturesEnabled))
    XCTAssertEqual(destination.workspaceToolsEnabled, true, "Disabling experiments preserves the per-destination preference")
  }

  func testHostBindsTurnAndRequiresExactReviewedPreview() async throws {
    for approves in [false, true] {
      var text = "* TODO Unsaved draft\n"
      var writes = 0
      var reviews = 0
      let broker = OpenClawLocalEditBroker(documentReader: { turnID, path, _ in
        XCTAssertEqual(turnID, "host-turn")
        return OpenClawLocalEditDocument(relativePath: path, text: text, origin: .editor)
      }, replacementApplier: { turnID, replacements in
        XCTAssertEqual(turnID, "host-turn")
        writes += 1
        text = replacements[0].replacementText
        return OpenClawLocalEditApplyResult(summary: OpenClawCorpusChangeSummary(files: []))
      })
      await broker.beginTurn("host-turn")
      let workspace = BundledAgentWorkspaceTools(
        turnID: "host-turn", corpusRoot: URL(fileURLWithPath: "/fixture"),
        cli: Org2CLI(repoRoot: URL(fileURLWithPath: "/fixture")), broker: broker,
        approve: { review in
          reviews += 1
          XCTAssertTrue(review.contains("* TODO Unsaved draft"))
          XCTAssertTrue(review.contains("* DONE Unsaved draft"))
          return approves
        }
      )
      let unknown = try await workspace.execute("exec", arguments: .object([:]))
      XCTAssertFalse(unknown.success)
      let forged = try await workspace.execute("org2_workspace_patch_apply", arguments: .object(["previewId": .string("forged")]))
      XCTAssertFalse(forged.success)
      XCTAssertEqual(reviews, 0)
      let read = try await workspace.execute("org2_workspace_read", arguments: .object([
        "turnId": .string("model-forged-turn"), "path": .string("notes/task.org")
      ]))
      let readValue = try JSONDecoder().decode(JSONValue.self, from: Data(read.text.utf8))
      XCTAssertEqual(readValue["origin"]?.stringValue, "editor")
      let preview = try await workspace.execute("org2_workspace_patch_preview", arguments: .object([
        "edits": .array([.object([
          "path": .string("notes/task.org"),
          "expectedSha256": try XCTUnwrap(readValue["sha256"]),
          "replacementText": .string("* DONE Unsaved draft\n")
        ])])
      ]))
      XCTAssertTrue(preview.success)
      let previewValue = try JSONDecoder().decode(JSONValue.self, from: Data(preview.text.utf8))
      let applyArgs: JSONValue = .object(["previewId": try XCTUnwrap(previewValue["previewId"])])
      let applied = try await workspace.execute("org2_workspace_patch_apply", arguments: applyArgs)
      XCTAssertEqual(applied.success, approves)
      XCTAssertEqual(writes, approves ? 1 : 0)
      XCTAssertEqual(reviews, 1)
      let repeated = try await workspace.execute("org2_workspace_patch_apply", arguments: applyArgs)
      XCTAssertFalse(repeated.success)
      XCTAssertEqual(reviews, 1)
      await broker.endTurn("host-turn")
    }
  }

  func testFileChangedDuringApprovalIsNotWritten() async throws {
    var text = "Original"
    let broker = OpenClawLocalEditBroker(documentReader: { _, path, _ in
      OpenClawLocalEditDocument(relativePath: path, text: text, origin: .editor)
    }, replacementApplier: { _, _ in
      XCTFail("Stale patch must not be applied")
      return OpenClawLocalEditApplyResult(summary: OpenClawCorpusChangeSummary(files: []))
    })
    await broker.beginTurn("turn")
    let workspace = BundledAgentWorkspaceTools(
      turnID: "turn", corpusRoot: URL(fileURLWithPath: "/fixture"),
      cli: Org2CLI(repoRoot: URL(fileURLWithPath: "/fixture")), broker: broker,
      approve: { _ in text = "New user draft"; return true }
    )
    _ = try await workspace.execute("org2_workspace_read", arguments: .object(["path": .string("note.org")]))
    let preview = try await workspace.execute("org2_workspace_patch_preview", arguments: .object([
      "edits": .array([.object([
        "path": .string("note.org"), "expectedSha256": .string(OpenClawLocalEditBroker.sha256(text)),
        "replacementText": .string("Proposed")
      ])])
    ]))
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(preview.text.utf8))
    let result = try await workspace.execute("org2_workspace_patch_apply", arguments: .object(["previewId": try XCTUnwrap(value["previewId"])]))
    XCTAssertFalse(result.success)
    XCTAssertEqual(text, "New user draft")
  }

  func testChildProtocolRoundTripAndPrivateCredentialTransport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("dist"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = """
    IFS= read -r request
    test -z "$OPENAI_API_KEY" || exit 8
    case "$request" in *test-private-credential*) ;; *) exit 9 ;; esac
    printf '%s\\n' '{"type":"tool","id":"1","name":"org2_workspace_read","arguments":{"path":"note.org"}}'
    IFS= read -r result
    case "$result" in *toolResult*) ;; *) exit 10 ;; esac
    printf '%s\\n' '{"type":"done","reply":"Read completed"}'
    """
    try script.write(to: root.appendingPathComponent("dist/bundled-agent.js"), atomically: true, encoding: .utf8)
    let settings = try AIProviderChatSettings(adapter: .ollama, endpoint: "http://127.0.0.1:11434/api", apiKey: "test-private-credential")
    let reply = try await BundledAgentClient(cli: Org2CLI(repoRoot: root, nodePath: "/bin/sh")).send(
      settings: settings, model: "fixture", messages: [], system: "Fixture", tools: [], onEvent: { _ in },
      execute: { name, args in
        XCTAssertEqual(name, "org2_workspace_read")
        XCTAssertEqual(args["path"]?.stringValue, "note.org")
        return CodexDynamicToolResult(success: true, text: "Fixture read")
      }
    )
    XCTAssertEqual(reply, "Read completed")
  }

  func testCancellationTerminatesAWaitingChild() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("dist"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // exec ensures there is no shell descendant keeping stdout open after Stop.
    try "exec /bin/sleep 30\n".write(to: root.appendingPathComponent("dist/bundled-agent.js"), atomically: true, encoding: .utf8)
    let settings = try AIProviderChatSettings(adapter: .ollama, endpoint: "", apiKey: nil)
    let client = BundledAgentClient(cli: Org2CLI(repoRoot: root, nodePath: "/bin/sh"))
    let task = Task {
      try await client.send(settings: settings, model: "fixture", messages: [], system: "", tools: [], onEvent: { _ in },
        execute: { _, _ in XCTFail("Canceled turn executed a tool"); return CodexDynamicToolResult(success: false, text: "") })
    }
    try await Task.sleep(for: .milliseconds(150))
    let start = Date()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Canceled child returned success")
    } catch is CancellationError {
      XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
  }
}
