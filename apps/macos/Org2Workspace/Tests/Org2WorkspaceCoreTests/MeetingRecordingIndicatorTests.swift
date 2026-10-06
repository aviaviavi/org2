import XCTest
@testable import Org2WorkspaceCore

final class MeetingRecordingIndicatorTests: XCTestCase {
  func testClockExcludesPausedTime() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    var clock = MeetingRecordingClock()
    XCTAssertEqual(clock.elapsed(at: start), 0)
    clock.resume(at: start)
    XCTAssertFalse(clock.isActive, "resume before start must not start the clock")

    clock.start(at: start)
    XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(65)), 65)
    clock.pause(at: start.addingTimeInterval(65))
    XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(500)), 65)
    clock.resume(at: start.addingTimeInterval(500))
    XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(510)), 75)
    clock.reset()
    XCTAssertEqual(clock, MeetingRecordingClock())
  }

  func testPresentationForEachRecordingPhase() {
    XCTAssertNil(MeetingRecordingIndicatorPresentation.make(
      isRecording: false, isPaused: false, isStopping: false, isProcessing: false, elapsed: 0
    ))

    let recording = MeetingRecordingIndicatorPresentation.make(
      isRecording: true, isPaused: false, isStopping: false, isProcessing: false, elapsed: 754
    )
    XCTAssertEqual(recording?.phase, .recording)
    XCTAssertEqual(recording?.elapsedText, "12:34")
    XCTAssertEqual(recording?.canStop, true)
    XCTAssertEqual(recording?.canPauseOrResume, true)

    let paused = MeetingRecordingIndicatorPresentation.make(
      isRecording: true, isPaused: true, isStopping: false, isProcessing: false, elapsed: 3_725
    )
    XCTAssertEqual(paused?.phase, .paused)
    XCTAssertEqual(paused?.title, "Paused")
    XCTAssertEqual(paused?.elapsedText, "1:02:05")

    let stopping = MeetingRecordingIndicatorPresentation.make(
      isRecording: true, isPaused: false, isStopping: true, isProcessing: false, elapsed: 5
    )
    XCTAssertEqual(stopping?.phase, .stopping)
    XCTAssertEqual(stopping?.canStop, false)
    XCTAssertEqual(stopping?.canPauseOrResume, false)

    let processing = MeetingRecordingIndicatorPresentation.make(
      isRecording: false, isPaused: false, isStopping: false, isProcessing: true, elapsed: 0
    )
    XCTAssertEqual(processing?.phase, .processing)
    XCTAssertNil(processing?.elapsedText)
    XCTAssertEqual(processing?.canStop, false)
  }

  @MainActor
  func testStoreDrivesIndicatorFromRecordingState() throws {
    let suiteName = "org2-meeting-indicator-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    store.selectedSurface = .agenda

    XCTAssertNil(store.meetingRecordingIndicator())
    store.isRecordingMeeting = true
    XCTAssertTrue(store.meetingRecordingClock.isActive)
    XCTAssertEqual(store.meetingRecordingIndicator()?.phase, .recording)
    store.isMeetingRecordingPaused = true
    XCTAssertNil(store.meetingRecordingClock.runningSince)
    XCTAssertEqual(store.meetingRecordingIndicator()?.phase, .paused)
    store.isMeetingRecordingPaused = false
    store.isRecordingMeeting = false
    XCTAssertFalse(store.meetingRecordingClock.isActive)
    store.isProcessingMeeting = true
    XCTAssertEqual(store.meetingRecordingIndicator()?.phase, .processing)
    store.isProcessingMeeting = false
    XCTAssertNil(store.meetingRecordingIndicator())
    XCTAssertEqual(store.selectedSurface, .agenda, "the indicator state never changes the surface")
  }
}
