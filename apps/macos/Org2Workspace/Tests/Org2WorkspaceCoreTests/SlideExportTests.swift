import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class SlideExportTests: XCTestCase {
  func testSlideExportFormatMetadata() {
    XCTAssertEqual(Org2SlideExportFormat.pdf.fileExtension, "pdf")
    XCTAssertEqual(Org2SlideExportFormat.pdf.title, "PDF")
    XCTAssertEqual(Org2SlideExportFormat.latex.fileExtension, "tex")
    XCTAssertEqual(Org2SlideExportFormat.latex.title, "LaTeX")
  }

  func testDocumentPreviewKindMetadata() {
    XCTAssertEqual(OrgDocumentPreviewKind.document.title, "Document")
    XCTAssertEqual(OrgDocumentPreviewKind.document.systemImage, "doc.richtext")
    XCTAssertEqual(OrgDocumentPreviewKind.slides.title, "Slides")
    XCTAssertEqual(OrgDocumentPreviewKind.slides.systemImage, "rectangle.on.rectangle")
  }

  func testOrg2CLIIncludesMacTeXInChildProcessPath() {
    let path = Org2CLI.processEnvironment()["PATH"] ?? ""
    XCTAssertTrue(path.split(separator: ":").contains("/Library/TeX/texbin"))
  }

  @MainActor
  func testWorkspaceOffersSlideExportOnlyForOrgFiles() {
    let suiteName = "Org2SlideExportTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory),
      defaults: defaults
    )

    store.selectedEntrySource = EntrySource(
      file: "/tmp/talk.org2",
      startLine: 1,
      endLineExclusive: 2,
      text: "* Slide\n",
      isSubtree: false
    )
    XCTAssertTrue(store.canExportSlides)
    XCTAssertTrue(store.canPreviewSlides)

    store.selectedEntrySource = EntrySource(
      file: "/tmp/notes.md",
      startLine: 1,
      endLineExclusive: 2,
      text: "# Notes\n",
      isSubtree: false
    )
    XCTAssertFalse(store.canExportSlides)
    XCTAssertFalse(store.canPreviewSlides)
  }

  func testOrg2CLIRendersPresentationPDFFromStandardInput() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-slide-preview-cli-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try """
    const fs = require("fs");
    fs.writeFileSync("arguments.json", JSON.stringify(process.argv.slice(2)));
    fs.writeFileSync("input.org2", fs.readFileSync(0));
    process.stdout.write("%PDF-1.4\\n");
    """.write(
      to: dist.appendingPathComponent("render-presentation-pdf.js"),
      atomically: true,
      encoding: .utf8
    )

    let cli = Org2CLI(repoRoot: root)
    let sourcePath = "/tmp/unsaved-talk.org2"
    let draft = "#+TITLE: Unsaved\n* Section\n** Draft slide\n"
    let pdf = try await cli.renderPresentationPDF(
      draft,
      sourcePath: sourcePath,
      passes: 1
    )

    XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("input.org2"), encoding: .utf8),
      draft
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        [String].self,
        from: Data(contentsOf: root.appendingPathComponent("arguments.json"))
      ),
      ["--source-path", sourcePath, "--passes", "1"]
    )
  }

  @MainActor
  func testLiveSlidePreviewKeepsLastSuccessfulPDFWhenDraftFails() async throws {
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory)
    )
    let source = EntrySource(
      file: "/tmp/talk.org2",
      startLine: 1,
      endLineExclusive: 5,
      text: "#+TITLE: Talk\n* Section\n** Initial\n",
      isSubtree: false
    )
    let expectedPDF = Data("%PDF-1.4\npreview".utf8)
    let recorder = SlidePreviewRecorder(pdf: expectedPDF)
    store.slidePreviewRendererForTesting = { text, sourcePath, passes in
      try await recorder.render(text: text, sourcePath: sourcePath, passes: passes)
    }
    store.selectedEntrySource = source
    store.beginEditingSelectedEntry()
    store.sourceEditorPresentation = .split
    store.documentPreviewKind = .slides

    let validDraft = "#+TITLE: Talk\n* Section\n** Live draft\n"
    store.editableEntryText = validDraft
    store.scheduleSourceEditorPreview(immediate: true)
    try await waitForSlidePreview(store) { $0.slidePreviewPDF == expectedPDF }

    let invalidDraft = "#+TITLE: Talk\n* Section\nBROKEN\n"
    store.editableEntryText = invalidDraft
    store.scheduleSourceEditorPreview(immediate: true)
    try await waitForSlidePreview(store) { $0.slidePreviewError != nil }

    XCTAssertEqual(store.slidePreviewPDF, expectedPDF)
    XCTAssertEqual(store.slidePreviewError, "Draft could not compile")
    let calls = await recorder.recordedCalls()
    XCTAssertEqual(calls.map(\.text), [validDraft, invalidDraft])
    XCTAssertTrue(calls.allSatisfy { $0.sourcePath == source.file && $0.passes == 1 })
  }

  func testOrg2CLIExportsBeamerPDFWithApplyFlag() async throws {
    try await assertExportArguments(
      format: .pdf,
      expectedTail: ["--pdf", "--format", "json", "--apply"]
    )
  }

  func testOrg2CLIExportsBeamerLatexWithoutPDFFlag() async throws {
    try await assertExportArguments(
      format: .latex,
      expectedTail: ["--format", "json", "--apply"]
    )
  }

  @MainActor
  func testSuccessfulPDFExportOpensTheDeckAutomatically() {
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory)
    )
    let destination = URL(fileURLWithPath: "/tmp/talk.pdf")
    var openedURL: URL?
    store.slideExportFileOpenerForTesting = { url in
      openedURL = url
      return true
    }

    store.finishSuccessfulSlideExport(format: .pdf, destination: destination)

    XCTAssertEqual(openedURL, destination)
    XCTAssertEqual(store.statusText, "Exported and opened talk.pdf")
    XCTAssertNil(store.slideExportNotice)
    XCTAssertNil(store.errorText)
  }

  @MainActor
  func testSuccessfulLatexExportDoesNotOpenTheFile() {
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory)
    )
    let destination = URL(fileURLWithPath: "/tmp/talk.tex")
    var didAttemptOpen = false
    store.slideExportFileOpenerForTesting = { _ in
      didAttemptOpen = true
      return true
    }

    store.finishSuccessfulSlideExport(format: .latex, destination: destination)

    XCTAssertFalse(didAttemptOpen)
    XCTAssertEqual(store.statusText, "Exported slides to talk.tex")
    XCTAssertEqual(store.slideExportNotice?.message, destination.path)
  }

  @MainActor
  func testPDFOpenFailureKeepsTheSuccessfulExport() {
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory)
    )
    let destination = URL(fileURLWithPath: "/tmp/talk.pdf")
    store.slideExportFileOpenerForTesting = { _ in false }

    store.finishSuccessfulSlideExport(format: .pdf, destination: destination)

    XCTAssertTrue(store.statusText.contains("but couldn’t open the PDF"))
    XCTAssertEqual(store.slideExportNotice?.title, "Slides Exported")
    XCTAssertTrue(store.slideExportNotice?.message.contains("was saved") == true)
    XCTAssertNil(store.errorText)
  }

  private func assertExportArguments(
    format: Org2SlideExportFormat,
    expectedTail: [String]
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-slide-export-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("talk.org2")
    let destination = root.appendingPathComponent("talk.\(format.fileExtension)")
    try "* Slide\n".write(to: source, atomically: true, encoding: .utf8)
    try """
    const fs = require("fs");
    fs.writeFileSync("arguments.json", JSON.stringify(process.argv.slice(2)));
    """.write(
      to: dist.appendingPathComponent("cli.js"),
      atomically: true,
      encoding: .utf8
    )

    let argumentsFile = root.appendingPathComponent("arguments.json")
    let cli = Org2CLI(repoRoot: root)
    try await cli.exportBeamer(
      file: source,
      destination: destination,
      format: format
    )

    let arguments = try JSONDecoder().decode(
      [String].self,
      from: Data(contentsOf: argumentsFile)
    )
    XCTAssertEqual(
      arguments,
      [
        "export", "beamer",
        "--file", source.standardizedFileURL.path,
        "--out", destination.standardizedFileURL.path,
      ] + expectedTail
    )
  }

  @MainActor
  private func waitForSlidePreview(
    _ store: WorkspaceStore,
    condition: (WorkspaceStore) -> Bool
  ) async throws {
    for _ in 0..<200 {
      if condition(store) { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for slide preview")
  }
}

private actor SlidePreviewRecorder {
  struct Call: Sendable {
    let text: String
    let sourcePath: String
    let passes: Int
  }

  private let pdf: Data
  private var calls: [Call] = []

  init(pdf: Data) {
    self.pdf = pdf
  }

  func render(text: String, sourcePath: String, passes: Int) throws -> Data {
    calls.append(Call(text: text, sourcePath: sourcePath, passes: passes))
    if text.contains("BROKEN") {
      throw Org2CLIError.commandFailed(status: 1, message: "Draft could not compile")
    }
    return pdf
  }

  func recordedCalls() -> [Call] {
    calls
  }
}
