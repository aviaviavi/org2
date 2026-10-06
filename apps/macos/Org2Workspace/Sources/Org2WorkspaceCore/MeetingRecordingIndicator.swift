import Foundation
import SwiftUI

/// Active recording time for a meeting, excluding time spent paused.
public struct MeetingRecordingClock: Equatable, Sendable {
  public private(set) var isActive = false
  public private(set) var accumulated: TimeInterval = 0
  public private(set) var runningSince: Date?

  public init() {}

  public mutating func start(at date: Date) {
    isActive = true
    accumulated = 0
    runningSince = date
  }

  public mutating func pause(at date: Date) {
    guard isActive, let runningSince else { return }
    accumulated += max(0, date.timeIntervalSince(runningSince))
    self.runningSince = nil
  }

  public mutating func resume(at date: Date) {
    guard isActive, runningSince == nil else { return }
    runningSince = date
  }

  public mutating func reset() {
    self = MeetingRecordingClock()
  }

  public func elapsed(at now: Date) -> TimeInterval {
    accumulated + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
  }
}

/// What the app-wide recording indicator shows for the current meeting
/// recording state. `nil` when no recording is active or being finished.
public struct MeetingRecordingIndicatorPresentation: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case recording
    case paused
    case stopping
    case processing
  }

  public let phase: Phase
  public let title: String
  public let systemImage: String
  public let elapsedText: String?
  public let canStop: Bool
  public let canPauseOrResume: Bool
  public let help: String

  public static func make(
    isRecording: Bool,
    isPaused: Bool,
    isStopping: Bool,
    isProcessing: Bool,
    elapsed: TimeInterval
  ) -> MeetingRecordingIndicatorPresentation? {
    if isStopping {
      return MeetingRecordingIndicatorPresentation(
        phase: .stopping,
        title: "Stopping",
        systemImage: "stop.circle",
        elapsedText: elapsedText(elapsed),
        canStop: false,
        canPauseOrResume: false,
        help: "Finishing the meeting recording. Click to open Meetings."
      )
    }
    if isRecording {
      return MeetingRecordingIndicatorPresentation(
        phase: isPaused ? .paused : .recording,
        title: isPaused ? "Paused" : "REC",
        systemImage: isPaused ? "pause.circle.fill" : "record.circle.fill",
        elapsedText: elapsedText(elapsed),
        canStop: true,
        canPauseOrResume: true,
        help: isPaused
          ? "Meeting recording is paused. Click to open Meetings."
          : "Recording a meeting. Click to open Meetings."
      )
    }
    if isProcessing {
      return MeetingRecordingIndicatorPresentation(
        phase: .processing,
        title: "Transcribing",
        systemImage: "waveform",
        elapsedText: nil,
        canStop: false,
        canPauseOrResume: false,
        help: "Transcribing and saving the meeting. Click to open Meetings."
      )
    }
    return nil
  }

  /// `m:ss` below an hour, `h:mm:ss` from an hour on.
  public static func elapsedText(_ elapsed: TimeInterval) -> String {
    let total = max(0, Int(elapsed.rounded(.down)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
  }
}

extension WorkspaceStore {
  public func meetingRecordingIndicator(at now: Date = Date()) -> MeetingRecordingIndicatorPresentation? {
    MeetingRecordingIndicatorPresentation.make(
      isRecording: isRecordingMeeting,
      isPaused: isMeetingRecordingPaused,
      isStopping: isStoppingMeetingRecording,
      isProcessing: isProcessingMeeting,
      elapsed: meetingRecordingClock.elapsed(at: now)
    )
  }
}

/// A compact toolbar pill that shows meeting recording state on every
/// surface. Clicking it opens Meetings; it also offers pause/resume and stop.
struct MeetingRecordingToolbarIndicator: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    if store.meetingRecordingIndicator() != nil {
      let ticks = store.isRecordingMeeting && !store.isMeetingRecordingPaused
      TimelineView(.periodic(from: .now, by: 1)) { context in
        if let presentation = store.meetingRecordingIndicator(at: ticks ? context.date : Date()) {
          pill(presentation)
        }
      }
    }
  }

  private func pill(_ presentation: MeetingRecordingIndicatorPresentation) -> some View {
    HStack(spacing: 4) {
      Button {
        store.makeSurfacePrimary(.meetings)
      } label: {
        HStack(spacing: 5) {
          Image(systemName: presentation.systemImage)
            .foregroundStyle(tint(for: presentation.phase))
            .symbolEffect(.pulse, isActive: presentation.phase == .recording)
          Text(presentation.title)
            .font(.caption.weight(.semibold))
          if let elapsed = presentation.elapsedText {
            Text(elapsed)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(presentation.help)
      .accessibilityLabel(accessibilityLabel(presentation))

      if presentation.canPauseOrResume {
        Button {
          Task {
            if store.isMeetingRecordingPaused {
              await store.resumeMeetingRecording()
            } else {
              await store.pauseMeetingRecording()
            }
          }
        } label: {
          Image(systemName: presentation.phase == .paused ? "play.fill" : "pause.fill")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .help(presentation.phase == .paused ? "Resume recording" : "Pause recording")
        .accessibilityLabel(presentation.phase == .paused ? "Resume recording" : "Pause recording")
      }

      if presentation.canStop {
        Button {
          Task { await store.stopMeetingRecording() }
        } label: {
          Image(systemName: "stop.fill")
            .font(.caption2)
            .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .help("Stop recording and transcribe")
        .accessibilityLabel("Stop recording")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(tint(for: presentation.phase).opacity(0.12), in: Capsule())
    .overlay(Capsule().stroke(tint(for: presentation.phase).opacity(0.35), lineWidth: 1))
    .fixedSize()
  }

  private func tint(for phase: MeetingRecordingIndicatorPresentation.Phase) -> Color {
    switch phase {
    case .recording: .red
    case .paused: .orange
    case .stopping, .processing: .secondary
    }
  }

  private func accessibilityLabel(_ presentation: MeetingRecordingIndicatorPresentation) -> String {
    [presentation.title == "REC" ? "Recording" : presentation.title, presentation.elapsedText]
      .compactMap { $0 }
      .joined(separator: " ")
  }
}
