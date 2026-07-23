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

    store.selectedEntrySource = EntrySource(
      file: "/tmp/notes.md",
      startLine: 1,
      endLineExclusive: 2,
      text: "# Notes\n",
      isSubtree: false
    )
    XCTAssertFalse(store.canExportSlides)
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
}
