import Foundation
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class FormatOnSaveTests: XCTestCase {
  func testFormatOnSaveDefaultsOnAndPersistsOptOut() throws {
    let suiteName = "org2-format-on-save-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let initialStore = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    XCTAssertTrue(initialStore.formatOrgFilesOnSave)

    initialStore.formatOrgFilesOnSave = false
    let restoredStore = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    XCTAssertFalse(restoredStore.formatOrgFilesOnSave)
  }

  func testFullPageSaveFormatsOrgTableByDefault() async throws {
    let initial = """
    #+TITLE: Inventory

    * Items
    Original body
    """
    let draft = """
    #+TITLE: Inventory

    * Items
    | Name|Count |
    |---+---|
    | Apples|2|
    """
    let harness = try await makeHarness(initialText: initial)
    defer { harness.defaults.removePersistentDomain(forName: harness.defaultsSuiteName) }
    let expected = try await harness.cli.formatOrgText(draft)

    harness.store.beginEditingCurrentScope()
    harness.store.editableEntryText = draft
    harness.store.noteSourceEditorLocalTextChanged(draft)
    await harness.store.saveActiveEdit()

    XCTAssertEqual(try String(contentsOf: harness.file, encoding: .utf8), expected)
    XCTAssertEqual(harness.store.selectedEntrySource?.text, expected)
    XCTAssertFalse(harness.store.entryEditorHasUnsavedChanges)
  }

  func testFullPageSavePreservesSourceWhenFormatOnSaveIsDisabled() async throws {
    let initial = """
    #+TITLE: Inventory

    * Items
    Original body
    """
    let draft = """
    #+TITLE: Inventory

    * Items
    | Name|Count |
    |---+---|
    | Apples|2|
    """
    let harness = try await makeHarness(initialText: initial)
    defer { harness.defaults.removePersistentDomain(forName: harness.defaultsSuiteName) }
    harness.store.formatOrgFilesOnSave = false

    harness.store.beginEditingCurrentScope()
    harness.store.editableEntryText = draft
    harness.store.noteSourceEditorLocalTextChanged(draft)
    await harness.store.saveActiveEdit()

    XCTAssertEqual(try String(contentsOf: harness.file, encoding: .utf8), draft)
    XCTAssertEqual(harness.store.selectedEntrySource?.text, draft)
    XCTAssertFalse(harness.store.entryEditorHasUnsavedChanges)
  }

  func testFullPageOrgSaveCanonicalizesAcceptedSyntaxSugar() async throws {
    let initial = """
    #+TITLE: Canonical Org

    * Example
    Original body
    """
    let draft = """
    #+TITLE: Canonical Org

    * Example
    Use `inline code` here.

    ```js
    const value = `literal`;
    ```
    """
    let harness = try await makeHarness(initialText: initial, fileExtension: "org")
    defer { harness.defaults.removePersistentDomain(forName: harness.defaultsSuiteName) }

    harness.store.beginEditingCurrentScope()
    harness.store.editableEntryText = draft
    harness.store.noteSourceEditorLocalTextChanged(draft)
    await harness.store.saveActiveEdit()

    let saved = try String(contentsOf: harness.file, encoding: .utf8)
    XCTAssertTrue(saved.contains("Use ~inline code~ here."))
    XCTAssertTrue(saved.contains("#+begin_src js\nconst value = `literal`;\n#+end_src"))
    XCTAssertFalse(saved.contains("```js"))
    XCTAssertEqual(harness.store.selectedEntrySource?.text, saved)
    XCTAssertFalse(harness.store.entryEditorHasUnsavedChanges)
  }

  func testOrgSaveCanonicalizesSugarWhenGeneralFormattingIsDisabled() async throws {
    let initial = """
    * Example
    Original body
    """
    let draft = """
    * Example
    Use `inline code` here.
    """
    let harness = try await makeHarness(initialText: initial, fileExtension: "org")
    defer { harness.defaults.removePersistentDomain(forName: harness.defaultsSuiteName) }
    harness.store.formatOrgFilesOnSave = false

    harness.store.beginEditingCurrentScope()
    harness.store.editableEntryText = draft
    harness.store.noteSourceEditorLocalTextChanged(draft)
    await harness.store.saveActiveEdit()

    let saved = try String(contentsOf: harness.file, encoding: .utf8)
    XCTAssertTrue(
      saved.contains("Use ~inline code~ here."),
      "Expected canonical Org syntax after save; status: \(harness.store.statusText)"
    )
    XCTAssertFalse(
      saved.contains("`inline code`"),
      "Expected syntax sugar to be removed after save; status: \(harness.store.statusText)"
    )
  }

  func testFormattingFailureStillSavesOriginalDraft() async throws {
    let initial = """
    #+TITLE: Inventory

    * Items
    Original body
    """
    let draft = """
    #+TITLE: Inventory

    * Items
    | Name|Count |
    |---+---|
    | Apples|2|
    """
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-format-on-save-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("inventory.org2")
    try initial.write(to: file, atomically: true, encoding: .utf8)
    let suiteName = "org2-format-on-save-failure-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let missingRuntime = root.appendingPathComponent("missing-runtime", isDirectory: true)
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: missingRuntime),
      defaults: defaults,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.selectCorpusFile(CorpusFile(
      path: file.path,
      relativePath: file.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    store.selectedEntrySource = EntrySource(
      file: file.path,
      startLine: 1,
      endLineExclusive: 5,
      text: initial,
      isSubtree: false
    )
    store.editableEntryText = initial

    store.beginEditingCurrentScope()
    store.editableEntryText = draft
    store.noteSourceEditorLocalTextChanged(draft)
    await store.saveActiveEdit()

    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), draft)
    XCTAssertTrue(store.statusText.contains("formatting failed"))
    XCTAssertFalse(store.entryEditorHasUnsavedChanges)
  }

  private func makeHarness(
    initialText: String,
    fileExtension: String = "org2"
  ) async throws -> FormatOnSaveHarness {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-format-on-save-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("inventory.\(fileExtension)")
    try initialText.write(to: file, atomically: true, encoding: .utf8)

    let suiteName = "org2-format-on-save-harness-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let store = WorkspaceStore(cli: cli, defaults: defaults, legacyDefaultsDomains: [])
    store.setCorpusRoot(root, persistsDefault: false)
    store.selectCorpusFile(CorpusFile(
      path: file.path,
      relativePath: file.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    _ = try XCTUnwrap(store.selectedEntrySource)
    return FormatOnSaveHarness(
      store: store,
      cli: cli,
      file: file,
      defaults: defaults,
      defaultsSuiteName: suiteName
    )
  }
}

private struct FormatOnSaveHarness {
  let store: WorkspaceStore
  let cli: Org2CLI
  let file: URL
  let defaults: UserDefaults
  let defaultsSuiteName: String
}
