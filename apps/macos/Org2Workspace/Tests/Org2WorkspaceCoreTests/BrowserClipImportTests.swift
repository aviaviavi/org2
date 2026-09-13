import XCTest
@testable import Org2WorkspaceCore

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
}
