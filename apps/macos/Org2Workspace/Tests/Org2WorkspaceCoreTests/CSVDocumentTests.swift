import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

final class CSVDocumentTests: XCTestCase {
  func testParsesQuotedFieldsCRLFAndEmbeddedNewlines() throws {
    let source = "name,note\r\nAvi,\"hello, \"\"team\"\"\"\r\nJane,\"line one\nline two\"\r\n"

    let document = try CSVDocument(parsing: source)

    XCTAssertEqual(document.rowCount, 3)
    XCTAssertEqual(document.columnCount, 2)
    XCTAssertEqual(document.value(row: 1, column: 1), #"hello, "team""#)
    XCTAssertEqual(document.value(row: 2, column: 1), "line one\nline two")
    XCTAssertTrue(document.hasTrailingNewline)
    XCTAssertEqual(
      document.serialized(),
      "name,note\nAvi,\"hello, \"\"team\"\"\"\nJane,\"line one\nline two\"\n"
    )
  }

  func testPreservesTrailingEmptyFieldsAndFinalNewline() throws {
    let document = try CSVDocument(parsing: "a,b,\n1,2,\n")

    XCTAssertEqual(document.rows, [["a", "b", ""], ["1", "2", ""]])
    XCTAssertTrue(document.hasTrailingNewline)
    XCTAssertEqual(document.serialized(), "a,b,\n1,2,\n")
  }

  func testTableMutationsGrowAndSerializeDocument() throws {
    var document = try CSVDocument(parsing: "name,count\nAvi,1\n")

    document.setValue("2,000", row: 1, column: 1)
    document.appendColumn()
    document.setValue("status", row: 0, column: 2)
    document.setValue("active", row: 1, column: 2)
    document.appendRow()
    document.setValue("Jane", row: 2, column: 0)
    document.setValue("pending", row: 2, column: 2)

    XCTAssertEqual(document.rowCount, 3)
    XCTAssertEqual(document.columnCount, 3)
    XCTAssertEqual(
      document.serialized(),
      "name,count,status\nAvi,\"2,000\",active\nJane,,pending\n"
    )

    document.removeColumn(at: 1)
    document.removeRow(at: 1)
    XCTAssertEqual(document.serialized(), "name,status\nJane,pending\n")
  }

  func testRejectsUnterminatedQuotedField() {
    XCTAssertThrowsError(try CSVDocument(parsing: "name,note\nAvi,\"unfinished")) { error in
      XCTAssertEqual(error as? CSVDocumentError, .unterminatedQuotedField)
    }
  }

  func testRenderedDocumentRoutesStructuredAndPDFLinksIntoWorkspace() {
    XCTAssertTrue(OrgHTMLDocumentLinkRouting.opensInWorkspace(URL(fileURLWithPath: "/tmp/sample.CSV")))
    XCTAssertTrue(OrgHTMLDocumentLinkRouting.opensInWorkspace(URL(fileURLWithPath: "/tmp/note.org2")))
    XCTAssertTrue(OrgHTMLDocumentLinkRouting.opensInWorkspace(URL(fileURLWithPath: "/tmp/report.PDF")))
    XCTAssertFalse(OrgHTMLDocumentLinkRouting.opensInWorkspace(URL(fileURLWithPath: "/tmp/report.png")))
  }

  @MainActor
  func testWideTableStartsAtLeadingEdgeAndProvidesHorizontalScrollRange() async throws {
    var document = CSVDocument(rows: [
      (0..<19).map { "column-\($0)" },
      (0..<19).map { "value-\($0)" },
    ])
    let editor = CSVTableEditor(
      document: Binding(
        get: { document },
        set: { document = $0 }
      ),
      publish: { document = $0 }
    )
    .frame(width: 800, height: 420)
    let hostingView = NSHostingView(rootView: editor)
    hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 420)
    let window = NSWindow(
      contentRect: hostingView.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    defer { window.orderOut(nil) }
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)

    for _ in 0..<5 {
      try await Task.sleep(nanoseconds: 25_000_000)
      window.layoutIfNeeded()
      hostingView.layoutSubtreeIfNeeded()
    }

    let scrollView = try XCTUnwrap(allScrollViews(in: hostingView).first {
      $0.hasHorizontalScroller
    })
    let documentView = try XCTUnwrap(scrollView.documentView)
    XCTAssertGreaterThan(documentView.bounds.width, scrollView.contentView.bounds.width + 2_000)
    XCTAssertEqual(scrollView.contentView.bounds.origin.x, 0, accuracy: 1)

    let originalY = scrollView.contentView.bounds.origin.y
    scrollView.contentView.scroll(to: NSPoint(x: 500, y: originalY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    XCTAssertGreaterThan(scrollView.contentView.bounds.origin.x, 400)
  }

  @MainActor
  func testCSVFilesAreDiscoveredAndDoNotBecomeRoamNodes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-csv-files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let csv = root.appendingPathComponent("sample.csv")
    try "#+TITLE: Not a node,* Fake heading\nvalue,other\n"
      .write(to: csv, atomically: true, encoding: .utf8)

    let store = try makeStore()
    store.setCorpusRoot(root, persistsDefault: false)
    await store.refreshCorpusFiles()

    try await waitForCondition {
      store.corpusFiles.map(\.relativePath) == ["sample.csv"]
    }
    try await waitForCondition {
      store.orgRoamLinkResolver.nodes.isEmpty
    }
  }

  @MainActor
  func testChatCSVLinkLoadsWithoutOrgRenderingAndSavesChanges() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-csv-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let csv = root.appendingPathComponent("sample.csv")
    try "name,count\nAvi,1\n".write(to: csv, atomically: true, encoding: .utf8)

    let store = try makeStore()
    store.setCorpusRoot(root, persistsDefault: false)
    store.openChatFileReference(OpenClawFileReference(path: csv.path, line: nil))

    try await waitForCondition {
      store.selectedEntrySource?.file == csv.path && !store.isLoadingEntrySource
    }

    XCTAssertTrue(store.selectedFileIsCSV)
    XCTAssertTrue(store.isLiveFileEditorSelected)
    XCTAssertTrue(store.isLiveFileEditorAvailable)
    XCTAssertNil(store.selectedEntryHTML)
    XCTAssertNil(store.selectedEntryRenderError)

    store.noteLiveFileEditorTextChanged("name,count\nAvi,2\n")
    await store.saveLiveFileEditor(explicit: true)

    XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), "name,count\nAvi,2\n")
    XCTAssertFalse(store.liveFileEditorHasUnsavedChanges)
  }

  @MainActor
  func testChatPDFLinkLoadsInTheNativePreviewWithoutOrgRendering() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-pdf-\(UUID().uuidString)", isDirectory: true)
    let reports = root.appendingPathComponent("reports", isDirectory: true)
    try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = reports.appendingPathComponent("brief.pdf")
    let expectedData = Data("%PDF-1.4\n% linked preview\n".utf8)
    try expectedData.write(to: pdf)

    let store = try makeStore()
    store.setCorpusRoot(root, persistsDefault: false)
    store.entrySourceLoaderForTesting = { _, _, _ in
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    store.linkedPDFDataLoaderForTesting = { url in
      try Data(contentsOf: url)
    }

    store.openChatFileReference(OpenClawFileReference(path: "reports/brief.pdf", line: nil))

    try await waitForCondition {
      store.linkedPDFPreviewData != nil && !store.isLoadingLinkedPDFPreview
    }

    XCTAssertTrue(store.selectedFileIsPDF)
    XCTAssertEqual(store.selectedLocation?.file, pdf.path)
    XCTAssertEqual(store.linkedPDFPreviewData, expectedData)
    XCTAssertNil(store.selectedEntrySource)
    XCTAssertNil(store.selectedEntryRenderError)
    XCTAssertNil(store.linkedPDFPreviewError)
  }

  @MainActor
  private func waitForCondition(
    timeout: TimeInterval = 5,
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Timed out waiting for condition")
  }

  @MainActor
  private func makeStore() throws -> WorkspaceStore {
    let suiteName = "org2-workspace-csv-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      legacyDefaultsDomains: []
    )
  }

  @MainActor
  private func allScrollViews(in view: NSView) -> [NSScrollView] {
    let current = (view as? NSScrollView).map { [$0] } ?? []
    return current + view.subviews.flatMap(allScrollViews)
  }
}
