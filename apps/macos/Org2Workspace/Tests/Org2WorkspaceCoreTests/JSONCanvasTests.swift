import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class JSONCanvasTests: XCTestCase {
  func testSharedCanvasContractDecodesTypesOrderingAndGeometry() throws {
    let payload = try JSONDecoder().decode(JSONCanvasPayload.self, from: Data(Self.fixture.utf8))
    let nodes = try XCTUnwrap(payload.document.nodes)
    XCTAssertEqual(nodes.map(\.id), ["group", "note", "text"])
    XCTAssertEqual(nodes[1].org2Ref, "id:stable-heading")
    XCTAssertEqual(nodes[1].subpath, "#id:stable-heading")
    let bounds = JSONCanvasGeometry.bounds(nodes)
    XCTAssertEqual(bounds.minX, -100)
    XCTAssertEqual(bounds.minY, -60)
    XCTAssertEqual(bounds.maxX, 700)
    XCTAssertEqual(bounds.maxY, 400)
    XCTAssertEqual(JSONCanvasGeometry.anchor(nodes[1].rectangle, side: "left"), CGPoint(x: 0, y: 110))
    XCTAssertEqual(JSONCanvasGeometry.anchor(nodes[1].rectangle, side: "bottom"), CGPoint(x: 150, y: 220))
    XCTAssertEqual(payload.document.edges?.first?.fromSide, "right")
    XCTAssertEqual(payload.document.edges?.first?.toEnd, "none")
  }

  func testResolvedStableSourceRetainsExactNavigationAndRevision() throws {
    let payload = try JSONDecoder().decode(JSONCanvasPayload.self, from: Data(Self.fixture.utf8))
    let source = try XCTUnwrap(payload.resources["note"])
    XCTAssertEqual(source.location?.file, "/corpus/notes/renamed.org")
    XCTAssertEqual(source.location?.lineForEditor, 17)
    XCTAssertEqual(source.location?.idValue, "stable-heading")
    XCTAssertEqual(payload.revision, "sha256:canvas-revision")
    let draft = CanvasEditorDraft(edge: try XCTUnwrap(payload.document.edges?.first))
    XCTAssertEqual(draft.type, "edge")
    XCTAssertEqual(draft.nodeID, "connection")
    XCTAssertEqual(draft.toEnd, "none")
    XCTAssertEqual(draft.content, "Reference")
  }

  func testOptionalTopLevelArraysAndUnknownFieldsAreAcceptedByNativeProjection() throws {
    let payload = try JSONDecoder().decode(JSONCanvasPayload.self, from: Data(#"{"file":"/corpus/empty.canvas","revision":"sha256:empty","document":{"plugin":{"opaque":true}},"resources":{}}"#.utf8))
    XCTAssertNil(payload.document.nodes)
    XCTAssertNil(payload.document.edges)
    XCTAssertTrue(JSONCanvasGeometry.bounds([]).isNull)
  }

  func testTargetPickerKeepsFileIdentityDistinctFromHeadingID() throws {
    let targets = try JSONDecoder().decode(JSONCanvasTargetsPayload.self, from: Data(##"{"targets":[{"title":"Architecture","file":"notes/a.org","line":17,"id":"stable-heading","org2Ref":"id:stable-heading","subpath":"#id:stable-heading"}],"truncated":false}"##.utf8))
    XCTAssertEqual(targets.targets.first?.nodeID, "stable-heading")
    XCTAssertEqual(targets.targets.first?.id, "notes/a.org:17:stable-heading")
  }

  @MainActor
  func testWorkspaceCanvasMutationsPersistGeometryConnectionsAndRejectStaleRevision() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-native-canvas-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let root = temporary.resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "org2-native-canvas-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let store = WorkspaceStore(
      cli: cli,
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent(".test-state/chat.json"),
      legacyDefaultsDomains: []
    )
    store.setWorkspaceRealtimeRefreshActive(false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.openClawTranscriptSaverForTesting = {}
    store.setCorpusRoot(root, persistsDefault: false)

    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let source = notes.appendingPathComponent("original.org")
    let sourceText = "#+TITLE: Project\n\n* Architecture\n:PROPERTIES:\n:ID: stable-heading\n:END:\nCanonical source remains unchanged.\n"
    try sourceText.write(to: source, atomically: true, encoding: .utf8)
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.fixture.utf8)) as? [String: Any])
    let original = try XCTUnwrap(fixture["document"] as? [String: Any])
    let canvas = root.appendingPathComponent("work.canvas")
    try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]).write(to: canvas, options: .atomic)
    store.selectCorpusFile(CorpusFile(path: canvas.path, relativePath: "work.canvas", modifiedAt: nil, byteCount: nil))
    XCTAssertTrue(store.selectedFileIsCanvas)

    let before: JSONCanvasPayload = try await cli.runJSON(["canvas", "show", "--dir", root.path, "--file", canvas.path, "--json"])
    XCTAssertEqual(before.resources["note"]?.location?.file, source.path)
    XCTAssertEqual(before.resources["note"]?.location?.lineForEditor, 3)
    let moved = try await store.mutateJSONCanvas(
      file: canvas.path, root: root.path, revision: before.revision,
      operations: JSONSerialization.data(withJSONObject: [[
        "action": "update-node", "id": "text", "patch": ["x": -250, "y": 145],
      ]])
    )
    XCTAssertTrue(moved.applied)
    XCTAssertNotEqual(moved.revision, before.revision)
    let resized = try await store.mutateJSONCanvas(
      file: canvas.path, root: root.path, revision: moved.revision,
      operations: JSONSerialization.data(withJSONObject: [[
        "action": "update-node", "id": "text", "patch": ["width": 420, "height": 270],
      ]])
    )
    let connection: [String: Any] = [
      "id": "native-connection", "fromNode": "note", "toNode": "text",
      "fromSide": "bottom", "toSide": "top", "toEnd": "arrow", "label": "Reviewed",
    ]
    let connected = try await store.mutateJSONCanvas(
      file: canvas.path, root: root.path, revision: resized.revision,
      operations: JSONSerialization.data(withJSONObject: [["action": "add-edge", "edge": connection]])
    )
    let reloaded: JSONCanvasPayload = try await cli.runJSON(["canvas", "show", "--dir", root.path, "--file", canvas.path, "--json"])
    let text = try XCTUnwrap(reloaded.document.nodes?.first { $0.id == "text" })
    XCTAssertEqual(text.rectangle, CGRect(x: -250, y: 145, width: 420, height: 270))
    XCTAssertEqual(reloaded.revision, connected.revision)
    XCTAssertEqual(reloaded.document.edges?.last?.id, "native-connection")
    XCTAssertEqual(reloaded.document.edges?.last?.fromNode, "note")
    XCTAssertEqual(reloaded.document.edges?.last?.toNode, "text")
    XCTAssertTrue(store.corpusFiles.contains { $0.path == canvas.path })

    // Compare the complete persisted document, including opaque fields the native models omit.
    var expected = original
    var expectedNodes = try XCTUnwrap(original["nodes"] as? [[String: Any]])
    let textIndex = try XCTUnwrap(expectedNodes.firstIndex { $0["id"] as? String == "text" })
    expectedNodes[textIndex]["x"] = -250
    expectedNodes[textIndex]["y"] = 145
    expectedNodes[textIndex]["width"] = 420
    expectedNodes[textIndex]["height"] = 270
    expected["nodes"] = expectedNodes
    expected["edges"] = try XCTUnwrap(original["edges"] as? [[String: Any]]) + [connection]
    let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: canvas)) as? [String: Any])
    XCTAssertEqual(NSDictionary(dictionary: persisted), NSDictionary(dictionary: expected))
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), sourceText)

    var externallyChanged = persisted
    externallyChanged["otherEditor"] = ["preserve": "external change"]
    let externalBytes = try JSONSerialization.data(withJSONObject: externallyChanged, options: [.sortedKeys])
    try externalBytes.write(to: canvas, options: .atomic)
    do {
      _ = try await store.mutateJSONCanvas(
        file: canvas.path, root: root.path, revision: connected.revision,
        operations: JSONSerialization.data(withJSONObject: [["action": "remove-node", "id": "text"]])
      )
      XCTFail("A stale Canvas revision must not replace another editor's changes")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Canvas changed since it was opened"), error.localizedDescription)
    }
    XCTAssertEqual(try Data(contentsOf: canvas), externalBytes)
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), sourceText)
  }

  private static let fixture = #"""
  {
    "file":"/corpus/work.canvas","revision":"sha256:canvas-revision",
    "document": {
      "unknown":{"preservedByRuntime":true},
      "nodes":[
        {"id":"group","type":"group","x":-100,"y":-60,"width":800,"height":460,"label":"Project"},
        {"id":"note","type":"file","x":0,"y":0,"width":300,"height":220,"file":"notes/original.org","org2Ref":"id:stable-heading","subpath":"#id:stable-heading"},
        {"id":"text","type":"text","x":350,"y":0,"width":250,"height":180,"text":"Draft","vendor":{"owner":"plugin","flags":[1,2]}}
      ],
      "edges":[{"id":"connection","fromNode":"text","toNode":"note","fromSide":"right","toSide":"left","toEnd":"none","label":"Reference","vendor":{"weight":7,"routing":{"bend":45}}}]
    },
    "resources":{"note":{"status":"ready","title":"Architecture","file":"/corpus/notes/renamed.org","line":17,"id":"stable-heading","text":"Source preview"}}
  }
  """#
}
