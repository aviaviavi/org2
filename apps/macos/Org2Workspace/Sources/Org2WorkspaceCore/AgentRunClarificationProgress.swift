import Foundation

/// The step a *Reply & Resume* request is on. The run detail shows it
/// prominently so a slow Gateway or CLI round trip never looks idle.
public enum AgentRunClarificationReplyPhase: String, Equatable, Sendable, CaseIterable {
  /// Recording the answer on the durable run (Gateway or local CLI).
  case recording
  /// Moving the blocked run back to running.
  case resuming
  /// Opening the correlated chat and sending the continuation.
  case handingOff

  public var title: String {
    switch self {
    case .recording: "Sending your reply…"
    case .resuming: "Resuming the run…"
    case .handingOff: "Handing off to the agent…"
    }
  }

  public var detail: String {
    switch self {
    case .recording: "Recording your answer on the run. This can take a few seconds."
    case .resuming: "Your answer is recorded. Moving the run out of the blocked state."
    case .handingOff: "Opening the agent's chat and sending your answer so it can continue."
    }
  }

  /// Short label for the busy Reply & Resume button.
  public var buttonTitle: String {
    switch self {
    case .recording: "Sending…"
    case .resuming: "Resuming…"
    case .handingOff: "Handing Off…"
    }
  }

  /// 1-based step number, for "Step 2 of 3".
  public var stepNumber: Int {
    (Self.allCases.firstIndex(of: self) ?? 0) + 1
  }

  public var stepLabel: String {
    "Step \(stepNumber) of \(Self.allCases.count)"
  }
}
