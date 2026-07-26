import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class Org2CoordinatedFileMutationTests: XCTestCase {
  private let liveToken = "00000000-0000-4000-8000-000000000001"
  private let replacementToken = "00000000-0000-4000-8000-000000000002"

  func testRefusesMutationWhileLiveOrg2OwnerHoldsSharedLock() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let participant = try writeParticipant(
      for: file,
      host: ProcessInfo.processInfo.hostName,
      pid: ProcessInfo.processInfo.processIdentifier,
      token: liveToken,
      phase: .ticket,
      ticket: 1
    )
    let participantData = try Data(contentsOf: participant)

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.writeTextAtomicallyIfUnchanged(
        "* DONE Review exact draft\n",
        to: file,
        expectedText: original
      )
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("already updating"))
    }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    XCTAssertEqual(try Data(contentsOf: participant), participantData)
    XCTAssertEqual(try participantFilenames(for: file), [participant.lastPathComponent])
  }

  func testRejectsStaleReviewedTextAfterLockIsAcquired() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("review.org2")
    let reviewed = "* TODO Review exact draft\nOriginal body\n"
    let changed = "* TODO Review exact draft\nChanged body\n"
    try changed.write(to: file, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.writeTextAtomicallyIfUnchanged(
        "* DONE Review exact draft\nOriginal body\n",
        to: file,
        expectedText: reviewed
      )
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("changed since it was reviewed"))
    }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), changed)
    XCTAssertTrue(isLockDirectory(for: file))
    XCTAssertEqual(try participantFilenames(for: file), [])
  }

  func testReclaimsOnlyVerifiedDeadLocalParticipantBeforeMutation() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let deadParticipant = try writeParticipant(
      for: file,
      host: ProcessInfo.processInfo.hostName,
      pid: Int32.max,
      token: liveToken,
      phase: .ticket,
      ticket: 1
    )

    try Org2CoordinatedFileMutation.writeTextAtomicallyIfUnchanged(
      "* DONE Review exact draft\n",
      to: file,
      expectedText: original
    )

    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "* DONE Review exact draft\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: deadParticipant.path))
    XCTAssertTrue(isLockDirectory(for: file))
    XCTAssertEqual(try participantFilenames(for: file), [])
  }

  func testDeadCleanupCannotDisplaceIndependentLiveParticipant() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let dead = try writeParticipant(
      for: file,
      host: ProcessInfo.processInfo.hostName,
      pid: Int32.max,
      token: liveToken,
      phase: .ticket,
      ticket: 1
    )
    let live = try writeParticipant(
      for: file,
      host: ProcessInfo.processInfo.hostName,
      pid: ProcessInfo.processInfo.processIdentifier,
      token: replacementToken,
      phase: .ticket,
      ticket: 2
    )
    let liveData = try Data(contentsOf: live)

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.writeTextAtomicallyIfUnchanged(
        "* DONE Review exact draft\n",
        to: file,
        expectedText: original
      )
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
    XCTAssertEqual(try Data(contentsOf: live), liveData)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    XCTAssertEqual(try participantFilenames(for: file), [live.lastPathComponent])
  }

  func testForeignHostParticipantFailsClosedEvenWhenPIDIsDeadLocally() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let foreign = try writeParticipant(
      for: file,
      host: "other-host.example",
      pid: Int32.max,
      token: liveToken,
      phase: .ticket,
      ticket: 1
    )
    let foreignData = try Data(contentsOf: foreign)

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.writeTextAtomicallyIfUnchanged(
        "* DONE Review exact draft\n",
        to: file,
        expectedText: original
      )
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("already updating"))
    }

    XCTAssertEqual(try Data(contentsOf: foreign), foreignData)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
  }

  func testLegacyFixedLockFileFailsClosedWithoutAutomaticReplacement() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let lock = Org2CoordinatedFileMutation.mutationLockURL(for: file)
    let legacy = Data("999999\n".utf8)
    try legacy.write(to: lock)

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.writeTextAtomicallyIfUnchanged(
        "* DONE Review exact draft\n",
        to: file,
        expectedText: original
      )
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("legacy or unsupported"))
    }

    XCTAssertEqual(try Data(contentsOf: lock), legacy)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
  }

  func testPublishesCompleteTicketMetadataBeforeEnteringMutation() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("review.org2")
    try "* TODO Review exact draft\n".write(to: file, atomically: true, encoding: .utf8)
    let lock = Org2CoordinatedFileMutation.mutationLockURL(for: file)

    try Org2CoordinatedFileMutation.mutateTextAtomically(at: file) { current in
      let names = try participantFilenames(for: file)
      XCTAssertEqual(names.count, 1)
      let name = try XCTUnwrap(names.first)
      XCTAssertTrue(name.hasPrefix("ticket."))
      let data = try Data(contentsOf: lock.appendingPathComponent(name))
      let owner = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(owner["schema"] as? String, Org2CoordinatedFileMutation.lockOwnerSchema)
      XCTAssertEqual(owner["host"] as? String, ProcessInfo.processInfo.hostName)
      XCTAssertEqual((owner["pid"] as? NSNumber)?.int32Value, ProcessInfo.processInfo.processIdentifier)
      XCTAssertEqual(owner["phase"] as? String, "ticket")
      XCTAssertNotNil(owner["ticket"])
      XCTAssertFalse((owner["token"] as? String)?.isEmpty ?? true)
      XCTAssertFalse((owner["createdAt"] as? String)?.isEmpty ?? true)
      XCTAssertFalse(
        try FileManager.default.contentsOfDirectory(atPath: lock.path)
          .contains(where: { $0.hasPrefix(".candidate.") })
      )
      return (current, ())
    }

    XCTAssertTrue(isLockDirectory(for: file))
    XCTAssertEqual(try participantFilenames(for: file), [])
  }

  func testDetectsCompetingWriterBeforeReplacement() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    let competing = "* TODO Review exact draft\nCompeting edit\n"
    try original.write(to: file, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.mutateTextAtomically(at: file) { current in
        XCTAssertEqual(current, original)
        try competing.write(to: file, atomically: true, encoding: .utf8)
        return ("* DONE Review exact draft\n", ())
      }
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("competing writer"))
    }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), competing)
    XCTAssertTrue(isLockDirectory(for: file))
    XCTAssertEqual(try participantFilenames(for: file), [])
  }

  func testCleanupDoesNotRemoveReplacementTicketOwner() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("review.org2")
    try "* TODO Review exact draft\n".write(to: file, atomically: true, encoding: .utf8)
    var replacementURL: URL?
    var replacementData: Data?

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.mutateTextAtomically(at: file) { current in
        let lock = Org2CoordinatedFileMutation.mutationLockURL(for: file)
        let name = try XCTUnwrap(try participantFilenames(for: file).first)
        let url = lock.appendingPathComponent(name)
        let replacement = try Org2CoordinatedFileMutation.lockOwnerData(
          host: ProcessInfo.processInfo.hostName,
          pid: ProcessInfo.processInfo.processIdentifier,
          token: replacementToken,
          phase: .ticket,
          ticket: 1,
          createdAt: "2026-07-25T00:00:01Z"
        )
        try replacement.write(to: url, options: .atomic)
        replacementURL = url
        replacementData = replacement
        return (current, ())
      }
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("ticket changed"))
    }

    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replacementURL)), replacementData)
  }

  func testMaximumSafeTicketFailsClosedWithoutPublishingAnotherTicket() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let maximum = try writeParticipant(
      for: file,
      host: "other-host.example",
      pid: 42,
      token: liveToken,
      phase: .ticket,
      ticket: Org2CoordinatedFileMutation.maximumSafeTicket
    )

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.writeTextAtomicallyIfUnchanged(
        "* DONE Review exact draft\n",
        to: file,
        expectedText: original
      )
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("maximum safe value"))
    }

    XCTAssertEqual(try participantFilenames(for: file), [maximum.lastPathComponent])
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
  }

  func testParticipantInteropFixtureUsesCanonicalJSONAndFilenames() throws {
    let token = "12345678-1234-4abc-8def-1234567890ab"
    XCTAssertEqual(
      Org2CoordinatedFileMutation.choosingFilename(token: token),
      "choosing.12345678-1234-4abc-8def-1234567890ab.json"
    )
    XCTAssertEqual(
      Org2CoordinatedFileMutation.ticketFilename(ticket: 7, token: token),
      "ticket.0000000000000007.12345678-1234-4abc-8def-1234567890ab.json"
    )
    let owner = try Org2CoordinatedFileMutation.lockOwnerData(
      host: "press.local",
      pid: 42,
      token: token,
      phase: .ticket,
      ticket: 7,
      createdAt: "2026-07-25T00:00:00Z"
    )
    XCTAssertEqual(
      String(decoding: owner, as: UTF8.self),
      #"{"createdAt":"2026-07-25T00:00:00Z","host":"press.local","phase":"ticket","pid":42,"schema":"org2:mutation-lock-owner:v2","ticket":7,"token":"12345678-1234-4abc-8def-1234567890ab"}"# + "\n"
    )
  }

  func testBooleanPIDAndTicketMetadataFailClosed() throws {
    for malformedField in ["pid", "ticket"] {
      let directory = try makeTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let file = directory.appendingPathComponent("review.org2")
      let original = "* TODO Review exact draft\n"
      try original.write(to: file, atomically: true, encoding: .utf8)
      let lock = Org2CoordinatedFileMutation.mutationLockURL(for: file)
      try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
      var owner: [String: Any] = [
        "schema": Org2CoordinatedFileMutation.lockOwnerSchema,
        "host": ProcessInfo.processInfo.hostName,
        "pid": Int32.max,
        "token": liveToken,
        "phase": "ticket",
        "ticket": 1,
        "createdAt": "2026-07-25T00:00:00Z",
      ]
      owner[malformedField] = true
      let data = try JSONSerialization.data(withJSONObject: owner, options: [.sortedKeys])
        + Data("\n".utf8)
      let participant = lock.appendingPathComponent(
        Org2CoordinatedFileMutation.ticketFilename(ticket: 1, token: liveToken)
      )
      try data.write(to: participant)

      XCTAssertThrowsError(
        try Org2CoordinatedFileMutation.writeTextAtomicallyIfUnchanged(
          "* DONE Review exact draft\n",
          to: file,
          expectedText: original
        )
      ) { error in
        XCTAssertTrue(error.localizedDescription.contains("Malformed"))
      }
      XCTAssertEqual(try Data(contentsOf: participant), data)
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    }
  }

  func testFractionalPIDMetadataFailsClosed() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let lock = Org2CoordinatedFileMutation.mutationLockURL(for: file)
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
    let owner: [String: Any] = [
      "schema": Org2CoordinatedFileMutation.lockOwnerSchema,
      "host": ProcessInfo.processInfo.hostName,
      "pid": 99_999_999.5,
      "token": liveToken,
      "phase": "ticket",
      "ticket": 1,
      "createdAt": "2026-07-25T00:00:00Z",
    ]
    let data = try JSONSerialization.data(withJSONObject: owner, options: [.sortedKeys])
      + Data("\n".utf8)
    let participant = lock.appendingPathComponent(
      Org2CoordinatedFileMutation.ticketFilename(ticket: 1, token: liveToken)
    )
    try data.write(to: participant)

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.writeTextAtomicallyIfUnchanged(
        "* DONE Review exact draft\n",
        to: file,
        expectedText: original
      )
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("Malformed"))
    }
    XCTAssertEqual(try Data(contentsOf: participant), data)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
  }

  func testLiveTicketPreventsMissingFileCreation() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("new.org2")
    _ = try writeParticipant(
      for: file,
      host: ProcessInfo.processInfo.hostName,
      pid: ProcessInfo.processInfo.processIdentifier,
      token: liveToken,
      phase: .ticket,
      ticket: 1
    )

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.mutateTextAtomically(
        at: file,
        createIfMissing: true
      ) { _, _ in
        ("#+TITLE: New\n\n* TODO Captured entry\n", ())
      }
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testCreateIfMissingPreservesCompetingCompleteFile() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("new.org2")
    let competing = "#+TITLE: Competing\n\n* TODO Complete competing entry\n"

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.mutateTextAtomically(
        at: file,
        createIfMissing: true
      ) { current, existed in
        XCTAssertFalse(existed)
        XCTAssertEqual(current, "")
        try competing.write(to: file, atomically: true, encoding: .utf8)
        return ("#+TITLE: New\n\n* TODO Captured entry\n", ())
      }
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("competing writer"))
    }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), competing)
    XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).isEmpty)
    XCTAssertEqual(try participantFilenames(for: file), [])
  }

  private func writeParticipant(
    for file: URL,
    host: String,
    pid: pid_t,
    token: String,
    phase: Org2CoordinatedFileMutation.LockPhase,
    ticket: UInt64?
  ) throws -> URL {
    let lock = Org2CoordinatedFileMutation.mutationLockURL(for: file)
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
    let data = try Org2CoordinatedFileMutation.lockOwnerData(
      host: host,
      pid: pid,
      token: token,
      phase: phase,
      ticket: ticket,
      createdAt: "2026-07-25T00:00:00Z"
    )
    let name: String
    switch phase {
    case .choosing:
      name = Org2CoordinatedFileMutation.choosingFilename(token: token)
    case .ticket:
      name = Org2CoordinatedFileMutation.ticketFilename(ticket: try XCTUnwrap(ticket), token: token)
    }
    let url = lock.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  private func participantFilenames(for file: URL) throws -> [String] {
    let lock = Org2CoordinatedFileMutation.mutationLockURL(for: file)
    guard FileManager.default.fileExists(atPath: lock.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: lock.path)
      .filter { !$0.hasPrefix(".candidate.") }
      .sorted()
  }

  private func isLockDirectory(for file: URL) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: Org2CoordinatedFileMutation.mutationLockURL(for: file).path,
      isDirectory: &isDirectory
    )
    return exists && isDirectory.boolValue
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mutation-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
