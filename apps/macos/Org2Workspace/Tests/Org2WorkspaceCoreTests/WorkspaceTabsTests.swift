import AppKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceTabsTests: XCTestCase {
  func testTabsKeepNavigationAndBackHistoryIndependent() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstTabID = store.selectedWorkspaceTabID
    store.selectedSurface = .agenda
    store.makeSurfacePrimary(.files)
    XCTAssertTrue(store.canNavigateBack)

    let secondTabID = store.newWorkspaceTab()
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertFalse(store.canNavigateBack)

    store.selectedSurface = .approvals
    store.makeSurfacePrimary(.meetings)
    XCTAssertTrue(store.canNavigateBack)

    store.selectWorkspaceTab(firstTabID)
    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertTrue(store.canNavigateBack)
    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .agenda)
    XCTAssertFalse(store.canNavigateBack)

    store.selectWorkspaceTab(secondTabID)
    XCTAssertEqual(store.selectedSurface, .meetings)
    XCTAssertTrue(store.canNavigateBack)
    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertFalse(store.canNavigateBack)
  }

  func testDuplicateTabCopiesCurrentLocationAndBackHistory() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let originalTabID = store.selectedWorkspaceTabID
    store.selectedSurface = .agenda
    store.makeSurfacePrimary(.files)

    let duplicateTabID = store.duplicateWorkspaceTab()
    XCTAssertNotEqual(duplicateTabID, originalTabID)
    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertTrue(store.canNavigateBack)

    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .agenda)
    store.selectWorkspaceTab(originalTabID)
    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertTrue(store.canNavigateBack)
  }

  func testClosingTabsUsesTheAdjacentTabWithoutAddingBackHistory() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstTabID = store.selectedWorkspaceTabID
    let secondTabID = store.newWorkspaceTab()
    store.selectedSurface = .agenda
    let thirdTabID = store.newWorkspaceTab()
    store.selectedSurface = .files

    store.closeWorkspaceTab(secondTabID)
    XCTAssertEqual(store.workspaceTabs.map(\.id), [firstTabID, thirdTabID])
    XCTAssertEqual(store.selectedWorkspaceTabID, thirdTabID)

    store.closeWorkspaceTab(thirdTabID)
    XCTAssertEqual(store.workspaceTabs.map(\.id), [firstTabID])
    XCTAssertEqual(store.selectedWorkspaceTabID, firstTabID)
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertFalse(store.canNavigateBack)

    store.closeWorkspaceTab(firstTabID)
    XCTAssertEqual(store.workspaceTabs.map(\.id), [firstTabID])
  }

  func testTabReorderingPreservesSelectionAndNavigationState() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstTabID = store.selectedWorkspaceTabID
    let secondTabID = store.newWorkspaceTab()
    store.selectedSurface = .agenda
    let thirdTabID = store.newWorkspaceTab()
    store.selectedSurface = .files

    XCTAssertTrue(store.moveWorkspaceTab(firstTabID, to: thirdTabID))
    XCTAssertEqual(store.workspaceTabs.map(\.id), [secondTabID, thirdTabID, firstTabID])
    XCTAssertEqual(store.selectedWorkspaceTabID, thirdTabID)
    XCTAssertEqual(store.selectedSurface, .files)

    store.moveWorkspaceTab(thirdTabID, offset: -1)
    XCTAssertEqual(store.workspaceTabs.map(\.id), [thirdTabID, secondTabID, firstTabID])
    XCTAssertEqual(store.selectedWorkspaceTabID, thirdTabID)
  }

  func testAdjacentTabSelectionWrapsAtBothEnds() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstTabID = store.selectedWorkspaceTabID
    let secondTabID = store.newWorkspaceTab()
    let thirdTabID = store.newWorkspaceTab()

    store.selectNextWorkspaceTab()
    XCTAssertEqual(store.selectedWorkspaceTabID, firstTabID)
    store.selectPreviousWorkspaceTab()
    XCTAssertEqual(store.selectedWorkspaceTabID, thirdTabID)
    store.selectPreviousWorkspaceTab()
    XCTAssertEqual(store.selectedWorkspaceTabID, secondTabID)
  }

  func testKeyboardShortcutsCreateSelectAndCloseTabs() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstTabID = store.selectedWorkspaceTabID
    XCTAssertTrue(store.handleGlobalKeyDown(
      keyDown("t", keyCode: 17, modifiers: [.command]),
      scope: .globalOnly
    ))
    let secondTabID = store.selectedWorkspaceTabID
    XCTAssertNotEqual(secondTabID, firstTabID)
    XCTAssertEqual(store.workspaceTabs.count, 2)

    XCTAssertTrue(store.handleGlobalKeyDown(
      keyDown("[", keyCode: 33, modifiers: [.command, .shift]),
      scope: .globalOnly
    ))
    XCTAssertEqual(store.selectedWorkspaceTabID, firstTabID)

    XCTAssertTrue(store.handleGlobalKeyDown(
      keyDown("]", keyCode: 30, modifiers: [.command, .shift]),
      scope: .globalOnly
    ))
    XCTAssertEqual(store.selectedWorkspaceTabID, secondTabID)

    XCTAssertTrue(store.handleGlobalKeyDown(
      keyDown("w", keyCode: 13, modifiers: [.command]),
      scope: .globalOnly
    ))
    XCTAssertEqual(store.workspaceTabs.map(\.id), [firstTabID])
    XCTAssertFalse(store.handleGlobalKeyDown(
      keyDown("w", keyCode: 13, modifiers: [.command]),
      scope: .globalOnly
    ))
  }

  func testTabSwitchDoesNotAutosaveAStaleSourceForAnotherLocation() async throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-tab-stale-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let loadedFile = root.appendingPathComponent("loaded.org2")
    let selectedFile = root.appendingPathComponent("selected.org2")
    let loadedText = "#+TITLE: Loaded\n"
    try loadedText.write(to: loadedFile, atomically: true, encoding: .utf8)
    try "#+TITLE: Selected\n".write(to: selectedFile, atomically: true, encoding: .utf8)

    store.selectedSurface = .files
    store.selectedEntrySourceMode = .page
    store.selectedLocation = .openClaw(OpenClawThread(
      title: "Selected",
      file: selectedFile.path,
      zone: "notes",
      modifiedAt: nil
    ))
    store.selectedEntrySource = EntrySource(
      file: loadedFile.path,
      startLine: 1,
      endLineExclusive: 2,
      text: loadedText,
      isSubtree: false
    )
    store.editableEntryText = ""

    XCTAssertFalse(store.liveFileEditorHasUnsavedChanges)
    store.newWorkspaceTab()
    try? await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(try String(contentsOf: loadedFile, encoding: .utf8), loadedText)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".org2-recovery").path))
  }

  private func makeStore() throws -> (WorkspaceStore, UserDefaults, String) {
    let suiteName = "org2-workspace-tabs-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    return (
      WorkspaceStore(defaults: defaults, legacyDefaultsDomains: []),
      defaults,
      suiteName
    )
  }

  private func keyDown(
    _ characters: String,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode
    )!
  }
}
