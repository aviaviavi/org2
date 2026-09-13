import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class PropertyViewTests: XCTestCase {
  func testPortableDefinitionRetainsBuilderConfiguration() throws {
    var definition = PropertyViewDefinition()
    definition.layout = "cards"
    definition.scope = .init(kind: "all", filePrefix: "notes/projects/")
    definition.columns = ["title", "ASSIGNEE", "STATUS"]
    definition.filters = [.init(field: "STATUS", operator: "is", value: "open"), .init(field: "ASSIGNEE", operator: "exists", value: "")]
    definition.match = "any"
    definition.sort = [.init(field: "STATUS", direction: "desc")]
    definition.groupBy = "ASSIGNEE"
    let decoded = try JSONDecoder().decode(PropertyViewDefinition.self, from: Data(try definition.json().utf8))
    XCTAssertEqual(decoded, definition)
    XCTAssertFalse(try definition.json().contains("/Users/"))
  }

  func testGroupsPreserveSharedRuntimeOrderAndInheritedValues() throws {
    let result = try fixtureResult()
    XCTAssertEqual(result.groups.map(\.name), ["Team B", "Team A"])
    XCTAssertEqual(result.groups[0].rows.map(\.key), ["first", "third"])
    XCTAssertEqual(result.rows[0].inheritedProperties["ASSIGNEE"], "Team B")
    XCTAssertTrue(result.editableFields.contains("STATUS"))
    XCTAssertFalse(result.editableFields.contains("id"))
  }

  func testSourceEditCarriesExactRowIdentityAndRevisionThroughPreviewAndApply() throws {
    let row = try fixtureResult().rows[0]
    let cell = PropertyViewCellEdit(row: row, field: "STATUS")
    let preview = PropertyViewCommands.edit(root: "/corpus", cell: cell, value: "review")
    XCTAssertEqual(preview, ["property-view", "edit", "--dir", "/corpus", "--file", "notes/work.org", "--kind", "heading", "--line", "7", "--property", "STATUS", "--value", "review", "--if-revision", "sha256:row"])
    XCTAssertFalse(preview.contains("--apply"))
    let apply = PropertyViewCommands.edit(root: "/corpus", cell: cell, value: "review", revision: "sha256:preview", apply: true)
    XCTAssertEqual(Array(apply.suffix(3)), ["--if-revision", "sha256:preview", "--apply"])
  }

  func testNativeCLIQueriesAndAppliesSourceEditEndToEnd() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("org2-property-view-swift-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("work.org")
    try "#+title: Work\n* TODO Ship\n:PROPERTIES:\n:STATUS: open\n:END:\nKeep body.\n".write(to: note, atomically: true, encoding: .utf8)
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    var definition = PropertyViewDefinition()
    definition.columns = ["title", "STATUS"]
    let save: PropertyViewSaveResult = try await cli.runJSON(["property-view", "save", "--dir", root.path, "--definition", definition.json(), "--apply"])
    let list: PropertyViewList = try await cli.runJSON(["property-view", "list", "--dir", root.path])
    XCTAssertEqual(list.views.first?.revision, save.revision)
    let result: PropertyViewResult = try await cli.runJSON(["property-view", "query", "--dir", root.path, "--view", definition.id])
    let row = try XCTUnwrap(result.rows.first)
    XCTAssertEqual(row.values["STATUS"], "open")
    let cell = PropertyViewCellEdit(row: row, field: "STATUS")
    let preview: PropertyViewEditResult = try await cli.runJSON(PropertyViewCommands.edit(root: root.path, cell: cell, value: "review"))
    XCTAssertEqual(preview.oldValue, "open")
    XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains(":STATUS: open"))
    let _: PropertyViewEditResult = try await cli.runJSON(PropertyViewCommands.edit(root: root.path, cell: cell, value: "review", revision: preview.revision, apply: true))
    let text = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(text.contains(":STATUS: review"))
    XCTAssertTrue(text.contains("Keep body."))
    do {
      let _: PropertyViewEditResult = try await cli.runJSON(PropertyViewCommands.edit(root: root.path, cell: cell, value: "stale", apply: true))
      XCTFail("Stale source revision must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
  }

  private func fixtureResult() throws -> PropertyViewResult {
    let definition = PropertyViewDefinition()
    let rows: [[String: Any]] = [("first", "Team B"), ("second", "Team A"), ("third", "Team B")].map { key, group in
      ["key": key, "kind": "heading", "file": "notes/work.org", "line": 7, "title": key,
       "revision": "sha256:row", "properties": ["STATUS": "open"], "inheritedProperties": ["ASSIGNEE": group],
       "values": ["title": key, "STATUS": "open", "ASSIGNEE": group], "group": group, "editable": true]
    }
    let object: [String: Any] = ["definition": try JSONSerialization.jsonObject(with: Data(definition.json().utf8)), "total": 3, "truncated": false, "fields": ["title", "STATUS"], "editableFields": ["STATUS"], "rows": rows]
    return try JSONDecoder().decode(PropertyViewResult.self, from: JSONSerialization.data(withJSONObject: object))
  }
}
