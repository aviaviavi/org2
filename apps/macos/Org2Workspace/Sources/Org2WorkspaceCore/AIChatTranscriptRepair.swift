import Foundation

public struct AIChatTranscriptRepairReport: Codable, Sendable {
  public let schema: String
  public let applied: Bool
  public let changed: Bool
  public let checked: Bool
  public let revision: String
  public let threadCount: Int
  public let mergedShardCount: Int
  public let warnings: [String]
}

/// Shares the desktop's transcript reconciler; never starts a model or dispatches a turn.
public enum AIChatTranscriptRepair {
  public static func run(
    corpusRoot: URL, apply: Bool = false, expectedRevision: String? = nil, onlyIfChanged: Bool = false
  ) throws -> AIChatTranscriptRepairReport {
    try AIChatTranscriptStore.shared.repair(
      legacyURL: CelorgaNames.stateDirectory(corpusRoot: corpusRoot).appendingPathComponent("openclaw-chat.json"),
      apply: apply, expectedRevision: expectedRevision, onlyIfChanged: onlyIfChanged
    )
  }

  public static let defaultIntervalSeconds: TimeInterval = 120
  public static let intervalChoices: [TimeInterval] = [0, 120, 300, 900, 3600]

  public static func intervalTitle(_ seconds: TimeInterval) -> String {
    if seconds == 0 { return "Off" }
    if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 {
      let hours = Int(seconds / 3600)
      return hours == 1 ? "Every hour" : "Every \(hours) hours"
    }
    if seconds.truncatingRemainder(dividingBy: 60) == 0 {
      return "Every \(Int(seconds / 60)) minutes"
    }
    return "Every \(Int(seconds)) seconds"
  }
}
