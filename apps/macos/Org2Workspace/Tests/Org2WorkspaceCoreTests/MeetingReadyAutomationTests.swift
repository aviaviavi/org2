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
  func testFirstEnableBaselinesExistingMeetingsAndQueuesEachNewMeetingOnce() async throws {
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
    store.reconcileMeetingReadyAutomationForTesting(with: [oldMeeting, newMeeting, unavailableMeeting])
    store.reconcileMeetingReadyAutomationForTesting(with: [oldMeeting, newMeeting, unavailableMeeting])

    let thread = try XCTUnwrap(
      store.openClawChatThreads.first(where: { $0.title.contains("Launch review") })
    )
    let userMessages = thread.messages.filter { $0.role == .user }
    XCTAssertEqual(userMessages.count, 1)
    XCTAssertTrue(userMessages[0].content.contains(
      "#+org2_automation_event_id: meeting-ready:meeting-id:launch-review"
    ))
    XCTAssertTrue(userMessages[0].content.contains("Extract the follow-ups."))

    let unavailableThread = try XCTUnwrap(
      store.openClawChatThreads.first(where: { $0.title.contains("Transcript needs attention") })
    )
    XCTAssertEqual(unavailableThread.messages.filter { $0.role == .user }.count, 1)
  }

  @MainActor
  func testRelaunchReconcilesAnUndeliveredMeetingIntoTheConfiguredThread() async throws {
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

    let recorder = MeetingAutomationSendRecorder()
    let relaunchedStore = WorkspaceStore(
      defaults: fixture.defaults,
      openClawTranscriptURL: fixture.transcript,
      openClawSendHandler: { messages, _, _, _ in
        await recorder.send(messages)
      },
      legacyDefaultsDomains: []
    )
    relaunchedStore.setCorpusRoot(fixture.root, persistsDefault: false)
    XCTAssertTrue(relaunchedStore.meetingReadyAutomationSettings.isEnabled)
    XCTAssertEqual(relaunchedStore.meetingReadyAutomationSettings.threadID, threadID)

    let missedMeeting = meeting(
      title: "Customer sync",
      file: fixture.root.appendingPathComponent("meetings/customer-sync.org2").path,
      idValue: "customer-sync"
    )
    relaunchedStore.reconcileMeetingReadyAutomationForTesting(with: [missedMeeting])
    relaunchedStore.reconcileMeetingReadyAutomationForTesting(with: [missedMeeting])

    let target = try XCTUnwrap(
      relaunchedStore.openClawChatThreads.first(where: { $0.id == threadID })
    )
    XCTAssertFalse(target.isSettled)
    XCTAssertEqual(target.messages.filter { $0.role == .user }.count, 1)
    XCTAssertTrue(
      target.messages.first(where: { $0.role == .user })?.content.contains(
        "#+org2_automation_event_id: meeting-ready:meeting-id:customer-sync"
      ) == true
    )
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
