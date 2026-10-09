import XCTest
@testable import Org2WorkspaceCore

final class SidebarSectionCollapseTests: XCTestCase {
  func testEverySectionStartsExpanded() {
    let state = SidebarSectionCollapseState(storage: "")
    for section in SidebarSectionID.allCases {
      XCTAssertFalse(state.isCollapsed(section), "\(section) should start expanded")
    }
    XCTAssertEqual(state.storage, "")
  }

  func testToggleRoundTripsThroughStorage() {
    var storage = ""
    storage = SidebarSectionCollapseState.toggling(.daily, in: storage)
    storage = SidebarSectionCollapseState.toggling(.workspace, in: storage)
    // Stored in a stable order regardless of toggle order.
    XCTAssertEqual(storage, "workspace,daily")

    let restored = SidebarSectionCollapseState(storage: storage)
    XCTAssertTrue(restored.isCollapsed(.workspace))
    XCTAssertTrue(restored.isCollapsed(.daily))
    XCTAssertFalse(restored.isCollapsed(.pinned))
    XCTAssertFalse(restored.isCollapsed(.projects))
    XCTAssertFalse(restored.isCollapsed(.chat))

    storage = SidebarSectionCollapseState.toggling(.workspace, in: storage)
    XCTAssertEqual(storage, "daily")
  }

  func testFilesIsACollapsibleSectionLikeTheOthers() {
    // Files used to be a plain row rather than a section header, so a fully
    // folded sidebar showed it differently from every other section.
    XCTAssertEqual(
      SidebarSectionID.allCases,
      [.workspace, .pinned, .daily, .files, .projects, .chat],
      "Sidebar sections in display order"
    )
    let allCollapsed = SidebarSectionID.allCases.reduce("") {
      SidebarSectionCollapseState.toggling($1, in: $0)
    }
    XCTAssertEqual(allCollapsed, "workspace,pinned,daily,files,projects,chat")
    XCTAssertTrue(SidebarSectionCollapseState(storage: allCollapsed).isCollapsed(.files))
  }

  func testUnknownStoredSectionsAreIgnored() {
    let state = SidebarSectionCollapseState(storage: "pinned, retired-section,,chat")
    XCTAssertEqual(state.collapsed, [.pinned, .chat])
    XCTAssertEqual(state.storage, "pinned,chat")
  }

  func testCollapsedSectionsPersistInUserDefaults() throws {
    let suiteName = "org2-sidebar-sections-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let key = SidebarSectionCollapseState.defaultsKey
    defaults.set(SidebarSectionCollapseState.toggling(.pinned, in: defaults.string(forKey: key) ?? ""), forKey: key)

    let relaunched = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let state = SidebarSectionCollapseState(storage: relaunched.string(forKey: key) ?? "")
    XCTAssertTrue(state.isCollapsed(.pinned))
    XCTAssertFalse(state.isCollapsed(.workspace))
  }
}
