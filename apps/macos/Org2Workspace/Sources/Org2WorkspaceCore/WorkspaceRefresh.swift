import Foundation
import OSLog

public struct WorkspaceRefreshMetric: Sendable {
  public let stage: String
  public let elapsedMilliseconds: Double
}

enum WorkspaceRefreshStage: String, CaseIterable, Sendable {
  case audio, document, identity, agenda, meetings, sources, files, assignedWork
  case approvals, agentState, threads
}

enum WorkspaceRefreshScheduler {
  /// The caller supplies dependency chains as individual jobs. A small pool
  /// overlaps independent I/O without launching every corpus scan at once.
  static func run(
    stages: [WorkspaceRefreshStage],
    concurrency: Int = 2,
    operation: @escaping @MainActor @Sendable (WorkspaceRefreshStage) async -> Void
  ) async {
    await withTaskGroup(of: Void.self) { group in
      var remaining = stages.makeIterator()
      for _ in 0..<min(max(1, concurrency), stages.count) {
        guard !Task.isCancelled, let stage = remaining.next() else { break }
        group.addTask { await operation(stage) }
      }
      while await group.next() != nil {
        guard !Task.isCancelled, let stage = remaining.next() else { continue }
        group.addTask { await operation(stage) }
      }
    }
  }

  private static let logger = Logger(subsystem: "org.org2.workspace", category: "WorkspaceRefresh")
  static func record(_ metric: WorkspaceRefreshMetric) {
    logger.info("stage=\(metric.stage, privacy: .public) elapsed_ms=\(metric.elapsedMilliseconds, privacy: .public)")
  }
}

public struct WorkspaceAgentStateSection<Value: Decodable & Sendable>: Decodable, Sendable {
  let value: Value?
  let error: String?
  let elapsedMilliseconds: Double

  func get() throws -> Value {
    if let error { throw WorkspaceAgentStateError.section(error) }
    guard let value else { throw WorkspaceAgentStateError.section("Missing workspace agent-state section") }
    return value
  }
}

private enum WorkspaceAgentStateError: LocalizedError {
  case section(String)
  var errorDescription: String? {
    switch self { case .section(let message): return message }
  }
}

struct WorkspaceAgentStateSnapshot: Decodable, Sendable {
  let runs: WorkspaceAgentStateSection<AgentRunListPayload>
  let workflows: WorkspaceAgentStateSection<AgentWorkflowListPayload>
  let goals: WorkspaceAgentStateSection<AgentGoalListPayload>
  let profiles: WorkspaceAgentStateSection<AgentProfileListPayload>
}
