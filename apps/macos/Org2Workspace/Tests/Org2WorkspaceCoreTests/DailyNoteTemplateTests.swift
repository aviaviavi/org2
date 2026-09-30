import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

final class DailyNoteTemplateTests: XCTestCase {
  private struct Fixture: Decodable {
    struct Render: Decodable {
      let template: String
      let date: String
      let path: String
    }

    let render: [Render]
    let invalid: [String]
  }

  /// The CLI and the app must resolve the same file for the same format.
  func testRendersAndRejectsTheSharedFixtureLikeTheCLI() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // DailyNoteTemplateTests.swift
      .deletingLastPathComponent()  // Org2WorkspaceCoreTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // Org2Workspace
      .deletingLastPathComponent()  // macos
      .deletingLastPathComponent()  // apps
      .appendingPathComponent("test/fixtures/daily-note-templates.json")
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
    XCTAssertFalse(fixture.render.isEmpty)

    let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    for item in fixture.render {
      let template = try XCTUnwrap(DailyNoteTemplate(item.template), item.template)
      let parts = item.date.split(separator: "-").compactMap { Int($0) }
      let date = try XCTUnwrap(
        calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
      )
      XCTAssertEqual(template.relativePath(for: date, timeZone: utc), item.path, item.template)
    }
    for template in fixture.invalid {
      XCTAssertNotNil(DailyNoteTemplate.problem(template), "Expected \(template.debugDescription) to be rejected")
      XCTAssertNil(DailyNoteTemplate(template))
    }
  }

  func testNewNotesStartWithTitleSyntaxForTheirFormat() {
    XCTAssertEqual(
      DailyNoteTemplate.initialContent(for: URL(fileURLWithPath: "/c/daily/2026-09-29.org")),
      "#+TITLE: 2026-09-29\n\n"
    )
    XCTAssertEqual(
      DailyNoteTemplate.initialContent(for: URL(fileURLWithPath: "/c/ops/0929-startup.md")),
      "# 0929-startup\n\n"
    )
    XCTAssertEqual(DailyNoteTemplate.initialContent(for: URL(fileURLWithPath: "/c/log/0929.txt")), "")
  }

  @MainActor
  func testTodayOpensTheFileNamedByTheConfiguredFormat() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-daily-template-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let format = "ops/{YYYY}/{MM}{DD}-startup.md"
    try #"{"roam":{"dailiesDir":"daily","dailyFileTemplate":"ops/{YYYY}/{MM}{DD}-startup.md"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)
    let template = try XCTUnwrap(DailyNoteTemplate(format))
    let yesterday = try XCTUnwrap(Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: Date()))
    let existing = template.url(for: yesterday, corpusRoot: root)
    try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "# Startup\n\nexisting\n".write(to: existing, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)

    // An existing note is opened, not rewritten.
    store.openDailyNote(.yesterday)
    await store.waitForDailyNoteNavigationForTesting()
    XCTAssertEqual(store.selectedLocation?.file, existing.standardizedFileURL.path)
    XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "# Startup\n\nexisting\n")
    XCTAssertEqual(store.activeDailyNoteTemplate, template)
    XCTAssertEqual(store.existingDailyNoteFile(for: yesterday)?.path, existing.standardizedFileURL.path)

    // A missing note is created at the format's path with Markdown syntax.
    store.openDailyNote(.today)
    await store.waitForDailyNoteNavigationForTesting()
    let today = template.url(for: Date(), corpusRoot: root)
    XCTAssertEqual(store.selectedLocation?.file, today.path)
    let created = try String(contentsOf: today, encoding: .utf8)
    XCTAssertEqual(created, "# \(today.deletingPathExtension().lastPathComponent)\n\n")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("daily").path),
      "The dailiesDir convention must not be used while a format is configured"
    )

    // With automatic creation disabled, Home reports the format's path.
    store.automaticDailyNoteCreationDisabled = true
    try FileManager.default.removeItem(at: today)
    store.openHome()
    await store.waitForDailyNoteNavigationForTesting()
    XCTAssertEqual(store.missingDailyNote?.file, today.path)
    XCTAssertEqual(store.missingDailyNote?.opensHome, true)
  }

  @MainActor
  func testClearingTheFormatRestoresTheDailiesDirConvention() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-daily-template-clear-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("org2.json")
    try #"{"roam":{"dailiesDir":"daily","dailyFileTemplate":"j/{MM}-{DD}.md"}}"#
      .write(to: config, atomically: true, encoding: .utf8)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    _ = await store.dailyNoteDirectoryForTesting(corpusRoot: root)
    XCTAssertEqual(store.activeDailyNoteTemplate?.template, "j/{MM}-{DD}.md")

    try #"{"roam":{"dailiesDir":"daily","dailyFileTemplate":"../j/{MM}-{DD}.md"}}"#
      .write(to: config, atomically: true, encoding: .utf8)
    store.reloadDailyNoteConfiguration()
    let directory = await store.dailyNoteDirectoryForTesting(corpusRoot: root)
    XCTAssertNil(store.activeDailyNoteTemplate, "An invalid format falls back to dailiesDir")
    XCTAssertEqual(directory, root.appendingPathComponent("daily", isDirectory: true).standardizedFileURL)
  }

  @MainActor
  func testFormatSettingsRender() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-daily-format-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try #"{"roam":{"dailyFileTemplate":"ops/{YYYY}/{MM}{DD}-startup.md"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    let template = try XCTUnwrap(DailyNoteTemplate("ops/{YYYY}/{MM}{DD}-startup.md"))
    let view = Form {
      DailyNoteFormatSettingsSection()
      Section { DailyNoteFormatPreview(template: template, corpusRoot: root) }
    }
    .formStyle(.grouped).environment(store).frame(width: 620, height: 360)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.contentView = nil; window.close() }
    for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)) }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: "/tmp/openorg-daily-format-settings.png"))
  }
}
