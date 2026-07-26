import XCTest
@testable import Org2Mobile

final class ApprovalSemanticsTests: XCTestCase {
  func testLegacyFingerprintMatchesCoreGoldenVector() {
    let input = LegacyHeadlineApprovalFingerprintInput(
      title: "Review outreach copy",
      body: "Send this once approved.",
      properties: ["STATUS": "draft-needs-review", "ID": "approval-1"],
      status: "draft-needs-review",
      todo: "TODO",
      pairedAction: nil
    )

    XCTAssertEqual(
      ApprovalSemantics.fingerprint(for: input),
      "sha256:fffe8c41264f251fcb42bf29a213be53ff0c3012267f8ca6868c948af2dc94a2"
    )
  }

  func testPairedActionFingerprintMatchesCoreGoldenVector() {
    let input = LegacyHeadlineApprovalFingerprintInput(
      title: "Approve release",
      body: "Ship exact bytes.",
      properties: [
        "STATUS": "review-required",
        "PAIRED_SEND_TODO": "Send approved release",
      ],
      status: "review-required",
      todo: "TODO",
      pairedAction: LegacyPairedApprovalAction(
        mode: .existing,
        title: "Send approved release",
        todo: "TODO",
        properties: ["STATUS": "ready-for-agent"],
        body: "Exact command.",
        line: 2
      )
    )

    XCTAssertEqual(
      ApprovalSemantics.fingerprint(for: input),
      "sha256:c297d09e829a6b34234be6444e2062ad805657c2d23461db68b204fdcfcfe44e"
    )
  }

  func testPropertyOrderDoesNotChangeFingerprint() {
    let first = LegacyHeadlineApprovalFingerprintInput(
      title: "Review deployment",
      body: "Exact body",
      properties: ["ZETA": "last", "ALPHA": "first"],
      status: "review-required",
      todo: "TODO",
      pairedAction: nil
    )
    let second = LegacyHeadlineApprovalFingerprintInput(
      title: first.title,
      body: first.body,
      properties: ["ALPHA": "first", "ZETA": "last"],
      status: first.status,
      todo: first.todo,
      pairedAction: nil
    )

    XCTAssertEqual(
      ApprovalSemantics.fingerprint(for: first),
      ApprovalSemantics.fingerprint(for: second)
    )
  }

  func testCRLFAndLFProduceTheSameReviewedFingerprint() throws {
    let lf = """
    * TODO Review release
    :PROPERTIES:
    :STATUS: review-required
    :END:
    Exact release notes.
    """
    let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")

    XCTAssertEqual(
      try XCTUnwrap(ApprovalSemantics.snapshots(in: lf).first).fingerprint,
      try XCTUnwrap(ApprovalSemantics.snapshots(in: crlf).first).fingerprint
    )
  }

  func testNestedApprovalSubtreeMatchesCoreGoldenFingerprint() throws {
    let raw = """
    * TODO Review parent release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: parent-review
    :STATUS: review-required
    :END:
    Parent exact bytes.
    ** TODO Nested execution
    :PROPERTIES:
    :STATUS: ready-for-agent
    :END:
    Nested exact bytes.
    """

    let snapshot = try XCTUnwrap(ApprovalSemantics.snapshots(in: raw).first)
    XCTAssertEqual(
      snapshot.body,
      """
      Parent exact bytes.
      ** TODO Nested execution
      :PROPERTIES:
      :STATUS: ready-for-agent
      :END:
      Nested exact bytes.
      """
    )
    XCTAssertEqual(
      snapshot.fingerprint,
      "sha256:b3b16ff398e66680d5bbaae82ac6a2cc1befefb86e7640359b158ee9a554e0ca"
    )
  }

  func testNestedApprovalChildChangeIsRejectedAsStale() throws {
    let original = """
    * TODO Review parent release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: parent-review
    :STATUS: review-required
    :END:
    Parent exact bytes.
    ** TODO Nested execution
    :PROPERTIES:
    :STATUS: ready-for-agent
    :END:
    Nested exact bytes.
    """
    let snapshot = try XCTUnwrap(ApprovalSemantics.snapshots(in: original).first)
    let changed = original.replacingOccurrences(
      of: "Nested exact bytes.",
      with: "Changed nested bytes."
    )

    XCTAssertThrowsError(
      try ApprovalSemantics.resolve(
        in: changed,
        reference: LegacyHeadlineApprovalReference(
          approvalID: snapshot.approvalID,
          sourceID: snapshot.sourceID,
          line: snapshot.headingIndex + 1,
          fingerprint: snapshot.fingerprint
        )
      )
    ) { error in
      XCTAssertEqual(error as? LegacyHeadlineApprovalResolutionError, .stale)
    }
  }

  func testStableIdentityPrefersApprovalIDThenSourceID() {
    XCTAssertEqual(
      ApprovalSemantics.rowIdentity(
        file: "queue.org",
        line: 9,
        approvalID: "approval-9",
        sourceID: "source-9"
      ),
      "approval:approval-9"
    )
    XCTAssertEqual(
      ApprovalSemantics.rowIdentity(
        file: "queue.org",
        line: 9,
        approvalID: nil,
        sourceID: "source-9"
      ),
      "source:source-9"
    )
    XCTAssertEqual(
      ApprovalSemantics.rowIdentity(
        file: "queue.org",
        line: 9,
        approvalID: nil,
        sourceID: nil
      ),
      "provisional:queue.org:9"
    )
  }

  func testStableApprovalIDSurvivesLineMovement() throws {
    let original = """
    * TODO Review release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: release-review
    :STATUS: review-required
    :END:
    Exact release notes.
    """
    let snapshot = try XCTUnwrap(ApprovalSemantics.snapshots(in: original).first)
    let moved = "# Preamble\n\n" + original
    let resolved = try ApprovalSemantics.resolve(
      in: moved,
      reference: LegacyHeadlineApprovalReference(
        approvalID: snapshot.approvalID,
        sourceID: snapshot.sourceID,
        line: snapshot.headingIndex + 1,
        fingerprint: snapshot.fingerprint
      )
    )

    XCTAssertEqual(resolved.approvalID, "release-review")
    XCTAssertEqual(resolved.headingIndex, snapshot.headingIndex + 2)
  }

  func testChangedReviewedBodyIsRejectedAsStale() throws {
    let original = """
    * TODO Review release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: release-review
    :STATUS: review-required
    :END:
    Exact release notes.
    """
    let snapshot = try XCTUnwrap(ApprovalSemantics.snapshots(in: original).first)
    let changed = original.replacingOccurrences(of: "Exact release notes.", with: "Changed release notes.")

    XCTAssertThrowsError(
      try ApprovalSemantics.resolve(
        in: changed,
        reference: LegacyHeadlineApprovalReference(
          approvalID: snapshot.approvalID,
          sourceID: snapshot.sourceID,
          line: snapshot.headingIndex + 1,
          fingerprint: snapshot.fingerprint
        )
      )
    ) { error in
      XCTAssertEqual(error as? LegacyHeadlineApprovalResolutionError, .stale)
    }
  }

  func testIdentitylessDuplicateFingerprintIsAmbiguous() throws {
    let headline = """
    * TODO Review release
    :PROPERTIES:
    :STATUS: review-required
    :END:
    Exact release notes.
    """
    let raw = headline + "\n" + headline
    let snapshot = try XCTUnwrap(ApprovalSemantics.snapshots(in: raw).first)

    XCTAssertThrowsError(
      try ApprovalSemantics.resolve(
        in: raw,
        reference: LegacyHeadlineApprovalReference(
          approvalID: nil,
          sourceID: nil,
          line: snapshot.headingIndex + 1,
          fingerprint: snapshot.fingerprint
        )
      )
    ) { error in
      XCTAssertEqual(error as? LegacyHeadlineApprovalResolutionError, .ambiguous)
    }
  }

  func testAmbiguousPairedActionCannotBeApproved() throws {
    let raw = """
    * TODO Send approved release
    :PROPERTIES:
    :STATUS: ready-for-agent
    :END:

    * TODO Send approved release
    :PROPERTIES:
    :STATUS: ready-for-agent
    :END:

    * TODO Approve release
    :PROPERTIES:
    :PAIRED_SEND_TODO: Send approved release
    :STATUS: review-required
    :END:
    Exact release notes.
    """

    let snapshot = try XCTUnwrap(ApprovalSemantics.snapshots(in: raw).first)
    XCTAssertFalse(snapshot.canApprove)
    XCTAssertNotNil(snapshot.approvalBlockedReason)
  }

  func testConflictingPairedPointersBlockApprovalButNotSafeRejectionResolution() throws {
    let raw = """
    * TODO Approve release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: release-review
    :PAIRED_SEND_TODO: Send approved release
    :PAIRED_AGENT_TODO: Continue approved release
    :STATUS: review-required
    :END:
    Exact release notes.
    """

    let snapshot = try XCTUnwrap(ApprovalSemantics.snapshots(in: raw).first)
    let reference = LegacyHeadlineApprovalReference(
      approvalID: snapshot.approvalID,
      sourceID: snapshot.sourceID,
      line: snapshot.headingIndex + 1,
      fingerprint: snapshot.fingerprint
    )

    XCTAssertFalse(snapshot.canApprove)
    XCTAssertThrowsError(try ApprovalSemantics.resolve(in: raw, reference: reference)) { error in
      guard case .blocked = error as? LegacyHeadlineApprovalResolutionError else {
        return XCTFail("Expected approval to be blocked, got \(error)")
      }
    }
    XCTAssertEqual(
      try ApprovalSemantics.resolve(in: raw, reference: reference, requireApprovable: false).fingerprint,
      snapshot.fingerprint
    )
  }

  func testDuplicatePropertiesBlockApprovalButNotSafeRejectionResolution() throws {
    let raw = """
    * TODO Review release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: release-review
    :STATUS: review-required
    :STATUS: review-required
    :END:
    Exact release notes.
    """

    let snapshot = try XCTUnwrap(ApprovalSemantics.snapshots(in: raw).first)
    let reference = LegacyHeadlineApprovalReference(
      approvalID: snapshot.approvalID,
      sourceID: snapshot.sourceID,
      line: snapshot.headingIndex + 1,
      fingerprint: snapshot.fingerprint
    )

    XCTAssertFalse(snapshot.canApprove)
    XCTAssertThrowsError(try ApprovalSemantics.resolve(in: raw, reference: reference)) { error in
      guard case .blocked = error as? LegacyHeadlineApprovalResolutionError else {
        return XCTFail("Expected approval to be blocked, got \(error)")
      }
    }
    XCTAssertNoThrow(
      try ApprovalSemantics.resolve(in: raw, reference: reference, requireApprovable: false)
    )
  }

  func testDuplicateApprovalIdentityBlocksRejectionResolution() throws {
    let raw = """
    * TODO Review first release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: duplicate-review
    :STATUS: review-required
    :END:
    First exact release notes.

    * TODO Review second release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: duplicate-review
    :STATUS: review-required
    :END:
    Second exact release notes.
    """

    let snapshots = ApprovalSemantics.snapshots(in: raw)
    XCTAssertEqual(snapshots.count, 2)
    XCTAssertTrue(snapshots.allSatisfy { !$0.canApprove })
    let first = try XCTUnwrap(snapshots.first)

    XCTAssertThrowsError(
      try ApprovalSemantics.resolve(
        in: raw,
        reference: LegacyHeadlineApprovalReference(
          approvalID: first.approvalID,
          sourceID: first.sourceID,
          line: first.headingIndex + 1,
          fingerprint: first.fingerprint
        ),
        requireApprovable: false
      )
    ) { error in
      XCTAssertEqual(error as? LegacyHeadlineApprovalResolutionError, .ambiguous)
    }
  }

  func testTerminalOrSentPairedActionBlocksApprovalButNotSafeRejectionResolution() throws {
    let raw = """
    * DONE Send approved release
    :PROPERTIES:
    :SENT_AT: [2026-07-25 Sat 09:00]
    :STATUS: sent
    :END:
    Already sent.

    * TODO Approve release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: release-review
    :PAIRED_SEND_TODO: Send approved release
    :STATUS: review-required
    :END:
    Exact release notes.
    """

    let snapshot = try XCTUnwrap(ApprovalSemantics.snapshots(in: raw).first)
    let reference = LegacyHeadlineApprovalReference(
      approvalID: snapshot.approvalID,
      sourceID: snapshot.sourceID,
      line: snapshot.headingIndex + 1,
      fingerprint: snapshot.fingerprint
    )

    XCTAssertFalse(snapshot.canApprove)
    XCTAssertEqual(snapshot.pairedAction?.todo, "DONE")
    XCTAssertThrowsError(try ApprovalSemantics.resolve(in: raw, reference: reference)) { error in
      guard case .blocked = error as? LegacyHeadlineApprovalResolutionError else {
        return XCTFail("Expected approval to be blocked, got \(error)")
      }
    }
    XCTAssertNoThrow(
      try ApprovalSemantics.resolve(in: raw, reference: reference, requireApprovable: false)
    )
  }

  @MainActor
  func testPropertyUpsertUpdatesEveryDuplicateOccurrence() {
    let store = CorpusStore()
    var lines = [
      "* TODO Review release",
      ":PROPERTIES:",
      ":STATUS: review-required",
      ":STATUS: draft-needs-review",
      ":WAITING_ON: Avi approval",
      ":WAITING_ON: Human review",
      ":END:",
    ]

    store.upsertProperties(
      ["STATUS": "rejected", "WAITING_ON": "resolved"],
      in: &lines,
      headingIndex: 0
    )

    XCTAssertEqual(lines.filter { $0 == ":STATUS: rejected" }.count, 2)
    XCTAssertEqual(lines.filter { $0 == ":WAITING_ON: resolved" }.count, 2)
  }

  @MainActor
  func testBlockedDuplicatePropertiesCanBeRejectedAndAllCopiesAreTerminalized() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-approval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("queue.org2")
    let raw = """
    * TODO Review release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: release-review
    :STATUS: review-required
    :STATUS: review-required
    :WAITING_ON: Avi approval
    :WAITING_ON: Human review
    :END:
    Exact release notes.
    """
    try raw.write(to: file, atomically: true, encoding: .utf8)

    let store = CorpusStore()
    await store.selectCorpus(root)
    store.prepareCorpusViews()
    await store.refresh()
    let approval = try XCTUnwrap(store.approvals.first)
    XCTAssertFalse(approval.canApprove)

    await store.reject(approval, endStatus: .canceled, reason: "Not approved")

    let updated = try String(contentsOf: file, encoding: .utf8)
    XCTAssertEqual(updated.components(separatedBy: ":STATUS: rejected").count - 1, 2)
    XCTAssertEqual(updated.components(separatedBy: ":WAITING_ON: resolved").count - 1, 2)
    XCTAssertTrue(updated.contains(":ORG2_APPROVAL_DECISION: rejected"))
    XCTAssertNil(store.errorMessage)
  }

  @MainActor
  func testRejectingBlockedTerminalPairLeavesPairedActionUnchanged() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-terminal-pair-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("queue.org2")
    let pairedHeading = """
    * DONE Send approved release
    :PROPERTIES:
    :SENT_AT: [2026-07-25 Sat 09:00]
    :STATUS: sent
    :END:
    Already sent.
    """
    let raw = """
    \(pairedHeading)

    * TODO Approve release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: release-review
    :PAIRED_SEND_TODO: Send approved release
    :STATUS: review-required
    :END:
    Exact release notes.
    """
    try raw.write(to: file, atomically: true, encoding: .utf8)

    let store = CorpusStore()
    await store.selectCorpus(root)
    store.prepareCorpusViews()
    await store.refresh()
    let approval = try XCTUnwrap(store.approvals.first)
    XCTAssertFalse(approval.canApprove)

    await store.reject(approval, endStatus: .canceled, reason: "Do not send")

    let updated = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(updated.hasPrefix(pairedHeading))
    XCTAssertTrue(updated.contains("* CANCELED Approve release"))
    XCTAssertTrue(updated.contains(":ORG2_APPROVAL_DECISION: rejected"))
    XCTAssertNil(store.errorMessage)
  }

  @MainActor
  func testAgendaShortcutCannotTerminalizePendingApproval() async throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-agenda-approval")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("queue.org2")
    let raw = """
    * TODO Review scheduled release
    SCHEDULED: <2026-07-25 Sat>
    :PROPERTIES:
    :ORG2_APPROVAL_ID: scheduled-review
    :STATUS: review-required
    :END:
    Exact release notes.
    """
    try raw.write(to: file, atomically: true, encoding: .utf8)

    let store = CorpusStore()
    await store.selectCorpus(root)
    store.prepareCorpusViews()
    await store.refresh()
    let agendaEntry = try XCTUnwrap(store.agenda.first)
    XCTAssertEqual(store.approvals.count, 1)

    await store.setTodoStatus(.done, for: agendaEntry)

    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), raw)
    XCTAssertTrue(store.errorMessage?.contains("Corpus Approvals") == true)
    XCTAssertTrue(isLockDirectory(for: file))
    XCTAssertEqual(try participantFilenames(for: file), [])
  }

  func testSharedMutationLockRefusesLiveOwner() throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-live-lock")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let participant = try writeLockParticipant(
      for: file,
      host: ProcessInfo.processInfo.hostName,
      pid: ProcessInfo.processInfo.processIdentifier,
      token: "00000000-0000-4000-8000-000000000001",
      phase: .ticket,
      ticket: 1
    )
    let participantData = try Data(contentsOf: participant)

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.mutateTextAtomically(at: file) { _ in
        ("* DONE Review exact draft\n", ())
      }
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("already updating"))
    }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    XCTAssertEqual(try Data(contentsOf: participant), participantData)
  }

  func testSharedMutationLockReclaimsVerifiedDeadOwner() throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-dead-lock")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    let updated = "* DONE Review exact draft\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let participant = try writeLockParticipant(
      for: file,
      host: ProcessInfo.processInfo.hostName,
      pid: Int32.max,
      token: "00000000-0000-4000-8000-000000000001",
      phase: .ticket,
      ticket: 1
    )

    try Org2CoordinatedFileMutation.mutateTextAtomically(at: file) { current in
      XCTAssertEqual(current, original)
      return (updated, ())
    }

    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), updated)
    XCTAssertFalse(FileManager.default.fileExists(atPath: participant.path))
    XCTAssertTrue(isLockDirectory(for: file))
    XCTAssertEqual(try participantFilenames(for: file), [])
  }

  func testSharedMutationLockRejectsStaleReviewedText() throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-stale-review")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("review.org2")
    let reviewed = "* TODO Review exact draft\nOriginal body\n"
    let changed = "* TODO Review exact draft\nChanged body\n"
    try changed.write(to: file, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.mutateTextAtomically(
        at: file,
        expectedText: reviewed
      ) { _ in
        ("* DONE Review exact draft\nOriginal body\n", ())
      }
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("changed since it was reviewed"))
    }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), changed)
  }

  func testSharedMutationLockDetectsCompetingWriterBeforeReplacement() throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-competing-writer")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("review.org2")
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

  @MainActor
  func testApprovalDecisionHonorsLiveSharedMutationLock() async throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-approval-lock")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("queue.org2")
    let raw = """
    * TODO Review release
    :PROPERTIES:
    :ORG2_APPROVAL_ID: release-review
    :STATUS: review-required
    :END:
    Exact release notes.
    """
    try raw.write(to: file, atomically: true, encoding: .utf8)

    let store = CorpusStore()
    await store.selectCorpus(root)
    store.prepareCorpusViews()
    await store.refresh()
    let approval = try XCTUnwrap(store.approvals.first)
    _ = try writeLockParticipant(
      for: file,
      host: ProcessInfo.processInfo.hostName,
      pid: ProcessInfo.processInfo.processIdentifier,
      token: "00000000-0000-4000-8000-000000000001",
      phase: .ticket,
      ticket: 1
    )

    await store.reject(approval, endStatus: .canceled, reason: "Do not send")

    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), raw)
  }

  func testMutationLockInteropFixtureMatchesCoreAndMac() throws {
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

  func testForeignHostMutationTicketFailsClosed() throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-foreign-lock")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let foreign = try writeLockParticipant(
      for: file,
      host: "other-host.example",
      pid: Int32.max,
      token: "00000000-0000-4000-8000-000000000001",
      phase: .ticket,
      ticket: 1
    )
    let foreignData = try Data(contentsOf: foreign)

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.mutateTextAtomically(at: file) { _ in
        ("* DONE Review exact draft\n", ())
      }
    )

    XCTAssertEqual(try Data(contentsOf: foreign), foreignData)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
  }

  func testBooleanPIDAndTicketMetadataFailClosed() throws {
    for malformedField in ["pid", "ticket"] {
      let root = try makeTemporaryDirectory(prefix: "org2-mobile-malformed-lock")
      defer { try? FileManager.default.removeItem(at: root) }
      let file = root.appendingPathComponent("review.org2")
      let original = "* TODO Review exact draft\n"
      try original.write(to: file, atomically: true, encoding: .utf8)
      let lock = Org2CoordinatedFileMutation.mutationLockURL(for: file)
      try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
      let token = "00000000-0000-4000-8000-000000000001"
      var owner: [String: Any] = [
        "schema": Org2CoordinatedFileMutation.lockOwnerSchema,
        "host": ProcessInfo.processInfo.hostName,
        "pid": Int32.max,
        "token": token,
        "phase": "ticket",
        "ticket": 1,
        "createdAt": "2026-07-25T00:00:00Z",
      ]
      owner[malformedField] = true
      let data = try JSONSerialization.data(withJSONObject: owner, options: [.sortedKeys])
        + Data("\n".utf8)
      let participant = lock.appendingPathComponent(
        Org2CoordinatedFileMutation.ticketFilename(ticket: 1, token: token)
      )
      try data.write(to: participant)

      XCTAssertThrowsError(
        try Org2CoordinatedFileMutation.mutateTextAtomically(at: file) { _ in
          ("* DONE Review exact draft\n", ())
        }
      ) { error in
        XCTAssertTrue(error.localizedDescription.contains("Malformed"))
      }
      XCTAssertEqual(try Data(contentsOf: participant), data)
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    }
  }

  func testFractionalPIDMetadataFailsClosed() throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-fractional-pid")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("review.org2")
    let original = "* TODO Review exact draft\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let lock = Org2CoordinatedFileMutation.mutationLockURL(for: file)
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
    let token = "00000000-0000-4000-8000-000000000001"
    let owner: [String: Any] = [
      "schema": Org2CoordinatedFileMutation.lockOwnerSchema,
      "host": ProcessInfo.processInfo.hostName,
      "pid": 99_999_999.5,
      "token": token,
      "phase": "ticket",
      "ticket": 1,
      "createdAt": "2026-07-25T00:00:00Z",
    ]
    let data = try JSONSerialization.data(withJSONObject: owner, options: [.sortedKeys])
      + Data("\n".utf8)
    let participant = lock.appendingPathComponent(
      Org2CoordinatedFileMutation.ticketFilename(ticket: 1, token: token)
    )
    try data.write(to: participant)

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.mutateTextAtomically(at: file) { _ in
        ("* DONE Review exact draft\n", ())
      }
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("Malformed"))
    }
    XCTAssertEqual(try Data(contentsOf: participant), data)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
  }

  func testCreateIfMissingDetectsCompetingInboxWriter() throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-create-race")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("mobile-inbox.org2")
    let competing = "#+TITLE: Competing Inbox\n"

    XCTAssertThrowsError(
      try Org2CoordinatedFileMutation.mutateTextAtomically(
        at: file,
        createIfMissing: true
      ) { current in
        XCTAssertEqual(current, "")
        try competing.write(to: file, atomically: true, encoding: .utf8)
        return ("#+TITLE: Org2 Mobile Inbox\n", ())
      }
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("competing writer"))
    }

    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), competing)
    XCTAssertEqual(try participantFilenames(for: file), [])
  }

  func testMobileCaptureCreatesAndAppendsInboxUnderSharedLock() throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-capture-lock")
    defer { try? FileManager.default.removeItem(at: root) }

    let inbox = try MobileCaptureWriter.appendMobileInbox(
      "\n\n* First capture\n",
      attachments: [],
      entryID: "first",
      baseURL: root
    )
    _ = try MobileCaptureWriter.appendMobileInbox(
      "\n\n* Second capture\n",
      attachments: [],
      entryID: "second",
      baseURL: root
    )

    let raw = try String(contentsOf: inbox, encoding: .utf8)
    XCTAssertTrue(raw.hasPrefix("#+TITLE: Org2 Mobile Inbox\n\n"))
    XCTAssertEqual(raw.components(separatedBy: "#+TITLE: Org2 Mobile Inbox").count - 1, 1)
    XCTAssertTrue(raw.contains("* First capture"))
    XCTAssertTrue(raw.contains("* Second capture"))
    XCTAssertTrue(isLockDirectory(for: inbox))
    XCTAssertEqual(try participantFilenames(for: inbox), [])
  }

  func testMobileCaptureCannotAppendAcrossLiveApprovalWriterTicket() throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-capture-approval-lock")
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent(MobileCaptureWriter.mobileInboxFilename)
    let original = """
    #+TITLE: Org2 Mobile Inbox

    * TODO Review captured release
    """
    try original.write(to: inbox, atomically: true, encoding: .utf8)
    _ = try writeLockParticipant(
      for: inbox,
      host: ProcessInfo.processInfo.hostName,
      pid: ProcessInfo.processInfo.processIdentifier,
      token: "00000000-0000-4000-8000-000000000001",
      phase: .ticket,
      ticket: 1
    )

    XCTAssertThrowsError(
      try MobileCaptureWriter.appendMobileInbox(
        "\n\n* Competing capture\n",
        attachments: [],
        entryID: "blocked",
        baseURL: root
      )
    )

    XCTAssertEqual(try String(contentsOf: inbox, encoding: .utf8), original)
  }

  @MainActor
  func testCorpusStoreOpenClawCaptureUsesSharedInboxTicket() async throws {
    let root = try makeTemporaryDirectory(prefix: "org2-mobile-store-capture-lock")
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("mobile-inbox.org2")
    let participant = try writeLockParticipant(
      for: inbox,
      host: ProcessInfo.processInfo.hostName,
      pid: ProcessInfo.processInfo.processIdentifier,
      token: "00000000-0000-4000-8000-000000000001",
      phase: .ticket,
      ticket: 1
    )
    let fingerprintInput = LegacyHeadlineApprovalFingerprintInput(
      title: "Review release",
      body: "Exact release.",
      properties: ["STATUS": "review-required"],
      status: "review-required",
      todo: "TODO",
      pairedAction: nil
    )
    let approval = ApprovalEntry(
      id: "approval:release",
      title: "Review release",
      status: "review-required",
      todo: "TODO",
      level: 1,
      file: "queue.org2",
      line: 1,
      approvalID: "release",
      sourceID: nil,
      fingerprint: ApprovalSemantics.fingerprint(for: fingerprintInput),
      fingerprintInput: fingerprintInput,
      binding: .legacyHeadline,
      canApprove: true,
      approvalBlockedReason: nil,
      properties: fingerprintInput.properties,
      body: fingerprintInput.body,
      tags: []
    )
    let store = CorpusStore()
    await store.selectCorpus(root)

    await store.sendToOpenClaw(.discuss, approval: approval, message: "Review the exact release.")
    XCTAssertNotNil(store.errorMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path))

    try FileManager.default.removeItem(at: participant)
    store.errorMessage = nil
    await store.sendToOpenClaw(.discuss, approval: approval, message: "Review the exact release.")

    XCTAssertNil(store.errorMessage)
    XCTAssertTrue(try String(contentsOf: inbox, encoding: .utf8).contains("Mobile Discuss: Review release"))
    XCTAssertEqual(try participantFilenames(for: inbox), [])
  }

  func testScanningDoesNotMintApprovalID() throws {
    let raw = """
    * TODO Review release
    :PROPERTIES:
    :ID: existing-source-id
    :STATUS: review-required
    :END:
    Exact release notes.
    """

    let snapshot = try XCTUnwrap(ApprovalSemantics.snapshots(in: raw).first)
    XCTAssertNil(snapshot.approvalID)
    XCTAssertEqual(snapshot.sourceID, "existing-source-id")
    XCTAssertFalse(raw.contains("ORG2_APPROVAL_ID"))
  }

  private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func writeLockParticipant(
    for file: URL,
    host: String,
    pid: pid_t,
    token: String,
    phase: Org2CoordinatedFileMutation.LockPhase,
    ticket: UInt64?
  ) throws -> URL {
    let lock = Org2CoordinatedFileMutation.mutationLockURL(for: file)
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
    let owner = try Org2CoordinatedFileMutation.lockOwnerData(
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
    let participant = lock.appendingPathComponent(name)
    try owner.write(to: participant)
    return participant
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
}
