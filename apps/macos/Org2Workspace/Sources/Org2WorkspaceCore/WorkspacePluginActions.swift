import Foundation
import SwiftUI

// MARK: - Models (shared CLI contracts)

public struct WorkspacePluginActionListPayload: Decodable, Equatable, Sendable {
  public let actions: [WorkspacePluginAction]
  public let hooks: [WorkspacePluginHook]
  public let sandbox: String?
}

/// A context-aware action a trusted or untrusted plugin contributes.
public struct WorkspacePluginAction: Decodable, Equatable, Sendable, Identifiable {
  public let id: String
  public let pluginId: String
  public let pluginName: String
  public let actionId: String
  public let title: String
  public let description: String?
  public let contexts: [String]
  public let capabilities: [String]
  public let trusted: Bool
}

public struct WorkspacePluginHook: Decodable, Equatable, Sendable, Identifiable {
  public let id: String
  public let pluginId: String
  public let events: [String]
  public let trusted: Bool
}

/// The selection an action runs against.
public enum WorkspacePluginActionContext: Equatable, Sendable {
  case note(file: String)
  case heading(file: String, line: Int)
  case thread(UUID)
  case run(String)
  case approval(runID: String, approvalID: String?)

  public var kind: String {
    switch self {
    case .note: "note"
    case .heading: "heading"
    case .thread: "thread"
    case .run: "run"
    case .approval: "approval"
    }
  }

  var arguments: [String] {
    switch self {
    case .note(let file): ["--context", "note", "--file", file]
    case .heading(let file, let line): ["--context", "heading", "--file", file, "--line", String(max(1, line))]
    case .thread(let id): ["--context", "thread", "--thread", id.uuidString]
    case .run(let id): ["--context", "run", "--run", id]
    case .approval(let runID, let approvalID):
      ["--context", "approval", "--run", runID] + (approvalID.map { ["--approval", $0] } ?? [])
    }
  }
}

public struct WorkspacePluginProposal: Decodable, Equatable, Sendable, Identifiable {
  public struct Source: Decodable, Equatable, Sendable {
    public let kind: String
    public let pluginId: String
    public let pluginName: String
    public let contributionId: String
    public let title: String
  }

  public struct Change: Decodable, Equatable, Sendable {
    public let kind: String
    public let path: String?
    public let threadId: String?
    public let runId: String?
    public let summary: String?

    public var target: String { path ?? threadId.map { "chat \($0)" } ?? runId.map { "run \($0)" } ?? "" }
  }

  public let id: String
  public let createdAt: String
  public let status: String
  public let source: Source
  public let text: String?
  public let proposals: [Change]
  public let sandbox: String?
}

public struct WorkspacePluginActionRunResult: Decodable, Equatable, Sendable {
  public let action: String
  public let text: String?
  public let proposal: WorkspacePluginProposal?
}

public struct WorkspacePluginProposalPreview: Decodable, Equatable, Sendable {
  public struct Change: Decodable, Equatable, Sendable, Identifiable {
    public let index: Int
    public let kind: String
    public let target: String
    public let summary: String?
    public let ok: Bool
    public let detail: String
    public let diff: String?
    public var id: Int { index }
  }

  public let applied: Bool
  public let proposal: WorkspacePluginProposal
  public let changes: [Change]
}

struct WorkspacePluginProposalListPayload: Decodable {
  let proposals: [WorkspacePluginProposal]
}

/// The review sheet's state: an action's output plus a pending proposal.
public struct WorkspacePluginReview: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let text: String?
  public let preview: WorkspacePluginProposalPreview?
  public var error: String?
}

// MARK: - Store

extension WorkspaceStore {
  private var pluginLockExists: Bool {
    guard let corpusRoot else { return false }
    return FileManager.default.fileExists(atPath: corpusRoot.appendingPathComponent("org2.plugins.lock.json").path)
  }

  /// Loads plugin actions, hooks, and pending proposals for the corpus.
  public func refreshPluginActions() async {
    guard let corpusRoot, pluginLockExists else {
      pluginActions = []
      pluginHooks = []
      pendingPluginProposals = []
      return
    }
    do {
      let list: WorkspacePluginActionListPayload = try await cli.runJSON(["plugin", "actions", "--dir", corpusRoot.path, "--json"])
      let proposals: WorkspacePluginProposalListPayload = try await cli.runJSON([
        "plugin", "proposals", "list", "--status", "pending", "--dir", corpusRoot.path, "--json",
      ])
      pluginActions = list.actions
      pluginHooks = list.hooks
      pendingPluginProposals = proposals.proposals
    } catch {
      pluginActions = []
      pluginHooks = []
    }
  }

  public func pluginActions(for context: WorkspacePluginActionContext) -> [WorkspacePluginAction] {
    pluginActions.filter { $0.contexts.contains(context.kind) }
  }

  /// Plugin actions offered for an Activity row.
  public func pluginActionContext(for item: WorkspaceActivityItem) -> WorkspacePluginActionContext? {
    switch item.target {
    case .thread(let id): return .thread(id)
    case .run(let id): return .run(id)
    case .approval(let id):
      guard let approval = approvalItems.first(where: { $0.id == id }), let runID = approval.runId else { return nil }
      return .approval(runID: runID, approvalID: approval.approvalId)
    case .workflow, .file, .pluginProposal: return nil
    }
  }

  /// Runs an action against a selection and opens the review sheet with its
  /// output and any proposed changes. Nothing is written until the person
  /// applies the proposal.
  public func runPluginAction(_ action: WorkspacePluginAction, context: WorkspacePluginActionContext) async {
    guard let corpusRoot else { return }
    guard action.trusted else {
      activePluginReview = WorkspacePluginReview(
        id: action.id, title: action.title, text: nil, preview: nil,
        error: "\(action.pluginName) is not trusted on this Mac. Review it, then run “celorga plugin trust \(action.pluginId) --apply”."
      )
      return
    }
    statusText = "Running \(action.title)…"
    do {
      let result: WorkspacePluginActionRunResult = try await cli.runJSON(
        ["plugin", "action", "run", action.id] + context.arguments + ["--dir", corpusRoot.path, "--json"]
      )
      var preview: WorkspacePluginProposalPreview?
      if let proposal = result.proposal {
        preview = try await cli.runJSON(["plugin", "proposals", "apply", proposal.id, "--dir", corpusRoot.path, "--json"])
        pendingPluginProposals.insert(proposal, at: 0)
      }
      activePluginReview = WorkspacePluginReview(id: result.proposal?.id ?? action.id, title: action.title, text: result.text, preview: preview)
      statusText = result.proposal == nil ? "\(action.title) finished" : "\(action.title) proposed changes for review"
    } catch {
      activePluginReview = WorkspacePluginReview(id: action.id, title: action.title, text: nil, preview: nil, error: error.localizedDescription)
      statusText = "\(action.title) failed"
    }
  }

  /// Opens the review sheet for a pending proposal, such as one from a hook.
  public func reviewPluginProposal(id: String) async {
    guard let corpusRoot else { return }
    do {
      let preview: WorkspacePluginProposalPreview = try await cli.runJSON(["plugin", "proposals", "apply", id, "--dir", corpusRoot.path, "--json"])
      activePluginReview = WorkspacePluginReview(id: id, title: preview.proposal.source.title, text: preview.proposal.text, preview: preview)
    } catch {
      activePluginReview = WorkspacePluginReview(id: id, title: "Plugin proposal", text: nil, preview: nil, error: error.localizedDescription)
    }
  }

  public func decidePluginProposal(_ id: String, apply: Bool) async {
    guard let corpusRoot else { return }
    do {
      if apply {
        _ = try await cli.run(["plugin", "proposals", "apply", id, "--actor", NSFullUserName(), "--apply", "--dir", corpusRoot.path, "--json"])
        statusText = "Applied plugin proposal"
      } else {
        _ = try await cli.run(["plugin", "proposals", "dismiss", id, "--actor", NSFullUserName(), "--apply", "--dir", corpusRoot.path, "--json"])
        statusText = "Dismissed plugin proposal"
      }
      pendingPluginProposals.removeAll { $0.id == id }
      activePluginReview = nil
      await refreshWorkspaceAfterPluginProposal()
    } catch {
      activePluginReview?.error = error.localizedDescription
    }
  }

  private func refreshWorkspaceAfterPluginProposal() async {
    await refreshPluginActions()
    await refreshAgentRuns()
  }

  /// The scheduler owner dispatches plugin lifecycle hooks so each event is
  /// delivered once across hosts. Results are pending proposals.
  func dispatchPluginHooksIfOwner() async {
    guard let corpusRoot, pluginLockExists, !isDispatchingPluginHooks else { return }
    isDispatchingPluginHooks = true
    defer { isDispatchingPluginHooks = false }
    if corpusAutomationHostRef == nil { refreshCorpusAutomationHostRef() }
    if pluginHooks.isEmpty { await refreshPluginActions() }
    guard pluginHooks.contains(where: \.trusted) else { return }
    let owner = corpusAutomationHostRef ?? "desktop"
    let isOwner = owner == aiChatHostIdentity.ref || owner == automationHostRef
      || (owner == "desktop" && aiChatHostIdentity.kind == .desktop)
    guard isOwner else { return }
    _ = try? await cli.run(["plugin", "hooks", "dispatch", "--apply", "--dir", corpusRoot.path, "--json"])
    if let proposals: WorkspacePluginProposalListPayload = try? await cli.runJSON([
      "plugin", "proposals", "list", "--status", "pending", "--dir", corpusRoot.path, "--json",
    ]) {
      pendingPluginProposals = proposals.proposals
    }
  }
}

// MARK: - Views

/// A menu of plugin actions for one selection. Hidden when none apply.
struct PluginActionsMenu: View {
  @Environment(WorkspaceStore.self) private var store
  let context: WorkspacePluginActionContext
  var title = "Plugin Actions"

  var body: some View {
    let actions = store.pluginActions(for: context)
    if !actions.isEmpty {
      Menu {
        ForEach(actions) { action in
          Button {
            Task { await store.runPluginAction(action, context: context) }
          } label: {
            Text(action.trusted ? action.title : "\(action.title) (untrusted)")
          }
          .help(action.description ?? "\(action.pluginName) · returns changes for your review")
        }
      } label: {
        Label(title, systemImage: "puzzlepiece.extension")
      }
    }
  }
}

/// Reviews a plugin's output and proposed changes before anything is written.
struct PluginProposalReviewSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let review: WorkspacePluginReview
  @State private var isWorking = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "puzzlepiece.extension")
          .foregroundStyle(.secondary)
        Text(review.title)
          .font(.headline)
        Spacer()
        if let sandbox = review.preview?.proposal.sandbox {
          Text(sandbox == "none" ? "Not sandboxed" : "Sandboxed")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .help(sandbox == "none" ? "This platform has no plugin sandbox; the plugin could not write the corpus directly but had your file access" : "The plugin ran without corpus write access")
        }
      }
      if let error = review.error {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
      if let text = review.text, !text.isEmpty {
        ScrollView {
          Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 160)
      }
      if let preview = review.preview {
        Text("\(preview.changes.count) proposed change\(preview.changes.count == 1 ? "" : "s"). Nothing is written until you apply.")
          .font(.callout)
          .foregroundStyle(.secondary)
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(preview.changes) { change in
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                  Image(systemName: change.ok ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(change.ok ? .green : .red)
                  Text(change.summary ?? change.kind)
                    .font(.callout.weight(.medium))
                  Text(change.target)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Text(change.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if let diff = change.diff, !diff.isEmpty {
                  Text(diff)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .textSelection(.enabled)
                }
              }
            }
          }
        }
        .frame(minHeight: 120, maxHeight: 360)
      }
      HStack {
        Spacer()
        if let preview = review.preview, preview.proposal.status == "pending" {
          Button("Dismiss Proposal", role: .destructive) {
            isWorking = true
            Task { await store.decidePluginProposal(review.id, apply: false); isWorking = false }
          }
          .disabled(isWorking)
          Button("Close") { store.activePluginReview = nil }
          Button("Apply Changes") {
            isWorking = true
            Task { await store.decidePluginProposal(review.id, apply: true); isWorking = false }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(isWorking || preview.changes.contains { !$0.ok })
        } else {
          Button("Done") { store.activePluginReview = nil }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .frame(width: 620)
  }
}
