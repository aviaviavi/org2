import Foundation
import SwiftUI

// MARK: - Shared explanation model (org2:activity-explanation:v1)

/// The `org2 activity explain --json` envelope. The CLI derives every field
/// from structured presence, transcript, run, and workflow records; the app
/// only presents it.
public struct WorkspaceActivityExplanationPayload: Decodable, Equatable, Sendable {
  public let schema: String
  public let generatedAt: String
  public let automationHostRef: String?
  public let items: [WorkspaceActivityExplanation]
}

public struct WorkspaceActivityExplanation: Decodable, Equatable, Sendable, Identifiable {
  public struct Reason: Decodable, Equatable, Sendable {
    public let code: String
    public let summary: String
  }

  public struct ReportedBy: Decodable, Equatable, Sendable {
    public let hostRef: String?
    public let hostName: String?
    public let hostKind: String?
    public let hostState: String?
    public let runtime: String?
    public let destinationID: String?
    public let destinationName: String?
    public let model: String?
    public let actor: String?
  }

  public struct Signal: Decodable, Equatable, Sendable {
    public let type: String
    public let at: String
    public let ageSeconds: Int
    public let detail: String?
  }

  public struct Blocker: Decodable, Equatable, Sendable, Identifiable {
    public let kind: String
    public let summary: String
    public let runId: String?
    public let approvalId: String?
    public let title: String?
    public let action: String?
    public let riskClass: String?
    public let fingerprint: String?
    public let requestedFrom: String?
    public let requestedAt: String?
    public let artifactId: String?
    public let path: String?
    public let messageId: String?
    public let nextActions: [String]?
    public let command: String?

    public var id: String {
      [kind, runId, approvalId, artifactId, messageId, summary].compactMap { $0 }.joined(separator: ":")
    }
  }

  public struct Evidence: Decodable, Equatable, Sendable, Identifiable {
    public let source: String
    public let ref: String
    public let at: String?
    public let detail: String

    public var id: String { "\(source):\(ref):\(at ?? ""):\(detail)" }
  }

  public struct Related: Decodable, Equatable, Sendable, Identifiable {
    public let kind: String
    public let id: String
    public let relation: String
  }

  public let kind: String
  public let id: String
  public let title: String
  public let state: String
  public let needsAttention: Bool
  public let reason: Reason
  public let reportedBy: ReportedBy
  public let lastSignal: Signal?
  public let confidence: String
  public let confidenceReason: String
  public let blocking: [Blocker]
  public let related: [Related]
  public let evidence: [Evidence]

  /// "AiroPress · codex · Remote Codex"
  public var reporterSummary: String? {
    let parts = [
      reportedBy.hostName ?? reportedBy.hostRef,
      reportedBy.runtime,
      reportedBy.destinationName ?? reportedBy.destinationID,
      reportedBy.model,
    ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  public var signalDate: Date? {
    lastSignal.flatMap { WorkspaceStore.activityDate($0.at) }
  }

  public var signalLabel: String {
    switch lastSignal?.type {
    case "heartbeat": "Last heartbeat"
    case "transition": "Last transition"
    case "message": "Last message"
    case "trigger-attempt": "Last dispatch"
    default: "Last update"
    }
  }
}

public enum WorkspaceActivityExplanationState: Equatable, Sendable {
  case idle
  case loading
  case loaded(WorkspaceActivityExplanation)
  case failed(String)
}

extension WorkspaceStore {
  /// The CLI target for an Activity row, or nil for rows that are not agent
  /// work (changed files).
  public func activityExplanationArguments(for item: WorkspaceActivityItem) -> [String]? {
    switch item.target {
    case .thread(let id): return ["--thread", id.uuidString]
    case .run(let id): return ["--run", id]
    case .workflow(let id): return ["--workflow", id]
    case .approval(let id):
      guard let runID = approvalItems.first(where: { $0.id == id })?.runId else { return nil }
      return ["--run", runID]
    case .file: return nil
    }
  }

  public func canExplainActivityItem(_ item: WorkspaceActivityItem) -> Bool {
    activityExplanationArguments(for: item) != nil
  }

  /// Asks the shared runtime why `item` is in its current state.
  public func explainActivityItem(_ item: WorkspaceActivityItem) async throws -> WorkspaceActivityExplanation {
    guard let corpusRoot else { throw Org2CLIError.commandFailed(status: 1, message: "Open a corpus first.") }
    guard let target = activityExplanationArguments(for: item) else {
      throw Org2CLIError.commandFailed(status: 1, message: "This item has no agent state to explain.")
    }
    usageLog.record(.activityOpen, ["kind": .string(item.kind.rawValue), "target": "explain"])
    let payload: WorkspaceActivityExplanationPayload
    if let activityExplanationLoaderForTesting {
      payload = try await activityExplanationLoaderForTesting(target)
    } else {
      payload = try await cli.runJSON(["activity", "explain"] + target + ["--dir", corpusRoot.path, "--json"])
    }
    guard let explanation = payload.items.first else {
      throw Org2CLIError.commandFailed(status: 1, message: "No explanation was returned.")
    }
    return explanation
  }

  /// Opens the review queue at the approval an explanation names.
  public func openActivityBlocker(_ blocker: WorkspaceActivityExplanation.Blocker) {
    switch blocker.kind {
    case "approval":
      openReviewQueue()
      if let approval = approvalItems.first(where: {
        $0.runId == blocker.runId && ($0.approvalId == blocker.approvalId || $0.idValue == blocker.approvalId)
      }) {
        selectApprovalItem(approval)
      }
    case "question", "artifact-review":
      if let runID = blocker.runId { openHeadingWork(threadID: nil, runID: runID) }
    default:
      break
    }
  }
}

// MARK: - Inspector

/// "Explain Status": why an Activity row is working or needs attention, who
/// reported it, how fresh that report is, and what exactly blocks it.
struct ActivityExplanationInspector: View {
  @Environment(WorkspaceStore.self) private var store
  let item: WorkspaceActivityItem
  @State private var state: WorkspaceActivityExplanationState = .idle

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "questionmark.circle")
          .foregroundStyle(.secondary)
        Text("Explain Status")
          .font(.headline)
        Spacer(minLength: 8)
        Button {
          Task { await load() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Explain again from the latest records")
      }
      Text(item.title)
        .font(.callout.weight(.medium))
        .lineLimit(2)
      Divider()
      content
    }
    .padding(16)
    .frame(width: 420, alignment: .topLeading)
    .task(id: item.id) { await load() }
  }

  @ViewBuilder
  private var content: some View {
    switch state {
    case .idle, .loading:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Reading presence, transcript, and run records…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    case .loaded(let explanation):
      ActivityExplanationDetails(explanation: explanation)
    }
  }

  private func load() async {
    state = .loading
    do {
      state = .loaded(try await store.explainActivityItem(item))
    } catch {
      state = .failed(error.localizedDescription)
    }
  }
}

struct ActivityExplanationDetails: View {
  @Environment(WorkspaceStore.self) private var store
  let explanation: WorkspaceActivityExplanation

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          ActivityStatePill(state: explanation.state, needsAttention: explanation.needsAttention)
          ActivityConfidencePill(confidence: explanation.confidence)
            .help(explanation.confidenceReason)
          Spacer(minLength: 0)
        }
        field("Why", explanation.reason.summary)
        if let reporter = explanation.reporterSummary {
          field(
            "Reported by",
            reporter + (explanation.reportedBy.hostState.map { " (\($0))" } ?? "")
          )
        }
        if let signal = explanation.lastSignal {
          VStack(alignment: .leading, spacing: 2) {
            Text(explanation.signalLabel)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            HStack(spacing: 4) {
              if let date = explanation.signalDate {
                Text(date, style: .relative) + Text(" ago")
              } else {
                Text(signal.at)
              }
              if let detail = signal.detail {
                Text("· \(detail)")
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
            .font(.callout)
          }
        }
        field("Confidence", explanation.confidenceReason)
        if !explanation.blocking.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Blocking")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            ForEach(explanation.blocking) { blocker in
              ActivityBlockerRow(blocker: blocker)
            }
          }
        }
        if !explanation.evidence.isEmpty {
          DisclosureGroup("Evidence") {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(explanation.evidence) { evidence in
                VStack(alignment: .leading, spacing: 1) {
                  Text(evidence.detail)
                    .font(.caption)
                  Text([evidence.source, evidence.at].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .textSelection(.enabled)
              }
            }
            .padding(.top, 4)
          }
          .font(.caption.weight(.semibold))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: 460)
  }

  private func field(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
  }
}

private struct ActivityBlockerRow: View {
  @Environment(WorkspaceStore.self) private var store
  let blocker: WorkspaceActivityExplanation.Blocker

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: icon)
          .foregroundStyle(.orange)
        Text(blocker.summary)
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      if let action = blocker.action, blocker.kind == "approval" {
        Text("Action: \(action)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      if let nextActions = blocker.nextActions, !nextActions.isEmpty {
        ForEach(nextActions, id: \.self) { action in
          Text("• \(action)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 10) {
        if blocker.kind == "approval" {
          Button("Open in Review") { store.openActivityBlocker(blocker) }
        } else if blocker.runId != nil, blocker.kind == "question" || blocker.kind == "artifact-review" {
          Button("Open Run") { store.openActivityBlocker(blocker) }
        }
        if let command = blocker.command {
          Button("Copy Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
          }
          .help(command)
        }
      }
      .buttonStyle(.link)
      .font(.caption)
    }
    .padding(8)
    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private var icon: String {
    switch blocker.kind {
    case "approval": "checkmark.seal"
    case "question": "questionmark.bubble"
    case "delivery-failure": "exclamationmark.triangle"
    case "artifact-review": "doc.badge.ellipsis"
    default: "bubble.left"
    }
  }
}

struct ActivityStatePill: View {
  let state: String
  let needsAttention: Bool

  var body: some View {
    Text(label)
      .font(.caption.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(tint.opacity(0.13), in: Capsule())
  }

  private var label: String {
    switch state {
    case "needs-you": "Needs you"
    case "your-turn": "Your turn"
    case "working": "Working"
    case "queued": "Queued"
    case "failed": "Failed"
    case "scheduled": "Scheduled"
    case "due": "Due"
    case "paused": "Paused"
    case "settled": "Settled"
    case "done": "Done"
    default: "Idle"
    }
  }

  private var tint: Color {
    if state == "failed" { return .red }
    if needsAttention { return .orange }
    switch state {
    case "working": return .accentColor
    case "done": return .green
    default: return .secondary
    }
  }
}

struct ActivityConfidencePill: View {
  let confidence: String

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
      Text(label)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(tint.opacity(0.12), in: Capsule())
    .accessibilityLabel("Confidence: \(label)")
  }

  private var label: String {
    switch confidence {
    case "live": "Live"
    case "uncertain": "Uncertain"
    default: "Cached"
    }
  }

  private var icon: String {
    switch confidence {
    case "live": "dot.radiowaves.left.and.right"
    case "uncertain": "questionmark.diamond"
    default: "tray.full"
    }
  }

  private var tint: Color {
    switch confidence {
    case "live": .green
    case "uncertain": .orange
    default: .secondary
    }
  }
}
