import AppKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceSlashCommandsTests: XCTestCase {
  private func match(_ text: String) -> WorkspaceSlashCommandMatch? {
    WorkspaceSlashCommands.match(in: text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
  }

  func testSlashImageMatchesOnlyAsATypedCommand() {
    XCTAssertEqual(match("/")?.replacementRange, NSRange(location: 0, length: 1))
    XCTAssertEqual(match("- notes /im"), WorkspaceSlashCommandMatch(query: "im", replacementRange: NSRange(location: 8, length: 3)))
    XCTAssertEqual(match("line\n/image")?.query, "image")
    XCTAssertEqual(match("/image").map(WorkspaceSlashCommands.options(for:)), [.image])

    XCTAssertNil(match("and/or"))
    XCTAssertNil(match("see /Users/avi"))
    XCTAssertNil(match("https://example.com/i"))
    XCTAssertNil(match("/italic"))
    XCTAssertNil(match("/image now"))
    XCTAssertNil(WorkspaceSlashCommands.match(in: "/image", selectedRange: NSRange(location: 0, length: 6)))
  }

  func testAcceptRemovesTheTypedCommandAndReportsIt() throws {
    let found = try XCTUnwrap(match("Shot: /ima"))
    var state = WorkspaceSlashCommandCompletionState()
    var accepted: WorkspaceSlashCommand?
    let result = state.handle(.accept, match: found, options: [.image], accepted: &accepted)
    XCTAssertEqual(accepted, .image)
    guard case .replace(let range, let text) = result else { return XCTFail("expected replace") }
    XCTAssertEqual(range, NSRange(location: 6, length: 4))
    XCTAssertEqual(text, "")

    accepted = nil
    XCTAssertEqual(state.handle(.dismiss, match: found, options: [.image], accepted: &accepted), .handled)
    XCTAssertTrue(state.isDismissed(found))
    XCTAssertEqual(state.handle(.accept, match: found, options: [.image], accepted: &accepted), .ignored)
    XCTAssertNil(accepted)
  }

  func testImportCopiesOutsideImagesIntoAttachmentsAndLinksFromTheNote() async throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-slash-image-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("corpus", isDirectory: true)
    let outside = base.appendingPathComponent("Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("daily"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let screenshot = outside.appendingPathComponent("Screenshot 2026-10-02 at 9.28.55\u{202F}AM.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: screenshot)
    let existing = root.appendingPathComponent("images/chart one.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: existing)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedEntrySource = EntrySource(
      file: root.appendingPathComponent("daily/2026-10-02.org").path,
      startLine: 1, endLineExclusive: 1, text: "", isSubtree: false
    )

    let imported = await store.importSourceEditorImage(from: screenshot)
    let link = try XCTUnwrap(imported)
    XCTAssertTrue(link.hasPrefix("[[file:../attachments/"), link)
    XCTAssertTrue(link.hasSuffix("-screenshot-2026-10-02-at-9-28-55-am.png]]"), link)
    let copied = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("attachments").path)
    XCTAssertEqual(copied.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.path))

    let linkedInPlace = await store.importSourceEditorImage(from: existing)
    let inCorpus = try XCTUnwrap(linkedInPlace)
    XCTAssertEqual(inCorpus, "[[file:../images/chart one.png]]")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("attachments").path).count,
      1
    )
  }
}
