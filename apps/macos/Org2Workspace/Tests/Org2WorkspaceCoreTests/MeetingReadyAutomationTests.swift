import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor MeetingAutomationSendRecorder {
  private var calls: [[OpenClawChatMessage]] = []

  func send(_ messages: [OpenClawChatMessage]) -> String {
    calls.append(messages)
    return "Meeting processed"
  }

  func callCount() -> Int {
    calls.count
  }
}

final class MeetingReadyAutomationTests: XCTestCase {
  @MainActor
  func testOnlySuccessfulCompletionEventsQueueEachNewMeetingOnce() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let recorder = MeetingAutomationSendRecorder()
    let store = WorkspaceStore(
      defaults: fixture.defaults,
      openClawTranscriptURL: fixture.transcript,
      openClawSendHandler: { messages, _, _, _ in
        await recorder.send(messages)
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(fixture.root, persistsDefault: false)
    let oldMeeting = meeting(
      title: "Old planning call",
      file: fixture.root.appendingPathComponent("meetings/old.org2").path,
      idValue: "old-meeting"
    )
    store.meetings = [oldMeeting]

    XCTAssertTrue(store.saveMeetingReadyAutomationConfiguration(
      isEnabled: true,
      destinationID: AIChatDestinationConfiguration.openClawID,
      threadMode: .newThread,
      threadID: nil,
      prompt: "Extract the follow-ups."
    ))
    XCTAssertFalse(store.openClawChatThreads.contains(where: { $0.title.contains("Old planning call") }))

    let newMeeting = meeting(
      title: "Launch review",
      file: fixture.root.appendingPathComponent("meetings/launch-review.org2").path,
      idValue: "launch-review"
    )
    let unavailableMeeting = meeting(
      title: "Transcript needs attention",
      file: fixture.root.appendingPathComponent("meetings/transcript-needs-attention.org2").path,
      idValue: "transcript-needs-attention",
      transcriptionStatus: "unavailable"
    )
    let failedMeeting = meeting(
      title: "Transcript failed",
      file: fixture.root.appendingPathComponent("meetings/transcript-failed.org2").path,
      idValue: "transcript-failed",
      transcriptionStatus: "failed"
    )
    store.meetingTranscriptionDidCompleteForTesting(newMeeting)
    store.meetingTranscriptionDidCompleteForTesting(newMeeting)
    store.meetingTranscriptionDidCompleteForTesting(unavailableMeeting)
    store.meetingTranscriptionDidCompleteForTesting(failedMeeting)

    let thread = try XCTUnwrap(
      store.openClawChatThreads.first(where: { $0.title.contains("Launch review") })
    )
    let userMessages = thread.messages.filter { $0.role == .user }
    XCTAssertEqual(userMessages.count, 1)
    XCTAssertTrue(userMessages[0].content.contains(
      "#+org2_automation_event_id: meeting-ready:meeting-id:launch-review"
    ))
    XCTAssertTrue(userMessages[0].content.contains("Extract the follow-ups."))

    XCTAssertFalse(store.openClawChatThreads.contains(where: {
      $0.title.contains("Transcript needs attention") || $0.title.contains("Transcript failed")
    }))
  }

  @MainActor
  func testRelaunchAndRefreshDoNotQueueHistoricalCompletedMeetings() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let firstStore = WorkspaceStore(
      defaults: fixture.defaults,
      openClawTranscriptURL: fixture.transcript,
      legacyDefaultsDomains: []
    )
    firstStore.setCorpusRoot(fixture.root, persistsDefault: false)
    let threadID = firstStore.createOpenClawChatThread(runtime: .openClaw)
    firstStore.settleOpenClawChatThread(threadID)
    XCTAssertTrue(firstStore.saveMeetingReadyAutomationConfiguration(
      isEnabled: true,
      destinationID: AIChatDestinationConfiguration.openClawID,
      threadMode: .existingThread,
      threadID: threadID,
      prompt: "Process the completed meeting."
    ))
    firstStore.flushDeferredAIChatTranscriptPersistence()

    let relaunchedStore = WorkspaceStore(
      defaults: fixture.defaults,
      openClawTranscriptURL: fixture.transcript,
      legacyDefaultsDomains: []
    )
    relaunchedStore.setCorpusRoot(fixture.root, persistsDefault: false)
    XCTAssertTrue(relaunchedStore.meetingReadyAutomationSettings.isEnabled)
    XCTAssertEqual(relaunchedStore.meetingReadyAutomationSettings.threadID, threadID)

    let meetingsDirectory = fixture.root.appendingPathComponent("meetings", isDirectory: true)
    try FileManager.default.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true)
    let file = meetingsDirectory.appendingPathComponent("customer-sync.org2")
    try """
    #+TITLE: Meeting: Customer sync
    #+ORG2_KIND: meeting

    * Meeting: Customer sync
    :PROPERTIES:
    :ID: customer-sync
    :kind: meeting
    :recorded_at: 2026-08-19T12:00:00-07:00
    :audio_artifact: meetings/customer-sync.wav
    :transcript_artifact: meetings/customer-sync.transcript.org2
    :transcription_status: complete
    :END:
    """.write(to: file, atomically: true, encoding: .utf8)

    await relaunchedStore.refreshMeetings()
    await relaunchedStore.refreshMeetings()

    let target = try XCTUnwrap(
      relaunchedStore.openClawChatThreads.first(where: { $0.id == threadID })
    )
    XCTAssertTrue(target.isSettled)
    XCTAssertEqual(target.messages.filter { $0.role == .user }.count, 0)
    XCTAssertFalse(relaunchedStore.openClawChatThreads.contains(where: {
      $0.messages.contains(where: { $0.content.contains("meeting-ready:meeting-id:customer-sync") })
    }))
  }

  @MainActor
  func testLinkifiedFileLevelIDDoesNotQueueMeetingTwiceAfterRefresh() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = WorkspaceStore(
      defaults: fixture.defaults,
      openClawTranscriptURL: fixture.transcript,
      openClawSendHandler: { _, _, _, _ in "Meeting processed" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(fixture.root, persistsDefault: false)
    XCTAssertTrue(store.saveMeetingReadyAutomationConfiguration(
      isEnabled: true,
      destinationID: AIChatDestinationConfiguration.openClawID,
      threadMode: .newThread,
      threadID: nil,
      prompt: "Process the completed meeting."
    ))

    let meetingsDirectory = fixture.root.appendingPathComponent("meetings", isDirectory: true)
    try FileManager.default.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true)
    let file = meetingsDirectory.appendingPathComponent("customer-sync.org2")
    let canonicalMeetingID = "048c73c3-b253-4964-9aee-3f3e625d55cc"
    let initialItem = meeting(
      title: "Customer sync",
      file: file.path,
      idValue: canonicalMeetingID
    )
    store.meetingTranscriptionDidCompleteForTesting(initialItem)

    try """
    :PROPERTIES:
    :ID: 3494fc49-0103-40bc-b35c-ec696a09ab8e
    :END:

    #+TITLE: Meeting: Customer sync
    #+ORG2_KIND: meeting

    * Meeting: Customer sync
    :PROPERTIES:
    :ID: \(canonicalMeetingID)
    :kind: meeting
    :recorded_at: 2026-08-20T12:00:00-07:00
    :audio_artifact: meetings/customer-sync.wav
    :transcript_artifact: meetings/customer-sync.transcript.org2
    :transcription_status: complete
    :END:
    """.write(to: file, atomically: true, encoding: .utf8)

    await store.refreshMeetings()

    XCTAssertEqual(store.meetings.first?.idValue, canonicalMeetingID)
    let automationMessages = store.openClawChatThreads
      .flatMap(\.messages)
      .filter { $0.role == .user && $0.content.contains("#+org2_automation_event_id:") }
    XCTAssertEqual(automationMessages.count, 1)
    XCTAssertTrue(automationMessages[0].content.contains(
      "meeting-ready:meeting-id:\(canonicalMeetingID)"
    ))
  }

  private func meeting(
    title: String,
    file: String,
    idValue: String,
    transcriptionStatus: String = "complete"
  ) -> MeetingWorkspaceItem {
    MeetingWorkspaceItem(
      title: title,
      file: file,
      recordedAt: "2026-08-19T12:00:00-07:00",
      modifiedAt: Date(),
      audioArtifact: "audio.m4a",
      transcriptArtifact: "transcript.org2",
      transcriptionStatus: transcriptionStatus,
      idValue: idValue
    )
  }

  private func makeFixture() throws -> (
    root: URL,
    transcript: URL,
    defaults: UserDefaults,
    cleanup: () -> Void
  ) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-meeting-automation-\(UUID().uuidString)", isDirectory: true)
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let suiteName = "MeetingReadyAutomationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    return (
      root,
      transcript,
      defaults,
      {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
      }
    )
  }
}
