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

  @MainActor
  func testEditorModelDoesNotParseLargeTextDuringInitialization() async throws {
    let parser = ControlledCSVDocumentParser()
    let source = String(repeating: "name,value\nAvi,1\n", count: 10_000)
    let model = CSVDocumentEditorModel(
      rawText: source,
      parser: { text in await parser.parse(text) }
    )

    XCTAssertEqual(model.rawText.count, source.count)
    XCTAssertTrue(model.isParsing)
    let parsedDuringInitialization = await parser.hasRequest(for: source)
    XCTAssertFalse(parsedDuringInitialization)

    model.startInitialParse()
    try await waitForParseRequest(source, parser: parser)
    await parser.resolve(
      source,
      with: .success(CSVDocument(rows: [["name", "value"], ["Avi", "1"]]))
    )
    try await waitForCondition { !model.isParsing }

    XCTAssertEqual(model.document.rowCount, 2)
    XCTAssertEqual(model.presentation, .table)
  }

  @MainActor
  func testEditorModelRejectsAStaleParseAfterRawTextChanges() async throws {
    let parser = ControlledCSVDocumentParser()
    let original = "name,value\nold,1\n"
    let replacement = "name,value\nnew,2\n"
    let model = CSVDocumentEditorModel(
      rawText: original,
      parser: { text in await parser.parse(text) }
    )

    model.startInitialParse()
    try await waitForParseRequest(original, parser: parser)

    model.noteRawTextChanged(replacement)
    model.selectTablePresentation()
    try await waitForParseRequest(replacement, parser: parser)
    await parser.resolve(
      replacement,
      with: .success(CSVDocument(rows: [["name", "value"], ["new", "2"]]))
    )
    try await waitForCondition { !model.isParsing }

    await parser.resolve(
      original,
      with: .success(CSVDocument(rows: [["name", "value"], ["old", "1"]]))
    )
    try await Task.sleep(nanoseconds: 25_000_000)

    XCTAssertEqual(model.rawText, replacement)
    XCTAssertEqual(model.document.value(row: 1, column: 0), "new")
    XCTAssertEqual(model.textRevision, 3)
  }

  @MainActor
  func testEditorModelKeepsInvalidCSVInRawPresentation() async throws {
    let model = CSVDocumentEditorModel(rawText: "name,note\nAvi,\"unfinished")

    model.startInitialParse()
    try await waitForCondition { !model.isParsing }

    XCTAssertEqual(model.presentation, .raw)
    XCTAssertEqual(
      model.parseError,
      CSVDocumentError.unterminatedQuotedField.localizedDescription
    )
  }

  @MainActor
  func testTableTypingPublishesLatestBatchWithoutCopyingOrSerializingPerKey() async throws {
    let serializer = ControlledCSVTableSerializer()
    let recorder = CSVTablePublisherRecorder()
    let rows = await Task.detached {
      (0..<20_000).map { row in
        (0..<8).map { column in "r\(row)-c\(column)" }
      }
    }.value
    let original = CSVDocument(rows: rows, hasTrailingNewline: true)
    let originalText = original.serialized()
    let model = CSVDocumentEditorModel(
      rawText: originalText,
      tablePublicationDelayNanoseconds: 0,
      tableSerializer: { edits, document in
        await serializer.serialize(edits: edits, document: document)
      }
    )
    model.document = original

    model.noteTableCellChanged("first", row: 19_999, column: 7) { text, expectedText in
      recorder.publish(text, expectedText: expectedText)
      return true
    }
    XCTAssertEqual(model.tableValue(row: 19_999, column: 7), "first")
    XCTAssertEqual(model.document.value(row: 19_999, column: 7), "r19999-c7")
    XCTAssertEqual(model.rawText, originalText)
    var deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !(await serializer.hasRequest(for: "first")) {
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    let receivedFirstRequest = await serializer.hasRequest(for: "first")
    XCTAssertTrue(receivedFirstRequest)

    model.noteTableCellChanged("latest", row: 19_999, column: 7) { text, expectedText in
      recorder.publish(text, expectedText: expectedText)
      return true
    }
    deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !(await serializer.hasRequest(for: "latest")) {
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    let receivedLatestRequest = await serializer.hasRequest(for: "latest")
    XCTAssertTrue(receivedLatestRequest)
    await serializer.resolve("latest")
    try await waitForCondition { recorder.texts.count == 1 }

    XCTAssertEqual(model.document.value(row: 19_999, column: 7), "latest")
    XCTAssertEqual(model.tableValue(row: 19_999, column: 7), "latest")
    XCTAssertTrue(recorder.texts[0].hasSuffix(",latest\n"))
    XCTAssertEqual(recorder.expectedTexts, [originalText])

    await serializer.resolve("first")
    try await Task.sleep(for: .milliseconds(25))
    XCTAssertEqual(recorder.texts.count, 1)
    XCTAssertEqual(model.document.value(row: 19_999, column: 7), "latest")
  }

  @MainActor
  func testSwitchingFromTableToRawAwaitsTheLatestPublication() async throws {
    let serializer = ControlledCSVTableSerializer()
    let publisher = ControlledCSVTablePublisher()
    let original = CSVDocument(rows: [["name", "value"], ["Avi", "1"]])
    let originalText = original.serialized()
    let model = CSVDocumentEditorModel(
      rawText: originalText,
      tablePublicationDelayNanoseconds: 60_000_000_000,
      tableSerializer: { edits, document in
        await serializer.serialize(edits: edits, document: document)
      }
    )
    model.document = original

    model.noteTableCellChanged("2", row: 1, column: 1) { text, expectedText in
      await publisher.publish(text, expectedText: expectedText)
    }
    let transition = Task { @MainActor in
      await model.selectRawPresentation { text, expectedText in
        await publisher.publish(text, expectedText: expectedText)
      }
    }

    try await waitForTableSerializationRequest("2", serializer: serializer)
    await serializer.resolve("2")
    try await waitForCondition { publisher.hasPendingRequest }

    XCTAssertEqual(model.presentation, .table)
    XCTAssertEqual(model.rawText, originalText)
    publisher.resolve(succeeded: true)

    let transitionSucceeded = await transition.value
    XCTAssertTrue(transitionSucceeded)
    XCTAssertEqual(model.presentation, .raw)
    XCTAssertEqual(model.rawText, "name,value\nAvi,2")
  }

  @MainActor
  func testCSVLifecycleCheckpointAwaitsSerializationAndPublication() async throws {
    let serializer = ControlledCSVTableSerializer()
    let publisher = ControlledCSVTablePublisher()
    let original = CSVDocument(rows: [["name", "value"], ["Avi", "1"]])
    let model = CSVDocumentEditorModel(
      rawText: original.serialized(),
      tablePublicationDelayNanoseconds: 60_000_000_000,
      tableSerializer: { edits, document in
        await serializer.serialize(edits: edits, document: document)
      }
    )
    model.document = original
    CSVDocumentEditorLifecycle.register(model) { text, expectedText in
      await publisher.publish(text, expectedText: expectedText)
    }
    defer { CSVDocumentEditorLifecycle.unregister(model) }

    model.noteTableCellChanged("checkpointed", row: 1, column: 1) { text, expectedText in
      await publisher.publish(text, expectedText: expectedText)
    }
    let checkpoint = Task { @MainActor in
      await CSVDocumentEditorLifecycle.checkpointPendingTableEdits()
    }

    try await waitForTableSerializationRequest("checkpointed", serializer: serializer)
    await serializer.resolve("checkpointed")
    try await waitForCondition { publisher.hasPendingRequest }
    XCTAssertEqual(model.rawText, original.serialized())

    publisher.resolve(succeeded: true)
    let checkpointSucceeded = await checkpoint.value
    XCTAssertTrue(checkpointSucceeded)
    XCTAssertEqual(model.rawText, "name,value\nAvi,checkpointed")
    XCTAssertTrue(model.pendingTableCellValues.isEmpty)
  }

  @MainActor
  func testTerminationPersistsDebouncedCSVTableEdits() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-csv-termination-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let csv = root.appendingPathComponent("sample.csv")
    let originalText = "name,value\nAvi,1\n"
    try originalText.write(to: csv, atomically: true, encoding: .utf8)
    let suiteName = "org2-workspace-csv-termination-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      openClawTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    await store.waitForAIChatTranscriptLoadForTesting()
    store.openClawTranscriptSaverForTesting = {}
    store.setCorpusRoot(root, persistsDefault: false)

    let source = EntrySource(
      file: csv.path,
      startLine: 1,
      endLineExclusive: 3,
      text: originalText,
      isSubtree: false
    )
    let model = CSVDocumentEditorModel(
      rawText: originalText,
      tablePublicationDelayNanoseconds: 60_000_000_000
    )
    model.document = try CSVDocument(parsing: originalText)
    CSVDocumentEditorLifecycle.register(model) { text, expectedText in
      await store.persistDeferredLiveFileEditorText(
        text,
        expectedText: expectedText,
        source: source
      )
    }
    defer { CSVDocumentEditorLifecycle.unregister(model) }

    model.noteTableCellChanged("durable", row: 1, column: 1) { text, expectedText in
      await store.persistDeferredLiveFileEditorText(
        text,
        expectedText: expectedText,
        source: source
      )
    }

    let canTerminate = await store.prepareForTermination()
    XCTAssertTrue(canTerminate, store.statusText)
    XCTAssertEqual(
      try String(contentsOf: csv, encoding: .utf8),
      "name,value\nAvi,durable\n"
    )
  }

  @MainActor
  func testTerminationRefusesAFailedCSVTableCheckpoint() async throws {
    let store = try makeStore()
    let original = CSVDocument(rows: [["name", "value"], ["Avi", "1"]])
    let model = CSVDocumentEditorModel(
      rawText: original.serialized(),
      tablePublicationDelayNanoseconds: 60_000_000_000
    )
    model.document = original
    CSVDocumentEditorLifecycle.register(model) { _, _ in false }
    defer { CSVDocumentEditorLifecycle.unregister(model) }
    model.noteTableCellChanged("still-in-memory", row: 1, column: 1) { _, _ in false }

    let canTerminate = await store.prepareForTermination()

    XCTAssertFalse(canTerminate)
    XCTAssertEqual(store.statusText, "Could not save all editor changes before quitting")
    XCTAssertEqual(model.tableValue(row: 1, column: 1), "still-in-memory")
    XCTAssertFalse(model.pendingTableCellValues.isEmpty)
  }

  func testRenderedDocumentRoutesStructuredAndPDFLinksIntoWorkspace() {
    XCTAssertTrue(OrgHTMLDocumentLinkRouting.opensInWorkspace(URL(fileURLWithPath: "/tmp/sample.CSV")))
    XCTAssertTrue(OrgHTMLDocumentLinkRouting.opensInWorkspace(URL(fileURLWithPath: "/tmp/note.org2")))
    XCTAssertTrue(OrgHTMLDocumentLinkRouting.opensInWorkspace(URL(fileURLWithPath: "/tmp/report.PDF")))
    XCTAssertFalse(OrgHTMLDocumentLinkRouting.opensInWorkspace(URL(fileURLWithPath: "/tmp/report.png")))
  }

  @MainActor
  func testWideTableStartsAtLeadingEdgeAndProvidesHorizontalScrollRange() async throws {
    let document = CSVDocument(rows: [
      (0..<19).map { "column-\($0)" },
      (0..<19).map { "value-\($0)" },
    ])
    let editor = CSVTableEditor(
      document: document,
      value: { document.value(row: $0, column: $1) },
      setValue: { _, _, _ in },
      mutate: { _ in }
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
  private func waitForParseRequest(
    _ text: String,
    parser: ControlledCSVDocumentParser,
    timeout: TimeInterval = 5
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await parser.hasRequest(for: text) { return }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Timed out waiting for CSV parse request")
  }

  @MainActor
  private func waitForTableSerializationRequest(
    _ key: String,
    serializer: ControlledCSVTableSerializer,
    timeout: TimeInterval = 5
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await serializer.hasRequest(for: key) { return }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Timed out waiting for CSV table serialization")
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

private actor ControlledCSVDocumentParser {
  private var pending: [String: CheckedContinuation<CSVDocumentParseOutcome, Never>] = [:]

  func parse(_ text: String) async -> CSVDocumentParseOutcome {
    await withCheckedContinuation { continuation in
      pending[text] = continuation
    }
  }

  func hasRequest(for text: String) -> Bool {
    pending[text] != nil
  }

  func resolve(_ text: String, with outcome: CSVDocumentParseOutcome) {
    pending.removeValue(forKey: text)?.resume(returning: outcome)
  }
}

@MainActor
private final class CSVTablePublisherRecorder {
  private(set) var texts: [String] = []
  private(set) var expectedTexts: [String] = []

  func publish(_ text: String, expectedText: String) {
    texts.append(text)
    expectedTexts.append(expectedText)
  }
}

@MainActor
private final class ControlledCSVTablePublisher {
  private(set) var texts: [String] = []
  private(set) var expectedTexts: [String] = []
  private var continuation: CheckedContinuation<Bool, Never>?

  var hasPendingRequest: Bool {
    continuation != nil
  }

  func publish(_ text: String, expectedText: String) async -> Bool {
    texts.append(text)
    expectedTexts.append(expectedText)
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func resolve(succeeded: Bool) {
    continuation?.resume(returning: succeeded)
    continuation = nil
  }
}

private actor ControlledCSVTableSerializer {
  private struct Request {
    let edits: [CSVTableCellCoordinate: String]
    let document: CSVDocument
    let continuation: CheckedContinuation<CSVTablePublication, Never>
  }

  private var requests: [String: Request] = [:]

  func serialize(
    edits: [CSVTableCellCoordinate: String],
    document: CSVDocument
  ) async -> CSVTablePublication {
    let key = edits.values.sorted().last ?? ""
    return await withCheckedContinuation { continuation in
      requests[key] = Request(edits: edits, document: document, continuation: continuation)
    }
  }

  func hasRequest(for key: String) -> Bool {
    requests[key] != nil
  }

  func resolve(_ key: String) {
    guard let request = requests.removeValue(forKey: key) else { return }
    var updated = request.document
    for (coordinate, value) in request.edits {
      updated.setValue(value, row: coordinate.row, column: coordinate.column)
    }
    request.continuation.resume(returning: CSVTablePublication(
      document: updated,
      text: updated.serialized()
    ))
  }
}
