import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AIChatThreadOutputsTests: XCTestCase {
  private let root = "/corpus"
  private let home = "/Users/me"
  private let room = "/corpus/views/data-rooms/acme"

  private func reply(_ content: String, edits: [(String, AIChatCorpusFileChange.Status)] = []) -> AIChatMessage {
    AIChatMessage(
      role: .assistant,
      content: content,
      changeSummary: edits.isEmpty ? nil : AIChatCorpusChangeSummary(files: edits.map {
        AIChatCorpusFileChange(relativePath: $0.0, status: $0.1, insertions: 1, deletions: 0)
      })
    )
  }

  func testDerivesEditedAndLinkedFilesGroupedBySourceAndPublishedFormats() {
    let first = reply(
      "Done. [[file:~/corpus-remote/views/data-rooms/acme/sales/pipeline.pdf][PDF]] and [[file:/corpus/views/data-rooms/acme/INDEX.org::12][Index]]",
      edits: [("views/data-rooms/acme/sales/pipeline.org", .modified), ("views/data-rooms/acme/INDEX.org", .created)]
    )
    let second = reply(
      "Updated [[file:views/data-rooms/acme/sales/pipeline.org][pipeline]], see views/data-rooms/acme/sales/pipeline.org again.",
      edits: [("views/data-rooms/acme/sales/pipeline.org", .modified), ("daily/2026-09-29.org", .modified)]
    )
    let messages = [AIChatMessage(role: .user, content: "see /corpus/notes/ignored.org"), first, second]

    let outputs = AIChatThreadOutputs.derive(
      messages: messages,
      corpusRoot: root,
      remoteCorpusRoot: "~/corpus-remote",
      homeDirectory: home
    )

    XCTAssertEqual(outputs.folder, room)
    let pipeline = try! XCTUnwrap(outputs.groups.first { $0.stem == "pipeline" })
    XCTAssertEqual(pipeline.files.map(\.fileExtension), ["org", "pdf"])
    XCTAssertEqual(pipeline.editCount, 2)
    XCTAssertEqual(pipeline.linkCount, 2, "a file linked twice in one reply counts once")
    XCTAssertEqual(pipeline.lastMessageID, second.id)
    XCTAssertEqual(outputs.groups.first?.stem, "pipeline", "most recently touched first")
    let index = try! XCTUnwrap(outputs.groups.first { $0.stem == "INDEX" })
    XCTAssertTrue(index.primary.wasCreated)
    XCTAssertEqual(outputs.groupsInFolder.map(\.stem).sorted(), ["INDEX", "pipeline"])
    XCTAssertEqual(outputs.groupsOutsideFolder.map(\.stem), ["2026-09-29"])
    XCTAssertFalse(outputs.touchedPaths.contains("/corpus/notes/ignored.org"), "user messages do not count")
  }

  func testIgnoresNonFileLinksAndChatState() {
    let message = reply(
      "[[id:abc][node]] [[https://example.com/a.pdf][web]] [[*Heading]] [[file:.org2/runs/x.org2][run]] [[file:~/notes/.hidden.org][h]]"
    )
    let outputs = AIChatThreadOutputs.derive(messages: [message], corpusRoot: root, homeDirectory: home)
    XCTAssertTrue(outputs.isEmpty)
  }

  func testWorkingFolderPrefersLinkedFilesAndSkipsBroadFolders() {
    // Concurrent writes such as meeting notes land in change summaries; the
    // deliberately linked files decide the folder.
    let messages = [
      reply(
        "[[file:/Users/me/dev/app/Sources/A.swift][A]] [[file:/Users/me/dev/app/Sources/B.swift][B]]",
        edits: [("meetings/one.org", .modified), ("meetings/two.org", .modified), ("meetings/three.org", .modified)]
      ),
    ]
    let outputs = AIChatThreadOutputs.derive(messages: messages, corpusRoot: root, homeDirectory: home)
    XCTAssertEqual(outputs.folder, "/Users/me/dev/app/Sources")

    let noise = AIChatThreadOutputs.derive(
      messages: [reply("", edits: [("daily/a.org", .modified), ("daily/b.org", .modified)])],
      corpusRoot: root,
      homeDirectory: home
    )
    XCTAssertNil(noise.folder, "daily/ is a bucket, not a working folder")
    XCTAssertNil(AIChatThreadOutputs.workingFolder(for: ["/Users/me/dev", "/Users/me/dev"], corpusRoot: root, homeDirectory: home))
    XCTAssertNil(AIChatThreadOutputs.workingFolder(for: ["\(room)/a"], corpusRoot: root, homeDirectory: home), "one output is not a folder")
  }

  func testWorkingFolderIsDeepestFolderHoldingMostOutputs() {
    let directories = ["\(room)/customers", "\(room)/customers", "\(room)/sales", room, "/corpus/meetings"]
    XCTAssertEqual(AIChatThreadOutputs.workingFolder(for: directories, corpusRoot: root, homeDirectory: home), room)
  }

  func testFileStatusAddsPublishedSiblingsFlagsStaleFormatsAndDropsFolders() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("outputs-\(UUID().uuidString)")
      .standardizedFileURL
    let corpus = base.path
    try FileManager.default.createDirectory(at: base.appendingPathComponent("room/sub"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("room/report.org")
    let pdf = base.appendingPathComponent("room/report.pdf")
    let html = base.appendingPathComponent("room/report.html")
    for url in [source, pdf, html, base.appendingPathComponent("room/other.org")] {
      try Data("x".utf8).write(to: url)
    }
    let now = Date()
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: source.path)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: pdf.path)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: html.path)

    let message = reply(
      "Built [[file:\(corpus)/room/report.pdf][PDF]]. Folder: \(corpus)/room/sub.org2 is not a file",
      edits: [("room/report.org", .modified), ("room/other.org", .modified), ("room/gone.org", .deleted)]
    )
    try FileManager.default.createDirectory(at: base.appendingPathComponent("room/sub.org2"), withIntermediateDirectories: true)

    let outputs = AIChatThreadOutputs.derive(messages: [message], corpusRoot: corpus, homeDirectory: home)
      .resolvingFileStatus()

    XCTAssertFalse(outputs.groups.contains { $0.stem == "sub" }, "directories are not outputs")
    let report = try XCTUnwrap(outputs.groups.first { $0.stem == "report" })
    XCTAssertEqual(report.files.map(\.fileExtension), ["org", "pdf", "html"])
    XCTAssertTrue(try XCTUnwrap(report.files.first { $0.fileExtension == "html" }).isSibling)
    XCTAssertEqual(report.staleFormats, ["PDF"], "only formats older than the source are stale")
    XCTAssertEqual(outputs.staleCount, 1)
    XCTAssertFalse(try XCTUnwrap(outputs.groups.first { $0.stem == "gone" }).exists)
    XCTAssertEqual(outputs.folder, corpus + "/room")
    XCTAssertEqual(outputs.displayPath(corpus + "/room/report.org"), "room/report.org")
  }

  func testFolderEntriesListFoldersFirstAndSkipHiddenAndBackupFiles() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("outputs-list-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base.appendingPathComponent("b-dir"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    for name in ["a.org", "c.pdf", ".DS_Store", "a.tex~"] {
      try Data().write(to: base.appendingPathComponent(name))
    }
    let entries = AIChatOutputsFolderEntry.list(base.path)
    XCTAssertEqual(entries.map(\.name), ["b-dir", "a.org", "c.pdf"])
    XCTAssertTrue(entries[0].isDirectory)
  }
}
