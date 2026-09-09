import XCTest
import AppKit
import SwiftUI
@testable import Org2WorkspaceCore

final class CorpusTodoSettingsTests: XCTestCase {
  func testCorpusDefaultsReachFilesDraftsAndSettings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("org2-corpus-todo-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("tasks.org")
    let source = "* missed Follow up\n"
    try source.write(to: file, atomically: true, encoding: .utf8)
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let args = ["todo-config", "set", "--dir", root.path, "--sequences-json", "[\"TODO missed | DONE SKIPPED\"]"]
    let preview: CorpusTodoConfiguration = try await cli.runJSON(args)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("org2.json").path))
    let saved: CorpusTodoConfiguration = try await cli.runJSON(args + ["--if-revision", preview.revision, "--apply"])
    XCTAssertEqual(saved.sequenceFields.first?.active, "TODO missed")
    XCTAssertEqual(saved.sequenceFields.first?.terminal, "DONE SKIPPED")
    let document: Org2CanonicalDocument = try await cli.parseFileJSON(file, sourceRanges: true)
    let draft: Org2CanonicalDocument = try await cli.parseTextJSON(source, sourceRanges: true, sourcePath: file.path)
    for parsed in [document, draft] {
      let blocks = OrgEntryRenderer.parseEditable(source, canonicalDocument: parsed)
      guard case .heading(let heading) = try XCTUnwrap(blocks.first).rendered else { return XCTFail("Missing heading") }
      XCTAssertEqual(heading.todo, "missed")
      XCTAssertEqual(heading.title, "Follow up")
      XCTAssertEqual(WorkspaceStore.nextHeadingTodoStatus(after: "missed", sequences: heading.todoSequences), "DONE")
    }
    _ = try await cli.analyzeEditorText(source, sourcePath: file.path)
  }

  @MainActor
  func testCorpusSettingsRender() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("org2-todo-settings-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "{\"todo\":{\"sequences\":[\"TODO missed | DONE SKIPPED\",\"DRAFT REVIEW | PUBLISHED\"]}}".write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    let view = Form { CorpusTodoSettingsSection() }.formStyle(.grouped).environment(store).frame(width: 620, height: 440)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.contentView = nil; window.close() }
    for _ in 0..<40 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)) }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/openorg-corpus-todo-settings.png"))
  }
}
