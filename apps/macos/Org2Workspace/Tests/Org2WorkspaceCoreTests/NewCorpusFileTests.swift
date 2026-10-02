import XCTest
@testable import Org2WorkspaceCore

final class NewCorpusFileTests: XCTestCase {
  private let root = URL(fileURLWithPath: "/tmp/org2-new-file-corpus", isDirectory: true)

  func testNameWithoutExtensionBecomesSluggedOrgFileWithTypedTitle() throws {
    let plan = try NewCorpusFilePlan.plan(name: "  Launch Blog Post! ", folder: "notes", corpusRoot: root)
    XCTAssertEqual(plan.relativePath, "notes/launch-blog-post.org")
    XCTAssertEqual(plan.url.path, "/tmp/org2-new-file-corpus/notes/launch-blog-post.org")
    XCTAssertEqual(plan.title, "Launch Blog Post!")

    let content = plan.initialContent(id: "ID-1", createdAt: Date(timeIntervalSince1970: 0))
    XCTAssertTrue(content.hasPrefix(":PROPERTIES:\n:ID: ID-1\n:CREATED: ["), content)
    XCTAssertTrue(content.hasSuffix(":END:\n#+TITLE: Launch Blog Post!\n\n"), content)
  }

  func testExplicitExtensionAndNestedFolderAreKeptVerbatim() throws {
    let markdown = try NewCorpusFilePlan.plan(name: "Scratch.md", folder: "drafts//2026/", corpusRoot: root)
    XCTAssertEqual(markdown.relativePath, "drafts/2026/Scratch.md")
    XCTAssertEqual(markdown.initialContent(), "# Scratch\n\n")

    let rootFile = try NewCorpusFilePlan.plan(name: "todo.org2", folder: "  ", corpusRoot: root)
    XCTAssertEqual(rootFile.relativePath, "todo.org2")
  }

  func testRejectsNamesAndFoldersThatEscapeTheCorpus() {
    XCTAssertThrowsError(try NewCorpusFilePlan.plan(name: "  ", folder: "notes", corpusRoot: root)) {
      XCTAssertEqual($0 as? NewCorpusFilePlan.Failure, .emptyName)
    }
    for name in ["../escape", "a/b", ".hidden", ".."] {
      XCTAssertThrowsError(try NewCorpusFilePlan.plan(name: name, folder: "notes", corpusRoot: root), name) {
        XCTAssertEqual($0 as? NewCorpusFilePlan.Failure, .invalidName)
      }
    }
    for folder in ["../outside", "notes/../../x", "~/notes"] {
      XCTAssertThrowsError(try NewCorpusFilePlan.plan(name: "x", folder: folder, corpusRoot: root), folder) {
        XCTAssertEqual($0 as? NewCorpusFilePlan.Failure, .invalidFolder)
      }
    }
  }

  @MainActor
  func testStoreCreatesOpensAndRefusesToOverwrite() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-new-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try #"{"roam":{"nodesDir":"pages","dailiesDir":"daily"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)

    store.presentNewCorpusFileSheet()
    XCTAssertTrue(store.isNewCorpusFileSheetPresented)
    XCTAssertEqual(store.newCorpusFileDefaultFolder, "pages")

    let created = await store.createNewCorpusFile(name: "Weekly Plan", folder: store.newCorpusFileDefaultFolder)
    let url = root.appendingPathComponent("pages/weekly-plan.org").standardizedFileURL
    XCTAssertEqual(created?.path, url.path)
    XCTAssertFalse(store.isNewCorpusFileSheetPresented)
    XCTAssertNil(store.newCorpusFileError)
    XCTAssertEqual(store.selectedLocation?.file, url.path)
    let text = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(text.contains("#+TITLE: Weekly Plan\n"), text)
    XCTAssertTrue(text.contains(":ID: "), text)

    try "edited\n".write(to: url, atomically: true, encoding: .utf8)
    store.presentNewCorpusFileSheet()
    let duplicate = await store.createNewCorpusFile(name: "Weekly Plan", folder: "pages")
    XCTAssertNil(duplicate)
    XCTAssertTrue(store.isNewCorpusFileSheetPresented)
    XCTAssertEqual(store.newCorpusFileError, "pages/weekly-plan.org already exists.")
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "edited\n")
  }
}
