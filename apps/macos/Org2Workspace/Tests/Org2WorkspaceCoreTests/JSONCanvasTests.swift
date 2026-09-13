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

  private static let fixture = #"""
  {
    "file":"/corpus/work.canvas","revision":"sha256:canvas-revision",
    "document": {
      "unknown":{"preservedByRuntime":true},
      "nodes":[
        {"id":"group","type":"group","x":-100,"y":-60,"width":800,"height":460,"label":"Project"},
        {"id":"note","type":"file","x":0,"y":0,"width":300,"height":220,"file":"notes/original.org","org2Ref":"id:stable-heading","subpath":"#id:stable-heading"},
        {"id":"text","type":"text","x":350,"y":0,"width":250,"height":180,"text":"Draft"}
      ],
      "edges":[{"id":"connection","fromNode":"text","toNode":"note","fromSide":"right","toSide":"left","toEnd":"none","label":"Reference"}]
    },
    "resources":{"note":{"status":"ready","title":"Architecture","file":"/corpus/notes/renamed.org","line":17,"id":"stable-heading","text":"Source preview"}}
  }
  """#
}
