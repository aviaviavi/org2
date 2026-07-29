import XCTest
@testable import Org2WorkspaceCore

final class OrgRoamLinkResolverEqualityTests: XCTestCase {
  func testEqualityUsesOrderIndependentResolverSignature() {
    let firstNode = OrgRoamNodeReference(
      idValue: "first",
      title: "First",
      file: "notes/first.org2",
      line: 1
    )
    let secondNode = OrgRoamNodeReference(
      idValue: "second",
      title: "Second",
      file: "notes/second.org2",
      line: 1
    )

    let forward = OrgRoamLinkResolver(nodes: [firstNode, secondNode])
    let reversed = OrgRoamLinkResolver(nodes: [secondNode, firstNode])
    let changed = OrgRoamLinkResolver(nodes: [
      firstNode,
      OrgRoamNodeReference(
        idValue: "second",
        title: "Changed",
        file: "notes/second.org2",
        line: 1
      ),
    ])

    XCTAssertEqual(forward, reversed)
    XCTAssertNotEqual(forward, changed)
  }
}
