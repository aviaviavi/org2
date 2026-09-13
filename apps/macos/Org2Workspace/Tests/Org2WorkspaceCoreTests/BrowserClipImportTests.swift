import XCTest
@testable import Org2WorkspaceCore

private actor BrowserClipOperationGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var entered = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func suspend() async {
    entered = true
    waiters.forEach { $0.resume() }
    waiters = []
    await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

final class BrowserClipImportTests: XCTestCase {
  func testNativeImportUsesPreviewRevisionsAndPreservesBrowserTemplate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("org2-browser-native-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clip = root.appendingPathComponent("article.org2clip")
    let envelope = #"{"schema":"org2:browser-clip:v1","url":"https://example.com/story","title":"Story","author":"Ada","capturedAt":"2026-09-13T12:00:00Z","mode":"selection","template":"task","content":"A selected passage."}"#
    try envelope.write(to: clip, atomically: true, encoding: .utf8)
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let arguments = ["browser-clip", "import", "--file", clip.path, "--dir", root.path, "--json"]
    let preview: BrowserClipImportResult = try await cli.runJSON(arguments)
    XCTAssertEqual(preview.clip.template, "task")
    XCTAssertEqual(preview.clip.author, "Ada")
    XCTAssertEqual(preview.revision, "absent")
    XCTAssertFalse(FileManager.default.fileExists(atPath: preview.file))
    let imported: BrowserClipImportResult = try await cli.runJSON(arguments + ["--if-revision", preview.revision, "--if-clip-revision", preview.clipRevision, "--apply"])
    XCTAssertEqual(imported.headingLine, 1)
    XCTAssertTrue(imported.entryText.hasPrefix("* TODO Story"))
    let repeated: BrowserClipImportResult = try await cli.runJSON(arguments)
    XCTAssertTrue(repeated.duplicate)
    XCTAssertEqual(repeated.headingLine, 1)
  }

  @MainActor
  func testImportPreparationPreservesCaptureTextAttachmentsAndMetadataChanges() async throws {
    try await withSessionFixture { store, _, _, _ in
      let initial = WorkspaceCaptureDraft()
      XCTAssertFalse(store.prepareCaptureDraftForBrowserImport(initial, initialDraft: initial))
      var draft = initial
      draft.title = "An unfinished capture"
      draft.body = "Keep these words"
      draft.priority = "A"
      draft.attachments = [WorkspaceCaptureAttachmentDraft(
        kind: .file, name: "evidence.txt", data: Data("Evidence".utf8), suggestedExtension: "txt"
      )]
      XCTAssertTrue(store.prepareCaptureDraftForBrowserImport(draft, initialDraft: initial))
      XCTAssertEqual(store.captureDraft, draft)
      XCTAssertTrue(store.prepareCaptureDraftForBrowserImport(draft, initialDraft: draft))
      var metadataOnly = initial
      metadataOnly.tagsText = "followup"
      XCTAssertTrue(store.prepareCaptureDraftForBrowserImport(metadataOnly, initialDraft: initial))
      XCTAssertEqual(store.captureDraft.tagsText, "followup")
    }
  }

  @MainActor
  func testSessionAppliesReviewedRevisionsAndNavigatesOnCurrentCompletion() async throws {
    try await withSessionFixture { store, root, clip, result in
      let session = BrowserClipImportSession()
      defer { session.close() }
      var appliedArguments: [String]?
      session.commandForTesting = { arguments in
        if arguments.contains("--apply") { appliedArguments = arguments }
        return result
      }
      session.chooseClip(clip, store: store)
      await session.waitForOperationForTesting()
      XCTAssertEqual(session.template, "task")
      var completed = false
      session.importClip(store: store) { _ in completed = true }
      XCTAssertTrue(session.isImporting)
      await session.waitForOperationForTesting()
      XCTAssertEqual(appliedArguments, [
        "browser-clip", "import", "--file", clip.path, "--dir", root.standardizedFileURL.path,
        "--template", "task", "--if-revision", "sha256:source", "--if-clip-revision", "clip-hash", "--apply", "--json"
      ])
      XCTAssertTrue(completed)
      XCTAssertTrue(session.imported)
      XCTAssertFalse(session.isImporting)
      XCTAssertEqual(store.selectedLocation?.file, result.file)
      XCTAssertTrue(store.isCapturePanelPresented, "The parent owns dismissal and its unsaved draft")
    }
  }

  @MainActor
  func testDismissedSessionDoesNotPublishLatePreview() async throws {
    try await withSessionFixture { store, _, clip, result in
      let gate = BrowserClipOperationGate()
      let session = BrowserClipImportSession()
      session.commandForTesting = { _ in await gate.suspend(); return result }
      session.chooseClip(clip, store: store)
      let operation = try XCTUnwrap(session.operationForTesting)
      await gate.waitUntilEntered()
      session.close()
      await gate.release()
      await operation.value
      XCTAssertNil(session.preview)
      XCTAssertFalse(session.busy)
    }
  }

  @MainActor
  func testDismissedImportDoesNotNavigateOrCloseCaptureAfterRefresh() async throws {
    try await withSessionFixture { store, _, clip, result in
      let gate = BrowserClipOperationGate()
      let session = BrowserClipImportSession()
      session.commandForTesting = { _ in result }
      session.chooseClip(clip, store: store)
      await session.waitForOperationForTesting()
      store.corpusFileScanForTesting = { _ in await gate.suspend(); return [] }
      var completed = false
      session.importClip(store: store) { _ in completed = true; store.isCapturePanelPresented = false }
      let operation = try XCTUnwrap(session.operationForTesting)
      await gate.waitUntilEntered()
      session.close()
      await gate.release()
      await operation.value
      XCTAssertFalse(completed)
      XCTAssertNil(store.selectedLocation)
      XCTAssertTrue(store.isCapturePanelPresented)
    }
  }

  @MainActor
  func testCorpusSwitchAwayAndBackDuringRefreshInvalidatesImportCompletion() async throws {
    try await withSessionFixture { store, root, clip, result in
      let other = root.appendingPathComponent("other")
      try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
      let gate = BrowserClipOperationGate()
      let session = BrowserClipImportSession()
      defer { session.close() }
      session.commandForTesting = { _ in result }
      session.chooseClip(clip, store: store)
      await session.waitForOperationForTesting()
      store.corpusFileScanForTesting = { _ in await gate.suspend(); return [] }
      var completed = false
      session.importClip(store: store) { _ in completed = true; store.isCapturePanelPresented = false }
      let operation = try XCTUnwrap(session.operationForTesting)
      await gate.waitUntilEntered()
      store.setCorpusRoot(other, persistsDefault: false)
      store.setCorpusRoot(root, persistsDefault: false)
      await gate.release()
      await operation.value
      XCTAssertFalse(completed, "Returning to the same path is a new corpus session")
      XCTAssertNil(store.selectedLocation)
      XCTAssertTrue(store.isCapturePanelPresented)
    }
  }

  @MainActor
  func testNewCaptureWhileImportRunsKeepsNewDraftAndPresentation() async throws {
    try await withSessionFixture { store, _, clip, result in
      let gate = BrowserClipOperationGate()
      let session = BrowserClipImportSession()
      defer { session.close() }
      session.commandForTesting = { arguments in
        if arguments.contains("--apply") { await gate.suspend() }
        return result
      }
      session.chooseClip(clip, store: store)
      await session.waitForOperationForTesting()
      var completed = false
      session.importClip(store: store) { _ in completed = true; store.isCapturePanelPresented = false }
      let operation = try XCTUnwrap(session.operationForTesting)
      await gate.waitUntilEntered()
      let newDraft = WorkspaceCaptureDraft(title: "A newer capture", body: "Keep this draft")
      store.presentCapturePanel(draft: newDraft)
      await gate.release()
      await operation.value
      XCTAssertFalse(completed)
      XCTAssertEqual(store.captureDraft, newDraft)
      XCTAssertTrue(store.isCapturePanelPresented)
      XCTAssertNil(store.selectedLocation)
    }
  }

  @MainActor
  func testSourceEditStartedDuringRefreshIsPreserved() async throws {
    try await withSessionFixture { store, root, clip, result in
      let source = root.appendingPathComponent("draft.org")
      try "* Draft\nOriginal text\n".write(to: source, atomically: true, encoding: .utf8)
      let location = WorkspaceLocation.openClaw(OpenClawThread(
        title: "Draft", file: source.path, line: 1, zone: "test", modifiedAt: nil
      ))
      store.select(location)
      await store.loadEntrySource(for: location)
      let gate = BrowserClipOperationGate()
      let session = BrowserClipImportSession()
      defer { session.close() }
      session.commandForTesting = { _ in result }
      session.chooseClip(clip, store: store)
      await session.waitForOperationForTesting()
      store.corpusFileScanForTesting = { _ in await gate.suspend(); return [] }
      var completed = false
      session.importClip(store: store) { _ in completed = true }
      let operation = try XCTUnwrap(session.operationForTesting)
      await gate.waitUntilEntered()
      store.beginEditingSelectedEntry()
      store.noteSourceEditorLocalTextChanged("An unsaved source edit")
      await gate.release()
      await operation.value
      XCTAssertFalse(completed)
      XCTAssertTrue(store.hasActiveEdit)
      XCTAssertTrue(store.entryEditorHasUnsavedChanges)
      XCTAssertEqual(store.selectedLocation?.file, source.path)
      XCTAssertTrue(session.imported)
      XCTAssertTrue(session.error?.contains("Finish the current source edit") == true)
    }
  }

  @MainActor
  private func withSessionFixture(
    _ body: @MainActor (WorkspaceStore, URL, URL, BrowserClipImportResult) async throws -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("org2-browser-session-\(UUID())")
    let views = root.appendingPathComponent("views")
    try FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "Org2BrowserClipSession.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(defaults: defaults, openClawTranscriptURL: root.appendingPathComponent("chat.json"))
    store.setWorkspaceRealtimeRefreshActive(false)
    store.setCorpusRoot(root, persistsDefault: false)
    store.isCapturePanelPresented = true
    store.corpusFileScanForTesting = { _ in [] }
    let file = views.appendingPathComponent("browser-clips.org")
    try "* TODO Story\n: A selected passage.\n".write(to: file, atomically: true, encoding: .utf8)
    let result = BrowserClipImportResult(
      clip: .init(title: "Story", url: "https://example.com/story", author: "Ada",
                  capturedAt: "2026-09-13T12:00:00Z", mode: "selection", template: "task", content: "A selected passage."),
      file: file.path, revision: "sha256:source", clipRevision: "clip-hash", duplicate: false,
      entryText: "* TODO Story\n: A selected passage.\n", headingLine: 1
    )
    try await body(store, root, root.appendingPathComponent("article.org2clip"), result)
  }
}
