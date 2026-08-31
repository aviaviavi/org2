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
    XCTAssertFalse(view.mouseDownCanMoveWindow)
  }

  func testNativeTabStripRoutesAWindowClickThroughEveryParent() throws {
    let firstID = WorkspaceTab.ID()
    let secondID = WorkspaceTab.ID()
    let strip = WorkspaceTabStripView(frame: NSRect(x: 0, y: 0, width: 420, height: 36))
    let coordinator = WorkspaceTabDragCoordinator()
    var selectedID: WorkspaceTab.ID?
    strip.update(
      items: [
        WorkspaceTabStripItem(id: firstID, title: "Home", systemImage: "house.fill"),
        WorkspaceTabStripItem(id: secondID, title: "Sources", systemImage: "arrow.triangle.2.circlepath.circle")
      ],
      selectedTabID: firstID,
      dragCoordinator: coordinator,
      select: { selectedID = $0 },
      close: { _ in },
      duplicate: { _ in },
      newTab: { _ in },
      move: { _, _ in },
      closeOthers: { _ in },
      moveTab: { _, _ in }
    )

    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 36),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = strip
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    strip.layoutSubtreeIfNeeded()

    let secondTab = try XCTUnwrap(strip.tabView(for: secondID))
    let pointInStrip = secondTab.convert(
      NSPoint(x: secondTab.bounds.midX, y: secondTab.bounds.midY),
      to: strip
    )
    XCTAssertTrue(strip.bounds.contains(pointInStrip))
    let hitView = strip.hitTest(pointInStrip)
    XCTAssertTrue(
      hitView === secondTab,
      "Expected the second tab, hit \(String(describing: hitView)) at \(pointInStrip)"
    )

    let pointInWindow = secondTab.convert(
      NSPoint(x: secondTab.bounds.midX, y: secondTab.bounds.midY),
      to: nil
    )
    let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: pointInWindow,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 2,
      clickCount: 1,
      pressure: 1
    ))
    window.sendEvent(mouseDown)

    XCTAssertEqual(selectedID, secondID)
  }

  func testNativeTabOwnsItsVisibleContentAndExactHitTargets() throws {
    let view = WorkspaceTabInteractionView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
    view.title = "Home"
    view.systemImage = "house.fill"
    view.isSelected = true
    view.showsCloseButton = true
    view.canClose = true
    view.updatePresentation()
    view.layoutSubtreeIfNeeded()

    let closeButton = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first)
    XCTAssertEqual(view.subviews.compactMap { $0 as? NSButton }.count, 1)
    XCTAssertEqual(view.subviews.compactMap { $0 as? NSTextField }.count, 1)
    XCTAssertTrue(view.hitTest(NSPoint(x: 80, y: 14)) === view)
    XCTAssertTrue(view.hitTest(NSPoint(x: closeButton.frame.midX, y: closeButton.frame.midY)) === closeButton)
    XCTAssertEqual(closeButton.frame, NSRect(x: 155, y: 5, width: 18, height: 18))
  }

  func testInactiveTabBackgroundResolvesForItsEffectiveAppearance() throws {
    let view = WorkspaceTabInteractionView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
    view.isSelected = false

    view.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
    view.updatePresentation()
    let darkBackground = try XCTUnwrap(view.layer?.backgroundColor)
    let darkColor = try XCTUnwrap(NSColor(cgColor: darkBackground)?.usingColorSpace(.sRGB))

    view.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
    view.updatePresentation()
    let lightBackground = try XCTUnwrap(view.layer?.backgroundColor)
    let lightColor = try XCTUnwrap(NSColor(cgColor: lightBackground)?.usingColorSpace(.sRGB))

    XCTAssertLessThan(darkColor.redComponent, 0.25)
    XCTAssertGreaterThan(lightColor.redComponent, 0.90)
    XCTAssertEqual(darkColor.alphaComponent, 0.78, accuracy: 0.01)
    XCTAssertEqual(lightColor.alphaComponent, 0.78, accuracy: 0.01)
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

  func testLiveTabDragTracksPointerAndShiftsNeighborsBeforeDrop() throws {
    let firstID = WorkspaceTab.ID()
    let secondID = WorkspaceTab.ID()
    let thirdID = WorkspaceTab.ID()
    let strip = WorkspaceTabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
    let coordinator = WorkspaceTabDragCoordinator(reorderAnimationDuration: 0)
    var movedSourceID: WorkspaceTab.ID?
    var movedTargetID: WorkspaceTab.ID?
    strip.update(
      items: [
        WorkspaceTabStripItem(id: firstID, title: "Home", systemImage: "house.fill"),
        WorkspaceTabStripItem(id: secondID, title: "Files", systemImage: "doc"),
        WorkspaceTabStripItem(id: thirdID, title: "Agenda", systemImage: "calendar")
      ],
      selectedTabID: firstID,
      dragCoordinator: coordinator,
      select: { _ in },
      close: { _ in },
      duplicate: { _ in },
      newTab: { _ in },
      move: { _, _ in },
      closeOthers: { _ in },
      moveTab: { sourceID, targetID in
        movedSourceID = sourceID
        movedTargetID = targetID
      }
    )
    strip.layoutSubtreeIfNeeded()

    let firstTab = try XCTUnwrap(strip.tabView(for: firstID))
    let secondTab = try XCTUnwrap(strip.tabView(for: secondID))
    let thirdTab = try XCTUnwrap(strip.tabView(for: thirdID))
    let originalFirstX = firstTab.frame.minX
    let originalSecondX = secondTab.frame.minX
    let originalThirdX = thirdTab.frame.minX
    let destinationX = thirdTab.frame.midX
    let grabOffsetX = firstTab.bounds.midX

    coordinator.begin(from: firstTab, grabOffsetX: grabOffsetX)
    coordinator.update(pointerX: originalSecondX + 36 + grabOffsetX)
    strip.needsLayout = true
    strip.layoutSubtreeIfNeeded()

    XCTAssertEqual(firstTab.frame.minX, originalSecondX + 36, accuracy: 0.01)
    XCTAssertEqual(secondTab.frame.minX, originalFirstX, accuracy: 0.01)
    XCTAssertEqual(thirdTab.frame.minX, originalThirdX, accuracy: 0.01)

    coordinator.update(pointerX: destinationX)

    XCTAssertTrue(firstTab.isBeingDragged)
    XCTAssertEqual(firstTab.frame.minX, originalThirdX, accuracy: 0.01)
    XCTAssertEqual(secondTab.frame.minX, originalFirstX, accuracy: 0.01)
    XCTAssertEqual(thirdTab.frame.minX, originalSecondX, accuracy: 0.01)
    XCTAssertNil(movedSourceID)
    XCTAssertNil(movedTargetID)

    coordinator.finish()

    XCTAssertFalse(firstTab.isBeingDragged)
    XCTAssertEqual(movedSourceID, firstID)
    XCTAssertEqual(movedTargetID, thirdID)
  }

  func testCancelingLiveTabDragRestoresTheOriginalOrder() {
    let coordinator = WorkspaceTabDragCoordinator(reorderAnimationDuration: 0)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 364, height: 28))
    let source = WorkspaceTabInteractionView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
    let target = WorkspaceTabInteractionView(frame: NSRect(x: 184, y: 0, width: 180, height: 28))
    var movedTabID: WorkspaceTab.ID?
    target.moveTab = { movedTabID = $0 }
    container.addSubview(source)
    container.addSubview(target)

    coordinator.begin(from: source, grabOffsetX: source.bounds.midX)
    coordinator.update(pointerX: target.frame.midX)

    XCTAssertEqual(source.frame.minX, 184, accuracy: 0.01)
    XCTAssertEqual(target.frame.minX, 0, accuracy: 0.01)

    coordinator.cancel()

    XCTAssertFalse(source.isBeingDragged)
    XCTAssertEqual(source.frame.minX, 0, accuracy: 0.01)
    XCTAssertEqual(target.frame.minX, 184, accuracy: 0.01)
    XCTAssertNil(movedTabID)
  }
}
