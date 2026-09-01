import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AIChatOperationJournalTests: XCTestCase {
  func testLoadsEveryOperationKindInCreatedAtThenIDOrder() async throws {
    let root = temporaryCorpus("kinds")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try makeOperationsDirectory(root)
    try writeJSON([
      "schema": AIChatOperationJournal.schema,
      "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "createdAt": "2026-08-20T10:00:00.000Z",
      "kind": "reopen-thread",
      "threadID": "thread-b",
    ], to: directory.appendingPathComponent("4.json"))
    try writeJSON([
      "schema": AIChatOperationJournal.schema,
      "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "createdAt": "2026-08-20T10:00:00.000Z",
      "kind": "settle-thread",
      "threadID": "thread-a",
      "settledAt": "2026-08-20T10:01:00.000Z",
    ], to: directory.appendingPathComponent("3.json"))
    try writeJSON([
      "schema": AIChatOperationJournal.schema,
      "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      "createdAt": "2026-08-20T09:00:00Z",
      "kind": "configure-auto-settle",
      "autoSettleAfterSeconds": 3600,
    ], to: directory.appendingPathComponent("2.json"))
    try writeJSON([
      "schema": AIChatOperationJournal.schema,
      "id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      "createdAt": "2026-08-20T11:00:00.000Z",
      "kind": "auto-settle",
      "evaluatedAt": "2026-08-20T11:00:00.000Z",
    ], to: directory.appendingPathComponent("1.json"))

    let scan = try await AIChatOperationJournal.load(corpusRoot: root)

    XCTAssertTrue(scan.issues.isEmpty)
    XCTAssertEqual(scan.entries.map(\.id), [
      "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    ])
    guard case .configureAutoSettle(let seconds) = scan.entries[0].operation else {
      return XCTFail("Expected configure-auto-settle")
    }
    XCTAssertEqual(seconds, 3600)
    guard case .settleThread(let threadID, _) = scan.entries[1].operation else {
      return XCTFail("Expected settle-thread")
    }
    XCTAssertEqual(threadID, "thread-a")
    guard case .reopenThread(let reopenedID) = scan.entries[2].operation else {
      return XCTFail("Expected reopen-thread")
    }
    XCTAssertEqual(reopenedID, "thread-b")
    guard case .autoSettle = scan.entries[3].operation else {
      return XCTFail("Expected auto-settle")
    }
  }

  func testReportsAndRetainsInvalidUnsafeAndOversizedJSONFiles() async throws {
    let root = temporaryCorpus("invalid")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try makeOperationsDirectory(root)
    let invalidUUID = directory.appendingPathComponent("invalid-uuid.json")
    try writeJSON([
      "schema": AIChatOperationJournal.schema,
      "id": "not-a-uuid",
      "createdAt": "2026-08-20T10:00:00.000Z",
      "kind": "reopen-thread",
      "threadID": "thread-a",
    ], to: invalidUUID)
    let invalidDate = directory.appendingPathComponent("invalid-date.json")
    try writeJSON([
      "schema": AIChatOperationJournal.schema,
      "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "createdAt": "not-a-date",
      "kind": "auto-settle",
      "evaluatedAt": "also-not-a-date",
    ], to: invalidDate)
    let invalidValue = directory.appendingPathComponent("invalid-value.json")
    try writeJSON([
      "schema": AIChatOperationJournal.schema,
      "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "createdAt": "2026-08-20T10:00:00.000Z",
      "kind": "configure-auto-settle",
      "autoSettleAfterSeconds": 0,
    ], to: invalidValue)
    let oversized = directory.appendingPathComponent("oversized.json")
    try Data(repeating: 65, count: AIChatOperationJournal.maximumEnvelopeBytes + 1)
      .write(to: oversized)
    let symlink = directory.appendingPathComponent("symlink.json")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: invalidUUID)
    let disguisedDirectory = directory.appendingPathComponent("directory.json", isDirectory: true)
    try FileManager.default.createDirectory(at: disguisedDirectory, withIntermediateDirectories: false)

    let scan = try await AIChatOperationJournal.load(corpusRoot: root)

    XCTAssertTrue(scan.entries.isEmpty)
    XCTAssertEqual(scan.issues.map { $0.fileURL.lastPathComponent }, [
      "directory.json",
      "invalid-date.json",
      "invalid-uuid.json",
      "invalid-value.json",
      "oversized.json",
      "symlink.json",
    ])
    for file in [invalidUUID, invalidDate, invalidValue, oversized, symlink, disguisedDirectory] {
      XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
  }

  func testRejectsSymbolicLinkOperationDirectory() async throws {
    let root = temporaryCorpus("directory-symlink")
    let destination = temporaryCorpus("directory-symlink-destination")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: destination)
    }
    let parent = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("ai-chat-inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: parent.appendingPathComponent("operations"),
      withDestinationURL: destination
    )

    do {
      _ = try await AIChatOperationJournal.load(corpusRoot: root)
      XCTFail("Expected unsafe directory rejection")
    } catch let error as AIChatOperationJournalError {
      guard case .unsafeOperationsDirectory = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testCommittedRemovalRefusesAChangedFileThenRemovesAReloadedExactFile() async throws {
    let root = temporaryCorpus("remove")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try makeOperationsDirectory(root)
    let file = directory.appendingPathComponent("operation.json")
    let first: [String: Any] = [
      "schema": AIChatOperationJournal.schema,
      "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "createdAt": "2026-08-20T10:00:00.000Z",
      "kind": "reopen-thread",
      "threadID": "thread-a",
    ]
    try writeJSON(first, to: file)
    let originalScan = try await AIChatOperationJournal.load(corpusRoot: root)
    let original = try XCTUnwrap(originalScan.entries.first)

    try FileManager.default.removeItem(at: file)
    var replacement = first
    replacement["threadID"] = "thread-b"
    try writeJSON(replacement, to: file)

    do {
      try await AIChatOperationJournal.removeCommitted(original)
      XCTFail("Expected replacement protection")
    } catch let error as AIChatOperationJournalError {
      guard case .operationFileChanged = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

    let reloadedScan = try await AIChatOperationJournal.load(corpusRoot: root)
    let reloaded = try XCTUnwrap(reloadedScan.entries.first)
    try await AIChatOperationJournal.removeCommitted(reloaded)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testMissingDirectoryIsAnEmptyJournal() async throws {
    let root = temporaryCorpus("missing")
    defer { try? FileManager.default.removeItem(at: root) }

    let scan = try await AIChatOperationJournal.load(corpusRoot: root)

    XCTAssertTrue(scan.entries.isEmpty)
    XCTAssertTrue(scan.issues.isEmpty)
  }

  private func temporaryCorpus(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-operation-\(label)-\(UUID().uuidString)", isDirectory: true)
  }

  @discardableResult
  private func makeOperationsDirectory(_ root: URL) throws -> URL {
    let directory = AIChatOperationJournal.operationsDirectory(corpusRoot: root)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func writeJSON(_ object: Any, to file: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    try data.write(to: file)
  }
}
