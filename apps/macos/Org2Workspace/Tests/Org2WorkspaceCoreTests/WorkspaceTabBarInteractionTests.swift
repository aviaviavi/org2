import AppKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceTabBarInteractionTests: XCTestCase {
  func testAppKitTabTargetHandlesPrimaryMouseClicks() throws {
    let view = WorkspaceTabInteractionView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
    var selectionCount = 0
    view.select = { selectionCount += 1 }

    let event = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: NSPoint(x: 80, y: 14),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))
    view.mouseDown(with: event)

    XCTAssertEqual(selectionCount, 1)
    XCTAssertTrue(view.acceptsFirstMouse(for: event))
  }

  func testAppKitTabTargetExposesClickableCloseControl() throws {
    let view = WorkspaceTabInteractionView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
    var closeCount = 0
    view.close = { closeCount += 1 }
    view.title = "Agenda"
    view.showsCloseButton = true
    view.canClose = true
    view.updatePresentation()
    view.layoutSubtreeIfNeeded()

    let closeButton = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first)
    XCTAssertFalse(closeButton.isHidden)
    XCTAssertTrue(closeButton.isEnabled)
    _ = NSApplication.shared
    XCTAssertTrue(NSApp.sendAction(
      try XCTUnwrap(closeButton.action),
      to: closeButton.target,
      from: closeButton
    ))

    XCTAssertEqual(closeCount, 1)
  }

  func testAppKitTabTargetBuildsEnabledContextMenuActions() throws {
    let view = WorkspaceTabInteractionView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
    view.canMoveLeft = false
    view.canMoveRight = true
    view.canClose = true

    let menu = view.makeContextMenu()
    XCTAssertEqual(
      menu.items.filter { !$0.isSeparatorItem }.map(\.title),
      [
        "New Tab",
        "Duplicate Tab",
        "Move Tab Left",
        "Move Tab Right",
        "Close Tab",
        "Close Other Tabs"
      ]
    )
    XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Move Tab Left")).isEnabled)
    XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Move Tab Right")).isEnabled)
    XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Close Tab")).isEnabled)
  }

  func testTabDragCoordinatorMovesTheSourceToTheTarget() async {
    let coordinator = WorkspaceTabDragCoordinator()
    let source = WorkspaceTabInteractionView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
    let target = WorkspaceTabInteractionView(frame: NSRect(x: 184, y: 0, width: 180, height: 28))
    var movedTabID: WorkspaceTab.ID?
    var targetStates: [Bool] = []
    target.moveTab = { movedTabID = $0 }
    target.dropTargetChanged = { targetStates.append($0) }

    coordinator.begin(from: source)
    coordinator.updateTarget(target)
    coordinator.finish()
    try? await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(movedTabID, source.tabID)
    XCTAssertEqual(targetStates, [true, false])
  }
}
