import XCTest
import AppKit
import SwiftUI
@testable import Org2WorkspaceCore

final class CustomTodoWorkflowTests: XCTestCase {
  func testCanonicalCustomStatesReachRenderedHeadings() async throws {
    let raw = "#+TODO: TODO(t) missed(m) | DONE(d) SKIPPED(s)\n* missed Follow up\n"
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let document: Org2CanonicalDocument = try await cli.parseTextJSON(raw, sourceRanges: true)
    let blocks = OrgEntryRenderer.parseEditable(raw, canonicalDocument: document)
    let block = try XCTUnwrap(blocks.first { if case .heading = $0.rendered { return true }; return false })
    guard case .heading(let heading) = block.rendered else { return XCTFail("No heading") }
    XCTAssertEqual(heading.todo, "missed")
    XCTAssertEqual(heading.title, "Follow up")
    XCTAssertEqual(heading.todoTerminal, false)
    XCTAssertEqual(heading.todoSequences.first?.terminal, ["DONE", "SKIPPED"])
    XCTAssertEqual(WorkspaceStore.nextHeadingTodoStatus(after: "missed", sequences: heading.todoSequences), "DONE")
    XCTAssertEqual(WorkspaceStore.nextHeadingTodoStatus(after: "SKIPPED", sequences: heading.todoSequences), "TODO")
    XCTAssertEqual(OrgRenderedLineDisplayCache.headingTitle(rawText: "* missed *Follow up*", fallback: "Follow up", knownTodo: "missed"), "*Follow up*")
  }

  @MainActor
  func testMarkMissedDoneThroughWorkspaceAction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("org2-custom-todo-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("tasks.org")
    try "#+TODO: TODO missed | DONE SKIPPED\n* missed Follow up\n:PROPERTIES:\n:ID: jacob-task\n:END:\n".write(to: file, atomically: true, encoding: .utf8)
    let json: [String: Any] = ["todo": "missed", "headline": "Follow up", "kind": "SCHEDULED", "file": file.path, "line": 1, "body": "", "level": 1, "tags": [], "properties": ["ID": "jacob-task"]]
    let item = try JSONDecoder().decode(AgendaItem.self, from: JSONSerialization.data(withJSONObject: json))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.applyTodoShortcut(.done, to: .agenda(item))
    let text = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(text.contains("* DONE Follow up\nCLOSED:"), store.errorText ?? text)
    XCTAssertFalse(text.contains("DONE missed"))
    XCTAssertTrue(text.contains(":ID: jacob-task"))
    XCTAssertFalse(store.statusText.contains("failed"), store.errorText ?? "")

    // A stale target must give feedback and preserve the file.
    try "* Different heading\n".write(to: file, atomically: true, encoding: .utf8)
    await store.applyTodoShortcut(.done, to: .agenda(item))
    XCTAssertNotNil(store.errorText)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "* Different heading\n")
  }
  @MainActor
  func testCustomWorkflowAndErrorBannerRender() async throws {
    let raw = "#+TODO: TODO missed | DONE SKIPPED\n* missed Follow up with Jacob\n* SKIPPED A terminal task\n"
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let document: Org2CanonicalDocument = try await cli.parseTextJSON(raw, sourceRanges: true)
    let blocks = OrgEntryRenderer.parseEditable(raw, canonicalDocument: document).filter {
      if case .heading = $0.rendered { return true }; return false
    }
    let root = VStack(alignment: .leading, spacing: 16) {
      WorkspaceActionErrorBanner(error: "The file changed before this action could finish. Refresh the note and try again.") {}
      ForEach(blocks) { block in
        RenderedBlockView(block: block.rendered, rawText: block.rawText).padding(.horizontal)
      }
      Spacer()
    }.frame(width: 620, height: 250).background(Color(nsColor: .textBackgroundColor))
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 250), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.contentView = nil; window.close() }
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/openorg-custom-todo.png"))
  }

}
