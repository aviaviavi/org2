import Foundation

extension WorkspaceStore {
  /// Builds the shared activity model from in-memory workspace state. Cheap
  /// enough to call from a view body: it is linear in runs, threads,
  /// approvals, workflows, and corpus files, and reads no files.
  public func activitySnapshot(now: Date = Date()) -> WorkspaceActivitySnapshot {
    var snapshot = WorkspaceActivitySnapshot()
    let root = corpusRoot?.standardizedFileURL.path
    let profileNames = Dictionary(
      agentProfiles.map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first }
    )
    func relative(_ path: String?) -> String? {
      guard let path, !path.isEmpty else { return nil }
      return WorkspaceActivityMap.relativePath(fromReference: path, corpusRoot: root)
    }
    func agentName(agentRef: String?, fallback: String?) -> String? {
      if let agentRef, let name = profileNames[agentRef] { return name }
      return fallback?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyActivity
    }

    // Live chat turns.
    var representedThreadIDs = Set<UUID>()
    for thread in aiChatThreads where !thread.isArchived {
      let running = isAIChatThreadRunning(thread.id)
      let destination = aiChatDestination(id: thread.destinationID)?.title
      if running {
        representedThreadIDs.insert(thread.id)
        snapshot.working.append(WorkspaceActivityItem(
          id: "thread:\(thread.id.uuidString)",
          kind: .working,
          title: thread.title,
          detail: thread.resource.map { "Chat on \(relativePathOrName($0.file))" } ?? "Chat turn in progress",
          agent: agentName(agentRef: thread.agentRef, fallback: destination ?? thread.runtime.title),
          relativePath: relative(thread.resource?.file),
          date: thread.updatedAt,
          state: .working,
          target: .thread(thread.id)
        ))
      } else if thread.latestDeliveryNeedsAttention {
        representedThreadIDs.insert(thread.id)
        snapshot.needsYou.append(WorkspaceActivityItem(
          id: "thread:\(thread.id.uuidString)",
          kind: .needsYou,
          title: thread.title,
          detail: "Latest message needs attention",
          agent: agentName(agentRef: thread.agentRef, fallback: destination),
          relativePath: relative(thread.resource?.file),
          date: thread.updatedAt,
          state: .needsYou,
          target: .thread(thread.id)
        ))
      }
    }

    // Unified decision queue.
    var runIDsWithApprovals = Set<String>()
    let runsByID = Dictionary(agentRuns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for approval in approvalItems {
      if let runID = approval.runId { runIDsWithApprovals.insert(runID) }
      // Run-backed approvals live in .org2/runs; place them at the run's cited source.
      var approvalPath = relative(approval.file)
      if approvalPath?.hasPrefix(".org2/") == true,
         let run = approval.runId.flatMap({ runsByID[$0] }),
         let cited = run.context.lazy.compactMap({ relative($0.fileReference) }).first {
        approvalPath = cited
      }
      snapshot.needsYou.append(WorkspaceActivityItem(
        id: "approval:\(approval.id)",
        kind: .needsYou,
        title: Org2Display.cleanInline(approval.title),
        detail: approval.action.map { "Approve: \($0)" } ?? "Waiting for your decision",
        agent: approval.requestedFrom,
        relativePath: approvalPath,
        date: approval.requestedAt.flatMap(Self.activityDate),
        state: .needsYou,
        target: .approval(approval.id)
      ))
    }

    // Durable runs.
    for run in agentRuns where !run.isFinished {
      let threadID = Self.activityThreadID(in: run)
      let threadExists = threadID.map { id in aiChatThreads.contains { $0.id == id } } ?? false
      let threadRunning = threadID.map(isAIChatThreadRunning) ?? false
      guard let state = HeadingWorkStatus.state(for: run, threadRunning: threadRunning, hasThread: threadExists) else {
        continue
      }
      if let threadID, representedThreadIDs.contains(threadID), state == .working { continue }
      if state == .needsYou, runIDsWithApprovals.contains(run.id) { continue }
      let path = run.context.lazy.compactMap { relative($0.fileReference) }.first
      let title = run.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyActivity ?? run.goal
      let agent = agentName(agentRef: run.agentRef, fallback: run.assignee ?? run.owner)
      let item = WorkspaceActivityItem(
        id: "run:\(run.id)",
        kind: state.needsAttention ? .needsYou : .working,
        title: title,
        detail: Self.activityRunDetail(run, state: state),
        agent: agent,
        relativePath: path,
        date: Self.activityDate(run.updatedAt),
        state: state,
        target: threadExists && state != .needsYou ? .thread(threadID!) : .run(run.id)
      )
      if item.kind == .needsYou {
        snapshot.needsYou.append(item)
      } else {
        snapshot.working.append(item)
      }
    }

    // Scheduled automations.
    for workflow in agentWorkflows {
      guard let trigger = workflow.scheduleTrigger, trigger.enabled,
            let expression = trigger.schedule,
            workflow.state.lowercased() == "active"
      else { continue }
      let schedule = AutomationScheduleDraft(expression: expression).summary
      snapshot.scheduled.append(WorkspaceActivityItem(
        id: "workflow:\(workflow.id)",
        kind: .scheduled,
        title: workflow.title,
        detail: schedule,
        agent: agentName(agentRef: workflow.agentRef, fallback: workflow.destinationRef.flatMap { aiChatDestination(id: $0)?.title }),
        relativePath: relative(workflow.file),
        date: nil,
        state: nil,
        target: .workflow(workflow.id)
      ))
    }

    // Recently changed files.
    let recentCutoff = now.addingTimeInterval(-24 * 3600)
    snapshot.changed = corpusFiles
      .lazy
      .filter { ($0.modifiedAt ?? .distantPast) >= recentCutoff }
      .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
      .prefix(20)
      .map { file in
        WorkspaceActivityItem(
          id: "file:\(file.relativePath)",
          kind: .changed,
          title: file.name,
          detail: file.directory.isEmpty ? "Top level" : file.directory,
          relativePath: file.relativePath,
          date: file.modifiedAt,
          target: .file(path: file.path, line: nil)
        )
      }

    let byDateDescending: (WorkspaceActivityItem, WorkspaceActivityItem) -> Bool = {
      ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
    }
    snapshot.needsYou.sort(by: byDateDescending)
    snapshot.working.sort(by: byDateDescending)
    snapshot.scheduled.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    return snapshot
  }

  public func activityMapAreas(prefix: String, snapshot: WorkspaceActivitySnapshot, now: Date = Date()) -> [WorkspaceActivityArea] {
    WorkspaceActivityMap.areas(
      files: corpusFiles,
      items: snapshot.allItems,
      prefix: prefix,
      now: now,
      visitScores: fileFrecencyScores(now: now)
    )
  }

  public func openActivityItem(_ item: WorkspaceActivityItem) {
    usageLog.record(.activityOpen, ["kind": .string(item.kind.rawValue), "target": .string(Self.activityTargetKind(item.target))])
    switch item.target {
    case .thread(let id):
      openHeadingWork(threadID: id, runID: nil)
    case .run(let id):
      openHeadingWork(threadID: nil, runID: id)
    case .approval(let id):
      openReviewQueue()
      if let approval = approvalItems.first(where: { $0.id == id }) {
        selectApprovalItem(approval)
      }
    case .workflow(let id):
      openAutomations()
      if let workflow = agentWorkflows.first(where: { $0.id == id }) {
        selectAgentWorkflow(workflow)
      }
    case .file(let path, let line):
      setPendingNavigationSource("activity")
      openChatFileReference(AIChatFileReference(path: path, line: line))
    }
  }

  public func openActivityMapFile(relativePath: String) {
    guard let file = corpusFiles.first(where: { $0.relativePath == relativePath }) else { return }
    usageLog.record(.activityMapNavigate, ["action": "open_file"])
    setPendingNavigationSource("activity_map")
    selectCorpusFile(file, surface: selectedSurface)
  }

  func refreshActivitySources() async {
    await refreshAgentRuns()
    await refreshApprovals()
    await refreshAgentWorkflows()
  }

  private func relativePathOrName(_ path: String) -> String {
    let value = relativePath(path)
    return value.hasPrefix("/") ? URL(fileURLWithPath: path).lastPathComponent : value
  }

  nonisolated static func activityThreadID(in run: AgentRunItem) -> UUID? {
    for comment in run.comments.reversed() {
      guard let range = comment.body.range(
        of: #"AI chat thread:?\s+[0-9A-Fa-f-]{36}"#,
        options: .regularExpression
      ) else { continue }
      let match = comment.body[range]
      if let id = UUID(uuidString: String(match.suffix(36))) { return id }
    }
    return nil
  }

  nonisolated static func activityRunDetail(_ run: AgentRunItem, state: HeadingWorkState) -> String {
    switch state {
    case .yourTurn: return "Agent replied, waiting for you"
    case .needsYou:
      if let reason = run.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
        return "Blocked: \(reason)"
      }
      return run.pendingApprovals.isEmpty ? "Needs your review" : "Waiting for approval"
    case .failed: return run.failure.map { "Failed: \($0)" } ?? "Run failed"
    case .queued: return "Queued run"
    case .working: return run.workflowId.map { "Automation \($0) running" } ?? "Run in progress"
    case .done: return "Completed"
    }
  }

  nonisolated static func activityDate(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: raw)
  }

  private nonisolated static func activityTargetKind(_ target: WorkspaceActivityItem.Target) -> String {
    switch target {
    case .thread: "thread"
    case .run: "run"
    case .approval: "approval"
    case .workflow: "workflow"
    case .file: "file"
    }
  }
}

private extension String {
  var nilIfEmptyActivity: String? { isEmpty ? nil : self }
}
